const std = @import("std");
const bytecode = @import("frontend_bytecode");
const parser = @import("frontend_parser");
const ast_module = @import("frontend_ast");
const scope_module = @import("frontend_scope");
const gc = @import("runtime_gc");
const value_module = @import("runtime_value");
const number = @import("runtime_number");
const string = @import("runtime_string");
const exceptions = @import("runtime_exception");

const Ast = ast_module.Ast;
const Node = ast_module.Node;
const NodeId = ast_module.NodeId;
const Kind = ast_module.Kind;
const Span = ast_module.Span;
const Value = value_module.Value;
const Code = bytecode.Code;

pub const DiagnosticKind = enum { syntax_error, unsupported };

pub const Diagnostic = struct {
    kind: DiagnosticKind,
    message: []const u8,
    span: Span,
    line: usize,
    column: usize,
};

pub const CompileOutcome = union(enum) {
    ready: *Code,
    syntax_error: Diagnostic,
    unsupported: Diagnostic,
    python_exception: exceptions.PythonException,
};

/// Owns a short-lived parser and scope arena, then returns a code object whose
/// instructions, constants, names, filename and positions are session-owned.
pub fn compile(heap: *gc.Heap, source: []const u8, filename: []const u8) CompileOutcome {
    const parsed = parser.parse(std.heap.page_allocator, source) catch return memoryOutcome();
    switch (parsed) {
        .failure => |diagnostic| {
            const converted = Diagnostic{
                .kind = if (diagnostic.kind == .unsupported_feature) .unsupported else .syntax_error,
                .message = diagnostic.message,
                .span = diagnostic.span,
                .line = diagnostic.line,
                .column = diagnostic.column,
            };
            return if (converted.kind == .unsupported) .{ .unsupported = converted } else .{ .syntax_error = converted };
        },
        .ast => {},
    }
    var ast = parsed.ast;
    defer ast.deinit();

    const analyzed = scope_module.analyze(std.heap.page_allocator, &ast) catch return memoryOutcome();
    switch (analyzed) {
        .failure => |diagnostic| return .{ .syntax_error = .{
            .kind = .syntax_error,
            .message = diagnostic.message,
            .span = diagnostic.span,
            .line = diagnostic.line,
            .column = diagnostic.column,
        } },
        .analysis => {},
    }
    var analysis = analyzed.analysis;
    defer analysis.deinit();

    var scratch_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch_arena.deinit();
    var builder = Compiler.init(heap, &ast, &analysis, filename, scratch_arena.allocator());
    return builder.run();
}

pub const TempAllocator = struct {
    next: u32,
    high_water: u32,

    pub fn init(first_register: u32) TempAllocator {
        return .{ .next = first_register, .high_water = first_register };
    }

    pub fn acquire(self: *TempAllocator) error{RegisterOutOfRange}!u16 {
        if (self.next > std.math.maxInt(u16)) return error.RegisterOutOfRange;
        const register: u16 = @intCast(self.next);
        self.next += 1;
        self.high_water = @max(self.high_water, self.next);
        return register;
    }

    /// The expression compiler holds temporaries in strict LIFO order.
    pub fn release(self: *TempAllocator, register: u16) void {
        std.debug.assert(self.next == @as(u32, register) + 1);
        self.next -= 1;
    }
};

const BinaryOperation = enum(u8) {
    add,
    subtract,
    multiply,
    true_divide,
    floor_divide,
    modulo,
    power,
    bit_and,
    bit_or,
    bit_xor,
    shift_left,
    shift_right,
};

const UnaryOperation = enum(u8) { positive, negative, bit_not };
const CompileError = std.mem.Allocator.Error || error{Unsupported, PythonFault};

