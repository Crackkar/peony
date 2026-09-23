const std = @import("std");
const bytecode = @import("frontend_bytecode");
const compiler = @import("frontend_compiler");
const gc = @import("runtime_gc");
const value_module = @import("runtime_value");
const number = @import("runtime_number");
const string = @import("runtime_string");
const exceptions = @import("runtime_exception");
const iterator = @import("runtime_iterator");
const functions = @import("runtime_function");
const binder = @import("runtime_binder");
const ast_module = @import("frontend_ast");

const Value = value_module.Value;
const Code = bytecode.Code;

pub const CompileOutcome = compiler.CompileOutcome;
pub const PythonException = exceptions.PythonException;
pub const PythonExceptionKind = exceptions.PythonExceptionKind;

pub const RunStatus = enum {
    completed,
    python_exception,
    timeslice,
    cancelled,
    engine_error,
};

const default_quantum: u32 = 50_000;

const GlobalEntry = struct {
    name: []const u8,
    value: Value,
};

const Environment = struct {
    header: gc.Header,
    entries: std.ArrayList(GlobalEntry) = .empty,
};

const Frame = struct {
    code: *Code,
    previous: ?*Frame = null,
    return_destination: ?u16 = null,
    ip: usize = 0,
    registers: []Value = &.{},
    locals: []Value = &.{},
    local_cells: []?*functions.Cell = &.{},
    free_cells: []?*functions.Cell = &.{},
    roots: []gc.Root = &.{},
    root_frame: gc.RootFrame = .{},

    fn localRootStart(self: *const Frame) usize {
        return self.registers.len;
    }

    fn cellRootStart(self: *const Frame) usize {
        return self.registers.len + self.locals.len;
    }

    fn freeRootStart(self: *const Frame) usize {
        return self.cellRootStart() + self.local_cells.len;
    }
};

const environment_kind = gc.Kind{
    .trace = traceEnvironment,
    .destroy = destroyEnvironment,
};

fn traceEnvironment(header: *gc.Header, tracer: *gc.Tracer) void {
    const environment: *Environment = @ptrCast(@alignCast(header));
    for (environment.entries.items) |entry| tracer.visit(entry.value.asObject());
}

fn destroyEnvironment(header: *gc.Header, allocator: std.mem.Allocator) void {
    const environment: *Environment = @ptrCast(@alignCast(header));
    for (environment.entries.items) |entry| allocator.free(entry.name);
    environment.entries.deinit(allocator);
}

