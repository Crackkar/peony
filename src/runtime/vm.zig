const std = @import("std");
const bytecode = @import("frontend_bytecode");
const compiler = @import("frontend_compiler");
const gc = @import("runtime_gc");
const value_module = @import("runtime_value");
const number = @import("runtime_number");
const string = @import("runtime_string");
const byte_module = @import("runtime_bytes");
const sequence = @import("runtime_sequence");
const slice = @import("runtime_slice");
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
    repr_path: std.ArrayList(*gc.Header) = .empty,
    value_equality_depth: usize = 0,
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
        self.repr_path.deinit(self.heap.allocator);
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
        const positional_object = switch (sequence.createList(&self.heap, &.{})) {
            .value => |list| list,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        var call_roots = [_]gc.Root{
            .{ .object = &positional_object.header },
            .{ .object = null },
            .{ .object = null },
        };
        var call_root_frame = gc.RootFrame{};
        call_root_frame.push(&self.heap.roots);
        for (&call_roots) |*root| call_root_frame.add(root);
        var call_roots_active = true;
        defer if (call_roots_active) call_root_frame.pop();

        const keywords = allocator.alloc(binder.Keyword, count) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer allocator.free(keywords);
        var keyword_count: usize = 0;
        for (code.call_arguments[start..][0..count]) |argument| {
            if (!self.validRegister(argument.register)) return self.engineFault();
            const value = self.registers[argument.register];
            if (argument.keyword_name == std.math.maxInt(u32)) {
                if (argument.starred) {
                    const expanded = switch (iterator.createIterator(&self.heap, value)) {
                        .value => |selected| selected,
                        .python_exception => |exception| {
                            self.setException(exception, line, column, null);
                            return false;
                        },
                        .engine_error => return self.engineFault(),
                    };
                    call_roots[2].object = &expanded.header;
                    while (true) {
                        switch (iterator.next(&self.heap, expanded)) {
                            .item => |item| {
                                call_roots[1].object = item.asObject();
                                switch (sequence.append(&self.heap, positional_object, item)) {
                                    .value => {},
                                    .python_exception => |exception| {
                                        self.setException(exception, line, column, null);
                                        return false;
                                    },
                                    .engine_error => return self.engineFault(),
                                }
                            },
                            .done => break,
                            .python_exception => |exception| {
                                self.setException(exception, line, column, null);
                                return false;
                            },
                            .engine_error => return self.engineFault(),
                        }
                    }
                    call_roots[2].object = null;
                } else {
                    call_roots[1].object = value.asObject();
                    switch (sequence.append(&self.heap, positional_object, value)) {
                        .value => {},
                        .python_exception => |exception| {
                            self.setException(exception, line, column, null);
                            return false;
                        },
                        .engine_error => return self.engineFault(),
                    }
                }
            } else {
                const name = self.codeName(argument.keyword_name) orelse return self.engineFault();
                keywords[keyword_count] = .{ .name = name, .value = value };
                keyword_count += 1;
            }
        }
        const positional = positional_object.items.items;
        const callee = self.registers[instruction.a()];
        const header = callee.asObject() orelse {
            self.setException(.{ .kind = .type_error, .message = "object is not callable" }, line, column, null);
            return false;
        };
        const function = functions.functionFromHeader(header) orelse {
            self.setException(.{ .kind = .type_error, .message = "object is not callable" }, line, column, null);
            return false;
        };
        if (function.native) |native| return self.executeNativeCall(instruction.a(), native, function.bound_self, positional, keywords[0..keyword_count], line, column);

        const function_code = function.code orelse return self.engineFault();
        const bound = binder.bindFunction(
            &self.heap,
            allocator,
            function_code.parameter_names,
            function_code.parameter_flags,
            function.defaults,
            positional,
            keywords[0..keyword_count],
        ) catch |err| {
            self.setBinderException(err, line, column);
            return false;
        };
        defer allocator.free(bound);
        for (function_code.parameter_flags, 0..) |flags, index| {
            if (flags & binder.parameter_flags_module.var_positional != 0) {
                call_roots[1].object = bound[index].asObject();
            }
        }
        const bound_roots = allocator.alloc(gc.Root, bound.len) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer allocator.free(bound_roots);
        for (bound, 0..) |value, index| bound_roots[index] = .{ .object = value.asObject() };
        var bound_root_frame = gc.RootFrame{};
        bound_root_frame.push(&self.heap.roots);
        for (bound_roots) |*root| bound_root_frame.add(root);
        var bound_roots_active = true;
        defer if (bound_roots_active) bound_root_frame.pop();
        const frame = self.allocateFrame(function_code, instruction.a()) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        // Re-link the caller, frame and stable bound-value roots in strict LIFO
        // order. The bound roots stay above the frame until every cell is
        // created and initialized, so later cell allocations cannot sweep a
        // value whose provisional frame root has already become a Cell root.
        frame.root_frame.pop();
        bound_root_frame.pop();
        bound_roots_active = false;
        call_root_frame.pop();
        call_roots_active = false;
        frame.root_frame.push(&self.heap.roots);
        for (frame.roots) |*root| frame.root_frame.add(root);
        bound_root_frame.push(&self.heap.roots);
        for (bound_roots) |*root| bound_root_frame.add(root);
        bound_roots_active = true;
        for (function_code.parameter_names, 0..) |name, index| {
            const value = bound[index];
            if (indexOfName(function_code.local_names, name)) |local_index| {
                frame.locals[local_index] = value;
                frame.roots[frame.localRootStart() + local_index].object = value.asObject();
            } else if (indexOfName(function_code.cell_names, name)) |cell_index| {
                frame.roots[frame.cellRootStart() + cell_index].object = value.asObject();
            } else return self.engineFault();
        }
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
        bound_root_frame.pop();
        bound_roots_active = false;
        return true;
    }

    fn executeMaterializeStar(self: *Runtime, register: u16, line: u32, column: u32) bool {
        const source = self.registers[register];
        const created_iterator = iterator.createIterator(&self.heap, source);
        const iter = switch (created_iterator) {
            .value => |selected| selected,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        var iterator_root = gc.Root{ .object = &iter.header };
        var list_root = gc.Root{ .object = null };
        var item_root = gc.Root{ .object = null };
        var roots = gc.RootFrame{};
        roots.push(&self.heap.roots);
        roots.add(&iterator_root);
        roots.add(&list_root);
        roots.add(&item_root);
        defer roots.pop();

        const created_list = sequence.createList(&self.heap, &.{});
        const list = switch (created_list) {
            .value => |selected| selected,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        list_root.object = &list.header;
        while (true) {
            switch (iterator.next(&self.heap, iter)) {
                .item => |item| {
                    item_root.object = item.asObject();
                    switch (sequence.append(&self.heap, list, item)) {
                        .value => {},
                        .python_exception => |exception| {
                            self.setException(exception, line, column, null);
                            return false;
                        },
                        .engine_error => return self.engineFault(),
                    }
                },
                .done => break,
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            }
        }
        self.setRegister(register, Value.object(&list.header));
        return true;
    }

    fn extendListFromIterable(self: *Runtime, destination: u16, list: *sequence.List, source: Value, line: u32, column: u32) bool {
        var list_root = gc.Root{ .object = &list.header };
        var source_root = gc.Root{ .object = source.asObject() };
        var iterator_root = gc.Root{ .object = null };
        var item_root = gc.Root{ .object = null };
        var roots = gc.RootFrame{};
        roots.push(&self.heap.roots);
        roots.add(&list_root);
        roots.add(&source_root);
        roots.add(&iterator_root);
        roots.add(&item_root);
        defer roots.pop();

        if (source.asObject()) |source_header| {
            if (sequence.listFromHeader(source_header)) |other| {
                return self.storeVoidResult(destination, sequence.extend(&self.heap, list, other.items.items), line, column);
            }
            if (sequence.tupleFromHeader(source_header)) |other| {
                return self.storeVoidResult(destination, sequence.extend(&self.heap, list, other.items), line, column);
            }
        }
        const created = iterator.createIterator(&self.heap, source);
        const iter = switch (created) {
            .value => |selected| selected,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        iterator_root.object = &iter.header;
        while (true) {
            switch (iterator.next(&self.heap, iter)) {
                .item => |value| {
                    item_root.object = value.asObject();
                    switch (sequence.append(&self.heap, list, value)) {
                        .value => {},
                        .python_exception => |exception| {
                            self.setException(exception, line, column, null);
                            return false;
                        },
                        .engine_error => return self.engineFault(),
                    }
                },
                .done => break,
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            }
        }
        self.setRegister(destination, Value.noneValue());
        return true;
    }

    fn executeNativeCall(
        self: *Runtime,
        destination: u16,
        native: functions.Native,
        bound_self: Value,
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
            else => return self.executeOtherNativeCall(destination, native, bound_self, positional, keywords, line, column),
        }
    }

    fn executeOtherNativeCall(
        self: *Runtime,
        destination: u16,
        native: functions.Native,
        bound_self: Value,
        positional: []const Value,
        keywords: []const binder.Keyword,
        line: u32,
        column: u32,
    ) bool {
        switch (native) {
            .list_append, .list_extend, .list_insert, .list_pop, .list_remove, .list_clear, .list_index, .list_count, .list_reverse, .list_copy, .list_sort => {
                const header = bound_self.asObject() orelse return self.engineFault();
                const list = sequence.listFromHeader(header) orelse return self.engineFault();
                if (native == .list_sort) {
                    if (positional.len != 0 or keywords.len > 1 or (keywords.len == 1 and !std.mem.eql(u8, keywords[0].name, "reverse"))) return self.nativeTypeError(line, column, "invalid list.sort arguments");
                    var reverse = false;
                    if (keywords.len == 1) {
                        reverse = self.valueTruthy(keywords[0].value, line, column) orelse return false;
                    }
                    if (!self.sortList(list, reverse, line, column)) return false;
                    self.setRegister(destination, Value.noneValue());
                    return true;
                }
                if (keywords.len != 0) return self.nativeTypeError(line, column, "list method does not accept keyword arguments");
                switch (native) {
                    .list_append => {
                        if (positional.len != 1) return self.nativeArity(line, column);
                        return self.storeVoidResult(destination, sequence.append(&self.heap, list, positional[0]), line, column);
                    },
                    .list_extend => {
                        if (positional.len != 1) return self.nativeArity(line, column);
                        return self.extendListFromIterable(destination, list, positional[0], line, column);
                    },
                    .list_insert => {
                        if (positional.len != 2) return self.nativeArity(line, column);
                        return self.storeVoidResult(destination, sequence.insert(&self.heap, list, positional[0], positional[1]), line, column);
                    },
                    .list_pop => {
                        if (positional.len > 1) return self.nativeArity(line, column);
                        const index_value = if (positional.len == 0) Value.fromSmallInt(-1).? else positional[0];
                        if (!number.isIntegerValue(index_value)) return self.nativeTypeError(line, column, "'pop' index must be an integer");
                        if (index_value.asBool() == null and number.toInt(i64, index_value) == null) {
                            self.setException(.{ .kind = .overflow_error, .message = "Python int too large to convert to C ssize_t" }, line, column, null);
                            return false;
                        }
                        const index = sequence.getIndex(list.items.items.len, index_value);
                        const position = switch (index) {
                            .value => |value| value,
                            .python_exception => |exception| {
                                self.setException(exception, line, column, null);
                                return false;
                            },
                            .engine_error => return self.engineFault(),
                        };
                        return self.storeValueResult(destination, sequence.pop(list, position), line, column);
                    },
                    .list_remove => {
                        if (positional.len != 1) return self.nativeArity(line, column);
                        const index = self.findListItem(list, positional[0], line, column) orelse return false;
                        return self.storeVoidResult(destination, sequence.remove(&self.heap, list, index), line, column);
                    },
                    .list_clear => {
                        if (positional.len != 0) return self.nativeArity(line, column);
                        sequence.clear(&self.heap, list);
                        self.setRegister(destination, Value.noneValue());
                        return true;
                    },
                    .list_index, .list_count => {
                        if (positional.len != 1) return self.nativeArity(line, column);
                        var count: usize = 0;
                        var found: ?usize = null;
                        for (list.items.items, 0..) |value, index| {
                            const equal = self.valuesEqual(value, positional[0], line, column) orelse return false;
                            if (equal) {
                                count += 1;
                                if (found == null) found = index;
                            }
                        }
                        if (native == .list_index and found == null) {
                            self.setException(.{ .kind = .value_error, .message = "value is not in list" }, line, column, null);
                            return false;
                        }
                        self.setRegister(destination, Value.fromSmallInt(@intCast(if (native == .list_count) count else found.?)).?);
                        return true;
                    },
                    .list_reverse => {
                        if (positional.len != 0) return self.nativeArity(line, column);
                        sequence.reverse(list);
                        self.setRegister(destination, Value.noneValue());
                        return true;
                    },
                    .list_copy => {
                        if (positional.len != 0) return self.nativeArity(line, column);
                        return self.storeListResult(destination, sequence.copy(&self.heap, list), line, column);
                    },
                    else => return self.engineFault(),
                }
            },
            .str_find, .str_index, .str_split, .str_join, .str_strip, .str_upper, .str_lower, .str_replace, .str_count, .str_startswith, .str_endswith, .str_encode => {
                const header = bound_self.asObject() orelse return self.engineFault();
                const text = string.fromHeader(header) orelse return self.engineFault();
                return self.executeStringNative(destination, native, text, positional, keywords, line, column);
            },
            .bytes_split, .bytes_find, .bytes_decode => {
                const header = bound_self.asObject() orelse return self.engineFault();
                const data = byte_module.fromHeader(header) orelse return self.engineFault();
                return self.executeBytesNative(destination, native, data, positional, keywords, line, column);
            },
            .len => {
                if (positional.len != 1 or keywords.len != 0) return self.nativeArity(line, column);
                const value = positional[0];
                if (sequence.length(value)) |length_value| return self.setSmallInt(destination, length_value, line, column);
                if (value.asObject()) |header| {
                    if (string.fromHeader(header)) |text| return self.setSmallInt(destination, string.length(text), line, column);
                    if (byte_module.fromHeader(header)) |data| return self.setSmallInt(destination, data.data.len, line, column);
                    if (iterator.rangeFromHeader(header)) |range| {
                        const count = iterator.rangeLength(&self.heap, range);
                        const length_value = switch (count) {
                            .value => |result| result,
                            .python_exception => |exception| {
                                self.setException(exception, line, column, null);
                                return false;
                            },
                            .engine_error => return self.engineFault(),
                        };
                        if (number.toInt(i64, length_value) == null) {
                            self.setException(.{ .kind = .overflow_error, .message = "Python int too large to convert to C ssize_t" }, line, column, null);
                            return false;
                        }
                        self.setRegister(destination, length_value);
                        return true;
                    }
                }
                return self.nativeTypeError(line, column, "object has no length");
            },
            .list, .tuple => {
                if (keywords.len != 0 or positional.len > 1) return self.nativeArity(line, column);
                if (positional.len == 0) {
                    if (native == .list) return self.storeListResult(destination, sequence.createList(&self.heap, &.{}), line, column);
                    return self.storeTupleResult(destination, sequence.createTuple(&self.heap, &.{}), line, column);
                }
                return self.materializeSequence(destination, positional[0], native == .tuple, line, column);
            },
            .iter => {
                if (positional.len != 1 or keywords.len != 0) return self.nativeArity(line, column);
                return self.createIteratorResult(destination, positional[0], line, column);
            },
            .next => {
                if (positional.len != 1 or keywords.len != 0) return self.nativeArity(line, column);
                const header = positional[0].asObject() orelse return self.nativeTypeError(line, column, "object is not an iterator");
                const loop_iterator = iterator.iteratorFromHeader(header) orelse return self.nativeTypeError(line, column, "object is not an iterator");
                return switch (iterator.next(&self.heap, loop_iterator)) {
                    .item => |value| blk: {
                        self.setRegister(destination, value);
                        break :blk true;
                    },
                    .done => blk: {
                        self.setException(.{ .kind = .stop_iteration, .message = "" }, line, column, null);
                        break :blk false;
                    },
                    .python_exception => |exception| blk: {
                        self.setException(exception, line, column, null);
                        break :blk false;
                    },
                    .engine_error => self.engineFault(),
                };
            },
            .slice => return self.executeSliceBuiltin(destination, positional, keywords, line, column),
            .enumerate => {
                if (keywords.len != 0 or positional.len == 0 or positional.len > 2) return self.nativeArity(line, column);
                const start = if (positional.len == 2) positional[1] else Value.fromSmallInt(0).?;
                return self.storeIteratorOutcome(destination, iterator.createEnumerate(&self.heap, positional[0], start), line, column);
            },
            .zip => {
                if (keywords.len != 0) return self.nativeArity(line, column);
                return self.storeIteratorOutcome(destination, iterator.createZip(&self.heap, positional), line, column);
            },
            .reversed => {
                if (keywords.len != 0 or positional.len != 1) return self.nativeArity(line, column);
                return self.storeIteratorOutcome(destination, iterator.createReversed(&self.heap, positional[0]), line, column);
            },
            else => return self.engineFault(),
        }
    }

    fn executeStringNative(self: *Runtime, destination: u16, native: functions.Native, text: *string.Str, positional: []const Value, keywords: []const binder.Keyword, line: u32, column: u32) bool {
        if (keywords.len != 0) return self.nativeTypeError(line, column, "string method does not accept keyword arguments");
        switch (native) {
            .str_find, .str_index => {
                if (positional.len != 1) return self.nativeArity(line, column);
                const needle = self.valueString(positional[0]) orelse return self.nativeTypeError(line, column, "substring must be a string");
                const found = string.find(text, needle);
                if (native == .str_index and found == null) {
                    self.setException(.{ .kind = .value_error, .message = "substring not found" }, line, column, null);
                    return false;
                }
                const found_index: i64 = if (found) |index| std.math.cast(i64, index) orelse return self.nativeTypeError(line, column, "string is too large to search") else -1;
                return self.setSmallInt(destination, found_index, line, column);
            },
            .str_count => {
                if (positional.len != 1) return self.nativeArity(line, column);
                const needle = self.valueString(positional[0]) orelse return self.nativeTypeError(line, column, "substring must be a string");
                return self.setSmallInt(destination, string.count(text, needle), line, column);
            },
            .str_startswith, .str_endswith => {
                if (positional.len != 1) return self.nativeArity(line, column);
                const needle = self.valueString(positional[0]) orelse return self.nativeTypeError(line, column, "prefix/suffix must be a string");
                const yes = if (native == .str_startswith) string.startsWith(text, needle) else string.endsWith(text, needle);
                self.setRegister(destination, if (yes) Value.trueValue() else Value.falseValue());
                return true;
            },
            .str_strip, .str_upper, .str_lower => {
                if ((native == .str_strip and positional.len > 1) or (native != .str_strip and positional.len != 0)) return self.nativeArity(line, column);
                const result = switch (native) {
                    .str_strip => string.strip(&self.heap, text, if (positional.len == 0 or positional[0].tag() == .none) null else self.valueString(positional[0]) orelse return self.nativeTypeError(line, column, "strip characters must be a string")),
                    .str_upper => string.upper(&self.heap, text),
                    .str_lower => string.lower(&self.heap, text),
                    else => unreachable,
                };
                return self.storeStringResult(destination, result, line, column);
            },
            .str_replace => {
                if (positional.len < 2 or positional.len > 3) return self.nativeArity(line, column);
                const old = self.valueString(positional[0]) orelse return self.nativeTypeError(line, column, "replace arguments must be strings");
                const replacement = self.valueString(positional[1]) orelse return self.nativeTypeError(line, column, "replace arguments must be strings");
                var max_count: ?usize = null;
                if (positional.len == 3) {
                    if (!number.isIntegerValue(positional[2])) return self.nativeTypeError(line, column, "count must be an integer");
                    const count = number.toInt(i128, positional[2]) orelse std.math.maxInt(i128);
                    max_count = if (count < 0) null else std.math.cast(usize, count) orelse std.math.maxInt(usize);
                }
                return self.storeStringResult(destination, string.replace(&self.heap, text, old, replacement, max_count), line, column);
            },
            .str_encode => {
                if (positional.len > 1) return self.nativeArity(line, column);
                if (positional.len == 1 and !self.valueIsUtf8(positional[0])) return self.nativeTypeError(line, column, "only UTF-8 encoding is supported");
                return self.storeBytesResult(destination, byte_module.encode(&self.heap, text), line, column);
            },
            .str_split => {
                if (positional.len == 0) return self.splitStringWhitespaceResult(destination, text, line, column);
                if (positional.len != 1) return self.nativeArity(line, column);
                const separator = self.valueString(positional[0]) orelse return self.nativeTypeError(line, column, "separator must be a string");
                return self.splitStringResult(destination, text, separator, line, column);
            },
            .str_join => {
                if (positional.len != 1) return self.nativeArity(line, column);
                return self.joinStringResult(destination, text, positional[0], line, column);
            },
            else => return self.engineFault(),
        }
    }

    fn executeBytesNative(self: *Runtime, destination: u16, native: functions.Native, data: *byte_module.Bytes, positional: []const Value, keywords: []const binder.Keyword, line: u32, column: u32) bool {
        if (keywords.len != 0) return self.nativeTypeError(line, column, "bytes method does not accept keyword arguments");
        switch (native) {
            .bytes_find => {
                if (positional.len != 1) return self.nativeArity(line, column);
                const needle = self.valueBytes(positional[0]) orelse return self.nativeTypeError(line, column, "a bytes-like object is required");
                const found: i64 = if (std.mem.indexOf(u8, data.data, needle)) |index| std.math.cast(i64, index) orelse return self.nativeTypeError(line, column, "bytes object is too large to search") else -1;
                return self.setSmallInt(destination, found, line, column);
            },
            .bytes_decode => {
                if (positional.len > 1) return self.nativeArity(line, column);
                if (positional.len == 1 and !self.valueIsUtf8(positional[0])) return self.nativeTypeError(line, column, "only UTF-8 decoding is supported");
                return self.storeStringResult(destination, byte_module.decode(&self.heap, data), line, column);
            },
            .bytes_split => {
                if (positional.len != 1) return self.nativeArity(line, column);
                const sep = self.valueBytes(positional[0]) orelse return self.nativeTypeError(line, column, "separator must be bytes");
                return self.splitBytesResult(destination, data, sep, line, column);
            },
            else => return self.engineFault(),
        }
    }

    fn nativeTypeError(self: *Runtime, line: u32, column: u32, message: []const u8) bool {
        self.setException(.{ .kind = .type_error, .message = message }, line, column, null);
        return false;
    }

    fn nativeArity(self: *Runtime, line: u32, column: u32) bool {
        return self.nativeTypeError(line, column, "incorrect number of arguments");
    }

    fn storeVoidResult(self: *Runtime, destination: u16, result: exceptions.Result(void), line: u32, column: u32) bool {
        return switch (result) {
            .value => {
                self.setRegister(destination, Value.noneValue());
                return true;
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => self.engineFault(),
        };
    }

    fn storeValueResult(self: *Runtime, destination: u16, result: exceptions.Result(Value), line: u32, column: u32) bool {
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

    fn storeListResult(self: *Runtime, destination: u16, result: sequence.ListResult, line: u32, column: u32) bool {
        return switch (result) {
            .value => |list| blk: {
                self.setRegister(destination, Value.object(&list.header));
                break :blk true;
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => self.engineFault(),
        };
    }

    fn storeTupleResult(self: *Runtime, destination: u16, result: sequence.TupleResult, line: u32, column: u32) bool {
        return switch (result) {
            .value => |tuple| blk: {
                self.setRegister(destination, Value.object(&tuple.header));
                break :blk true;
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => self.engineFault(),
        };
    }

    fn setSmallInt(self: *Runtime, destination: u16, input: anytype, line: u32, column: u32) bool {
        const integer: i128 = @intCast(input);
        const narrowed = std.math.cast(i64, integer) orelse {
            self.setException(.{ .kind = .overflow_error, .message = "integer result exceeds machine bound" }, line, column, null);
            return false;
        };
        const value = Value.fromSmallInt(narrowed) orelse {
            self.setException(.{ .kind = .overflow_error, .message = "integer result exceeds tagged integer range" }, line, column, null);
            return false;
        };
        self.setRegister(destination, value);
        return true;
    }

    fn createIteratorResult(self: *Runtime, destination: u16, value: Value, line: u32, column: u32) bool {
        return self.storeIteratorOutcome(destination, iterator.createIterator(&self.heap, value), line, column);
    }

    fn storeIteratorOutcome(self: *Runtime, destination: u16, outcome: exceptions.Result(*iterator.Iterator), line: u32, column: u32) bool {
        return switch (outcome) {
            .value => |object| blk: {
                self.setRegister(destination, Value.object(&object.header));
                break :blk true;
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => self.engineFault(),
        };
    }

    fn materializeSequence(self: *Runtime, destination: u16, source: Value, want_tuple: bool, line: u32, column: u32) bool {
        if (source.asObject()) |header| {
            if (iterator.rangeFromHeader(header)) |range| {
                const count = switch (iterator.rangeLength(&self.heap, range)) {
                    .value => |value| value,
                    .python_exception => |exception| {
                        self.setException(exception, line, column, null);
                        return false;
                    },
                    .engine_error => return self.engineFault(),
                };
                const item_count = number.toInt(usize, count) orelse {
                    self.setException(.{ .kind = .memory_error, .message = "iterable is too large to materialize" }, line, column, null);
                    return false;
                };
                const estimated = std.math.mul(usize, item_count, @sizeOf(Value)) catch {
                    self.setException(.{ .kind = .memory_error, .message = "iterable is too large to materialize" }, line, column, null);
                    return false;
                };
                const remaining = self.session_allocator.max_bytes -| self.session_allocator.live_bytes;
                if (estimated > remaining) {
                    self.setException(.{ .kind = .memory_error, .message = "iterable is too large to materialize" }, line, column, null);
                    return false;
                }
            }
        }

        const iterator_value = switch (iterator.createIterator(&self.heap, source)) {
            .value => |object| object,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        var roots_frame = gc.RootFrame{};
        var roots = [_]gc.Root{
            .{ .object = &iterator_value.header },
            .{ .object = null },
            .{ .object = null },
        };
        roots_frame.push(&self.heap.roots);
        for (&roots) |*root| roots_frame.add(root);
        defer roots_frame.pop();

        const list = switch (sequence.createList(&self.heap, &.{})) {
            .value => |object| object,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        roots[1].object = &list.header;
        while (true) {
            switch (iterator.next(&self.heap, iterator_value)) {
                .item => |item| {
                    roots[2].object = item.asObject();
                    switch (sequence.append(&self.heap, list, item)) {
                        .value => {},
                        .python_exception => |exception| {
                            self.setException(exception, line, column, null);
                            return false;
                        },
                        .engine_error => return self.engineFault(),
                    }
                },
                .done => break,
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            }
        }
        if (!want_tuple) {
            self.setRegister(destination, Value.object(&list.header));
            return true;
        }
        return self.storeTupleResult(destination, sequence.createTuple(&self.heap, list.items.items), line, column);
    }

    fn executeSliceBuiltin(self: *Runtime, destination: u16, positional: []const Value, keywords: []const binder.Keyword, line: u32, column: u32) bool {
        if (keywords.len != 0 or positional.len == 0 or positional.len > 3) return self.nativeArity(line, column);
        const none = Value.noneValue();
        const start = if (positional.len == 1) none else positional[0];
        const stop = if (positional.len == 1) positional[0] else positional[1];
        const step = if (positional.len == 3) positional[2] else none;
        return switch (slice.create(&self.heap, start, stop, step)) {
            .value => |object| blk: {
                self.setRegister(destination, Value.object(&object.header));
                break :blk true;
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => self.engineFault(),
        };
    }

    fn valueString(_: *Runtime, value: Value) ?[]const u8 {
        const header = value.asObject() orelse return null;
        const text = string.fromHeader(header) orelse return null;
        return string.content(text);
    }

    fn valueBytes(_: *Runtime, value: Value) ?[]const u8 {
        const header = value.asObject() orelse return null;
        const data = byte_module.fromHeader(header) orelse return null;
        return data.data;
    }

    fn valueIsUtf8(self: *Runtime, value: Value) bool {
        const text = self.valueString(value) orelse return false;
        return std.mem.eql(u8, text, "utf-8") or std.mem.eql(u8, text, "utf8");
    }

    fn findListItem(self: *Runtime, list: *sequence.List, needle: Value, line: u32, column: u32) ?usize {
        for (list.items.items, 0..) |value, index| {
            const equal = self.valuesEqual(value, needle, line, column) orelse return null;
            if (equal) return index;
        }
        return null;
    }

    fn valuesEqual(self: *Runtime, left: Value, right: Value, line: u32, column: u32) ?bool {
        if (left.identical(right)) return true;
        if (self.value_equality_depth >= 128) {
            self.setException(.{ .kind = .recursion_error, .message = "maximum recursion depth exceeded in comparison" }, line, column, null);
            return null;
        }
        self.value_equality_depth += 1;
        defer self.value_equality_depth -= 1;
        if (left.asObject()) |left_header| {
            if (right.asObject()) |right_header| {
                if (string.fromHeader(left_header)) |left_text| if (string.fromHeader(right_header)) |right_text| return string.equal(left_text, right_text);
                if (byte_module.fromHeader(left_header)) |left_bytes| if (byte_module.fromHeader(right_header)) |right_bytes| return byte_module.equal(left_bytes, right_bytes);
                if (sequence.listFromHeader(left_header)) |left_list| if (sequence.listFromHeader(right_header)) |right_list| {
                    if (left_list.items.items.len != right_list.items.items.len) return false;
                    for (left_list.items.items, right_list.items.items) |a, b| {
                        const equal = self.valuesEqual(a, b, line, column) orelse return null;
                        if (!equal) return false;
                    }
                    return true;
                };
                if (sequence.tupleFromHeader(left_header)) |left_tuple| if (sequence.tupleFromHeader(right_header)) |right_tuple| {
                    if (left_tuple.items.len != right_tuple.items.len) return false;
                    for (left_tuple.items, right_tuple.items) |a, b| {
                        const equal = self.valuesEqual(a, b, line, column) orelse return null;
                        if (!equal) return false;
                    }
                    return true;
                };
            }
            return false;
        }
        if (right.asObject() != null) return false;
        if (number.isIntegerValue(left) or left.asFloat() != null) {
            if (!(number.isIntegerValue(right) or right.asFloat() != null)) return false;
            return switch (number.equal(left, right)) {
                .value => |equal| equal,
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
        return left.tag() == right.tag();
    }

    fn sortList(self: *Runtime, list: *sequence.List, reverse: bool, line: u32, column: u32) bool {
        var index: usize = 1;
        while (index < list.items.items.len) : (index += 1) {
            const item = list.items.items[index];
            var position = index;
            while (position > 0) {
                const order = self.sortOrder(item, list.items.items[position - 1], line, column) orelse return false;
                const precedes = if (reverse) order == .gt else order == .lt;
                if (!precedes) break;
                list.items.items[position] = list.items.items[position - 1];
                position -= 1;
            }
            list.items.items[position] = item;
        }
        return true;
    }

    fn sortOrder(self: *Runtime, left: Value, right: Value, line: u32, column: u32) ?std.math.Order {
        if (left.asObject()) |left_header| if (right.asObject()) |right_header| {
            if (string.fromHeader(left_header)) |left_text| if (string.fromHeader(right_header)) |right_text| return std.mem.order(u8, string.content(left_text), string.content(right_text));
        };
        return switch (number.compare(left, right)) {
            .value => |order| switch (order) {
                .less => .lt,
                .equal => .eq,
                .greater => .gt,
                .unordered => null,
            },
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

    fn splitStringResult(self: *Runtime, destination: u16, text: *string.Str, separator: []const u8, line: u32, column: u32) bool {
        const split = string.split(text, separator);
        const iterator_value = switch (split) {
            .value => |value| value,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        return self.splitStringIteratorResult(destination, text, iterator_value, line, column);
    }

    fn splitStringWhitespaceResult(self: *Runtime, destination: u16, text: *string.Str, line: u32, column: u32) bool {
        return self.splitStringIteratorResult(destination, text, string.splitWhitespace(text), line, column);
    }

    fn splitStringIteratorResult(
        self: *Runtime,
        destination: u16,
        text: *string.Str,
        iterator_value: string.SplitIterator,
        line: u32,
        column: u32,
    ) bool {
        var counter = iterator_value;
        var count: usize = 0;
        while (counter.next() != null) count += 1;
        const values = self.heap.allocator.alloc(Value, count) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer self.heap.allocator.free(values);
        const roots = self.heap.allocator.alloc(gc.Root, count) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer self.heap.allocator.free(roots);
        @memset(roots, .{ .object = null });
        var frame = gc.RootFrame{};
        frame.push(&self.heap.roots);
        var text_root = gc.Root{ .object = &text.header };
        frame.add(&text_root);
        for (roots) |*root| frame.add(root);
        defer frame.pop();
        var index: usize = 0;
        var parts = iterator_value;
        while (parts.next()) |part| {
            const created = string.create(&self.heap, part);
            const object = switch (created) {
                .value => |value| value,
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            };
            values[index] = Value.object(&object.header);
            roots[index].object = &object.header;
            index += 1;
        }
        return self.storeListResult(destination, sequence.createList(&self.heap, values[0..index]), line, column);
    }

    fn splitBytesResult(self: *Runtime, destination: u16, data: *byte_module.Bytes, separator: []const u8, line: u32, column: u32) bool {
        if (separator.len == 0) return self.nativeTypeError(line, column, "empty separator");
        var count: usize = 1;
        var cursor: usize = 0;
        while (std.mem.indexOf(u8, data.data[cursor..], separator)) |relative| {
            cursor += relative + separator.len;
            count += 1;
        }
        const values = self.heap.allocator.alloc(Value, count) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer self.heap.allocator.free(values);
        const roots = self.heap.allocator.alloc(gc.Root, count) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer self.heap.allocator.free(roots);
        @memset(roots, .{ .object = null });
        var frame = gc.RootFrame{};
        frame.push(&self.heap.roots);
        for (roots) |*root| frame.add(root);
        defer frame.pop();
        var offset: usize = 0;
        var parts: usize = 0;
        while (parts < count) : (parts += 1) {
            const relative = std.mem.indexOf(u8, data.data[offset..], separator);
            const end = if (relative) |found| offset + found else data.data.len;
            const created = byte_module.create(&self.heap, data.data[offset..end]);
            const object = switch (created) {
                .value => |value| value,
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            };
            values[parts] = Value.object(&object.header);
            roots[parts].object = &object.header;
            if (relative) |found| offset = end + found - found + separator.len else offset = data.data.len;
        }
        return self.storeListResult(destination, sequence.createList(&self.heap, values), line, column);
    }

    fn joinStringResult(self: *Runtime, destination: u16, separator: *string.Str, iterable: Value, line: u32, column: u32) bool {
        const count = sequence.length(iterable) orelse return self.nativeTypeError(line, column, "join expects a list or tuple");
        const parts = self.heap.allocator.alloc([]const u8, count) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer self.heap.allocator.free(parts);
        for (0..count) |index| {
            const value = sequence.itemAt(iterable, index) orelse return self.engineFault();
            parts[index] = self.valueString(value) orelse return self.nativeTypeError(line, column, "sequence item is not a string");
        }
        return self.storeStringResult(destination, string.join(&self.heap, separator.data, parts), line, column);
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
                } else if (builtinNative(name)) |native| {
                    switch (functions.createNative(&self.heap, native)) {
                        .value => |function| self.setRegister(instruction.a(), Value.object(&function.header)),
                        .python_exception => |exception| {
                            self.setException(exception, line, column, null);
                            return false;
                        },
                    }
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
            .make_sequence => return self.executeMakeSequence(instruction, line, column),
            .make_slice => return self.executeMakeSlice(instruction, line, column),
            .get_attribute => return self.executeGetAttribute(instruction, line, column),
            .get_item => return self.executeGetItem(instruction, line, column),
            .set_item => return self.executeSetItem(instruction, line, column),
            .delete_item => return self.executeDeleteItem(instruction, line, column),
            .delete_local => {
                const name = self.codeName(instruction.index32()) orelse return self.engineFault();
                return self.executeDeleteLocal(name, instruction.flags(), line, column);
            },
            .delete_global => {
                const name = self.codeName(instruction.index32()) orelse return self.engineFault();
                return self.executeDeleteGlobal(name, line, column);
            },
            .unpack => return self.executeUnpack(instruction, line, column),
            .materialize_star => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                return self.executeMaterializeStar(instruction.a(), line, column);
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

    fn executeMakeSequence(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
        const code = self.activeCode() orelse return self.engineFault();
        const site_index: usize = instruction.index32();
        if (!self.validRegister(instruction.a()) or site_index >= code.sequence_sites.len) return self.engineFault();
        const site = code.sequence_sites[site_index];
        const start: usize = site.argument_start;
        const count: usize = site.argument_count;
        if (start > code.argument_registers.len or count > code.argument_registers.len - start) return self.engineFault();
        const values = self.heap.allocator.alloc(Value, count) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer self.heap.allocator.free(values);
        for (code.argument_registers[start..][0..count], 0..) |register, index| {
            if (!self.validRegister(register)) return self.engineFault();
            values[index] = self.registers[register];
        }
        if (site.is_tuple) {
            return switch (sequence.createTuple(&self.heap, values)) {
                .value => |tuple| blk: {
                    self.setRegister(instruction.a(), Value.object(&tuple.header));
                    break :blk true;
                },
                .python_exception => |exception| blk: {
                    self.setException(exception, line, column, null);
                    break :blk false;
                },
                .engine_error => self.engineFault(),
            };
        }
        return switch (sequence.createList(&self.heap, values)) {
            .value => |list| blk: {
                self.setRegister(instruction.a(), Value.object(&list.header));
                break :blk true;
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => self.engineFault(),
        };
    }

    fn executeMakeSlice(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
        const code = self.activeCode() orelse return self.engineFault();
        const site_index: usize = instruction.index32();
        if (!self.validRegister(instruction.a()) or site_index >= code.slice_sites.len) return self.engineFault();
        const site = code.slice_sites[site_index];
        if (!self.validRegister(site.start) or !self.validRegister(site.stop) or !self.validRegister(site.step)) return self.engineFault();
        return switch (slice.create(&self.heap, self.registers[site.start], self.registers[site.stop], self.registers[site.step])) {
            .value => |object| blk: {
                self.setRegister(instruction.a(), Value.object(&object.header));
                break :blk true;
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => self.engineFault(),
        };
    }

    fn executeGetAttribute(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
        if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b())) return self.engineFault();
        const name = self.codeName(instruction.c()) orelse return self.engineFault();
        const receiver = self.registers[instruction.b()];
        const native = attributeNative(receiver, name) orelse {
            self.setException(.{ .kind = .attribute_error, .message = "object has no such attribute" }, line, column, null);
            return false;
        };
        switch (functions.createBoundNative(&self.heap, native, receiver)) {
            .value => |function| self.setRegister(instruction.a(), Value.object(&function.header)),
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
        }
        return true;
    }

    fn executeGetItem(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
        if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b()) or !self.validRegister(instruction.c())) return self.engineFault();
        const container = self.registers[instruction.b()];
        const index_value = self.registers[instruction.c()];
        const header = container.asObject() orelse {
            self.setException(.{ .kind = .type_error, .message = "object is not subscriptable" }, line, column, null);
            return false;
        };
        if (index_value.asObject()) |index_header| {
        if (slice.fromHeader(index_header) != null) return self.executeSliceItem(instruction.a(), container, index_value, line, column);
        }
        if (iterator.rangeFromHeader(header)) |range| {
            const result = iterator.rangeIndex(&self.heap, range, index_value);
            return self.storeValueResult(instruction.a(), result, line, column);
        }
        if (sequence.listFromHeader(header)) |list| return self.executeIndexedSequence(instruction.a(), container, list.items.items.len, index_value, line, column);
        if (sequence.tupleFromHeader(header)) |tuple| return self.executeIndexedSequence(instruction.a(), container, tuple.items.len, index_value, line, column);
        if (string.fromHeader(header)) |text| {
            const index = sequence.getIndex(string.length(text), index_value);
            return switch (index) {
                .value => |position| self.storeStringIndex(instruction.a(), text, position, line, column),
                .python_exception => |exception| blk: {
                    self.setException(exception, line, column, null);
                    break :blk false;
                },
                .engine_error => self.engineFault(),
            };
        }
        if (byte_module.fromHeader(header)) |data| {
            const index = sequence.getIndex(byte_module.length(data), index_value);
            return switch (index) {
                .value => |position| blk: {
                    self.setRegister(instruction.a(), Value.fromSmallInt(data.data[position]).?);
                    break :blk true;
                },
                .python_exception => |exception| blk: {
                    self.setException(exception, line, column, null);
                    break :blk false;
                },
                .engine_error => self.engineFault(),
            };
        }
        self.setException(.{ .kind = .type_error, .message = "object is not subscriptable" }, line, column, null);
        return false;
    }

    fn executeIndexedSequence(self: *Runtime, destination: u16, container: Value, length_value: usize, index_value: Value, line: u32, column: u32) bool {
        const index = sequence.getIndex(length_value, index_value);
        return switch (index) {
            .value => |position| blk: {
                const value = sequence.itemAt(container, position) orelse return self.engineFault();
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

    fn storeStringIndex(self: *Runtime, destination: u16, text: *string.Str, index: usize, line: u32, column: u32) bool {
        const bounded = std.math.cast(i64, index) orelse {
            self.setException(.{ .kind = .overflow_error, .message = "string is too large to index" }, line, column, null);
            return false;
        };
        return switch (string.index(&self.heap, text, bounded)) {
            .value => |character| blk: {
                self.setRegister(destination, Value.object(&character.header));
                break :blk true;
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => self.engineFault(),
        };
    }

    fn executeSliceItem(self: *Runtime, destination: u16, container: Value, slice_value: Value, line: u32, column: u32) bool {
        const header = container.asObject() orelse return self.engineFault();
        const slice_header = slice_value.asObject() orelse return self.engineFault();
        const slice_object = slice.fromHeader(slice_header) orelse return self.engineFault();
        if (iterator.rangeFromHeader(header)) |range| {
            const result = iterator.rangeSlice(&self.heap, range, slice_object);
            return switch (result) {
                .value => |value| blk: {
                    self.setRegister(destination, Value.object(&value.header));
                    break :blk true;
                },
                .python_exception => |exception| blk: {
                    self.setException(exception, line, column, null);
                    break :blk false;
                },
                .engine_error => self.engineFault(),
            };
        }
        if (sequence.listFromHeader(header)) |list| return self.sliceSequence(destination, container, list.items.items, slice_object, false, line, column);
        if (sequence.tupleFromHeader(header)) |tuple| return self.sliceSequence(destination, container, tuple.items, slice_object, true, line, column);
        if (string.fromHeader(header)) |text| {
            const normalized = slice.normalize(string.length(text), slice_object.start, slice_object.stop, slice_object.step);
            return switch (normalized) {
                .value => |indices| blk: {
                    const result = string.sliceNormalized(&self.heap, text, indices);
                    break :blk self.storeStringResult(destination, result, line, column);
                },
                .python_exception => |exception| blk: {
                    self.setException(exception, line, column, null);
                    break :blk false;
                },
                .engine_error => self.engineFault(),
            };
        }
        if (byte_module.fromHeader(header)) |data| {
            const normalized = slice.normalize(data.data.len, slice_object.start, slice_object.stop, slice_object.step);
            return switch (normalized) {
                .value => |indices| blk: {
                    const result = byte_module.sliceNormalized(&self.heap, data, indices);
                    break :blk self.storeBytesResult(destination, result, line, column);
                },
                .python_exception => |exception| blk: {
                    self.setException(exception, line, column, null);
                    break :blk false;
                },
                .engine_error => self.engineFault(),
            };
        }
        self.setException(.{ .kind = .type_error, .message = "object cannot be sliced" }, line, column, null);
        return false;
    }

    fn sliceSequence(self: *Runtime, destination: u16, container: Value, values: []const Value, slice_object: *slice.Slice, is_tuple: bool, line: u32, column: u32) bool {
        const normalized = slice.normalize(values.len, slice_object.start, slice_object.stop, slice_object.step);
        const indices = switch (normalized) {
            .value => |result| result,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        var output: std.ArrayList(Value) = .empty;
        defer output.deinit(self.heap.allocator);
        var index_value = indices.start;
        while (if (indices.step > 0) index_value < indices.stop else index_value > indices.stop) {
            output.append(self.heap.allocator, values[@intCast(index_value)]) catch {
                self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
                return false;
            };
            index_value = std.math.add(i128, index_value, indices.step) catch break;
        }
        _ = container;
        if (is_tuple) return switch (sequence.createTuple(&self.heap, output.items)) {
            .value => |tuple| blk: {
                self.setRegister(destination, Value.object(&tuple.header));
                break :blk true;
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => self.engineFault(),
        };
        return switch (sequence.createList(&self.heap, output.items)) {
            .value => |list| blk: {
                self.setRegister(destination, Value.object(&list.header));
                break :blk true;
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => self.engineFault(),
        };
    }

    fn storeStringResult(self: *Runtime, destination: u16, result: string.StringResult, line: u32, column: u32) bool {
        return switch (result) {
            .value => |text| blk: {
                self.setRegister(destination, Value.object(&text.header));
                break :blk true;
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => self.engineFault(),
        };
    }

    fn storeBytesResult(self: *Runtime, destination: u16, result: byte_module.BytesResult, line: u32, column: u32) bool {
        return switch (result) {
            .value => |data| blk: {
                self.setRegister(destination, Value.object(&data.header));
                break :blk true;
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => self.engineFault(),
        };
    }

    fn executeSetItem(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
        if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b()) or !self.validRegister(instruction.c())) return self.engineFault();
        const container = self.registers[instruction.b()].asObject() orelse {
            self.setException(.{ .kind = .type_error, .message = "object does not support item assignment" }, line, column, null);
            return false;
        };
        const list = sequence.listFromHeader(container) orelse {
            self.setException(.{ .kind = .type_error, .message = "object does not support item assignment" }, line, column, null);
            return false;
        };
        const index = sequence.getIndex(list.items.items.len, self.registers[instruction.c()]);
        const position = switch (index) {
            .value => |value| value,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        list.items.items[position] = self.registers[instruction.a()];
        return true;
    }

    fn executeDeleteItem(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
        if (!self.validRegister(instruction.b()) or !self.validRegister(instruction.c())) return self.engineFault();
        const container = self.registers[instruction.b()].asObject() orelse {
            self.setException(.{ .kind = .type_error, .message = "object does not support item deletion" }, line, column, null);
            return false;
        };
        const list = sequence.listFromHeader(container) orelse {
            self.setException(.{ .kind = .type_error, .message = "object does not support item deletion" }, line, column, null);
            return false;
        };
        const index = sequence.getIndex(list.items.items.len, self.registers[instruction.c()]);
        const position = switch (index) {
            .value => |value| value,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        _ = list.items.orderedRemove(position);
        return true;
    }

    fn executeDeleteLocal(self: *Runtime, name: []const u8, binding: u8, line: u32, column: u32) bool {
        const frame = self.top_frame orelse return self.engineFault();
        const kind: bytecode.LocalBinding = switch (binding) {
            0 => .local,
            1 => .cell,
            2 => .free,
            else => return self.engineFault(),
        };
        const target: *Value = switch (kind) {
            .local => blk: {
                const index = indexOfName(frame.code.local_names, name) orelse return self.engineFault();
                frame.roots[frame.localRootStart() + index].object = null;
                break :blk &frame.locals[index];
            },
            .cell => blk: {
                const index = indexOfName(frame.code.cell_names, name) orelse return self.engineFault();
                const cell = frame.local_cells[index] orelse return self.engineFault();
                break :blk &cell.value;
            },
            .free => blk: {
                const index = indexOfName(frame.code.free_names, name) orelse return self.engineFault();
                const cell = frame.free_cells[index] orelse return self.engineFault();
                break :blk &cell.value;
            },
        };
        if (target.tag() == .unbound or target.tag() == .deleted) {
            self.setException(.{ .kind = if (kind == .free) .name_error else .unbound_local_error, .message = "cannot delete unbound local" }, line, column, null);
            return false;
        }
        target.* = Value.deletedValue();
        return true;
    }

    fn executeDeleteGlobal(self: *Runtime, name: []const u8, line: u32, column: u32) bool {
        for (self.environment.entries.items, 0..) |entry, index| {
            if (!std.mem.eql(u8, entry.name, name)) continue;
            self.heap.allocator.free(entry.name);
            _ = self.environment.entries.orderedRemove(index);
            return true;
        }
        self.setException(.{ .kind = .name_error, .message = "name is not defined" }, line, column, name);
        return false;
    }

    fn executeUnpack(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
        const code = self.activeCode() orelse return self.engineFault();
        const site_index: usize = instruction.index32();
        if (!self.validRegister(instruction.a()) or site_index >= code.unpack_sites.len) return self.engineFault();
        const site = code.unpack_sites[site_index];
        const destination_start: usize = site.destination_start;
        const destination_count: usize = site.destination_count;
        if (destination_start > code.argument_registers.len or destination_count > code.argument_registers.len - destination_start) return self.engineFault();
        for (code.argument_registers[destination_start..][0..destination_count]) |destination| if (!self.validRegister(destination)) return self.engineFault();

        const source = self.registers[instruction.a()];
        const has_star = site.star_index != std.math.maxInt(u16);
        const minimum = if (has_star) destination_count -| 1 else destination_count;
        var known_length: ?usize = null;
        if (has_star) {
            known_length = sequence.length(source);
            if (source.asObject()) |header| {
                if (string.fromHeader(header)) |text| known_length = string.length(text);
                if (byte_module.fromHeader(header)) |data| known_length = data.data.len;
                if (iterator.rangeFromHeader(header)) |range| {
                    const length_result = iterator.rangeLength(&self.heap, range);
                    const length = switch (length_result) {
                        .value => |value| value,
                        .python_exception => |exception| {
                            self.setException(exception, line, column, null);
                            return false;
                        },
                        .engine_error => return self.engineFault(),
                    };
                    known_length = number.toInt(usize, length) orelse {
                        self.setException(.{ .kind = .memory_error, .message = "unpacked iterable exceeds available memory" }, line, column, null);
                        return false;
                    };
                }
            }
        }
        // Exact-size sources get exact temporary storage for starred unpacking.
        // Unknown iterators retain a temporary 65,536-item bound pending the
        // dynamically growing, session-accounted buffer work in Commit 23.
        const capacity: usize = if (!has_star)
            destination_count + 1
        else
            known_length orelse 65_536;
        const root_count = std.math.add(usize, capacity, 1) catch {
            self.setException(.{ .kind = .memory_error, .message = "unpacked iterable exceeds available memory" }, line, column, null);
            return false;
        };
        const values = self.heap.allocator.alloc(Value, capacity) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer self.heap.allocator.free(values);
        const roots = self.heap.allocator.alloc(gc.Root, root_count) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer self.heap.allocator.free(roots);
        @memset(roots, .{ .object = null });
        var root_frame = gc.RootFrame{};
        root_frame.push(&self.heap.roots);
        for (roots) |*root| root_frame.add(root);
        defer root_frame.pop();

        const created_iterator = iterator.createIterator(&self.heap, source);
        const loop_iterator = switch (created_iterator) {
            .value => |result| result,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        roots[0].object = &loop_iterator.header;
        var count: usize = 0;
        while (true) {
            switch (iterator.next(&self.heap, loop_iterator)) {
                .item => |value| {
                    if (!has_star and count >= destination_count) {
                        self.setException(.{ .kind = .value_error, .message = "too many values to unpack" }, line, column, null);
                        return false;
                    }
                    if (count == capacity) {
                        const message = if (has_star and known_length == null)
                            "unpacked iterator exceeds the temporary 65536-item limit"
                        else
                            "unpacked iterable exceeds its known length";
                        self.setException(.{ .kind = .memory_error, .message = message }, line, column, null);
                        return false;
                    }
                    values[count] = value;
                    roots[count + 1].object = value.asObject();
                    count += 1;
                },
                .done => break,
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            }
        }

        if (has_star) {
            if (count < minimum) {
                self.setException(.{ .kind = .value_error, .message = "not enough values to unpack" }, line, column, null);
                return false;
            }
            const star: usize = site.star_index;
            const tail_count = destination_count - star - 1;
            const middle_start = star;
            const middle_end = count - tail_count;
            const rest = sequence.createList(&self.heap, values[middle_start..middle_end]);
            const rest_value = switch (rest) {
                .value => |list| Value.object(&list.header),
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            };
            for (0..star) |index| self.setRegister(code.argument_registers[destination_start + index], values[index]);
            self.setRegister(code.argument_registers[destination_start + star], rest_value);
            for (star + 1..destination_count) |index| {
                const source_index = count - (destination_count - index);
                self.setRegister(code.argument_registers[destination_start + index], values[source_index]);
            }
            return true;
        }
        if (count != destination_count) {
            self.setException(.{ .kind = .value_error, .message = if (count < destination_count) "not enough values to unpack" else "too many values to unpack" }, line, column, null);
            return false;
        }
        for (0..count) |index| self.setRegister(code.argument_registers[destination_start + index], values[index]);
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
            if (sequence.length(left) != null and sequence.length(right) != null) {
                return self.storeValueResult(destination, sequence.concatenate(&self.heap, left, right), line, column);
            }
        }
        if (operation == 2) {
            if (sequence.length(left) != null) return self.storeValueResult(destination, sequence.repeat(&self.heap, left, right), line, column);
            if (sequence.length(right) != null) return self.storeValueResult(destination, sequence.repeat(&self.heap, right, left), line, column);
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
        return self.appendValueMode(value, false, line, column);
    }

    fn appendValueMode(self: *Runtime, value: Value, nested: bool, line: u32, column: u32) bool {
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
            if (string.fromHeader(header)) |text| {
                if (!nested) return self.appendOutput(string.content(text));
                return self.appendQuoted(string.content(text), false);
            }
            if (byte_module.fromHeader(header)) |data| return self.appendQuoted(data.data, true);
            if (sequence.listFromHeader(header)) |list| return self.appendSequence(header, list.items.items, false, line, column);
            if (sequence.tupleFromHeader(header)) |tuple| return self.appendSequence(header, tuple.items, true, line, column);
            if (iterator.rangeFromHeader(header)) |range| return self.appendRange(range, line, column);
            self.setException(.{ .kind = .type_error, .message = "object has no printable representation" }, line, column, null);
            return false;
        }
        return false;
    }

    fn appendSequence(self: *Runtime, header: *gc.Header, values: []const Value, is_tuple: bool, line: u32, column: u32) bool {
        for (self.repr_path.items) |ancestor| {
            if (ancestor == header) return self.appendOutput(if (is_tuple) "(...)" else "[...]");
        }
        if (self.repr_path.items.len >= 128) {
            self.setException(.{ .kind = .recursion_error, .message = "maximum recursion depth exceeded while getting the repr of an object" }, line, column, null);
            return false;
        }
        self.repr_path.append(self.heap.allocator, header) catch return false;
        defer _ = self.repr_path.pop();
        if (!self.appendOutput(if (is_tuple) "(" else "[")) return false;
        for (values, 0..) |value, index| {
            if (index != 0 and !self.appendOutput(", ")) return false;
            if (!self.appendValueMode(value, true, line, column)) return false;
        }
        if (is_tuple and values.len == 1 and !self.appendOutput(",")) return false;
        return self.appendOutput(if (is_tuple) ")" else "]");
    }

    fn appendQuoted(self: *Runtime, content: []const u8, is_bytes: bool) bool {
        if (is_bytes and !self.appendOutput("b")) return false;
        const has_single_quote = std.mem.indexOfScalar(u8, content, '\'') != null;
        const has_double_quote = std.mem.indexOfScalar(u8, content, '"') != null;
        const quote: u8 = if (has_single_quote and !has_double_quote) '"' else '\'';
        if (!self.appendOutput(&.{quote})) return false;
        for (content) |character| {
            const escaped = if (character == quote) switch (character) {
                '\'' => "\\'",
                '"' => "\\\"",
                else => unreachable,
            } else switch (character) {
                '\\' => "\\\\",
                '\n' => "\\n",
                '\r' => "\\r",
                '\t' => "\\t",
                else => null,
            };
            if (escaped) |text| {
                if (!self.appendOutput(text)) return false;
            } else if (character < 32 or character == 127 or (is_bytes and character >= 127)) {
                if (!self.appendFormatted("\\x{x:0>2}", .{character})) return false;
            } else if (!self.appendOutput(&.{character})) return false;
        }
        return self.appendOutput(&.{quote});
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
            if (sequence.length(value)) |count| return count != 0;
            if (string.fromHeader(header)) |text| return text.data.len != 0;
            if (byte_module.fromHeader(header)) |data| return data.data.len != 0;
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
                    if (sequence.listFromHeader(left_header)) |left_list| if (sequence.listFromHeader(right_header)) |right_list| {
                        const equal = self.valuesEqual(Value.object(&left_list.header), Value.object(&right_list.header), line, column) orelse return null;
                        return if (operation == 0) equal else !equal;
                    };
                    if (sequence.tupleFromHeader(left_header)) |left_tuple| if (sequence.tupleFromHeader(right_header)) |right_tuple| {
                        const equal = self.valuesEqual(Value.object(&left_tuple.header), Value.object(&right_tuple.header), line, column) orelse return null;
                        return if (operation == 0) equal else !equal;
                    };
                    if (byte_module.fromHeader(left_header)) |left_bytes| if (byte_module.fromHeader(right_header)) |right_bytes| {
                        const equal = byte_module.equal(left_bytes, right_bytes);
                        return if (operation == 0) equal else !equal;
                    };
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
        if (sequence.listFromHeader(header)) |list| {
            for (list.items.items) |candidate| {
                const equal = self.valuesEqual(candidate, item, line, column) orelse return null;
                if (equal) return true;
            }
            return false;
        }
        if (sequence.tupleFromHeader(header)) |tuple| {
            for (tuple.items) |candidate| {
                const equal = self.valuesEqual(candidate, item, line, column) orelse return null;
                if (equal) return true;
            }
            return false;
        }
        if (byte_module.fromHeader(header)) |data| {
            if (item.asObject()) |item_header| {
                if (byte_module.fromHeader(item_header)) |needle| return std.mem.indexOf(u8, data.data, needle.data) != null;
            }
            const needle: i128 = if (item.asBool()) |boolean|
                @intFromBool(boolean)
            else blk: {
                if (!number.isIntegerValue(item)) {
                    self.setException(.{ .kind = .type_error, .message = "a bytes-like object or integer is required" }, line, column, null);
                    return null;
                }
                break :blk number.toInt(i128, item) orelse {
                    self.setException(.{ .kind = .value_error, .message = "byte must be in range(0, 256)" }, line, column, null);
                    return null;
                };
            };
            if (needle < 0 or needle > 255) {
                self.setException(.{ .kind = .value_error, .message = "byte must be in range(0, 256)" }, line, column, null);
                return null;
            }
            return std.mem.indexOfScalar(u8, data.data, @intCast(needle)) != null;
        }
        self.setException(.{ .kind = .type_error, .message = "object is not a supported container" }, line, column, null);
        return null;
    }

    fn appendFormatted(self: *Runtime, comptime format: []const u8, arguments: anytype) bool {
        const text = std.fmt.allocPrint(self.heap.allocator, format, arguments) catch return false;
        defer self.heap.allocator.free(text);
        return self.appendOutput(text);
    }

    fn appendOutput(self: *Runtime, output: []const u8) bool {
        self.stdout_bytes.appendSlice(self.heap.allocator, output) catch return false;
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
        .recursion_error => "RecursionError",
        .type_error => "TypeError",
        .index_error => "IndexError",
        .unicode_decode_error => "UnicodeDecodeError",
        .attribute_error => "AttributeError",
        .stop_iteration => "StopIteration",
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

fn builtinNative(name: []const u8) ?functions.Native {
    if (std.mem.eql(u8, name, "len")) return .len;
    if (std.mem.eql(u8, name, "list")) return .list;
    if (std.mem.eql(u8, name, "tuple")) return .tuple;
    if (std.mem.eql(u8, name, "iter")) return .iter;
    if (std.mem.eql(u8, name, "next")) return .next;
    if (std.mem.eql(u8, name, "slice")) return .slice;
    if (std.mem.eql(u8, name, "enumerate")) return .enumerate;
    if (std.mem.eql(u8, name, "zip")) return .zip;
    if (std.mem.eql(u8, name, "reversed")) return .reversed;
    return null;
}

fn attributeNative(receiver: Value, name: []const u8) ?functions.Native {
    const header = receiver.asObject() orelse return null;
    if (sequence.listFromHeader(header) != null) {
        if (std.mem.eql(u8, name, "append")) return .list_append;
        if (std.mem.eql(u8, name, "extend")) return .list_extend;
        if (std.mem.eql(u8, name, "insert")) return .list_insert;
        if (std.mem.eql(u8, name, "pop")) return .list_pop;
        if (std.mem.eql(u8, name, "remove")) return .list_remove;
        if (std.mem.eql(u8, name, "clear")) return .list_clear;
        if (std.mem.eql(u8, name, "index")) return .list_index;
        if (std.mem.eql(u8, name, "count")) return .list_count;
        if (std.mem.eql(u8, name, "reverse")) return .list_reverse;
        if (std.mem.eql(u8, name, "copy")) return .list_copy;
        if (std.mem.eql(u8, name, "sort")) return .list_sort;
    }
    if (string.fromHeader(header) != null) {
        if (std.mem.eql(u8, name, "find")) return .str_find;
        if (std.mem.eql(u8, name, "index")) return .str_index;
        if (std.mem.eql(u8, name, "split")) return .str_split;
        if (std.mem.eql(u8, name, "join")) return .str_join;
        if (std.mem.eql(u8, name, "strip")) return .str_strip;
        if (std.mem.eql(u8, name, "upper")) return .str_upper;
        if (std.mem.eql(u8, name, "lower")) return .str_lower;
        if (std.mem.eql(u8, name, "replace")) return .str_replace;
        if (std.mem.eql(u8, name, "count")) return .str_count;
        if (std.mem.eql(u8, name, "startswith")) return .str_startswith;
        if (std.mem.eql(u8, name, "endswith")) return .str_endswith;
        if (std.mem.eql(u8, name, "encode")) return .str_encode;
    }
    if (byte_module.fromHeader(header) != null) {
        if (std.mem.eql(u8, name, "split")) return .bytes_split;
        if (std.mem.eql(u8, name, "find")) return .bytes_find;
        if (std.mem.eql(u8, name, "decode")) return .bytes_decode;
    }
    return null;
}