const Compiler = struct {
    heap: *gc.Heap,
    ast: *const Ast,
    analysis: *const scope_module.Analysis,
    allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    code: *Code,
    temps: TempAllocator = TempAllocator.init(0),
    instructions: std.ArrayList(bytecode.Instruction) = .empty,
    constants: std.ArrayList(Value) = .empty,
    names: std.ArrayList([]const u8) = .empty,
    argument_registers: std.ArrayList(u16) = .empty,
    positions: std.ArrayList(bytecode.SourcePosition) = .empty,
    diagnostic: ?Diagnostic = null,
    pending_exception: ?exceptions.PythonException = null,

    fn init(heap: *gc.Heap, ast: *const Ast, analysis: *const scope_module.Analysis, filename: []const u8, scratch_allocator: std.mem.Allocator) Compiler {
        const allocator = heap.allocator;
        const code = allocator.create(Code) catch return .{
            .heap = heap,
            .ast = ast,
            .analysis = analysis,
            .allocator = allocator,
            .scratch_allocator = scratch_allocator,
            .code = undefined,
            .pending_exception = .{ .kind = .memory_error, .message = "session memory limit exceeded" },
        };
        code.* = .{ .allocator = allocator };
        code.filename = allocator.dupe(u8, filename) catch {
            allocator.destroy(code);
            return .{ .heap = heap, .ast = ast, .analysis = analysis, .allocator = allocator, .scratch_allocator = scratch_allocator, .code = undefined, .pending_exception = .{ .kind = .memory_error, .message = "session memory limit exceeded" } };
        };
        code.display_name = allocator.dupe(u8, "<module>") catch {
            allocator.free(code.filename);
            allocator.destroy(code);
            return .{ .heap = heap, .ast = ast, .analysis = analysis, .allocator = allocator, .scratch_allocator = scratch_allocator, .code = undefined, .pending_exception = .{ .kind = .memory_error, .message = "session memory limit exceeded" } };
        };
        code.root_slots = allocator.alloc(gc.Root, ast.nodes.len) catch {
            allocator.free(code.display_name);
            allocator.free(code.filename);
            allocator.destroy(code);
            return .{ .heap = heap, .ast = ast, .analysis = analysis, .allocator = allocator, .scratch_allocator = scratch_allocator, .code = undefined, .pending_exception = .{ .kind = .memory_error, .message = "session memory limit exceeded" } };
        };
        @memset(code.root_slots, .{ .object = null });
        code.root_frame.push(&heap.roots);
        for (code.root_slots) |*root| code.root_frame.add(root);
        return .{ .heap = heap, .ast = ast, .analysis = analysis, .allocator = allocator, .scratch_allocator = scratch_allocator, .code = code };
    }

    fn run(self: *Compiler) CompileOutcome {
        if (self.pending_exception) |exception| return .{ .python_exception = exception };

        self.compileModule() catch |err| {
            self.discardCode();
            if (err == error.Unsupported or err == error.PythonFault) {
                if (self.pending_exception) |exception| return .{ .python_exception = exception };
                const diagnostic = self.diagnostic orelse unreachable;
                return if (diagnostic.kind == .unsupported) .{ .unsupported = diagnostic } else .{ .syntax_error = diagnostic };
            }
            return memoryOutcome();
        };

        self.code.register_count = self.temps.high_water;
        self.code.instructions = self.instructions.toOwnedSlice(self.allocator) catch {
            self.discardCode();
            return memoryOutcome();
        };
        self.code.constants = self.constants.toOwnedSlice(self.allocator) catch {
            self.discardCode();
            return memoryOutcome();
        };
        self.code.names = self.names.toOwnedSlice(self.allocator) catch {
            self.discardCode();
            return memoryOutcome();
        };
        self.code.argument_registers = self.argument_registers.toOwnedSlice(self.allocator) catch {
            self.discardCode();
            return memoryOutcome();
        };
        self.code.positions = self.positions.toOwnedSlice(self.allocator) catch {
            self.discardCode();
            return memoryOutcome();
        };
        return .{ .ready = self.code };
    }

    fn discardCode(self: *Compiler) void {
        for (self.names.items) |name| self.allocator.free(name);
        self.instructions.deinit(self.allocator);
        self.constants.deinit(self.allocator);
        self.names.deinit(self.allocator);
        self.argument_registers.deinit(self.allocator);
        self.positions.deinit(self.allocator);
        if (@intFromPtr(self.code) != 0) self.code.deinit(self.heap);
    }

    fn compileModule(self: *Compiler) CompileError!void {
        const root = self.ast.node(self.ast.root);
        if (root.kind != .module) return self.failUnsupported(root.span, "module code is required");
        for (self.ast.children(self.ast.root)) |statement| try self.compileStatement(statement);
        try self.emit(.return_value, 0, 0, 0, 0, root.span);
    }

    fn compileStatement(self: *Compiler, node_id: NodeId) CompileError!void {
        const node = self.ast.node(node_id);
        switch (node.kind) {
            .pass_statement => {},
            .expression_statement => {
                if (self.ast.children(node_id).len != 1) return self.failUnsupported(node.span, "expression statement shape is unsupported");
                const result = try self.compileExpression(self.ast.children(node_id)[0]);
                self.temps.release(result);
            },
            .assignment => try self.compileAssignment(node_id),
            else => return self.failUnsupported(node.span, statementUnsupportedMessage(node.kind)),
        }
    }

    fn compileAssignment(self: *Compiler, node_id: NodeId) CompileError!void {
        const children = self.ast.children(node_id);
        if (children.len < 2) return self.failUnsupported(self.ast.node(node_id).span, "assignment shape is unsupported");
        const value = try self.compileExpression(children[children.len - 1]);
        for (children[0 .. children.len - 1]) |target_id| {
            const target = self.ast.node(target_id);
            if (target.kind != .name) {
                self.temps.release(value);
                return self.failUnsupported(target.span, "attribute, subscript, and unpacking assignment are not implemented yet");
            }
            const name_index = try self.internName(target.text);
            try self.emitIndex(.store_global, value, name_index, 0, target.span);
        }
        self.temps.release(value);
    }

    fn compileExpression(self: *Compiler, node_id: NodeId) CompileError!u16 {
        const node = self.ast.node(node_id);
        switch (node.kind) {
            .integer_literal => {
                const parsed = number.parseIntegerLiteral(self.heap, node.text);
                const value = switch (parsed) {
                    .value => |item| item,
                    .python_exception => |exception| {
                        self.pending_exception = exception;
                        return error.PythonFault;
                    },
                    .engine_error => return error.PythonFault,
                };
                return self.loadConstant(value, node.span);
            },
            .float_literal => {
                const value = try self.parseFloat(node.text, node.span);
                return self.loadConstant(Value.fromFloat(value), node.span);
            },
            .string_literal => {
                const value = try self.parseString(node.text, node.span);
                return self.loadConstant(value, node.span);
            },
            .none_literal => return self.loadConstant(Value.noneValue(), node.span),
            .bool_literal => return self.loadConstant(if (std.mem.eql(u8, node.text, "True")) Value.trueValue() else Value.falseValue(), node.span),
            .name => {
                const name_index = try self.internName(node.text);
                const register = try self.acquire(node.span);
                try self.emitIndex(.load_global, register, name_index, 0, node.span);
                return register;
            },
            .unary_expression => return self.compileUnary(node_id),
            .binary_expression => return self.compileBinary(node_id),
            .call => return self.compileCall(node_id),
            else => return self.failUnsupported(node.span, expressionUnsupportedMessage(node.kind)),
        }
    }

    fn compileUnary(self: *Compiler, node_id: NodeId) CompileError!u16 {
        const node = self.ast.node(node_id);
        const operation: UnaryOperation = if (std.mem.eql(u8, node.text, "+")) .positive else if (std.mem.eql(u8, node.text, "-")) .negative else if (std.mem.eql(u8, node.text, "~")) .bit_not else return self.failUnsupported(node.span, "this unary operator is not implemented yet");
        const children = self.ast.children(node_id);
        if (children.len != 1) return self.failUnsupported(node.span, "unary expression shape is unsupported");
        const operand = try self.compileExpression(children[0]);
        try self.emit(.unary, operand, 0, 0, @intFromEnum(operation), node.span);
        return operand;
    }

    fn compileBinary(self: *Compiler, node_id: NodeId) CompileError!u16 {
        const node = self.ast.node(node_id);
        const operation = binaryOperation(node.text) orelse return self.failUnsupported(node.span, "this binary operator is not implemented yet");
        const children = self.ast.children(node_id);
        if (children.len != 2) return self.failUnsupported(node.span, "binary expression shape is unsupported");
        const left = try self.compileExpression(children[0]);
        const right = self.compileExpression(children[1]) catch |err| {
            self.temps.release(left);
            return err;
        };
        try self.emit(.binary, left, right, 0, @intFromEnum(operation), node.span);
        self.temps.release(right);
        return left;
    }

    fn compileCall(self: *Compiler, node_id: NodeId) CompileError!u16 {
        const node = self.ast.node(node_id);
        const children = self.ast.children(node_id);
        if (children.len == 0) return self.failUnsupported(node.span, "call shape is unsupported");
        const callee = self.ast.node(children[0]);
        if (callee.kind != .name or !std.mem.eql(u8, callee.text, "print")) {
            return self.failUnsupported(callee.span, "only direct calls to the builtin print are implemented in this commit");
        }

        const count = children.len - 1;
        if (count > std.math.maxInt(u16)) return self.failUnsupported(node.span, "print has more than 65,535 positional arguments");
        const held = self.scratch_allocator.alloc(u16, count) catch return error.OutOfMemory;
        var held_count: usize = 0;
        errdefer while (held_count > 0) {
            held_count -= 1;
            self.temps.release(held[held_count]);
        };

        for (children[1..]) |argument_id| {
            const argument = self.ast.node(argument_id);
            if (argument.kind == .keyword_argument) return self.failUnsupported(argument.span, "print keyword arguments are not implemented yet");
            const register = try self.compileExpression(argument_id);
            held[held_count] = register;
            held_count += 1;
        }
        const argument_start = self.argument_registers.items.len;
        const start32 = std.math.cast(u32, argument_start) orelse return self.failUnsupported(node.span, "code object has too many call operands");
        try self.argument_registers.appendSlice(self.allocator, held[0..held_count]);
        try self.emitIndex(.print, @intCast(count), start32, 0, node.span);
        while (held_count > 0) {
            held_count -= 1;
            self.temps.release(held[held_count]);
        }
        return self.loadConstant(Value.noneValue(), node.span);
    }

    fn parseFloat(self: *Compiler, spelling: []const u8, span: Span) CompileError!f64 {
        const scratch = self.scratch_allocator.alloc(u8, spelling.len) catch return error.OutOfMemory;
        var output_len: usize = 0;
        for (spelling) |character| {
            if (character == '_') continue;
            scratch[output_len] = character;
            output_len += 1;
        }
        return std.fmt.parseFloat(f64, scratch[0..output_len]) catch self.failSyntax(span, "invalid float literal");
    }

    fn parseString(self: *Compiler, spelling: []const u8, span: Span) CompileError!Value {
        var quote_index: usize = 0;
        while (quote_index < spelling.len and spelling[quote_index] != '\'' and spelling[quote_index] != '"') : (quote_index += 1) {}
        if (quote_index == spelling.len) return self.failSyntax(span, "invalid string literal");
        const prefix = spelling[0..quote_index];
        for (prefix) |character| {
            if (character == 'b' or character == 'B') return self.failUnsupported(span, "bytes literals are not implemented in this commit");
            if (character == 'f' or character == 'F') return self.failUnsupported(span, "f-string execution is not implemented in this commit");
        }
        const raw = std.mem.indexOfAny(u8, prefix, "rR") != null;
        const delimiter_len: usize = if (quote_index + 2 < spelling.len and spelling[quote_index + 1] == spelling[quote_index] and spelling[quote_index + 2] == spelling[quote_index]) 3 else 1;
        if (spelling.len < quote_index + delimiter_len * 2) return self.failSyntax(span, "unterminated string literal");
        const content = spelling[quote_index + delimiter_len .. spelling.len - delimiter_len];
        const allocator = self.scratch_allocator;
        var decoded: std.ArrayList(u8) = .empty;
        if (raw) {
            decoded.appendSlice(allocator, content) catch return error.OutOfMemory;
        } else {
            try decodeEscapes(allocator, &decoded, content, self, span);
        }
        const created = string.create(self.heap, decoded.items);
        return switch (created) {
            .value => |object| Value.object(&object.header),
            .python_exception => |exception| blk: {
                self.pending_exception = exception;
                break :blk error.PythonFault;
            },
            .engine_error => error.PythonFault,
        };
    }

    fn loadConstant(self: *Compiler, value: Value, span: Span) CompileError!u16 {
        const constant_index = std.math.cast(u32, self.constants.items.len) orelse return self.failUnsupported(span, "code object has too many constants");
        if (constant_index >= self.code.root_slots.len) return self.failUnsupported(span, "code object constant bound exceeded");
        self.code.root_slots[constant_index].object = value.asObject();
        try self.constants.append(self.allocator, value);
        const register = try self.acquire(span);
        try self.emitIndex(.load_const, register, constant_index, 0, span);
        return register;
    }

    fn internName(self: *Compiler, name: []const u8) std.mem.Allocator.Error!u32 {
        for (self.names.items, 0..) |existing, index| {
            if (std.mem.eql(u8, existing, name)) return @intCast(index);
        }
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        try self.names.append(self.allocator, owned);
        return @intCast(self.names.items.len - 1);
    }

    fn acquire(self: *Compiler, span: Span) CompileError!u16 {
        return self.temps.acquire() catch self.failUnsupported(span, "code object exceeds the 65,535-register limit");
    }

    fn emitIndex(self: *Compiler, op: bytecode.Opcode, a: u32, index: u32, flags: u8, span: Span) CompileError!void {
        const instruction = bytecode.Instruction.withIndex32(op, a, index, flags) catch return self.failUnsupported(span, "code object register operand is out of range");
        try self.appendInstruction(instruction, span);
    }

    fn emit(self: *Compiler, op: bytecode.Opcode, a: u32, b: u32, c: u32, flags: u8, span: Span) CompileError!void {
        const instruction = bytecode.Instruction.init(op, a, b, c, flags) catch return self.failUnsupported(span, "code object register operand is out of range");
        try self.appendInstruction(instruction, span);
    }

    fn appendInstruction(self: *Compiler, instruction: bytecode.Instruction, span: Span) std.mem.Allocator.Error!void {
        try self.instructions.append(self.allocator, instruction);
        const location = lineColumn(self.ast.source, span.start);
        try self.positions.append(self.allocator, .{
            .start = @intCast(span.start),
            .end = @intCast(span.end),
            .line = @intCast(location.line),
            .column = @intCast(location.column),
        });
    }

    fn failUnsupported(self: *Compiler, span: Span, message: []const u8) CompileError {
        self.diagnostic = .{ .kind = .unsupported, .message = message, .span = span, .line = lineColumn(self.ast.source, span.start).line, .column = lineColumn(self.ast.source, span.start).column };
        return error.Unsupported;
    }

    fn failSyntax(self: *Compiler, span: Span, message: []const u8) CompileError {
        self.diagnostic = .{ .kind = .syntax_error, .message = message, .span = span, .line = lineColumn(self.ast.source, span.start).line, .column = lineColumn(self.ast.source, span.start).column };
        return error.Unsupported;
    }
};