/// One interpreter session. Keep this value at a stable address after init;
/// its heap's allocation hook and root frames point into it.
pub const Runtime = struct {
    session_allocator: gc.SessionAllocator = undefined,
    heap: gc.Heap = .{},
    environment: *Environment = undefined,
    environment_frame: gc.RootFrame = .{},
    environment_root: gc.Root = .{ .object = null },
    builtin_frame: gc.RootFrame = .{},
    print_builtin_root: gc.Root = .{ .object = null },
    range_builtin_root: gc.Root = .{ .object = null },
    code: ?*Code = null,
    top_frame: ?*Frame = null,
    registers: []Value = &.{},
    register_roots: []gc.Root = &.{},
    register_frame: gc.RootFrame = .{},
    instruction_pointer: usize = 0,
    stdout_bytes: std.ArrayList(u8) = .empty,
    last_exception: ?PythonException = null,
    error_text_owned: ?[]u8 = null,
    error_text_static: []const u8 = "",
    cancel_requested: bool = false,
    engine_failed: bool = false,
    initialized: bool = false,

    pub fn init(self: *Runtime, backing: std.mem.Allocator, max_bytes: usize) std.mem.Allocator.Error!void {
        self.* = .{};
        self.session_allocator = gc.SessionAllocator.init(backing, max_bytes);
        self.heap.init(&self.session_allocator, .{});
        const environment = try self.heap.createObject(Environment, &environment_kind);
        environment.entries = .empty;
        self.environment = environment;
        self.environment_root.object = &environment.header;
        self.environment_frame.push(&self.heap.roots);
        self.environment_frame.add(&self.environment_root);
        self.builtin_frame.push(&self.heap.roots);
        self.builtin_frame.add(&self.print_builtin_root);
        self.builtin_frame.add(&self.range_builtin_root);
        const print_builtin = functions.createNative(&self.heap, .print);
        switch (print_builtin) {
            .value => |function| self.print_builtin_root.object = &function.header,
            .python_exception => {
                self.builtin_frame.pop();
                self.environment_frame.pop();
                self.heap.deinit();
                self.* = .{};
                return error.OutOfMemory;
            },
        }
        const range_builtin = functions.createNative(&self.heap, .range);
        switch (range_builtin) {
            .value => |function| self.range_builtin_root.object = &function.header,
            .python_exception => {
                self.builtin_frame.pop();
                self.environment_frame.pop();
                self.heap.deinit();
                self.* = .{};
                return error.OutOfMemory;
            },
        }
        self.initialized = true;
    }

    pub fn deinit(self: *Runtime) void {
        if (!self.initialized) return;
        self.resetProgram(false);
        self.stdout_bytes.deinit(self.heap.allocator);
        if (self.builtin_frame.stack != null) self.builtin_frame.pop();
        if (self.environment_frame.stack != null) self.environment_frame.pop();
        self.heap.deinit();
        std.debug.assert(self.session_allocator.live_bytes == 0);
        self.* = .{};
    }

    pub fn compileAndStart(self: *Runtime, source: []const u8, filename: []const u8) CompileOutcome {
        self.resetProgram(true);
        const outcome = compiler.compile(&self.heap, source, filename);
        switch (outcome) {
            .ready => |code| {
                self.code = code;
                if (self.prepareRegisters(code)) return .{ .ready = code };
                code.deinit(&self.heap);
                self.code = null;
                const exception = PythonException{ .kind = .memory_error, .message = "session memory limit exceeded" };
                self.setException(exception, 1, 1, null);
                return .{ .python_exception = exception };
            },
            .syntax_error => |diagnostic| {
                self.setStaticError(diagnostic.message);
                return .{ .syntax_error = diagnostic };
            },
            .unsupported => |diagnostic| {
                self.setStaticError(diagnostic.message);
                return .{ .unsupported = diagnostic };
            },
            .python_exception => |exception| {
                self.setException(exception, 1, 1, null);
                return .{ .python_exception = exception };
            },
        }
    }

    pub fn run(self: *Runtime, requested_quantum: u32) RunStatus {
        if (self.engine_failed) return .engine_error;
        if (self.cancel_requested) {
            self.cancel_requested = false;
            self.resetProgram(false);
            return .cancelled;
        }
        if (self.last_exception != null) return .python_exception;
        if (self.top_frame == null) return .completed;

        const quantum = if (requested_quantum == 0) default_quantum else requested_quantum;
        var executed: u32 = 0;
        while (executed < quantum) : (executed += 1) {
            const frame = self.top_frame orelse return .completed;
            if (frame.ip >= frame.code.instructions.len or frame.code.positions.len != frame.code.instructions.len) {
                _ = self.engineFault();
                self.unwindFrames();
                return .engine_error;
            }
            const current = frame.code.positions[frame.ip];
            const instruction = frame.code.instructions[frame.ip];
            frame.ip += 1;
            self.activateFrame(frame);
            if (!self.execute(instruction, current.line, current.column)) {
                self.unwindFrames();
                return if (self.engine_failed) .engine_error else .python_exception;
            }
            if (self.top_frame == frame) {
                frame.ip = self.instruction_pointer;
            }
            if (self.top_frame == null) return .completed;
        }
        return if (self.top_frame == null) .completed else .timeslice;
    }

    pub fn cancel(self: *Runtime) void {
        self.cancel_requested = true;
    }

    pub fn stdout(self: *const Runtime) []const u8 {
        return self.stdout_bytes.items;
    }

    pub fn consumeStdout(self: *Runtime, length: usize) bool {
        if (length > self.stdout_bytes.items.len) return false;
        const remaining = self.stdout_bytes.items.len - length;
        if (remaining != 0) std.mem.copyForwards(u8, self.stdout_bytes.items[0..remaining], self.stdout_bytes.items[length..]);
        self.stdout_bytes.items.len = remaining;
        return true;
    }

    pub fn pythonException(self: *const Runtime) ?PythonException {
        return self.last_exception;
    }

    pub fn errorText(self: *const Runtime) []const u8 {
        return self.error_text_owned orelse self.error_text_static;
    }

    fn prepareRegisters(self: *Runtime, code: *Code) bool {
        _ = self.allocateFrame(code, null) catch return false;
        return true;
    }

    fn resetProgram(self: *Runtime, clear_output: bool) void {
        self.unwindFrames();

        self.clearGlobals();
        if (self.code) |code| {
            code.deinit(&self.heap);
            self.code = null;
        }
        self.instruction_pointer = 0;
        self.cancel_requested = false;
        self.engine_failed = false;
        self.last_exception = null;
        self.clearErrorText();
        if (clear_output) self.stdout_bytes.clearRetainingCapacity();
        _ = self.heap.collect();
    }

    fn allocateFrame(self: *Runtime, code: *Code, return_destination: ?u16) error{OutOfMemory}!*Frame {
        const allocator = self.heap.allocator;
        const frame = allocator.create(Frame) catch return error.OutOfMemory;
        frame.* = .{ .code = code, .return_destination = return_destination };
        errdefer self.freeFrameStorage(frame);
        frame.registers = try allocator.alloc(Value, @intCast(code.register_count));
        @memset(frame.registers, Value.unboundValue());
        frame.locals = try allocator.alloc(Value, code.local_names.len);
        @memset(frame.locals, Value.unboundValue());
        frame.local_cells = try allocator.alloc(?*functions.Cell, code.cell_names.len);
        @memset(frame.local_cells, null);
        frame.free_cells = try allocator.alloc(?*functions.Cell, code.free_names.len);
        @memset(frame.free_cells, null);
        const first_roots = std.math.add(usize, frame.registers.len, frame.locals.len) catch return error.OutOfMemory;
        const root_count = std.math.add(usize, first_roots, frame.local_cells.len + frame.free_cells.len) catch return error.OutOfMemory;
        frame.roots = try allocator.alloc(gc.Root, root_count);
        @memset(frame.roots, .{ .object = null });
        frame.root_frame.push(&self.heap.roots);
        for (frame.roots) |*root| frame.root_frame.add(root);
        frame.previous = self.top_frame;
        self.top_frame = frame;
        self.activateFrame(frame);
        return frame;
    }

    fn freeFrameStorage(self: *Runtime, frame: *Frame) void {
        const allocator = self.heap.allocator;
        if (frame.roots.len != 0) allocator.free(frame.roots);
        if (frame.free_cells.len != 0) allocator.free(frame.free_cells);
        if (frame.local_cells.len != 0) allocator.free(frame.local_cells);
        if (frame.locals.len != 0) allocator.free(frame.locals);
        if (frame.registers.len != 0) allocator.free(frame.registers);
        allocator.destroy(frame);
    }

    fn activateFrame(self: *Runtime, frame: *Frame) void {
        self.registers = frame.registers;
        self.register_roots = frame.roots[0..frame.registers.len];
        self.instruction_pointer = frame.ip;
    }

    fn popFrame(self: *Runtime) ?*Frame {
        const frame = self.top_frame orelse return null;
        if (frame.root_frame.stack != null) frame.root_frame.pop();
        self.top_frame = frame.previous;
        const previous = self.top_frame;
        if (previous) |active| {
            self.activateFrame(active);
        } else {
            self.registers = &.{};
            self.register_roots = &.{};
            self.instruction_pointer = 0;
        }
        return frame;
    }

    fn unwindFrames(self: *Runtime) void {
        while (self.popFrame()) |frame| self.freeFrameStorage(frame);
    }

    fn executeCall(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
        const code = self.activeCode() orelse return self.engineFault();
        const site_index: usize = instruction.index32();
        if (site_index >= code.call_sites.len) return self.engineFault();
        const site = code.call_sites[site_index];
        const start: usize = site.argument_start;
        const count: usize = site.argument_count;
        if (start > code.call_arguments.len or count > code.call_arguments.len - start) return self.engineFault();

        const allocator = self.heap.allocator;
        const positional = allocator.alloc(Value, count) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer allocator.free(positional);
        const keywords = allocator.alloc(binder.Keyword, count) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer allocator.free(keywords);
        var positional_count: usize = 0;
        var keyword_count: usize = 0;
        for (code.call_arguments[start..][0..count]) |argument| {
            if (!self.validRegister(argument.register)) return self.engineFault();
            const value = self.registers[argument.register];
            if (argument.keyword_name == std.math.maxInt(u32)) {
                positional[positional_count] = value;
                positional_count += 1;
            } else {
                const name = self.codeName(argument.keyword_name) orelse return self.engineFault();
                keywords[keyword_count] = .{ .name = name, .value = value };
                keyword_count += 1;
            }
        }
        const callee = self.registers[instruction.a()];
        const header = callee.asObject() orelse {
            self.setException(.{ .kind = .type_error, .message = "object is not callable" }, line, column, null);
            return false;
        };
        const function = functions.functionFromHeader(header) orelse {
            self.setException(.{ .kind = .type_error, .message = "object is not callable" }, line, column, null);
            return false;
        };
        if (function.native) |native| return self.executeNativeCall(instruction.a(), native, positional[0..positional_count], keywords[0..keyword_count], line, column);

        const function_code = function.code orelse return self.engineFault();
        const bound = binder.bindFunction(
            allocator,
            function_code.parameter_names,
            function_code.parameter_flags,
            function.defaults,
            positional[0..positional_count],
            keywords[0..keyword_count],
        ) catch |err| {
            self.setBinderException(err, line, column);
            return false;
        };
        defer allocator.free(bound);
        const frame = self.allocateFrame(function_code, instruction.a()) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        if (function.cells.len != function_code.free_names.len) return self.engineFault();
        for (function.cells, 0..) |cell, index| {
            frame.free_cells[index] = cell;
            frame.roots[frame.freeRootStart() + index].object = &cell.header;
        }
        for (function_code.cell_names, 0..) |name, index| {
            const cell = functions.createCell(&self.heap, Value.unboundValue()) catch {
                self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
                return false;
            };
            frame.local_cells[index] = cell;
            frame.roots[frame.cellRootStart() + index].object = &cell.header;
            _ = name;
        }
        for (function_code.parameter_names, 0..) |name, index| {
            if (!self.storeFrameLocal(frame, name, bound[index])) return self.engineFault();
        }
        return true;
    }

    fn executeNativeCall(
        self: *Runtime,
        destination: u16,
        native: functions.Native,
        positional: []const Value,
        keywords: []const binder.Keyword,
        line: u32,
        column: u32,
    ) bool {
        switch (native) {
            .print => {
                const arguments = binder.bindPrint(positional, keywords) catch |err| {
                    self.setBinderException(err, line, column);
                    return false;
                };
                var separator: []const u8 = " ";
                var ending: []const u8 = "\n";
                if (arguments.separator) |value| {
                    if (value.tag() != .none) {
                        const header = value.asObject() orelse {
                            self.setException(.{ .kind = .type_error, .message = "sep must be None or a string" }, line, column, null);
                            return false;
                        };
                        const text = string.fromHeader(header) orelse {
                            self.setException(.{ .kind = .type_error, .message = "sep must be None or a string" }, line, column, null);
                            return false;
                        };
                        separator = string.content(text);
                    }
                }
                if (arguments.ending) |value| {
                    if (value.tag() != .none) {
                        const header = value.asObject() orelse {
                            self.setException(.{ .kind = .type_error, .message = "end must be None or a string" }, line, column, null);
                            return false;
                        };
                        const text = string.fromHeader(header) orelse {
                            self.setException(.{ .kind = .type_error, .message = "end must be None or a string" }, line, column, null);
                            return false;
                        };
                        ending = string.content(text);
                    }
                }
                if (!self.executePrintValues(arguments.values, separator, ending, line, column)) return false;
                self.setRegister(destination, Value.noneValue());
                return true;
            },
            .range => {
                const arguments = binder.bindRange(positional, keywords) catch |err| {
                    self.setBinderException(err, line, column);
                    return false;
                };
                switch (iterator.createRange(&self.heap, &arguments)) {
                    .value => |range| self.setRegister(destination, Value.object(&range.header)),
                    .python_exception => |exception| {
                        self.setException(exception, line, column, null);
                        return false;
                    },
                    .engine_error => return self.engineFault(),
                }
                return true;
            },
        }
    }

    fn executeMakeFunction(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
        const code = self.activeCode() orelse return self.engineFault();
        const site_index: usize = instruction.index32();
        if (site_index >= code.function_sites.len) return self.engineFault();
        const site = code.function_sites[site_index];
        const nested_index: usize = site.code_index;
        if (nested_index >= code.nested_codes.len) return self.engineFault();
        const nested_code = code.nested_codes[nested_index];
        const start: usize = site.value_start;
        const default_count: usize = site.default_count;
        const annotation_count: usize = site.annotation_count + @as(usize, @intFromBool(site.has_return_annotation));
        const value_count = default_count + annotation_count;
        if (start > code.argument_registers.len or value_count > code.argument_registers.len - start) return self.engineFault();
        const allocator = self.heap.allocator;
        const defaults = allocator.alloc(Value, nested_code.parameter_names.len) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer allocator.free(defaults);
        @memset(defaults, Value.unboundValue());
        var default_index: usize = 0;
        for (nested_code.parameter_flags, 0..) |flags, parameter_index| {
            if (flags & ast_module.parameter_flags.has_default == 0) continue;
            if (default_index >= default_count) return self.engineFault();
            const register = code.argument_registers[start + default_index];
            if (!self.validRegister(register)) return self.engineFault();
            defaults[parameter_index] = self.registers[register];
            default_index += 1;
        }
        if (default_index != default_count) return self.engineFault();
        const annotations = allocator.alloc(Value, annotation_count) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer allocator.free(annotations);
        for (annotations, 0..) |*annotation, index| {
            const register = code.argument_registers[start + default_count + index];
            if (!self.validRegister(register)) return self.engineFault();
            annotation.* = self.registers[register];
        }
        const captured = allocator.alloc(*functions.Cell, nested_code.free_names.len) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer allocator.free(captured);
        for (nested_code.free_names, 0..) |name, index| {
            captured[index] = self.findCell(name) orelse return self.engineFault();
        }
        switch (functions.createPython(&self.heap, nested_code, &self.environment.header, captured, defaults, annotations)) {
            .value => |function| self.setRegister(instruction.a(), Value.object(&function.header)),
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
        }
        return true;
    }

    fn setBinderException(self: *Runtime, err: anyerror, line: u32, column: u32) void {
        const message: []const u8 = if (err == error.TooManyPositional) "too many positional arguments" else if (err == error.MissingArgument) "missing required argument" else if (err == error.MultipleValues) "multiple values for an argument" else if (err == error.PositionalOnlyAsKeyword) "positional-only argument passed as a keyword" else if (err == error.UnexpectedKeyword) "unexpected keyword argument" else if (err == error.OutOfMemory) "session memory limit exceeded" else "invalid call arguments";
        const kind: PythonExceptionKind = if (err == error.OutOfMemory) .memory_error else .type_error;
        self.setException(.{ .kind = kind, .message = message }, line, column, null);
    }

    fn storeFrameLocal(self: *Runtime, frame: *Frame, name: []const u8, value: Value) bool {
        if (indexOfName(frame.code.cell_names, name)) |index| {
            const cell = frame.local_cells[index] orelse return false;
            cell.value = value;
            return true;
        }
        const index = indexOfName(frame.code.local_names, name) orelse return false;
        frame.locals[index] = value;
        frame.roots[frame.localRootStart() + index].object = value.asObject();
        _ = self;
        return true;
    }

    fn findCell(self: *Runtime, name: []const u8) ?*functions.Cell {
        const frame = self.top_frame orelse return null;
        if (indexOfName(frame.code.cell_names, name)) |index| return frame.local_cells[index];
        if (indexOfName(frame.code.free_names, name)) |index| return frame.free_cells[index];
        return null;
    }

    fn loadLocal(self: *Runtime, destination: u16, name: []const u8, binding: u8, line: u32, column: u32) bool {
        const frame = self.top_frame orelse return self.engineFault();
        const kind: bytecode.LocalBinding = switch (binding) {
            0 => .local,
            1 => .cell,
            2 => .free,
            else => return self.engineFault(),
        };
        const value = switch (kind) {
            .local => blk: {
                const index = indexOfName(frame.code.local_names, name) orelse return self.engineFault();
                break :blk frame.locals[index];
            },
            .cell => blk: {
                const index = indexOfName(frame.code.cell_names, name) orelse return self.engineFault();
                const cell = frame.local_cells[index] orelse return self.engineFault();
                break :blk cell.value;
            },
            .free => blk: {
                const index = indexOfName(frame.code.free_names, name) orelse return self.engineFault();
                const cell = frame.free_cells[index] orelse return self.engineFault();
                break :blk cell.value;
            },
        };
        if (value.tag() == .unbound or value.tag() == .deleted) {
            const kind_error: PythonExceptionKind = if (kind == .free) .name_error else .unbound_local_error;
            self.setException(.{ .kind = kind_error, .message = "local variable is not bound" }, line, column, null);
            return false;
        }
        self.setRegister(destination, value);
        return true;
    }

    fn storeLocal(self: *Runtime, source: u16, name: []const u8, binding: u8) bool {
        const frame = self.top_frame orelse return self.engineFault();
        const kind: bytecode.LocalBinding = switch (binding) {
            0 => .local,
            1 => .cell,
            2 => .free,
            else => return self.engineFault(),
        };
        const value = self.registers[source];
        switch (kind) {
            .local => {
                const index = indexOfName(frame.code.local_names, name) orelse return self.engineFault();
                frame.locals[index] = value;
                frame.roots[frame.localRootStart() + index].object = value.asObject();
            },
            .cell => {
                const index = indexOfName(frame.code.cell_names, name) orelse return self.engineFault();
                const cell = frame.local_cells[index] orelse return self.engineFault();
                cell.value = value;
            },
            .free => {
                const index = indexOfName(frame.code.free_names, name) orelse return self.engineFault();
                const cell = frame.free_cells[index] orelse return self.engineFault();
                cell.value = value;
            },
        }
        return true;
    }

    fn clearGlobals(self: *Runtime) void {
        for (self.environment.entries.items) |entry| self.heap.allocator.free(entry.name);
        self.environment.entries.clearRetainingCapacity();
    }

    fn execute(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
        const code = self.activeCode() orelse return false;
        const op = instruction.opcodeTag() orelse return self.engineFault();
        switch (op) {
            .load_const => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                const index: usize = @intCast(instruction.index32());
                if (index >= code.constants.len) return self.engineFault();
                self.setRegister(instruction.a(), code.constants[index]);
            },
            .load_none => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                self.setRegister(instruction.a(), Value.noneValue());
            },
            .load_global => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                const name = self.codeName(instruction.index32()) orelse return self.engineFault();
                if (self.globalValue(name) orelse self.builtinValue(name)) |value| {
                    self.setRegister(instruction.a(), value);
                } else {
                    self.setException(.{ .kind = .name_error, .message = "name is not defined" }, line, column, name);
                    return false;
                }
            },
            .store_global => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                const name = self.codeName(instruction.index32()) orelse return self.engineFault();
                if (!self.storeGlobal(name, self.registers[instruction.a()])) {
                    self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
                    return false;
                }
            },
            .load_local => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                const name = self.codeName(instruction.index32()) orelse return self.engineFault();
                if (!self.loadLocal(instruction.a(), name, instruction.flags(), line, column)) return false;
            },
            .store_local => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                const name = self.codeName(instruction.index32()) orelse return self.engineFault();
                if (!self.storeLocal(instruction.a(), name, instruction.flags())) return false;
            },
            .move => {
                if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b())) return self.engineFault();
                self.setRegister(instruction.a(), self.registers[instruction.b()]);
            },
            .unary => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                const input = self.registers[instruction.a()];
                if (instruction.flags() == 3) {
                    const truth = self.valueTruthy(input, line, column) orelse return false;
                    self.setRegister(instruction.a(), if (truth) Value.falseValue() else Value.trueValue());
                    return true;
                }
                const result = switch (@as(u8, instruction.flags())) {
                    0 => number.positive(&self.heap, input),
                    1 => number.negative(&self.heap, input),
                    2 => number.bitNot(&self.heap, input),
                    else => return self.engineFault(),
                };
                if (!self.storeNumberResult(instruction.a(), result, line, column)) return false;
            },
            .binary => {
                if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b())) return self.engineFault();
                const left = self.registers[instruction.a()];
                const right = self.registers[instruction.b()];
                if (!self.executeBinary(instruction.a(), left, right, instruction.flags(), line, column)) return false;
            },
            .print => {
                if (self.globalValue("print") != null) {
                    self.setException(.{ .kind = .type_error, .message = "'int' object is not callable" }, line, column, null);
                    return false;
                }
                const start: usize = @intCast(instruction.index32());
                const count: usize = instruction.a();
                if (start > code.argument_registers.len or count > code.argument_registers.len - start) return self.engineFault();
                for (code.argument_registers[start..][0..count]) |register| if (!self.validRegister(register)) return self.engineFault();
                if (!self.executePrint(code.argument_registers[start..][0..count], line, column)) return false;
            },
            .return_value => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                const result = self.registers[instruction.a()];
                const frame = self.popFrame() orelse return self.engineFault();
                const return_destination = frame.return_destination;
                self.freeFrameStorage(frame);
                if (self.top_frame) |caller| {
                    const destination = return_destination orelse return self.engineFault();
                    if (!self.validRegister(destination)) return self.engineFault();
                    self.setRegister(destination, result);
                    _ = caller;
                } else if (return_destination != null) return self.engineFault();
            },
            .call => {
                if (!self.validRegister(instruction.a()) or !self.executeCall(instruction, line, column)) return false;
            },
            .make_function => {
                if (!self.validRegister(instruction.a()) or !self.executeMakeFunction(instruction, line, column)) return false;
            },
            .jump => {
                if (!self.validJump(instruction.index32())) return self.engineFault();
                self.instruction_pointer = instruction.index32();
            },
            .jump_if_false, .jump_if_true => {
                if (!self.validRegister(instruction.a()) or !self.validJump(instruction.index32())) return self.engineFault();
                const truth = self.valueTruthy(self.registers[instruction.a()], line, column) orelse return false;
                if ((op == .jump_if_false and !truth) or (op == .jump_if_true and truth)) self.instruction_pointer = instruction.index32();
            },
            .truth => {
                if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b())) return self.engineFault();
                const truth = self.valueTruthy(self.registers[instruction.b()], line, column) orelse return false;
                self.setRegister(instruction.a(), if (truth) Value.trueValue() else Value.falseValue());
            },
            .compare => {
                if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b()) or !self.validRegister(instruction.c())) return self.engineFault();
                const result = self.compareValues(self.registers[instruction.b()], self.registers[instruction.c()], instruction.flags(), line, column) orelse return false;
                self.setRegister(instruction.a(), if (result) Value.trueValue() else Value.falseValue());
            },
            .make_range => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                const start: usize = @intCast(instruction.index32());
                const count: usize = instruction.flags();
                if (start > code.argument_registers.len or count > code.argument_registers.len - start) return self.engineFault();
                for (code.argument_registers[start..][0..count]) |register| if (!self.validRegister(register)) return self.engineFault();
                if (self.globalValue("range") != null) {
                    self.setException(.{ .kind = .type_error, .message = "'int' object is not callable" }, line, column, null);
                    return false;
                }
                if (count == 0 or count > 3) {
                    self.setException(.{ .kind = .type_error, .message = "range expected 1 to 3 arguments" }, line, column, null);
                    return false;
                }
                var args: [3]Value = undefined;
                for (code.argument_registers[start..][0..count], 0..) |register, index| args[index] = self.registers[register];
                switch (iterator.createRange(&self.heap, args[0..count])) {
                    .value => |range| self.setRegister(instruction.a(), Value.object(&range.header)),
                    .python_exception => |exception| {
                        self.setException(exception, line, column, null);
                        return false;
                    },
                    .engine_error => return self.engineFault(),
                }
            },
            .get_iterator => {
                if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b())) return self.engineFault();
                switch (iterator.createIterator(&self.heap, self.registers[instruction.b()])) {
                    .value => |result| self.setRegister(instruction.a(), Value.object(&result.header)),
                    .python_exception => |exception| {
                        self.setException(exception, line, column, null);
                        return false;
                    },
                    .engine_error => return self.engineFault(),
                }
            },
            .for_next => {
                if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b()) or !self.validRegister(instruction.c())) return self.engineFault();
                const header = self.registers[instruction.b()].asObject() orelse return self.engineFault();
                const loop_iterator = iterator.iteratorFromHeader(header) orelse return self.engineFault();
                switch (iterator.next(&self.heap, loop_iterator)) {
                    .item => |item| {
                        self.setRegister(instruction.a(), item);
                        self.setRegister(instruction.c(), Value.trueValue());
                    },
                    .done => self.setRegister(instruction.c(), Value.falseValue()),
                    .python_exception => |exception| {
                        self.setException(exception, line, column, null);
                        return false;
                    },
                    .engine_error => return self.engineFault(),
                }
            },
        }
        return true;
    }

    fn executeBinary(self: *Runtime, destination: u16, left: Value, right: Value, operation: u8, line: u32, column: u32) bool {
        if (operation == 0) {
            const left_header = left.asObject() orelse null;
            const right_header = right.asObject() orelse null;
            if (left_header) |left_object| {
                if (right_header) |right_object| {
                    if (string.fromHeader(left_object)) |left_text| {
                        if (string.fromHeader(right_object)) |right_text| {
                            return switch (string.concat(&self.heap, left_text, right_text)) {
                                .value => |joined| blk: {
                                    self.setRegister(destination, Value.object(&joined.header));
                                    break :blk true;
                                },
                                .python_exception => |exception| blk: {
                                    self.setException(exception, line, column, null);
                                    break :blk false;
                                },
                                .engine_error => self.engineFault(),
                            };
                        }
                    }
                }
            }
        }
        const result = switch (operation) {
            0 => number.add(&self.heap, left, right),
            1 => number.subtract(&self.heap, left, right),
            2 => number.multiply(&self.heap, left, right),
            3 => return self.storeFloatResult(destination, number.trueDivide(&self.heap, left, right), line, column),
            4 => number.floorDiv(&self.heap, left, right),
            5 => number.modulo(&self.heap, left, right),
            6 => number.power(&self.heap, left, right),
            7 => number.bitAnd(&self.heap, left, right),
            8 => number.bitOr(&self.heap, left, right),
            9 => number.bitXor(&self.heap, left, right),
            10 => number.shiftLeft(&self.heap, left, right),
            11 => number.shiftRight(&self.heap, left, right),
            else => return self.engineFault(),
        };
        return self.storeNumberResult(destination, result, line, column);
    }

    fn storeNumberResult(self: *Runtime, destination: u16, result: number.ValueResult, line: u32, column: u32) bool {
        return switch (result) {
            .value => |value| blk: {
                self.setRegister(destination, value);
                break :blk true;
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => self.engineFault(),
        };
    }

    fn storeFloatResult(self: *Runtime, destination: u16, result: number.FloatResult, line: u32, column: u32) bool {
        return switch (result) {
            .value => |value| blk: {
                self.setRegister(destination, Value.fromFloat(value));
                break :blk true;
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => self.engineFault(),
        };
    }

    fn executePrint(self: *Runtime, registers: []const u16, line: u32, column: u32) bool {
        for (registers, 0..) |register, index| {
            if (index != 0 and !self.appendOutput(" ")) {
                self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
                return false;
            }
            if (!self.appendValue(self.registers[register], line, column)) {
                if (self.last_exception == null) self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
                return false;
            }
        }
        if (!self.appendOutput("\n")) {
                    self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        }
        return true;
    }

    fn executePrintValues(self: *Runtime, values: []const Value, separator: []const u8, ending: []const u8, line: u32, column: u32) bool {
        for (values, 0..) |value, index| {
            if (index != 0 and !self.appendOutput(separator)) {
                self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
                return false;
            }
            if (!self.appendValue(value, line, column)) {
                if (self.last_exception == null) self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
                return false;
            }
        }
        if (!self.appendOutput(ending)) {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        }
        return true;
    }

    fn appendValue(self: *Runtime, value: Value, line: u32, column: u32) bool {
        if (value.tag() == .none) return self.appendOutput("None");
        if (value.asBool()) |boolean| return self.appendOutput(if (boolean) "True" else "False");
        if (value.asSmallInt()) |integer| return self.appendFormatted("{d}", .{integer});
        if (value.asFloat()) |float_value| return self.appendFormatted("{d}", .{float_value});
        if (number.formatInteger(&self.heap, value)) |formatted| {
            return switch (formatted) {
                .value => |bytes| blk: {
                    defer self.heap.allocator.free(bytes);
                    break :blk self.appendOutput(bytes);
                },
                .python_exception => |exception| blk: {
                    self.setException(exception, line, column, null);
                    break :blk false;
                },
                .engine_error => false,
            };
        }
        if (value.asObject()) |header| {
            if (string.fromHeader(header)) |text| return self.appendOutput(string.content(text));
            if (iterator.rangeFromHeader(header)) |range| return self.appendRange(range, line, column);
            self.setException(.{ .kind = .type_error, .message = "object has no printable representation" }, line, column, null);
            return false;
        }
        return false;
    }

    fn appendRange(self: *Runtime, range: *const iterator.Range, line: u32, column: u32) bool {
        if (!self.appendOutput("range(")) return false;
        if (!self.appendInteger(range.start, line, column) or !self.appendOutput(", ") or !self.appendInteger(range.stop, line, column)) return false;
        const unit_step = number.equal(range.step, Value.fromSmallInt(1).?);
        const has_unit_step = switch (unit_step) {
            .value => |equal| equal,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        if (!has_unit_step and (!self.appendOutput(", ") or !self.appendInteger(range.step, line, column))) return false;
        return self.appendOutput(")");
    }

    fn appendInteger(self: *Runtime, value: Value, line: u32, column: u32) bool {
        const formatted = number.formatInteger(&self.heap, value) orelse {
            self.setException(.{ .kind = .type_error, .message = "range contains a non-integer" }, line, column, null);
            return false;
        };
        return switch (formatted) {
            .value => |bytes| blk: {
                defer self.heap.allocator.free(bytes);
                break :blk self.appendOutput(bytes);
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => self.engineFault(),
        };
    }

    fn valueTruthy(self: *Runtime, value: Value, line: u32, column: u32) ?bool {
        if (value.tag() == .none) return false;
        if (value.asBool()) |boolean| return boolean;
        if (value.asSmallInt()) |integer| return integer != 0;
        if (value.asFloat()) |float_value| return float_value != 0;
        if (number.isIntegerValue(value)) return !number.isZeroValue(value);
        if (value.asObject()) |header| {
            if (string.fromHeader(header)) |text| return text.data.len != 0;
            if (iterator.rangeFromHeader(header)) |range| switch (iterator.truthyRange(range)) {
                .value => |truth| return truth,
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return null;
                },
                .engine_error => {
                    _ = self.engineFault();
                    return null;
                },
            };
            return true;
        }
        return false;
    }

    fn compareValues(self: *Runtime, left: Value, right: Value, operation: u8, line: u32, column: u32) ?bool {
        if (operation == 6) return left.identical(right);
        if (operation == 7) return !left.identical(right);
        if (operation == 8 or operation == 9) {
            const contained = self.containsValue(left, right, line, column) orelse return null;
            return if (operation == 8) contained else !contained;
        }

        if (operation == 0 or operation == 1) {
            if (left.asObject()) |left_header| {
                if (right.asObject()) |right_header| {
                    if (string.fromHeader(left_header)) |left_text| {
                        if (string.fromHeader(right_header)) |right_text| {
                            const equal = string.equal(left_text, right_text);
                            return if (operation == 0) equal else !equal;
                        }
                    }
                }
            }
            return switch (number.equal(left, right)) {
                .value => |equal| if (operation == 0) equal else !equal,
                .python_exception => |exception| blk: {
                    self.setException(exception, line, column, null);
                    break :blk null;
                },
                .engine_error => blk: {
                    _ = self.engineFault();
                    break :blk null;
                },
            };
        }

        if (left.asObject()) |left_header| {
            if (right.asObject()) |right_header| {
                if (string.fromHeader(left_header)) |left_text| {
                    if (string.fromHeader(right_header)) |right_text| {
                        const order = std.mem.order(u8, string.content(left_text), string.content(right_text));
                        return compareOrder(order, operation);
                    }
                }
            }
        }
        return switch (number.compare(left, right)) {
            .value => |order| compareNumericOrder(order, operation),
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk null;
            },
            .engine_error => blk: {
                _ = self.engineFault();
                break :blk null;
            },
        };
    }

    fn containsValue(self: *Runtime, item: Value, container: Value, line: u32, column: u32) ?bool {
        const header = container.asObject() orelse {
            self.setException(.{ .kind = .type_error, .message = "argument of type is not iterable" }, line, column, null);
            return null;
        };
        if (iterator.rangeFromHeader(header)) |range| return switch (iterator.rangeContains(&self.heap, range, item)) {
            .value => |contains| contains,
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk null;
            },
            .engine_error => blk: {
                _ = self.engineFault();
                break :blk null;
            },
        };
        if (string.fromHeader(header)) |text| {
            const needle_header = item.asObject() orelse {
                self.setException(.{ .kind = .type_error, .message = "substring membership requires a string" }, line, column, null);
                return null;
            };
            const needle = string.fromHeader(needle_header) orelse {
                self.setException(.{ .kind = .type_error, .message = "substring membership requires a string" }, line, column, null);
                return null;
            };
            return std.mem.indexOf(u8, string.content(text), string.content(needle)) != null;
        }
        self.setException(.{ .kind = .type_error, .message = "object is not a supported container" }, line, column, null);
        return null;
    }

    fn appendFormatted(self: *Runtime, comptime format: []const u8, arguments: anytype) bool {
        const text = std.fmt.allocPrint(self.heap.allocator, format, arguments) catch return false;
        defer self.heap.allocator.free(text);
        return self.appendOutput(text);
    }

    fn appendOutput(self: *Runtime, bytes: []const u8) bool {
        self.stdout_bytes.appendSlice(self.heap.allocator, bytes) catch return false;
        return true;
    }

    fn setRegister(self: *Runtime, index: u16, value: Value) void {
        const position: usize = index;
        if (position >= self.registers.len) unreachable;
        self.registers[position] = value;
        self.register_roots[position].object = value.asObject();
    }

    fn validRegister(self: *const Runtime, index: u16) bool {
        return @as(usize, index) < self.registers.len;
    }

    fn validJump(self: *const Runtime, target: u32) bool {
        const code = self.activeCode() orelse return false;
        return @as(usize, target) <= code.instructions.len;
    }

    fn codeName(self: *const Runtime, index: u32) ?[]const u8 {
        const code = self.activeCode() orelse return null;
        const position: usize = @intCast(index);
        if (position >= code.names.len) return null;
        return code.names[position];
    }

    fn globalValue(self: *const Runtime, name: []const u8) ?Value {
        for (self.environment.entries.items) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.value;
        return null;
    }

    fn builtinValue(self: *const Runtime, name: []const u8) ?Value {
        if (std.mem.eql(u8, name, "print")) return if (self.print_builtin_root.object) |header| Value.object(header) else null;
        if (std.mem.eql(u8, name, "range")) return if (self.range_builtin_root.object) |header| Value.object(header) else null;
        return null;
    }

    fn activeCode(self: *const Runtime) ?*Code {
        const frame = self.top_frame orelse return null;
        return frame.code;
    }

    fn storeGlobal(self: *Runtime, name: []const u8, value: Value) bool {
        for (self.environment.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                entry.value = value;
                return true;
            }
        }
        const owned_name = self.heap.allocator.dupe(u8, name) catch return false;
        self.environment.entries.append(self.heap.allocator, .{ .name = owned_name, .value = value }) catch {
            self.heap.allocator.free(owned_name);
            return false;
        };
        return true;
    }

    fn setException(self: *Runtime, exception: PythonException, line: u32, column: u32, name: ?[]const u8) void {
        self.last_exception = exception;
        self.clearErrorText();
        const message = if (name) |missing| blk: {
            break :blk std.fmt.allocPrint(
                self.heap.allocator,
                "{s}: name '{s}' is not defined ({s}:{d}:{d})",
                .{ exceptionName(exception.kind), missing, self.currentFilename(), line, column },
            ) catch null;
        } else std.fmt.allocPrint(
            self.heap.allocator,
            "{s}: {s} ({s}:{d}:{d})",
            .{ exceptionName(exception.kind), exception.message, self.currentFilename(), line, column },
        ) catch null;
        if (message) |owned| {
            self.error_text_owned = owned;
        } else {
            self.error_text_static = "MemoryError: unable to format the Python exception";
        }
    }

    fn currentFilename(self: *const Runtime) []const u8 {
        if (self.activeCode()) |code| return code.filename;
        return "<module>";
    }

    fn setStaticError(self: *Runtime, text: []const u8) void {
        self.last_exception = null;
        self.clearErrorText();
        self.error_text_static = text;
    }

    fn clearErrorText(self: *Runtime) void {
        if (self.error_text_owned) |owned| self.heap.allocator.free(owned);
        self.error_text_owned = null;
        self.error_text_static = "";
    }

    fn engineFault(self: *Runtime) bool {
        self.engine_failed = true;
        return false;
    }
};

fn exceptionName(kind: PythonExceptionKind) []const u8 {
    return switch (kind) {
        .base_exception => "BaseException",
        .exception => "Exception",
        .memory_error => "MemoryError",
        .name_error => "NameError",
        .unbound_local_error => "UnboundLocalError",
        .zero_division_error => "ZeroDivisionError",
        .value_error => "ValueError",
        .overflow_error => "OverflowError",
        .type_error => "TypeError",
        .index_error => "IndexError",
        .unicode_decode_error => "UnicodeDecodeError",
    };
}

fn indexOfName(names: []const []const u8, name: []const u8) ?usize {
    for (names, 0..) |candidate, index| if (std.mem.eql(u8, candidate, name)) return index;
    return null;
}

fn compareOrder(order: std.math.Order, operation: u8) bool {
    return switch (operation) {
        2 => order == .lt,
        3 => order != .gt,
        4 => order == .gt,
        5 => order != .lt,
        else => false,
    };
}

fn compareNumericOrder(order: number.Comparison, operation: u8) bool {
    return switch (operation) {
        2 => order == .less,
        3 => order == .less or order == .equal,
        4 => order == .greater,
        5 => order == .greater or order == .equal,
        else => false,
    };
}
