const std = @import("std");
const bytecode = @import("frontend_bytecode");
const parser = @import("frontend_parser");
const ast_module = @import("frontend_ast");
const scope_module = @import("frontend_scope");
const gc = @import("runtime_gc");
const value_module = @import("runtime_value");
const number = @import("runtime_number");
const string = @import("runtime_string");
const bytes = @import("runtime_bytes");
const exceptions = @import("runtime_exception");

const Ast = ast_module.Ast;
const Node = ast_module.Node;
const NodeId = ast_module.NodeId;
const Kind = ast_module.Kind;
const Span = ast_module.Span;
const Value = value_module.Value;
const Code = bytecode.Code;
const Binding = scope_module.Binding;

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
    if (builder.pending_exception) |exception| return .{ .python_exception = exception };
    var root_cursor: usize = 0;
    builder.root_owner = builder.code;
    builder.root_cursor = &root_cursor;
    builder.scope_id = analysis.scopeForNode(ast.root);
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

const UnaryOperation = enum(u8) { positive, negative, bit_not, logical_not };
const CompileError = std.mem.Allocator.Error || error{Unsupported, PythonFault};

const LoopContext = struct {
    continue_target: u32,
    break_jumps: std.ArrayList(u32) = .empty,
};

const Compiler = struct {
    heap: *gc.Heap,
    ast: *const Ast,
    analysis: *const scope_module.Analysis,
    allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    code: *Code,
    scope_id: ?scope_module.ScopeId = null,
    root_owner: ?*Code = null,
    root_cursor: ?*usize = null,
    temps: TempAllocator = TempAllocator.init(0),
    instructions: std.ArrayList(bytecode.Instruction) = .empty,
    constants: std.ArrayList(Value) = .empty,
    names: std.ArrayList([]const u8) = .empty,
    argument_registers: std.ArrayList(u16) = .empty,
    call_arguments: std.ArrayList(bytecode.CallArgument) = .empty,
    call_sites: std.ArrayList(bytecode.CallSite) = .empty,
    dstar_previous_arguments: std.ArrayList(bytecode.CallArgument) = .empty,
    dstar_sites: std.ArrayList(bytecode.DstarSite) = .empty,
    function_sites: std.ArrayList(bytecode.FunctionSite) = .empty,
    unpack_sites: std.ArrayList(bytecode.UnpackSite) = .empty,
    sequence_sites: std.ArrayList(bytecode.SequenceSite) = .empty,
    slice_sites: std.ArrayList(bytecode.SliceSite) = .empty,
    nested_codes: std.ArrayList(*Code) = .empty,
    local_names: std.ArrayList([]const u8) = .empty,
    cell_names: std.ArrayList([]const u8) = .empty,
    free_names: std.ArrayList([]const u8) = .empty,
    parameter_names: std.ArrayList([]const u8) = .empty,
    parameter_flags: std.ArrayList(u32) = .empty,
    positions: std.ArrayList(bytecode.SourcePosition) = .empty,
    diagnostic: ?Diagnostic = null,
    pending_exception: ?exceptions.PythonException = null,
    loop_stack: std.ArrayList(LoopContext) = .empty,

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

    fn initNested(parent: *Compiler, scope_id: scope_module.ScopeId, display_name: []const u8) std.mem.Allocator.Error!Compiler {
        const allocator = parent.heap.allocator;
        const code = allocator.create(Code) catch return error.OutOfMemory;
        code.* = .{ .allocator = allocator, .flags = bytecode.code_flags.function };
        code.filename = allocator.dupe(u8, parent.code.filename) catch {
            allocator.destroy(code);
            return error.OutOfMemory;
        };
        code.display_name = allocator.dupe(u8, display_name) catch {
            allocator.free(code.filename);
            allocator.destroy(code);
            return error.OutOfMemory;
        };

        var nested = Compiler{
            .heap = parent.heap,
            .ast = parent.ast,
            .analysis = parent.analysis,
            .allocator = allocator,
            .scratch_allocator = parent.scratch_allocator,
            .code = code,
            .scope_id = scope_id,
            .root_owner = parent.root_owner,
            .root_cursor = parent.root_cursor,
        };
        for (parent.analysis.scope(scope_id).symbols) |symbol| {
            const target: ?*std.ArrayList([]const u8) = switch (symbol.binding) {
                .local => &nested.local_names,
                .cell => &nested.cell_names,
                .free => &nested.free_names,
                .global_explicit, .global_implicit, .class_local => null,
            };
            if (target) |names| {
                const owned = allocator.dupe(u8, symbol.name) catch {
                    nested.discardCode();
                    return error.OutOfMemory;
                };
                names.append(allocator, owned) catch {
                    allocator.free(owned);
                    nested.discardCode();
                    return error.OutOfMemory;
                };
            }
        }
        return nested;
    }

    fn appendParameterMetadata(self: *Compiler, parameters: []const NodeId) CompileError!void {
        var positional_count: u32 = 0;
        var positional_only_count: u32 = 0;
        var keyword_only_count: u32 = 0;
        var has_var_positional = false;
        var has_var_keyword = false;
        for (parameters) |parameter_id| {
            const parameter = self.ast.node(parameter_id);
            if (parameter.kind != .parameter) return self.failUnsupported(parameter.span, "function parameter shape is unsupported");
            if (parameter.flags & ast_module.parameter_flags.var_positional != 0) has_var_positional = true;
            if (parameter.flags & ast_module.parameter_flags.var_keyword != 0) has_var_keyword = true;
            const parameter_name = self.allocator.dupe(u8, parameter.text) catch return error.OutOfMemory;
            self.parameter_names.append(self.allocator, parameter_name) catch {
                self.allocator.free(parameter_name);
                return error.OutOfMemory;
            };
            try self.parameter_flags.append(self.allocator, parameter.flags);
            if (parameter.flags & ast_module.parameter_flags.keyword_only != 0) {
                keyword_only_count += 1;
            } else if (parameter.flags & ast_module.parameter_flags.var_positional == 0) {
                positional_count += 1;
                if (parameter.flags & ast_module.parameter_flags.positional_only != 0) positional_only_count += 1;
            }
        }
        self.code.signature = .{
            .positional_count = std.math.cast(u16, positional_count) orelse return self.failUnsupported(if (parameters.len != 0) self.ast.node(parameters[0]).span else self.ast.node(self.ast.root).span, "too many function parameters"),
            .positional_only_count = std.math.cast(u16, positional_only_count) orelse return error.Unsupported,
            .keyword_only_count = std.math.cast(u16, keyword_only_count) orelse return error.Unsupported,
            .var_positional = has_var_positional,
            .var_keyword = has_var_keyword,
        };
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

        const completed = self.finishCode() catch {
            self.discardCode();
            return memoryOutcome();
        };
        return .{ .ready = completed };
    }

    fn finishCode(self: *Compiler) std.mem.Allocator.Error!*Code {
        self.code.register_count = self.temps.high_water;
        self.code.instructions = try self.instructions.toOwnedSlice(self.allocator);
        self.code.constants = try self.constants.toOwnedSlice(self.allocator);
        self.code.names = try self.names.toOwnedSlice(self.allocator);
        self.code.local_names = try self.local_names.toOwnedSlice(self.allocator);
        self.code.cell_names = try self.cell_names.toOwnedSlice(self.allocator);
        self.code.free_names = try self.free_names.toOwnedSlice(self.allocator);
        self.code.parameter_names = try self.parameter_names.toOwnedSlice(self.allocator);
        self.code.parameter_flags = try self.parameter_flags.toOwnedSlice(self.allocator);
        self.code.argument_registers = try self.argument_registers.toOwnedSlice(self.allocator);
        self.code.call_arguments = try self.call_arguments.toOwnedSlice(self.allocator);
        self.code.call_sites = try self.call_sites.toOwnedSlice(self.allocator);
        self.code.dstar_previous_arguments = try self.dstar_previous_arguments.toOwnedSlice(self.allocator);
        self.code.dstar_sites = try self.dstar_sites.toOwnedSlice(self.allocator);
        self.code.function_sites = try self.function_sites.toOwnedSlice(self.allocator);
        self.code.unpack_sites = try self.unpack_sites.toOwnedSlice(self.allocator);
        self.code.sequence_sites = try self.sequence_sites.toOwnedSlice(self.allocator);
        self.code.slice_sites = try self.slice_sites.toOwnedSlice(self.allocator);
        self.code.nested_codes = try self.nested_codes.toOwnedSlice(self.allocator);
        self.code.positions = try self.positions.toOwnedSlice(self.allocator);
        return self.code;
    }

    fn discardCode(self: *Compiler) void {
        for (self.nested_codes.items) |child| child.deinit(self.heap);
        for (self.names.items) |name| self.allocator.free(name);
        for (self.local_names.items) |name| self.allocator.free(name);
        for (self.cell_names.items) |name| self.allocator.free(name);
        for (self.free_names.items) |name| self.allocator.free(name);
        for (self.parameter_names.items) |name| self.allocator.free(name);
        self.instructions.deinit(self.allocator);
        self.constants.deinit(self.allocator);
        self.names.deinit(self.allocator);
        self.local_names.deinit(self.allocator);
        self.cell_names.deinit(self.allocator);
        self.free_names.deinit(self.allocator);
        self.parameter_names.deinit(self.allocator);
        self.parameter_flags.deinit(self.allocator);
        self.argument_registers.deinit(self.allocator);
        self.call_arguments.deinit(self.allocator);
        self.call_sites.deinit(self.allocator);
        self.dstar_previous_arguments.deinit(self.allocator);
        self.dstar_sites.deinit(self.allocator);
        self.function_sites.deinit(self.allocator);
        self.unpack_sites.deinit(self.allocator);
        self.sequence_sites.deinit(self.allocator);
        self.slice_sites.deinit(self.allocator);
        self.nested_codes.deinit(self.allocator);
        self.positions.deinit(self.allocator);
        if (@intFromPtr(self.code) != 0) self.code.deinit(self.heap);
    }

    fn compileModule(self: *Compiler) CompileError!void {
        const root = self.ast.node(self.ast.root);
        if (root.kind != .module) return self.failUnsupported(root.span, "module code is required");
        for (self.ast.children(self.ast.root)) |statement| try self.compileStatement(statement);
        const none = try self.loadConstant(Value.noneValue(), root.span);
        try self.emit(.return_value, none, 0, 0, 0, root.span);
        self.temps.release(none);
    }

    fn compileStatement(self: *Compiler, node_id: NodeId) CompileError!void {
        const node = self.ast.node(node_id);
        switch (node.kind) {
            .pass_statement => {},
            .block => try self.compileBlock(node_id),
            .function_definition => try self.compileFunctionDefinition(node_id),
            .delete_statement => try self.compileDelete(node_id),
            .return_statement => try self.compileReturn(node_id),
            .global_statement, .nonlocal_statement => {},
            .expression_statement => {
                if (self.ast.children(node_id).len != 1) return self.failUnsupported(node.span, "expression statement shape is unsupported");
                const result = try self.compileExpression(self.ast.children(node_id)[0]);
                self.temps.release(result);
            },
            .assignment => try self.compileAssignment(node_id),
            .augmented_assignment => try self.compileAugmentedAssignment(node_id),
            .if_statement => try self.compileIf(node_id),
            .while_statement => try self.compileWhile(node_id),
            .for_statement => try self.compileFor(node_id),
            .break_statement => try self.compileBreak(node_id),
            .continue_statement => try self.compileContinue(node_id),
            else => return self.failUnsupported(node.span, statementUnsupportedMessage(node.kind)),
        }
    }

    fn compileBlock(self: *Compiler, node_id: NodeId) CompileError!void {
        for (self.ast.children(node_id)) |statement| try self.compileStatement(statement);
    }

    fn compileReturn(self: *Compiler, node_id: NodeId) CompileError!void {
        const node = self.ast.node(node_id);
        if (self.code.flags & bytecode.code_flags.function == 0) return self.failUnsupported(node.span, "return is only supported inside a function");
        const children = self.ast.children(node_id);
        const result = if (children.len == 0) try self.loadConstant(Value.noneValue(), node.span) else try self.compileExpression(children[0]);
        try self.emit(.return_value, result, 0, 0, 0, node.span);
        self.temps.release(result);
    }

    fn compileFunctionDefinition(self: *Compiler, node_id: NodeId) CompileError!void {
        const node = self.ast.node(node_id);
        const children = self.ast.children(node_id);
        if (children.len == 0) return self.failUnsupported(node.span, "function definition shape is unsupported");
        const body_id = children[children.len - 1];
        const has_return_annotation = node.flags & ast_module.function_flags.has_return_annotation != 0;
        const return_annotation_id: ?NodeId = if (has_return_annotation) children[children.len - 2] else null;
        const parameter_end = children.len - 1 - @as(usize, @intFromBool(has_return_annotation));
        const parameter_ids = children[0..parameter_end];
        const function_scope = self.analysis.scopeForNode(body_id) orelse return self.failUnsupported(node.span, "function scope metadata is missing");
        const nested_code = try self.compileNestedFunction(function_scope, node.text, body_id, parameter_ids, node.span);
        const nested_index = std.math.cast(u32, self.nested_codes.items.len) orelse return self.failUnsupported(node.span, "too many nested code objects");
        self.nested_codes.append(self.allocator, nested_code) catch {
            nested_code.deinit(self.heap);
            return error.OutOfMemory;
        };

        var held: std.ArrayList(u16) = .empty;
        defer held.deinit(self.scratch_allocator);
        var values: std.ArrayList(u16) = .empty;
        defer values.deinit(self.scratch_allocator);
        var default_count: u32 = 0;
        var annotation_count: u32 = 0;

        // CPython evaluates every default before any parameter annotation.
        for (parameter_ids) |parameter_id| {
            const parameter = self.ast.node(parameter_id);
            if (parameter.flags & ast_module.parameter_flags.has_default == 0) continue;
            const children_of_parameter = self.ast.children(parameter_id);
            const default_index: usize = if (parameter.flags & ast_module.parameter_flags.has_annotation != 0) 1 else 0;
            const result = try self.compileExpression(children_of_parameter[default_index]);
            try held.append(self.scratch_allocator, result);
            try values.append(self.scratch_allocator, result);
            default_count += 1;
        }
        for (parameter_ids) |parameter_id| {
            const parameter = self.ast.node(parameter_id);
            if (parameter.flags & ast_module.parameter_flags.has_annotation == 0) continue;
            const annotation = try self.compileExpression(self.ast.children(parameter_id)[0]);
            try held.append(self.scratch_allocator, annotation);
            try values.append(self.scratch_allocator, annotation);
            annotation_count += 1;
        }
        if (return_annotation_id) |annotation_id| {
            const annotation = try self.compileExpression(annotation_id);
            try held.append(self.scratch_allocator, annotation);
            try values.append(self.scratch_allocator, annotation);
        }

        const value_start = std.math.cast(u32, self.argument_registers.items.len) orelse return self.failUnsupported(node.span, "code object has too many function values");
        try self.argument_registers.appendSlice(self.allocator, values.items);
        const site_index = std.math.cast(u32, self.function_sites.items.len) orelse return self.failUnsupported(node.span, "too many function definition sites");
        try self.function_sites.append(self.allocator, .{
            .code_index = nested_index,
            .value_start = value_start,
            .default_count = std.math.cast(u16, default_count) orelse return self.failUnsupported(node.span, "too many default values"),
            .annotation_count = std.math.cast(u16, annotation_count) orelse return self.failUnsupported(node.span, "too many annotations"),
            .has_return_annotation = has_return_annotation,
        });
        const destination = try self.acquire(node.span);
        try self.emitIndex(.make_function, destination, site_index, 0, node.span);
        const binding = self.analysis.symbol(self.scope_id orelse 0, node.text) orelse return self.failUnsupported(node.span, "function name binding metadata is missing");
        try self.compileStoreName(destination, node.text, binding.binding, node.span);
        self.temps.release(destination);
        while (held.items.len != 0) self.temps.release(held.pop().?);
    }

    fn compileNestedFunction(
        self: *Compiler,
        scope_id: scope_module.ScopeId,
        display_name: []const u8,
        body_id: NodeId,
        parameter_ids: []const NodeId,
        span: Span,
    ) CompileError!*Code {
        var nested = Compiler.initNested(self, scope_id, display_name) catch return error.OutOfMemory;
        var keep_code = false;
        defer if (!keep_code) nested.discardCode();
        nested.appendParameterMetadata(parameter_ids) catch |err| {
            self.diagnostic = nested.diagnostic;
            self.pending_exception = nested.pending_exception;
            return err;
        };
        nested.compileStatement(body_id) catch |err| {
            self.diagnostic = nested.diagnostic;
            self.pending_exception = nested.pending_exception;
            return err;
        };
        const none = nested.loadConstant(Value.noneValue(), span) catch |err| {
            self.diagnostic = nested.diagnostic;
            self.pending_exception = nested.pending_exception;
            return err;
        };
        nested.emit(.return_value, none, 0, 0, 0, span) catch |err| {
            self.diagnostic = nested.diagnostic;
            self.pending_exception = nested.pending_exception;
            return err;
        };
        nested.temps.release(none);
        const code = nested.finishCode() catch return error.OutOfMemory;
        keep_code = true;
        return code;
    }

    fn compileIf(self: *Compiler, node_id: NodeId) CompileError!void {
        const node = self.ast.node(node_id);
        const children = self.ast.children(node_id);
        if (children.len < 2 or children.len > 3) return self.failUnsupported(node.span, "if statement shape is unsupported");
        const condition = try self.compileExpression(children[0]);
        const false_jump = try self.emitJump(.jump_if_false, condition, 0, self.ast.node(children[0]).span);
        self.temps.release(condition);
        try self.compileStatement(children[1]);
        if (children.len == 3) {
            const end_jump = try self.emitJump(.jump, 0, 0, node.span);
            try self.patchJump(false_jump, try self.currentTarget(node.span));
            try self.compileStatement(children[2]);
            try self.patchJump(end_jump, try self.currentTarget(node.span));
        } else {
            try self.patchJump(false_jump, try self.currentTarget(node.span));
        }
    }

    fn compileWhile(self: *Compiler, node_id: NodeId) CompileError!void {
        const node = self.ast.node(node_id);
        const children = self.ast.children(node_id);
        if (children.len < 2 or children.len > 3) return self.failUnsupported(node.span, "while statement shape is unsupported");
        const test_target = try self.currentTarget(node.span);
        const condition = try self.compileExpression(children[0]);
        const exhausted = try self.emitJump(.jump_if_false, condition, 0, self.ast.node(children[0]).span);
        self.temps.release(condition);

        try self.loop_stack.append(self.scratch_allocator, .{ .continue_target = test_target });
        try self.compileStatement(children[1]);
        const context = self.loop_stack.pop().?;
        _ = try self.emitJump(.jump, 0, test_target, node.span);

        const else_target = try self.currentTarget(node.span);
        try self.patchJump(exhausted, else_target);
        if (children.len == 3) try self.compileStatement(children[2]);
        const end_target = try self.currentTarget(node.span);
        for (context.break_jumps.items) |jump_index| try self.patchJump(jump_index, end_target);
    }

    fn compileFor(self: *Compiler, node_id: NodeId) CompileError!void {
        const node = self.ast.node(node_id);
        const children = self.ast.children(node_id);
        if (children.len < 3 or children.len > 4) return self.failUnsupported(node.span, "for statement shape is unsupported");
        const target_node = self.ast.node(children[0]);
        const iterable_node = self.ast.node(children[1]);

        const source = try self.compileExpression(children[1]);
        const iterator_register = source;
        try self.emit(.get_iterator, iterator_register, source, 0, 0, iterable_node.span);
        const item_register = try self.acquire(target_node.span);
        const has_item_register = try self.acquire(target_node.span);
        const loop_start = try self.currentTarget(node.span);
        try self.emit(.for_next, item_register, iterator_register, has_item_register, 0, node.span);
        const exhausted = try self.emitJump(.jump_if_false, has_item_register, 0, node.span);
        try self.compileStoreTarget(children[0], item_register);

        try self.loop_stack.append(self.scratch_allocator, .{ .continue_target = loop_start });
        try self.compileStatement(children[2]);
        const context = self.loop_stack.pop().?;
        _ = try self.emitJump(.jump, 0, loop_start, node.span);

        const else_target = try self.currentTarget(node.span);
        try self.patchJump(exhausted, else_target);
        if (children.len == 4) try self.compileStatement(children[3]);
        const end_target = try self.currentTarget(node.span);
        for (context.break_jumps.items) |jump_index| try self.patchJump(jump_index, end_target);
        self.temps.release(has_item_register);
        self.temps.release(item_register);
        self.temps.release(iterator_register);
    }

    fn compileBreak(self: *Compiler, node_id: NodeId) CompileError!void {
        if (self.loop_stack.items.len == 0) return self.failUnsupported(self.ast.node(node_id).span, "break outside loop");
        const jump_index = try self.emitJump(.jump, 0, 0, self.ast.node(node_id).span);
        try self.loop_stack.items[self.loop_stack.items.len - 1].break_jumps.append(self.scratch_allocator, jump_index);
    }

    fn compileContinue(self: *Compiler, node_id: NodeId) CompileError!void {
        if (self.loop_stack.items.len == 0) return self.failUnsupported(self.ast.node(node_id).span, "continue outside loop");
        const target = self.loop_stack.items[self.loop_stack.items.len - 1].continue_target;
        _ = try self.emitJump(.jump, 0, target, self.ast.node(node_id).span);
    }

    fn compileAugmentedAssignment(self: *Compiler, node_id: NodeId) CompileError!void {
        const node = self.ast.node(node_id);
        const children = self.ast.children(node_id);
        if (children.len != 2) return self.failUnsupported(node.span, "augmented assignment shape is unsupported");
        const target = self.ast.node(children[0]);
        if (target.kind != .name) return self.failUnsupported(target.span, "attribute and subscript augmented assignment are not implemented yet");
        if (node.text.len < 2 or node.text[node.text.len - 1] != '=') return self.failUnsupported(node.span, "augmented operator is unsupported");
        const operation = binaryOperation(node.text[0 .. node.text.len - 1]) orelse return self.failUnsupported(node.span, "this augmented operator is not implemented yet");
        const binding = self.analysis.bindingOf(children[0]) orelse .global_implicit;
        const left = try self.acquire(target.span);
        try self.compileLoadName(left, target.text, binding, target.span);
        const right = self.compileExpression(children[1]) catch |err| {
            self.temps.release(left);
            return err;
        };
        try self.emit(.binary, left, right, 0, @intFromEnum(operation), node.span);
        self.temps.release(right);
        try self.compileStoreName(left, target.text, binding, node.span);
        self.temps.release(left);
    }

    fn compileAssignment(self: *Compiler, node_id: NodeId) CompileError!void {
        const children = self.ast.children(node_id);
        if (children.len < 2) return self.failUnsupported(self.ast.node(node_id).span, "assignment shape is unsupported");
        const value = try self.compileExpression(children[children.len - 1]);
        for (children[0 .. children.len - 1]) |target_id| try self.compileStoreTarget(target_id, value);
        self.temps.release(value);
    }

    fn compileStoreTarget(self: *Compiler, target_id: NodeId, value_register: u16) CompileError!void {
        const target = self.ast.node(target_id);
        if (target.kind == .name) {
            const binding = self.analysis.bindingOf(target_id) orelse .global_implicit;
            return self.compileStoreName(value_register, target.text, binding, target.span);
        }
        if (target.kind == .subscript) {
            const children = self.ast.children(target_id);
            if (children.len != 2) return self.failUnsupported(target.span, "subscript assignment shape is unsupported");
            const container = try self.compileExpression(children[0]);
            const index_register = self.compileExpression(children[1]) catch |err| {
                self.temps.release(container);
                return err;
            };
            try self.emit(.set_item, value_register, container, index_register, 0, target.span);
            self.temps.release(index_register);
            self.temps.release(container);
            return;
        }
        if (target.kind == .tuple_display or target.kind == .list_display) {
            const elements = self.ast.children(target_id);
            if (elements.len > std.math.maxInt(u16)) return self.failUnsupported(target.span, "unpacking target has too many values");
            const destinations = self.scratch_allocator.alloc(u16, elements.len) catch return error.OutOfMemory;
            for (destinations, 0..) |*destination, index| {
                destination.* = try self.acquire(target.span);
                _ = index;
            }
            const destination_start = std.math.cast(u32, self.argument_registers.items.len) orelse return self.failUnsupported(target.span, "too many unpacking destinations");
            try self.argument_registers.appendSlice(self.allocator, destinations);
            const site_index = std.math.cast(u32, self.unpack_sites.items.len) orelse return self.failUnsupported(target.span, "too many unpacking sites");
            var star_index: u16 = std.math.maxInt(u16);
            for (elements, 0..) |element_id, index| if (self.ast.node(element_id).kind == .starred) {
                if (star_index != std.math.maxInt(u16)) return self.failUnsupported(self.ast.node(element_id).span, "multiple starred targets are unsupported");
                star_index = @intCast(index);
            };
            try self.unpack_sites.append(self.allocator, .{ .destination_start = destination_start, .destination_count = @intCast(elements.len), .star_index = star_index });
            try self.emitIndex(.unpack, value_register, site_index, 0, target.span);
            for (elements, 0..) |element_id, index| {
                const child = self.ast.node(element_id);
                const actual_target = if (child.kind == .starred) self.ast.children(element_id)[0] else element_id;
                try self.compileStoreTarget(actual_target, destinations[index]);
            }
            var remaining = destinations.len;
            while (remaining > 0) {
                remaining -= 1;
                self.temps.release(destinations[remaining]);
            }
            return;
        }
        return self.failUnsupported(target.span, "this assignment target is not implemented yet");
    }

    fn compileDelete(self: *Compiler, node_id: NodeId) CompileError!void {
        const children = self.ast.children(node_id);
        if (children.len != 1) return self.failUnsupported(self.ast.node(node_id).span, "delete statement shape is unsupported");
        try self.compileDeleteTarget(children[0]);
    }

    fn compileDeleteTarget(self: *Compiler, target_id: NodeId) CompileError!void {
        const target = self.ast.node(target_id);
        if (target.kind == .name) {
            const name_index = try self.internName(target.text);
            const binding = self.analysis.bindingOf(target_id) orelse .global_implicit;
            switch (binding) {
                .local, .cell, .free => try self.emitIndex(.delete_local, 0, name_index, localBindingFlag(binding), target.span),
                .global_explicit, .global_implicit => try self.emitIndex(.delete_global, 0, name_index, 0, target.span),
                .class_local => return self.failUnsupported(target.span, "class namespace execution is not implemented yet"),
            }
            return;
        }
        if (target.kind == .subscript) {
            const children = self.ast.children(target_id);
            if (children.len != 2) return self.failUnsupported(target.span, "subscript delete shape is unsupported");
            const container = try self.compileExpression(children[0]);
            const index_register = self.compileExpression(children[1]) catch |err| {
                self.temps.release(container);
                return err;
            };
            try self.emit(.delete_item, 0, container, index_register, 0, target.span);
            self.temps.release(index_register);
            self.temps.release(container);
            return;
        }
        if (target.kind == .tuple_display or target.kind == .list_display) {
            for (self.ast.children(target_id)) |child| try self.compileDeleteTarget(child);
            return;
        }
        return self.failUnsupported(target.span, "this delete target is not implemented yet");
    }

    fn compileLoadName(self: *Compiler, destination: u16, name: []const u8, binding: Binding, span: Span) CompileError!void {
        const name_index = try self.internName(name);
        switch (binding) {
            .local, .cell, .free => try self.emitIndex(.load_local, destination, name_index, localBindingFlag(binding), span),
            .global_explicit, .global_implicit => try self.emitIndex(.load_global, destination, name_index, 0, span),
            .class_local => return self.failUnsupported(span, "class namespace execution is not implemented yet"),
        }
    }

    fn compileStoreName(self: *Compiler, source: u16, name: []const u8, binding: Binding, span: Span) CompileError!void {
        const name_index = try self.internName(name);
        switch (binding) {
            .local, .cell, .free => try self.emitIndex(.store_local, source, name_index, localBindingFlag(binding), span),
            .global_explicit, .global_implicit => try self.emitIndex(.store_global, source, name_index, 0, span),
            .class_local => return self.failUnsupported(span, "class namespace execution is not implemented yet"),
        }
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
                const register = try self.acquire(node.span);
                const binding = self.analysis.bindingOf(node_id) orelse .global_implicit;
                try self.compileLoadName(register, node.text, binding, node.span);
                return register;
            },
            .unary_expression => return self.compileUnary(node_id),
            .binary_expression => return self.compileBinary(node_id),
            .boolean_expression => return self.compileBoolean(node_id),
            .comparison_chain => return self.compileComparisonChain(node_id),
            .conditional_expression => return self.compileConditional(node_id),
            .call => return self.compileCall(node_id),
            .list_display => return self.compileSequence(node_id, false),
            .tuple_display => return self.compileSequence(node_id, true),
            .set_display => return self.compileMappingDisplay(node_id, true),
            .dict_display => return self.compileMappingDisplay(node_id, false),
            .attribute => return self.compileAttribute(node_id),
            .subscript => return self.compileSubscript(node_id),
            .bytes_literal => {
                const value = try self.parseString(node.text, node.span);
                return self.loadConstant(value, node.span);
            },
            else => return self.failUnsupported(node.span, expressionUnsupportedMessage(node.kind)),
        }
    }

    fn compileUnary(self: *Compiler, node_id: NodeId) CompileError!u16 {
        const node = self.ast.node(node_id);
        const operation: UnaryOperation = if (std.mem.eql(u8, node.text, "+")) .positive else if (std.mem.eql(u8, node.text, "-")) .negative else if (std.mem.eql(u8, node.text, "~")) .bit_not else if (std.mem.eql(u8, node.text, "not")) .logical_not else return self.failUnsupported(node.span, "this unary operator is not implemented yet");
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

    fn compileBoolean(self: *Compiler, node_id: NodeId) CompileError!u16 {
        const node = self.ast.node(node_id);
        const children = self.ast.children(node_id);
        if (children.len != 2) return self.failUnsupported(node.span, "boolean expression shape is unsupported");
        const left = try self.compileExpression(children[0]);
        const is_and = std.mem.eql(u8, node.text, "and");
        if (!is_and and !std.mem.eql(u8, node.text, "or")) return self.failUnsupported(node.span, "boolean operator is unsupported");
        const short = try self.emitJump(if (is_and) .jump_if_false else .jump_if_true, left, 0, self.ast.node(children[0]).span);
        const right = self.compileExpression(children[1]) catch |err| {
            self.temps.release(left);
            return err;
        };
        try self.emit(.move, left, right, 0, 0, node.span);
        self.temps.release(right);
        try self.patchJump(short, try self.currentTarget(node.span));
        return left;
    }

    fn compileConditional(self: *Compiler, node_id: NodeId) CompileError!u16 {
        const node = self.ast.node(node_id);
        const children = self.ast.children(node_id);
        if (children.len != 3) return self.failUnsupported(node.span, "conditional expression shape is unsupported");
        const result = try self.acquire(node.span);
        const condition = try self.compileExpression(children[0]);
        const alternative_jump = try self.emitJump(.jump_if_false, condition, 0, self.ast.node(children[0]).span);
        self.temps.release(condition);

        const positive = try self.compileExpression(children[1]);
        try self.emit(.move, result, positive, 0, 0, node.span);
        self.temps.release(positive);
        const end_jump = try self.emitJump(.jump, 0, 0, node.span);
        try self.patchJump(alternative_jump, try self.currentTarget(node.span));

        const negative = try self.compileExpression(children[2]);
        try self.emit(.move, result, negative, 0, 0, node.span);
        self.temps.release(negative);
        try self.patchJump(end_jump, try self.currentTarget(node.span));
        return result;
    }

    fn compileComparisonChain(self: *Compiler, node_id: NodeId) CompileError!u16 {
        const node = self.ast.node(node_id);
        const children = self.ast.children(node_id);
        if (children.len < 3 or children.len % 2 == 0) return self.failUnsupported(node.span, "comparison chain shape is unsupported");
        const result = try self.acquire(node.span);
        const operand_count = (children.len + 1) / 2;
        const operands = self.scratch_allocator.alloc(u16, operand_count) catch return error.OutOfMemory;
        var held: usize = 0;
        errdefer while (held > 0) {
            held -= 1;
            self.temps.release(operands[held]);
        };

        operands[held] = try self.compileExpression(children[0]);
        held += 1;
        var jumps: std.ArrayList(u32) = .empty;
        var pair: usize = 0;
        while (pair < operand_count - 1) : (pair += 1) {
            const op_node = self.ast.node(children[pair * 2 + 1]);
            const op = comparisonOperation(op_node.text) orelse return self.failUnsupported(op_node.span, "comparison operator is not implemented yet");
            operands[held] = try self.compileExpression(children[pair * 2 + 2]);
            held += 1;
            try self.emit(.compare, result, operands[held - 2], operands[held - 1], op, op_node.span);
            if (pair + 1 < operand_count - 1) try jumps.append(self.scratch_allocator, try self.emitJump(.jump_if_false, result, 0, op_node.span));
        }
        const end_target = try self.currentTarget(node.span);
        for (jumps.items) |jump_index| try self.patchJump(jump_index, end_target);
        while (held > 0) {
            held -= 1;
            self.temps.release(operands[held]);
        }
        return result;
    }

    fn compileSequence(self: *Compiler, node_id: NodeId, is_tuple: bool) CompileError!u16 {
        const node = self.ast.node(node_id);
        const children = self.ast.children(node_id);
        if (children.len > std.math.maxInt(u16)) return self.failUnsupported(node.span, "sequence display has too many values");
        const result = try self.acquire(node.span);
        const held = self.scratch_allocator.alloc(u16, children.len) catch return error.OutOfMemory;
        var held_count: usize = 0;
        for (children) |child| {
            held[held_count] = try self.compileExpression(child);
            held_count += 1;
        }
        const start = std.math.cast(u32, self.argument_registers.items.len) orelse return self.failUnsupported(node.span, "too many sequence operands");
        try self.argument_registers.appendSlice(self.allocator, held);
        const site_index = std.math.cast(u32, self.sequence_sites.items.len) orelse return self.failUnsupported(node.span, "too many sequence displays");
        try self.sequence_sites.append(self.allocator, .{ .argument_start = start, .argument_count = @intCast(children.len), .is_tuple = is_tuple });
        try self.emitIndex(.make_sequence, result, site_index, 0, node.span);
        while (held_count > 0) {
            held_count -= 1;
            self.temps.release(held[held_count]);
        }
        return result;
    }

    fn compileMappingDisplay(self: *Compiler, node_id: NodeId, is_set: bool) CompileError!u16 {
        const node = self.ast.node(node_id);
        const children = self.ast.children(node_id);
        const result = try self.acquire(node.span);
        try self.emit(.make_mapping, result, 0, 0, @intFromBool(is_set), node.span);
        var index: usize = 0;
        while (index < children.len) {
            const child = self.ast.node(children[index]);
            if (!is_set and child.kind == .starred and std.mem.eql(u8, child.text, "**")) {
                const values = self.ast.children(children[index]);
                if (values.len != 1) return self.failUnsupported(child.span, "dictionary unpacking shape is unsupported");
                const source = try self.compileExpression(values[0]);
                try self.emit(.mapping_update, result, source, 0, 1, child.span);
                self.temps.release(source);
                index += 1;
                continue;
            }
            const key = try self.compileExpression(children[index]);
            if (is_set) {
                try self.emit(.mapping_set, result, key, 0, 1, child.span);
                self.temps.release(key);
                index += 1;
                continue;
            }
            if (index + 1 >= children.len) return self.failUnsupported(child.span, "dictionary entry has no value");
            const value = self.compileExpression(children[index + 1]) catch |err| {
                self.temps.release(key);
                return err;
            };
            try self.emit(.mapping_set, result, key, value, 0, child.span);
            self.temps.release(value);
            self.temps.release(key);
            index += 2;
        }
        return result;
    }

    fn compileAttribute(self: *Compiler, node_id: NodeId) CompileError!u16 {
        const node = self.ast.node(node_id);
        const children = self.ast.children(node_id);
        if (children.len != 1) return self.failUnsupported(node.span, "attribute access shape is unsupported");
        const receiver = try self.compileExpression(children[0]);
        const name_index = try self.internName(node.text);
        if (name_index > std.math.maxInt(u16)) return self.failUnsupported(node.span, "too many attribute names in code object");
        try self.emit(.get_attribute, receiver, receiver, name_index, 0, node.span);
        return receiver;
    }

    fn compileSubscript(self: *Compiler, node_id: NodeId) CompileError!u16 {
        const node = self.ast.node(node_id);
        const children = self.ast.children(node_id);
        if (children.len != 2) return self.failUnsupported(node.span, "subscript expression shape is unsupported");
        const container = try self.compileExpression(children[0]);
        const index_node = self.ast.node(children[1]);
        const index_register = if (index_node.kind == .slice)
            try self.compileSlice(children[1])
        else
            self.compileExpression(children[1]) catch |err| {
                self.temps.release(container);
                return err;
            };
        try self.emit(.get_item, container, container, index_register, 0, node.span);
        self.temps.release(index_register);
        return container;
    }

    fn compileSlice(self: *Compiler, node_id: NodeId) CompileError!u16 {
        const node = self.ast.node(node_id);
        const children = self.ast.children(node_id);
        if (children.len != 3) return self.failUnsupported(node.span, "slice expression shape is unsupported");
        const result = try self.acquire(node.span);
        const start = try self.compileExpression(children[0]);
        const stop = self.compileExpression(children[1]) catch |err| {
            self.temps.release(start);
            return err;
        };
        const step = self.compileExpression(children[2]) catch |err| {
            self.temps.release(stop);
            self.temps.release(start);
            return err;
        };
        const site_index = std.math.cast(u32, self.slice_sites.items.len) orelse return self.failUnsupported(node.span, "too many slice expressions");
        try self.slice_sites.append(self.allocator, .{ .start = start, .stop = stop, .step = step });
        try self.emitIndex(.make_slice, result, site_index, 0, node.span);
        self.temps.release(step);
        self.temps.release(stop);
        self.temps.release(start);
        return result;
    }

    fn compileCall(self: *Compiler, node_id: NodeId) CompileError!u16 {
        const node = self.ast.node(node_id);
        const children = self.ast.children(node_id);
        if (children.len == 0) return self.failUnsupported(node.span, "call shape is unsupported");
        const count = children.len - 1;
        if (count > std.math.maxInt(u16)) return self.failUnsupported(node.span, "call has more than 65,535 arguments");
        const initial_temps = self.temps.next;
        errdefer self.temps.next = initial_temps;
        const callee = try self.compileExpression(children[0]);
        const held = self.scratch_allocator.alloc(bytecode.CallArgument, count) catch {
            return error.OutOfMemory;
        };
        var held_count: usize = 0;

        for (children[1..]) |argument_id| {
            const argument = self.ast.node(argument_id);
            const value_node = if (argument.kind == .keyword_argument or argument.kind == .starred) self.ast.children(argument_id)[0] else argument_id;
            const register = try self.compileExpression(value_node);
            const keyword_name = if (argument.kind == .keyword_argument) try self.internName(argument.text) else std.math.maxInt(u32);
            const call_argument = bytecode.CallArgument{
                .register = register,
                .keyword_name = keyword_name,
                .starred = argument.kind == .starred and std.mem.eql(u8, argument.text, "*"),
                .double_starred = argument.kind == .starred and std.mem.eql(u8, argument.text, "**"),
            };
            if (argument.kind == .starred) {
                const is_double = std.mem.eql(u8, argument.text, "**");
                if (is_double) {
                    const previous_start = std.math.cast(u32, self.dstar_previous_arguments.items.len) orelse return self.failUnsupported(argument.span, "too many double-star call operands");
                    var previous_count: usize = 0;
                    for (held[0..held_count]) |previous| {
                        if (previous.double_starred or previous.keyword_name != std.math.maxInt(u32)) {
                            try self.dstar_previous_arguments.append(self.allocator, previous);
                            previous_count += 1;
                        }
                    }
                    const previous_count_u16 = std.math.cast(u16, previous_count) orelse return self.failUnsupported(argument.span, "too many prior call keywords");
                    const dstar_site_index = std.math.cast(u32, self.dstar_sites.items.len) orelse return self.failUnsupported(argument.span, "too many double-star call sites");
                    try self.dstar_sites.append(self.allocator, .{ .previous_start = previous_start, .previous_count = previous_count_u16 });
                    try self.emitIndex(.materialize_dstar, register, dstar_site_index, 0, argument.span);
                } else {
                    try self.emit(.materialize_star, register, 0, 0, 0, argument.span);
                }
            }
            held[held_count] = call_argument;
            held_count += 1;
        }

        const argument_start = std.math.cast(u32, self.call_arguments.items.len) orelse return self.failUnsupported(node.span, "code object has too many call operands");
        try self.call_arguments.appendSlice(self.allocator, held[0..held_count]);
        const site_index = std.math.cast(u32, self.call_sites.items.len) orelse return self.failUnsupported(node.span, "too many call sites");
        try self.call_sites.append(self.allocator, .{ .argument_start = argument_start, .argument_count = @intCast(count) });
        try self.emitIndex(.call, callee, site_index, 0, node.span);
        while (held_count > 0) {
            held_count -= 1;
            self.temps.release(held[held_count].register);
        }
        return callee;
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
        const is_bytes = std.mem.indexOfAny(u8, prefix, "bB") != null;
        for (prefix) |character| {
            if (character == 'f' or character == 'F') return self.failUnsupported(span, "f-string execution is not implemented in this commit");
        }
        const raw = std.mem.indexOfAny(u8, prefix, "rR") != null;
        const delimiter_len: usize = if (quote_index + 2 < spelling.len and spelling[quote_index + 1] == spelling[quote_index] and spelling[quote_index + 2] == spelling[quote_index]) 3 else 1;
        if (spelling.len < quote_index + delimiter_len * 2) return self.failSyntax(span, "unterminated string literal");
        const content = spelling[quote_index + delimiter_len .. spelling.len - delimiter_len];
        if (is_bytes) {
            for (content) |character| if (character >= 0x80) return self.failSyntax(span, "bytes can only contain ASCII literal characters");
            if (!raw and (std.mem.indexOf(u8, content, "\\u") != null or std.mem.indexOf(u8, content, "\\U") != null or std.mem.indexOf(u8, content, "\\N") != null)) {
                return self.failSyntax(span, "Unicode escapes are not allowed in bytes literals");
            }
        }
        const allocator = self.scratch_allocator;
        var decoded: std.ArrayList(u8) = .empty;
        if (raw) {
            decoded.appendSlice(allocator, content) catch return error.OutOfMemory;
        } else {
            try decodeEscapes(allocator, &decoded, content, self, span);
        }
        if (is_bytes) {
            const created_bytes = bytes.create(self.heap, decoded.items);
            return switch (created_bytes) {
                .value => |object| Value.object(&object.header),
                .python_exception => |exception| blk: {
                    self.pending_exception = exception;
                    break :blk error.PythonFault;
                },
                .engine_error => error.PythonFault,
            };
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
        const owner = self.root_owner orelse self.code;
        const cursor = self.root_cursor orelse return self.failUnsupported(span, "code constant root owner is missing");
        if (cursor.* >= owner.root_slots.len) return self.failUnsupported(span, "code object constant bound exceeded");
        owner.root_slots[cursor.*].object = value.asObject();
        cursor.* += 1;
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

    fn emitJump(self: *Compiler, op: bytecode.Opcode, register: u32, target: u32, span: Span) CompileError!u32 {
        const index = std.math.cast(u32, self.instructions.items.len) orelse return self.failUnsupported(span, "code object has too many instructions");
        try self.emitIndex(op, register, target, 0, span);
        return index;
    }

    fn patchJump(self: *Compiler, instruction_index: u32, target: u32) CompileError!void {
        const index: usize = instruction_index;
        if (index >= self.instructions.items.len) return error.Unsupported;
        const previous = self.instructions.items[index];
        const op = previous.opcodeTag() orelse return error.Unsupported;
        const replacement = bytecode.Instruction.withIndex32(op, previous.a(), target, previous.flags()) catch return error.Unsupported;
        self.instructions.items[index] = replacement;
    }

    fn currentTarget(self: *Compiler, span: Span) CompileError!u32 {
        return std.math.cast(u32, self.instructions.items.len) orelse self.failUnsupported(span, "code object has too many instructions");
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

fn localBindingFlag(binding: Binding) u8 {
    return switch (binding) {
        .local => @intFromEnum(bytecode.LocalBinding.local),
        .cell => @intFromEnum(bytecode.LocalBinding.cell),
        .free => @intFromEnum(bytecode.LocalBinding.free),
        .global_explicit, .global_implicit, .class_local => unreachable,
    };
}

fn comparisonOperation(spelling: []const u8) ?u8 {
    if (std.mem.eql(u8, spelling, "==")) return 0;
    if (std.mem.eql(u8, spelling, "!=")) return 1;
    if (std.mem.eql(u8, spelling, "<")) return 2;
    if (std.mem.eql(u8, spelling, "<=")) return 3;
    if (std.mem.eql(u8, spelling, ">")) return 4;
    if (std.mem.eql(u8, spelling, ">=")) return 5;
    if (std.mem.eql(u8, spelling, "is")) return 6;
    if (std.mem.eql(u8, spelling, "is not")) return 7;
    if (std.mem.eql(u8, spelling, "in")) return 8;
    if (std.mem.eql(u8, spelling, "not in")) return 9;
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