fn decodeEscapes(allocator: std.mem.Allocator, output: *std.ArrayList(u8), input: []const u8, compiler: *Compiler, span: Span) CompileError!void {
    var index: usize = 0;
    while (index < input.len) {
        if (input[index] != '\\') {
            try output.append(allocator, input[index]);
            index += 1;
            continue;
        }
        index += 1;
        if (index >= input.len) return compiler.failSyntax(span, "trailing backslash in string literal");
        const escape = input[index];
        index += 1;
        const simple: ?u8 = switch (escape) {
            '\\' => '\\', '\'' => '\'', '"' => '"', 'a' => 7, 'b' => 8, 'f' => 12, 'n' => '\n', 'r' => '\r', 't' => '\t', 'v' => 11,
            else => null,
        };
        if (simple) |value| {
            try output.append(allocator, value);
            continue;
        }
        if (escape == '\n') continue;
        if (escape == '\r' and index < input.len and input[index] == '\n') {
            index += 1;
            continue;
        }
        if (escape == 'x' or escape == 'u' or escape == 'U') {
            const digits: usize = if (escape == 'x') 2 else if (escape == 'u') 4 else 8;
            if (input.len - index < digits) return compiler.failSyntax(span, "truncated hexadecimal escape");
            var codepoint: u32 = 0;
            for (input[index .. index + digits]) |character| {
                const digit = std.fmt.charToDigit(character, 16) catch return compiler.failSyntax(span, "invalid hexadecimal escape");
                codepoint = (codepoint << 4) | digit;
            }
                index += digits;
                if (escape == 'x') {
                    try output.append(allocator, @intCast(codepoint));
                } else {
                    var encoded: [4]u8 = undefined;
                    const codepoint_u21 = std.math.cast(u21, codepoint) orelse return compiler.failSyntax(span, "invalid Unicode escape");
                    const len = std.unicode.utf8Encode(codepoint_u21, &encoded) catch return compiler.failSyntax(span, "invalid Unicode escape");
                    try output.appendSlice(allocator, encoded[0..len]);
                }
            continue;
        }
        if (escape >= '0' and escape <= '7') {
            var value: u16 = escape - '0';
            var count: usize = 1;
            while (count < 3 and index < input.len and input[index] >= '0' and input[index] <= '7') : (count += 1) {
                value = value * 8 + (input[index] - '0');
                index += 1;
            }
            try output.append(allocator, @truncate(value));
            continue;
        }
        try output.append(allocator, '\\');
        try output.append(allocator, escape);
    }
}

fn binaryOperation(spelling: []const u8) ?BinaryOperation {
    if (std.mem.eql(u8, spelling, "+")) return .add;
    if (std.mem.eql(u8, spelling, "-")) return .subtract;
    if (std.mem.eql(u8, spelling, "*")) return .multiply;
    if (std.mem.eql(u8, spelling, "/")) return .true_divide;
    if (std.mem.eql(u8, spelling, "//")) return .floor_divide;
    if (std.mem.eql(u8, spelling, "%")) return .modulo;
    if (std.mem.eql(u8, spelling, "**")) return .power;
    if (std.mem.eql(u8, spelling, "&")) return .bit_and;
    if (std.mem.eql(u8, spelling, "|")) return .bit_or;
    if (std.mem.eql(u8, spelling, "^")) return .bit_xor;
    if (std.mem.eql(u8, spelling, "<<")) return .shift_left;
    if (std.mem.eql(u8, spelling, ">>")) return .shift_right;
    return null;
}

fn statementUnsupportedMessage(kind: Kind) []const u8 {
    return switch (kind) {
        .if_statement => "if statements are not implemented yet",
        .while_statement => "while loops are not implemented yet",
        .for_statement => "for loops are not implemented yet",
        .function_definition => "function definitions are not implemented yet",
        .class_definition => "class definitions are not implemented yet",
        .delete_statement => "delete statements are not implemented yet",
        .augmented_assignment => "augmented assignment is not implemented yet",
        .annotated_assignment => "annotated assignment is not implemented yet",
        .return_statement => "return statements are not implemented at module scope",
        .raise_statement => "raise statements are not implemented yet",
        .assert_statement => "assert statements are not implemented yet",
        .global_statement, .nonlocal_statement => "scope declarations are not executable yet",
        .import_statement => "import statements are not implemented yet",
        else => "this statement is not implemented yet",
    };
}

fn expressionUnsupportedMessage(kind: Kind) []const u8 {
    return switch (kind) {
        .boolean_expression => "boolean operators are not implemented yet",
        .comparison_chain => "comparisons are not implemented yet",
        .conditional_expression => "conditional expressions are not implemented yet",
        .tuple_display, .list_display, .set_display, .dict_display => "container displays are not implemented yet",
        .attribute => "attribute access is not implemented yet",
        .subscript => "subscription is not implemented yet",
        .lambda_expression => "lambda execution is not implemented yet",
        .named_expression => "assignment expressions are not implemented yet",
        .formatted_string_literal => "f-string execution is not implemented yet",
        .bytes_literal => "bytes literals are not implemented in this commit",
        else => "this expression is not implemented yet",
    };
}

fn lineColumn(source: []const u8, offset: usize) struct { line: usize, column: usize } {
    const limit = @min(offset, source.len);
    var line: usize = 1;
    var column: usize = 1;
    var index: usize = 0;
    while (index < limit) : (index += 1) {
        if (source[index] == '\n') {
            line += 1;
            column = 1;
        } else if (source[index] & 0xc0 != 0x80) {
            column += 1;
        }
    }
    return .{ .line = line, .column = column };
}

fn memoryOutcome() CompileOutcome {
    return .{ .python_exception = .{ .kind = .memory_error, .message = "session memory limit exceeded" } };
}
