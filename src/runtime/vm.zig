const std = @import("std");
const bytecode = @import("frontend_bytecode");
const compiler = @import("frontend_compiler");
const gc = @import("runtime_gc");
const value_module = @import("runtime_value");
const number = @import("runtime_number");
const string = @import("runtime_string");
const byte_module = @import("runtime_bytes");
const sequence = @import("runtime_sequence");
const dict_module = @import("runtime_dict");
const hash_module = @import("runtime_hash");
const slice = @import("runtime_slice");
const exceptions = @import("runtime_exception");
const iterator = @import("runtime_iterator");
const functions = @import("runtime_function");
const binder = @import("runtime_binder");
const ast_module = @import("frontend_ast");
const format_rules = @import("format.zig");

const Value = value_module.Value;
const Code = bytecode.Code;

var session_hash_nonce: u64 = 0;

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
    generator_owner: ?*iterator.Iterator = null,
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

fn destroyGeneratorFrameOpaque(pointer: *anyopaque, allocator: std.mem.Allocator) void {
    const frame: *Frame = @ptrCast(@alignCast(pointer));
    if (frame.root_frame.stack != null) frame.root_frame.pop();
    if (frame.roots.len != 0) allocator.free(frame.roots);
    if (frame.free_cells.len != 0) allocator.free(frame.free_cells);
    if (frame.local_cells.len != 0) allocator.free(frame.local_cells);
    if (frame.locals.len != 0) allocator.free(frame.locals);
    if (frame.registers.len != 0) allocator.free(frame.registers);
    allocator.destroy(frame);
}

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
    resuming_generator: ?*iterator.Iterator = null,
    synchronous_work_remaining: ?usize = null,
    stdout_bytes: std.ArrayList(u8) = .empty,
    repr_path: std.ArrayList(*gc.Header) = .empty,
    value_equality_depth: usize = 0,
    hash_seed: u64 = 0,
    last_exception: ?PythonException = null,
    error_text_owned: ?[]u8 = null,
    error_text_static: []const u8 = "",
    cancel_requested: bool = false,
    engine_failed: bool = false,
    initialized: bool = false,

    pub fn init(self: *Runtime, backing: std.mem.Allocator, max_bytes: usize) std.mem.Allocator.Error!void {
        self.* = .{};
        session_hash_nonce +%= 1;
        self.hash_seed = hash_module.mixSessionSeed(session_hash_nonce, @intFromPtr(self));
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
        while (self.popFrame()) |frame| {
            self.forgetGeneratorFrame(frame);
            self.freeFrameStorage(frame);
        }
    }

    fn unwindFramesUntil(self: *Runtime, boundary: *Frame) void {
        while (self.top_frame != boundary) {
            const frame = self.popFrame() orelse break;
            self.forgetGeneratorFrame(frame);
            self.freeFrameStorage(frame);
        }
    }

    fn forgetGeneratorFrame(self: *Runtime, frame: *Frame) void {
        _ = self;
        if (frame.generator_owner) |owner| {
            if (owner.generator_frame == @as(*anyopaque, @ptrCast(frame))) {
                owner.generator_frame = null;
                owner.generator_roots = &.{};
                owner.generator_done = true;
            }
        }
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

        var keyword_capacity = count;
        for (code.call_arguments[start..][0..count]) |argument| {
            if (!argument.double_starred) continue;
            if (!self.validRegister(argument.register)) return self.engineFault();
            const mapping_header = self.registers[argument.register].asObject() orelse return self.engineFault();
            const mapping = dict_module.dictFromHeader(mapping_header) orelse return self.engineFault();
            keyword_capacity = std.math.add(usize, keyword_capacity, mapping.size) catch {
                self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
                return false;
            };
        }
        const keywords = allocator.alloc(binder.Keyword, keyword_capacity) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer allocator.free(keywords);
        var keyword_count: usize = 0;
        for (code.call_arguments[start..][0..count]) |argument| {
            if (!self.validRegister(argument.register)) return self.engineFault();
            const value = self.registers[argument.register];
            if (argument.double_starred) {
                const mapping_header = value.asObject() orelse return self.engineFault();
                const mapping = dict_module.dictFromHeader(mapping_header) orelse return self.engineFault();
                for (mapping.entries.items) |entry| {
                    if (!entry.alive) continue;
                    const key_header = entry.key.asObject() orelse return self.nativeTypeError(line, column, "keywords must be strings");
                    const key = string.fromHeader(key_header) orelse return self.nativeTypeError(line, column, "keywords must be strings");
                    if (!self.appendCallKeyword(keywords, &keyword_count, string.content(key), entry.value, line, column)) return false;
                }
            } else if (argument.keyword_name == std.math.maxInt(u32)) {
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
                if (!self.appendCallKeyword(keywords, &keyword_count, name, value, line, column)) return false;
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
        const binding = binder.bindFunction(
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
        const bound = binding.values;
        defer allocator.free(bound);
        defer if (binding.extra_keywords.len != 0) allocator.free(binding.extra_keywords);
        for (function_code.parameter_flags, 0..) |flags, index| {
            if (flags & binder.parameter_flags_module.var_positional != 0) {
                call_roots[1].object = bound[index].asObject();
            }
            if (flags & binder.parameter_flags_module.var_keyword != 0) {
                const created = dict_module.create(&self.heap, false);
                const mapping = switch (created) {
                    .value => |selected| selected,
                    .python_exception => |exception| {
                        self.setException(exception, line, column, null);
                        return false;
                    },
                    .engine_error => return self.engineFault(),
                };
                call_roots[2].object = &mapping.header;
                for (binding.extra_keywords) |keyword| {
                    const key = switch (string.create(&self.heap, keyword.name)) {
                        .value => |selected| Value.object(&selected.header),
                        .python_exception => |exception| {
                            self.setException(exception, line, column, null);
                            return false;
                        },
                        .engine_error => return self.engineFault(),
                    };
                    if (!self.setMappingValue(mapping, key, keyword.value, line, column)) return false;
                }
                bound[index] = Value.object(&mapping.header);
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

    fn appendCallKeyword(self: *Runtime, keywords: []binder.Keyword, count: *usize, name: []const u8, value: Value, line: u32, column: u32) bool {
        for (keywords[0..count.*]) |previous| {
            if (std.mem.eql(u8, previous.name, name)) {
                self.setException(.{ .kind = .type_error, .message = "got multiple values for keyword argument" }, line, column, null);
                return false;
            }
        }
        if (count.* >= keywords.len) return self.engineFault();
        keywords[count.*] = .{ .name = name, .value = value };
        count.* += 1;
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
            .hash => {
                if (positional.len != 1 or keywords.len != 0) return self.nativeArity(line, column);
                const key_hash = self.pythonHash(positional[0], line, column) orelse return false;
                const signed: i64 = @bitCast(key_hash);
                const value = number.fromInt(&self.heap, signed);
                return self.storeValueResult(destination, value, line, column);
            },
            .str_constructor => {
                if (positional.len > 1 or keywords.len != 0) return self.nativeArity(line, column);
                const owned = if (positional.len == 0) blk: {
                    break :blk self.heap.allocator.dupe(u8, "") catch {
                        self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
                        return false;
                    };
                } else self.renderValueOwned(positional[0], false, line, column) orelse return false;
                defer self.heap.allocator.free(owned);
                return self.storeStringResult(destination, string.create(&self.heap, owned), line, column);
            },
            .format_builtin => {
                if (positional.len == 0 or positional.len > 2 or keywords.len != 0) return self.nativeArity(line, column);
                const spec = if (positional.len == 2) self.valueString(positional[1]) orelse return self.nativeTypeError(line, column, "format specifier must be a string") else "";
                return self.executeFormatValue(destination, positional[0], spec, 0, line, column);
            },
            .map, .filter => {
                if (keywords.len != 0 or (native == .filter and positional.len != 2) or (native == .map and positional.len < 2)) return self.nativeArity(line, column);
                const created = iterator.createMapFilter(&self.heap, native == .filter, positional[0], positional[1..]);
                return self.storeIteratorOutcome(destination, created, line, column);
            },
            .sorted => {
                if (positional.len != 1 or keywords.len > 2) return self.nativeArity(line, column);
                var reverse = false;
                var key: ?Value = null;
                for (keywords) |keyword| {
                    if (std.mem.eql(u8, keyword.name, "reverse")) reverse = self.valueTruthy(keyword.value, line, column) orelse return false else if (std.mem.eql(u8, keyword.name, "key")) {
                        if (keyword.value.tag() != .none and !self.isCallable(keyword.value)) return self.nativeTypeError(line, column, "key must be callable or None");
                        if (keyword.value.tag() != .none) key = keyword.value;
                    } else return self.nativeTypeError(line, column, "unexpected keyword argument");
                }
                const list_result = sequence.createList(&self.heap, &.{});
                const list = switch (list_result) {
                    .value => |selected| selected,
                    .python_exception => |exception| { self.setException(exception, line, column, null); return false; },
                    .engine_error => return self.engineFault(),
                };
                var list_root = gc.Root{ .object = &list.header };
                var root_frame = gc.RootFrame{};
                root_frame.push(&self.heap.roots);
                root_frame.add(&list_root);
                defer root_frame.pop();
                if (!self.extendListFromIterable(destination, list, positional[0], line, column)) return false;
                if (!self.sortListWithKey(list, key, reverse, destination, line, column)) return false;
                self.setRegister(destination, Value.object(&list.header));
                return true;
            },
            .dict, .set => return self.executeMappingConstructor(destination, native == .set, positional, keywords, line, column),
            .dict_get, .dict_keys, .dict_values, .dict_items, .dict_pop, .dict_setdefault, .dict_update, .dict_clear, .dict_copy,
            .set_add, .set_remove, .set_discard, .set_pop, .set_update, .set_clear, .set_copy,
            => return self.executeMappingMethod(destination, native, bound_self, positional, keywords, line, column),
            .list_append, .list_extend, .list_insert, .list_pop, .list_remove, .list_clear, .list_index, .list_count, .list_reverse, .list_copy, .list_sort => {
                const header = bound_self.asObject() orelse return self.engineFault();
                const list = sequence.listFromHeader(header) orelse return self.engineFault();
                if (native == .list_sort) {
                    if (positional.len != 0 or keywords.len > 2) return self.nativeTypeError(line, column, "invalid list.sort arguments");
                    var reverse = false;
                    var key: ?Value = null;
                    for (keywords) |keyword| {
                        if (std.mem.eql(u8, keyword.name, "reverse")) {
                            reverse = self.valueTruthy(keyword.value, line, column) orelse return false;
                        } else if (std.mem.eql(u8, keyword.name, "key")) {
                            if (keyword.value.tag() != .none and !self.isCallable(keyword.value)) return self.nativeTypeError(line, column, "key must be callable or None");
                            if (keyword.value.tag() != .none) key = keyword.value;
                        } else return self.nativeTypeError(line, column, "invalid list.sort arguments");
                    }
                    if (!self.sortListWithKey(list, key, reverse, destination, line, column)) return false;
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
                        if ((native == .list_count and positional.len != 1) or (native == .list_index and (positional.len < 1 or positional.len > 3))) return self.nativeArity(line, column);
                        const length = list.items.items.len;
                        const start = if (native == .list_index and positional.len >= 2) self.normalizeSearchBound(positional[1], length, line, column) orelse return false else 0;
                        const stop = if (native == .list_index and positional.len >= 3) self.normalizeSearchBound(positional[2], length, line, column) orelse return false else length;
                        var count: usize = 0;
                        var found: ?usize = null;
                        for (list.items.items[start..@max(start, stop)], start..) |value, index| {
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
            .str_find, .str_index, .str_split, .str_join, .str_strip, .str_upper, .str_lower, .str_replace, .str_count, .str_startswith, .str_endswith, .str_encode, .str_format => {
                const header = bound_self.asObject() orelse return self.engineFault();
                const text = string.fromHeader(header) orelse return self.engineFault();
                if (native == .str_format) return self.executeStrFormat(destination, text, positional, keywords, line, column);
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
                if (dict_module.sizeOf(value)) |mapping_length| {
                    const length_value = std.math.cast(i64, mapping_length) orelse {
                        self.setException(.{ .kind = .overflow_error, .message = "Python int too large to convert to C ssize_t" }, line, column, null);
                        return false;
                    };
                    return self.setSmallInt(destination, length_value, line, column);
                }
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
                return switch (self.nextIteratorValue(loop_iterator, destination, line, column)) {
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

    fn executeMappingConstructor(self: *Runtime, destination: u16, is_set: bool, positional: []const Value, keywords: []const binder.Keyword, line: u32, column: u32) bool {
        if (positional.len > 1 or (is_set and keywords.len != 0)) return self.nativeArity(line, column);
        const created = dict_module.create(&self.heap, is_set);
        const mapping = switch (created) {
            .value => |selected| selected,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        var root = gc.Root{ .object = &mapping.header };
        var roots = gc.RootFrame{};
        roots.push(&self.heap.roots);
        roots.add(&root);
        defer roots.pop();
        if (positional.len == 1) {
            if (is_set) {
                if (!self.updateSetFromIterable(mapping, positional[0], line, column)) return false;
            } else if (!self.updateDictFromValue(mapping, positional[0], line, column)) return false;
        }
        if (!is_set) for (keywords) |keyword| {
            const key = switch (string.create(&self.heap, keyword.name)) {
                .value => |selected| Value.object(&selected.header),
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            };
            if (!self.setMappingValue(mapping, key, keyword.value, line, column)) return false;
        };
        self.setRegister(destination, Value.object(&mapping.header));
        return true;
    }

    fn updateDictFromValue(self: *Runtime, mapping: *dict_module.Dict, source_value: Value, line: u32, column: u32) bool {
        if (source_value.asObject()) |source_header| if (dict_module.dictFromHeader(source_header)) |source| {
            if (!source.is_set) {
                for (source.entries.items) |entry| {
                    if (entry.alive and !self.setMappingValueWithHash(mapping, entry.key, entry.value, entry.hash, line, column)) return false;
                }
                return true;
            }
        };
        var roots: [7]gc.Root = [_]gc.Root{.{ .object = null }} ** 7;
        roots[0].object = &mapping.header;
        roots[1].object = source_value.asObject();
        var root_frame = gc.RootFrame{};
        root_frame.push(&self.heap.roots);
        for (&roots) |*root| root_frame.add(root);
        defer root_frame.pop();
        const created_iterator = iterator.createIterator(&self.heap, source_value);
        const source_iterator = switch (created_iterator) {
            .value => |selected| selected,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        roots[2].object = &source_iterator.header;
        while (true) {
            const next_pair = iterator.next(&self.heap, source_iterator);
            const pair = switch (next_pair) {
                .item => |selected| selected,
                .done => break,
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            };
            roots[3].object = pair.asObject();
            const pair_iterator_result = iterator.createIterator(&self.heap, pair);
            const pair_iterator = switch (pair_iterator_result) {
                .value => |selected| selected,
                .python_exception => {
                    self.setException(.{ .kind = .value_error, .message = "dictionary update sequence element is not a pair" }, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            };
            roots[4].object = &pair_iterator.header;
            const first = iterator.next(&self.heap, pair_iterator);
            roots[5].object = switch (first) {
                .item => |value| value.asObject(),
                .done => {
                    self.setException(.{ .kind = .value_error, .message = "dictionary update sequence element has length 0; 2 is required" }, line, column, null);
                    return false;
                },
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            };
            const first_value = switch (first) {
                .item => |value| value,
                else => unreachable,
            };
            const second = iterator.next(&self.heap, pair_iterator);
            roots[6].object = switch (second) {
                .item => |value| value.asObject(),
                .done => {
                    self.setException(.{ .kind = .value_error, .message = "dictionary update sequence element has length 1; 2 is required" }, line, column, null);
                    return false;
                },
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            };
            const second_value = switch (second) {
                .item => |value| value,
                else => unreachable,
            };
            switch (iterator.next(&self.heap, pair_iterator)) {
                .done => {},
                .item => {
                    self.setException(.{ .kind = .value_error, .message = "dictionary update sequence element has length greater than 2" }, line, column, null);
                    return false;
                },
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            }
            if (!self.setMappingValue(mapping, first_value, second_value, line, column)) return false;
        }
        return true;
    }

    fn updateSetFromIterable(self: *Runtime, target: *dict_module.Dict, source: Value, line: u32, column: u32) bool {
        var roots: [4]gc.Root = .{ .{ .object = &target.header }, .{ .object = source.asObject() }, .{ .object = null }, .{ .object = null } };
        var root_frame = gc.RootFrame{};
        root_frame.push(&self.heap.roots);
        for (&roots) |*root| root_frame.add(root);
        defer root_frame.pop();
        const created_iterator = iterator.createIterator(&self.heap, source);
        const source_iterator = switch (created_iterator) {
            .value => |selected| selected,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        roots[2].object = &source_iterator.header;
        while (true) switch (iterator.next(&self.heap, source_iterator)) {
            .item => |item| {
                roots[3].object = item.asObject();
                if (!self.setMappingValue(target, item, Value.noneValue(), line, column)) return false;
            },
            .done => return true,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
    }

    fn executeMappingMethod(self: *Runtime, destination: u16, native: functions.Native, bound_self: Value, positional: []const Value, keywords: []const binder.Keyword, line: u32, column: u32) bool {
        const header = bound_self.asObject() orelse return self.engineFault();
        const mapping = dict_module.dictFromHeader(header) orelse return self.engineFault();
        if (mapping.is_set != (native == .set_add or native == .set_remove or native == .set_discard or native == .set_pop or native == .set_update or native == .set_clear or native == .set_copy)) return self.engineFault();
        if (native == .dict_update) {
            if (positional.len > 1) return self.nativeArity(line, column);
            if (positional.len == 1 and !self.updateDictFromValue(mapping, positional[0], line, column)) return false;
            for (keywords) |keyword| {
                const key = switch (string.create(&self.heap, keyword.name)) {
                    .value => |selected| Value.object(&selected.header),
                    .python_exception => |exception| {
                        self.setException(exception, line, column, null);
                        return false;
                    },
                    .engine_error => return self.engineFault(),
                };
                if (!self.setMappingValue(mapping, key, keyword.value, line, column)) return false;
            }
            self.setRegister(destination, Value.noneValue());
            return true;
        }
        if (native == .set_update) {
            if (keywords.len != 0) return self.nativeTypeError(line, column, "set.update does not accept keyword arguments");
            for (positional) |source| if (!self.updateSetFromIterable(mapping, source, line, column)) return false;
            self.setRegister(destination, Value.noneValue());
            return true;
        }
        if (keywords.len != 0) return self.nativeTypeError(line, column, "mapping method does not accept keyword arguments");
        switch (native) {
            .dict_get => {
                if (positional.len < 1 or positional.len > 2) return self.nativeArity(line, column);
                const key_hash = self.pythonHash(positional[0], line, column) orelse return false;
                var context = DictEqualityContext{ .runtime = self, .line = line, .column = column };
                return switch (dict_module.get(mapping, positional[0], key_hash, &context, dictKeysEqual)) {
                    .value => |value| blk: { self.setRegister(destination, value); break :blk true; },
                    .missing => blk: { self.setRegister(destination, if (positional.len == 2) positional[1] else Value.noneValue()); break :blk true; },
                    .failed => self.last_exception == null and self.engineFault(),
                };
            },
            .dict_keys, .dict_values, .dict_items => {
                if (positional.len != 0) return self.nativeArity(line, column);
                const kind: dict_module.ViewKind = if (native == .dict_keys) .keys else if (native == .dict_values) .values else .items;
                return switch (dict_module.createView(&self.heap, mapping, kind)) {
                    .value => |view| blk: { self.setRegister(destination, Value.object(&view.header)); break :blk true; },
                    .python_exception => |exception| blk: { self.setException(exception, line, column, null); break :blk false; },
                    .engine_error => self.engineFault(),
                };
            },
            .dict_pop, .dict_setdefault => {
                if (positional.len < 1 or positional.len > (if (native == .dict_pop) @as(usize, 2) else 2)) return self.nativeArity(line, column);
                const key = positional[0];
                const key_hash = self.pythonHash(key, line, column) orelse return false;
                var context = DictEqualityContext{ .runtime = self, .line = line, .column = column };
                const lookup_result = dict_module.lookup(mapping, key, key_hash, &context, dictKeysEqual);
                switch (lookup_result) {
                    .failed => return self.last_exception == null and self.engineFault(),
                    .found => |index| {
                        const old_value = mapping.entries.items[index].value;
                        if (native == .dict_pop) {
                            _ = dict_module.delete(mapping, key, key_hash, &context, dictKeysEqual);
                        }
                        self.setRegister(destination, old_value);
                        return true;
                    },
                    .missing => {
                        if (native == .dict_pop) {
                            if (positional.len == 2) {
                                self.setRegister(destination, positional[1]);
                                return true;
                            }
                            self.setException(.{ .kind = .key_error, .message = "mapping key not found" }, line, column, null);
                            return false;
                        }
                        const value = if (positional.len == 2) positional[1] else Value.noneValue();
                        if (!self.setMappingValueWithHash(mapping, key, value, key_hash, line, column)) return false;
                        self.setRegister(destination, value);
                        return true;
                    },
                }
            },
            .dict_clear, .set_clear => {
                if (positional.len != 0) return self.nativeArity(line, column);
                dict_module.clear(&self.heap, mapping);
                self.setRegister(destination, Value.noneValue());
                return true;
            },
            .dict_copy, .set_copy => {
                if (positional.len != 0) return self.nativeArity(line, column);
                const copied = dict_module.copy(&self.heap, mapping);
                return self.storeDictResult(destination, copied, line, column);
            },
            .set_add => {
                if (positional.len != 1) return self.nativeArity(line, column);
                return self.storeVoidResult(destination, self.setMappingResult(mapping, positional[0], line, column), line, column);
            },
            .set_remove, .set_discard => {
                if (positional.len != 1) return self.nativeArity(line, column);
                const key_hash = self.pythonHash(positional[0], line, column) orelse return false;
                var context = DictEqualityContext{ .runtime = self, .line = line, .column = column };
                return switch (dict_module.delete(mapping, positional[0], key_hash, &context, dictKeysEqual)) {
                    .found => blk: { self.setRegister(destination, Value.noneValue()); break :blk true; },
                    .missing => blk: {
                        if (native == .set_remove) {
                            self.setException(.{ .kind = .key_error, .message = "element not found" }, line, column, null);
                            break :blk false;
                        }
                        self.setRegister(destination, Value.noneValue());
                        break :blk true;
                    },
                    .failed => self.last_exception == null and self.engineFault(),
                };
            },
            .set_pop => {
                if (positional.len != 0) return self.nativeArity(line, column);
                for (mapping.entries.items) |entry| if (entry.alive) {
                    var context = DictEqualityContext{ .runtime = self, .line = line, .column = column };
                    _ = dict_module.delete(mapping, entry.key, entry.hash, &context, dictKeysEqual);
                    self.setRegister(destination, entry.key);
                    return true;
                };
                self.setException(.{ .kind = .key_error, .message = "pop from an empty set" }, line, column, null);
                return false;
            },
            else => return self.engineFault(),
        }
    }

    fn setMappingResult(self: *Runtime, mapping: *dict_module.Dict, key: Value, line: u32, column: u32) exceptions.Result(void) {
        const key_hash = self.pythonHash(key, line, column) orelse return .{ .python_exception = self.last_exception.? };
        var context = DictEqualityContext{ .runtime = self, .line = line, .column = column };
        return dict_module.set(&self.heap, mapping, key, Value.noneValue(), key_hash, &context, dictKeysEqual);
    }

    fn storeDictResult(self: *Runtime, destination: u16, result: exceptions.Result(*dict_module.Dict), line: u32, column: u32) bool {
        return switch (result) {
            .value => |mapping| blk: { self.setRegister(destination, Value.object(&mapping.header)); break :blk true; },
            .python_exception => |exception| blk: { self.setException(exception, line, column, null); break :blk false; },
            .engine_error => self.engineFault(),
        };
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

    fn executeFormatValue(self: *Runtime, destination: u16, value: Value, spec: []const u8, conversion: u8, line: u32, column: u32) bool {
        const rendered = self.makeFormattedText(value, spec, conversion, line, column) orelse return false;
        defer self.heap.allocator.free(rendered);
        return self.storeStringResult(destination, string.create(&self.heap, rendered), line, column);
    }

    fn executeStrFormat(self: *Runtime, destination: u16, template: *string.Str, positional: []const Value, keywords: []const binder.Keyword, line: u32, column: u32) bool {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.heap.allocator);
        const source = string.content(template);
        var index: usize = 0;
        var automatic: usize = 0;
        var numbering_mode: enum { unset, automatic, manual } = .unset;
        while (index < source.len) {
            if (index + 1 < source.len and source[index] == '{' and source[index + 1] == '{') {
                output.append(self.heap.allocator, '{') catch { _ = self.formatMemoryFailure(line, column); return false; };
                index += 2;
                continue;
            }
            if (index + 1 < source.len and source[index] == '}' and source[index + 1] == '}') {
                output.append(self.heap.allocator, '}') catch { _ = self.formatMemoryFailure(line, column); return false; };
                index += 2;
                continue;
            }
            if (source[index] == '}') {
                _ = self.formatValueError(line, column, "single '}' encountered in format string");
                return false;
            }
            if (source[index] != '{') {
                output.append(self.heap.allocator, source[index]) catch { _ = self.formatMemoryFailure(line, column); return false; };
                index += 1;
                continue;
            }
            const close = std.mem.indexOfScalarPos(u8, source, index + 1, '}') orelse { _ = self.formatValueError(line, column, "unmatched '{' in format string"); return false; };
            const field = source[index + 1 .. close];
            const colon = std.mem.indexOfScalar(u8, field, ':');
            const name = if (colon) |at| field[0..at] else field;
            const spec = if (colon) |at| field[at + 1 ..] else "";
            var value: ?Value = null;
            if (name.len == 0) {
                if (numbering_mode == .manual) {
                    _ = self.formatValueError(line, column, "cannot switch from manual field specification to automatic field numbering");
                    return false;
                }
                numbering_mode = .automatic;
                if (automatic >= positional.len) { _ = self.formatValueError(line, column, "replacement index out of range"); return false; }
                value = positional[automatic];
                automatic += 1;
            } else if (std.fmt.parseInt(usize, name, 10) catch null) |position| {
                if (numbering_mode == .automatic) {
                    _ = self.formatValueError(line, column, "cannot switch from automatic field numbering to manual field specification");
                    return false;
                }
                numbering_mode = .manual;
                if (position >= positional.len) { _ = self.formatValueError(line, column, "replacement index out of range"); return false; }
                value = positional[position];
            } else {
                for (keywords) |keyword| if (std.mem.eql(u8, keyword.name, name)) {
                    value = keyword.value;
                    break;
                };
            }
            const selected = value orelse {
                self.setException(.{ .kind = .key_error, .message = "format key is missing" }, line, column, null);
                return false;
            };
            const formatted = self.makeFormattedText(selected, spec, 0, line, column) orelse return false;
            defer self.heap.allocator.free(formatted);
            output.appendSlice(self.heap.allocator, formatted) catch { _ = self.formatMemoryFailure(line, column); return false; };
            index = close + 1;
        }
        const owned = output.toOwnedSlice(self.heap.allocator) catch { _ = self.formatMemoryFailure(line, column); return false; };
        defer self.heap.allocator.free(owned);
        return self.storeStringResult(destination, string.create(&self.heap, owned), line, column);
    }

    fn makeFormattedText(self: *Runtime, value: Value, spec: []const u8, conversion: u8, line: u32, column: u32) ?[]u8 {
        var text: []u8 = undefined;
        if (conversion == 2 or conversion == 3) {
            text = self.renderValueOwned(value, true, line, column) orelse return null;
        } else if ((conversion == 0 or conversion == 1) and value.asObject() != null) {
            if (string.fromHeader(value.asObject().?)) |string_value| {
                text = self.heap.allocator.dupe(u8, string.content(string_value)) catch return self.formatMemoryFailure(line, column);
            } else {
                text = self.renderValueOwned(value, conversion == 2, line, column) orelse return null;
            }
        } else {
            text = self.renderValueOwned(value, false, line, column) orelse return null;
        }
        defer self.heap.allocator.free(text);
        if (conversion == 3) {
            const ascii = self.asciiEscape(text) orelse return self.formatMemoryFailure(line, column);
            self.heap.allocator.free(text);
            text = ascii;
        }
        if (spec.len == 0) return self.heap.allocator.dupe(u8, text) catch self.formatMemoryFailure(line, column);
        const is_string = conversion != 0 or (value.asObject() != null and string.fromHeader(value.asObject().?) != null);
        return self.applyFormatSpec(value, text, spec, line, column, is_string);
    }

    fn renderValueOwned(self: *Runtime, value: Value, nested: bool, line: u32, column: u32) ?[]u8 {
        const saved = self.stdout_bytes;
        self.stdout_bytes = .empty;
        const ok = self.appendValueMode(value, nested, line, column);
        const rendered = self.stdout_bytes.toOwnedSlice(self.heap.allocator) catch null;
        self.stdout_bytes = saved;
        if (!ok or rendered == null) {
            if (rendered) |owned| self.heap.allocator.free(owned);
            if (self.last_exception == null) self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return null;
        }
        return rendered.?;
    }

    fn asciiEscape(self: *Runtime, input: []const u8) ?[]u8 {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.heap.allocator);
        var index: usize = 0;
        while (index < input.len) {
            const first = input[index];
            if (first < 0x80) {
                output.append(self.heap.allocator, first) catch return null;
                index += 1;
                continue;
            }
            const width = std.unicode.utf8ByteSequenceLength(first) catch 1;
            const slice_bytes = input[index..@min(input.len, index + width)];
            const scalar = std.unicode.utf8Decode(slice_bytes) catch first;
            var escaped: []u8 = undefined;
            if (scalar <= 0xff) {
                escaped = std.fmt.allocPrint(self.heap.allocator, "\\x{x:0>2}", .{scalar}) catch return null;
            } else if (scalar <= 0xffff) {
                escaped = std.fmt.allocPrint(self.heap.allocator, "\\u{x:0>4}", .{scalar}) catch return null;
            } else {
                escaped = std.fmt.allocPrint(self.heap.allocator, "\\U{x:0>8}", .{scalar}) catch return null;
            }
            defer self.heap.allocator.free(escaped);
            output.appendSlice(self.heap.allocator, escaped) catch return null;
            index += width;
        }
        return output.toOwnedSlice(self.heap.allocator) catch null;
    }

    fn applyFormatSpec(self: *Runtime, value: Value, text: []const u8, spec: []const u8, line: u32, column: u32, force_string: bool) ?[]u8 {
        const parsed = format_rules.parse(spec) catch |err| return switch (err) {
            error.Overflow => self.formatMemoryFailure(line, column),
            error.MissingPrecisionDigits => self.formatValueError(line, column, "precision requires digits"),
            error.Invalid => self.formatValueError(line, column, "invalid format specifier"),
        };
        const kind = parsed.kind;
        const is_string = force_string or (value.asObject() != null and string.fromHeader(value.asObject().?) != null);
        if (is_string) {
            if ((kind != 0 and kind != 's') or parsed.sign_specified or parsed.alternate or parsed.comma or parsed.alignment == '=') return self.formatValueError(line, column, "invalid format specifier for string");
            const selected = if (parsed.precision) |precision| truncateUtf8(text, precision) else text;
            return self.padFormatted(selected, parsed.width, parsed.fill, parsed.alignment, 0, line, column);
        }
        if (kind == 'c') {
            if (!number.isIntegerValue(value)) return self.formatTypeError(line, column, "'c' requires an integer");
            if (parsed.sign_specified or parsed.alternate or parsed.comma or parsed.precision != null or parsed.alignment == '=') return self.formatValueError(line, column, "invalid format specifier with 'c'");
            const scalar = number.toInt(u21, value) orelse return self.formatValueError(line, column, "character argument not in range(0x110000)");
            var encoded: [4]u8 = undefined;
            const length = std.unicode.utf8Encode(scalar, &encoded) catch return self.formatValueError(line, column, "character argument not in range(0x110000)");
            return self.padFormatted(encoded[0..length], parsed.width, parsed.fill, parsed.alignment, 0, line, column);
        }
        const is_float_kind = kind == 'e' or kind == 'E' or kind == 'f' or kind == 'F' or kind == 'g' or kind == 'G' or kind == '%';
        const use_float = is_float_kind or (kind == 0 and value.asFloat() != null);
        if (use_float) {
            const float_value = switch (number.toFloat(&self.heap, value)) {
                .value => |selected| selected,
                .python_exception => |exception| { self.setException(exception, line, column, null); return null; },
                .engine_error => { _ = self.engineFault(); return null; },
            };
            if (kind == 0) {
                var default_text = if (parsed.precision) |precision|
                    self.formatFloat(float_value, precision, 'g', parsed.alternate, line, column) orelse return null
                else
                    self.heap.allocator.dupe(u8, text) catch return self.formatMemoryFailure(line, column);
                if (parsed.comma) {
                    const grouped = self.groupThousands(default_text) orelse {
                        self.heap.allocator.free(default_text);
                        return self.formatMemoryFailure(line, column);
                    };
                    self.heap.allocator.free(default_text);
                    default_text = grouped;
                }
                defer self.heap.allocator.free(default_text);
                return self.padSignedNumeric(default_text, parsed, line, column);
            }
            if (parsed.alternate and kind != 'g' and kind != 'G') return self.formatValueError(line, column, "alternate form is not supported for this float format");
            if (parsed.comma and (kind == 'e' or kind == 'E' or kind == 'g' or kind == 'G')) return self.formatValueError(line, column, "grouping is not supported for this float format");
            const actual_kind: u8 = if (kind == 0) 'g' else kind;
            const precision = parsed.precision orelse 6;
            const scaled = if (actual_kind == '%') float_value * 100 else float_value;
            var float_text = self.formatFloat(scaled, precision, actual_kind, parsed.alternate, line, column) orelse return null;
            if (parsed.comma) {
                const grouped = self.groupThousands(float_text) orelse { self.heap.allocator.free(float_text); return self.formatMemoryFailure(line, column); };
                self.heap.allocator.free(float_text);
                float_text = grouped;
            }
            defer self.heap.allocator.free(float_text);
            if (actual_kind == '%') {
                const percent = self.heap.allocator.dupeZ(u8, float_text) catch return self.formatMemoryFailure(line, column);
                defer self.heap.allocator.free(percent);
                var composed: std.ArrayList(u8) = .empty;
                defer composed.deinit(self.heap.allocator);
                composed.appendSlice(self.heap.allocator, percent) catch return self.formatMemoryFailure(line, column);
                composed.append(self.heap.allocator, '%') catch return self.formatMemoryFailure(line, column);
                const result = composed.toOwnedSlice(self.heap.allocator) catch return self.formatMemoryFailure(line, column);
                defer self.heap.allocator.free(result);
                return self.padSignedNumeric(result, parsed, line, column);
            }
            return self.padSignedNumeric(float_text, parsed, line, column);
        }
        if (kind != 0 and kind != 'd' and kind != 'b' and kind != 'o' and kind != 'x' and kind != 'X') return self.formatValueError(line, column, "invalid format specifier");
        if (!number.isIntegerValue(value)) return self.formatTypeError(line, column, "integer format requires an integer");
        if (parsed.precision != null or (parsed.comma and kind != 0 and kind != 'd')) return self.formatValueError(line, column, "invalid format specifier for integer");
        const base: u8 = if (kind == 'b') 2 else if (kind == 'o') 8 else if (kind == 'x' or kind == 'X') 16 else 10;
        const digits_result = number.formatIntegerBase(&self.heap, value, base, if (kind == 'X') .upper else .lower) orelse return self.formatTypeError(line, column, "integer format requires an integer");
        var digits_owned = switch (digits_result) {
            .value => |selected| selected,
            .python_exception => |exception| { self.setException(exception, line, column, null); return null; },
            .engine_error => { _ = self.engineFault(); return null; },
        };
        defer self.heap.allocator.free(digits_owned);
        const negative = digits_owned.len != 0 and digits_owned[0] == '-';
        const digit_start: usize = @intFromBool(negative);
        var digit_slice = digits_owned[digit_start..];
        if (parsed.comma) {
            const grouped = self.groupThousands(digit_slice) orelse return self.formatMemoryFailure(line, column);
            self.heap.allocator.free(digits_owned);
            digits_owned = grouped;
            digit_slice = digits_owned;
        }
        const prefix: []const u8 = if (parsed.alternate and base == 16) (if (kind == 'X') "0X" else "0x") else if (parsed.alternate and base == 8) "0o" else if (parsed.alternate and base == 2) "0b" else "";
        const sign: []const u8 = if (negative) "-" else if (parsed.sign == '+') "+" else if (parsed.sign == ' ') " " else "";
        var composed: std.ArrayList(u8) = .empty;
        defer composed.deinit(self.heap.allocator);
        composed.appendSlice(self.heap.allocator, sign) catch return self.formatMemoryFailure(line, column);
        composed.appendSlice(self.heap.allocator, prefix) catch return self.formatMemoryFailure(line, column);
        composed.appendSlice(self.heap.allocator, digit_slice) catch return self.formatMemoryFailure(line, column);
        const numeric = composed.toOwnedSlice(self.heap.allocator) catch return self.formatMemoryFailure(line, column);
        defer self.heap.allocator.free(numeric);
        return self.padFormatted(numeric, parsed.width, parsed.fill, parsed.alignment, sign.len + prefix.len, line, column);
    }

    fn padSignedNumeric(self: *Runtime, text: []const u8, spec: format_rules.Spec, line: u32, column: u32) ?[]u8 {
        const has_minus = text.len != 0 and text[0] == '-';
        const has_sign = has_minus or spec.sign_specified;
        const sign: []const u8 = if (has_minus) "-" else if (spec.sign == '+') "+" else if (spec.sign == ' ') " " else "";
        if (!has_sign) return self.padFormatted(text, spec.width, spec.fill, spec.alignment, 0, line, column);
        var combined: std.ArrayList(u8) = .empty;
        defer combined.deinit(self.heap.allocator);
        combined.appendSlice(self.heap.allocator, sign) catch return self.formatMemoryFailure(line, column);
        if (has_minus) combined.appendSlice(self.heap.allocator, text[1..]) catch return self.formatMemoryFailure(line, column) else combined.appendSlice(self.heap.allocator, text) catch return self.formatMemoryFailure(line, column);
        const signed = combined.toOwnedSlice(self.heap.allocator) catch return self.formatMemoryFailure(line, column);
        defer self.heap.allocator.free(signed);
        return self.padFormatted(signed, spec.width, spec.fill, spec.alignment, sign.len, line, column);
    }

    fn padFormatted(self: *Runtime, text: []const u8, width: usize, fill: u8, requested_align: u8, head_len: usize, line: u32, column: u32) ?[]u8 {
        const length = std.unicode.utf8CountCodepoints(text) catch text.len;
        if (width <= length) return self.heap.allocator.dupe(u8, text) catch self.formatMemoryFailure(line, column);
        const padding = width - length;
        if (padding > self.remainingSessionBytes()) return self.formatMemoryFailure(line, column);
        const alignment = if (requested_align == 0) '>' else requested_align;
        const left = if (alignment == '<') 0 else if (alignment == '^') padding / 2 else padding;
        const right = padding - left;
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.heap.allocator);
        const internal = alignment == '=' and head_len != 0;
        if (!internal) output.appendNTimes(self.heap.allocator, fill, left) catch return self.formatMemoryFailure(line, column);
        if (internal) {
            output.appendSlice(self.heap.allocator, text[0..@min(head_len, text.len)]) catch return self.formatMemoryFailure(line, column);
            output.appendNTimes(self.heap.allocator, fill, padding) catch return self.formatMemoryFailure(line, column);
            output.appendSlice(self.heap.allocator, text[@min(head_len, text.len)..]) catch return self.formatMemoryFailure(line, column);
        } else output.appendSlice(self.heap.allocator, text) catch return self.formatMemoryFailure(line, column);
        if (!internal) output.appendNTimes(self.heap.allocator, fill, right) catch return self.formatMemoryFailure(line, column);
        return output.toOwnedSlice(self.heap.allocator) catch self.formatMemoryFailure(line, column);
    }

    fn formatFloat(self: *Runtime, value: f64, precision: usize, kind: u8, alternate: bool, line: u32, column: u32) ?[]u8 {
        if (precision > 256 or precision > self.remainingSessionBytes()) return self.formatMemoryFailure(line, column);
        const upper = kind == 'E' or kind == 'F' or kind == 'G';
        if (kind == 'g' or kind == 'G') return self.formatGeneralFloat(value, precision, alternate, upper, line, column);
        const scientific = kind == 'e' or kind == 'E';
        const rendered_value = if (scientific) value else roundDecimalTieEven(value, precision);
        const mode: std.fmt.float.Mode = if (scientific) .scientific else .decimal;
        var buffer: [std.fmt.float.bufferSize(.decimal, f64)]u8 = undefined;
        const rendered = std.fmt.float.render(&buffer, rendered_value, .{ .mode = mode, .precision = precision }) catch return self.formatMemoryFailure(line, column);
        if (scientific) {
            const marker = std.mem.indexOfScalar(u8, rendered, 'e') orelse return self.formatValueError(line, column, "float formatter omitted exponent");
            const mantissa = rendered[0..marker];
            const parsed_exponent = std.fmt.parseInt(i32, rendered[marker + 1 ..], 10) catch return self.formatValueError(line, column, "invalid float exponent");
            return self.normalizedScientific(mantissa, parsed_exponent, upper, line, column);
        }
        const owned = self.heap.allocator.dupe(u8, rendered) catch return self.formatMemoryFailure(line, column);
        if (upper) {
            for (@constCast(owned)) |*character| character.* = std.ascii.toUpper(character.*);
        }
        return owned;
    }

    fn formatGeneralFloat(self: *Runtime, value: f64, precision: usize, alternate: bool, upper: bool, line: u32, column: u32) ?[]u8 {
        const significant = if (precision == 0) 1 else precision;
        var buffer: [std.fmt.float.bufferSize(.decimal, f64)]u8 = undefined;
        const rendered = std.fmt.float.render(&buffer, value, .{ .mode = .scientific, .precision = significant - 1 }) catch return self.formatMemoryFailure(line, column);
        const marker = std.mem.indexOfScalar(u8, rendered, 'e') orelse {
            const special = self.heap.allocator.dupe(u8, rendered) catch return self.formatMemoryFailure(line, column);
            if (upper) {
                for (@constCast(special)) |*character| character.* = std.ascii.toUpper(character.*);
            }
            return special;
        };
        const exponent = std.fmt.parseInt(i32, rendered[marker + 1 ..], 10) catch return self.formatValueError(line, column, "invalid float exponent");
        const mantissa = if (alternate) rendered[0..marker] else trimFloatZeros(rendered[0..marker]);
        if (exponent < -4 or exponent >= @as(i32, @intCast(significant))) {
            return self.normalizedScientific(mantissa, exponent, upper, line, column);
        }
        return self.scientificMantissaToFixed(mantissa, exponent, line, column);
    }

    fn normalizedScientific(self: *Runtime, mantissa: []const u8, exponent: i32, upper: bool, line: u32, column: u32) ?[]u8 {
        const marker: u8 = if (upper) 'E' else 'e';
        const sign: u8 = if (exponent < 0) '-' else '+';
        const magnitude: u32 = @intCast(@abs(exponent));
        const result = std.fmt.allocPrint(self.heap.allocator, "{s}{c}{c}{d:0>2}", .{ mantissa, marker, sign, magnitude }) catch return self.formatMemoryFailure(line, column);
        return result;
    }

    fn scientificMantissaToFixed(self: *Runtime, mantissa: []const u8, exponent: i32, line: u32, column: u32) ?[]u8 {
        const negative = mantissa.len != 0 and mantissa[0] == '-';
        const unsigned = if (negative) mantissa[1..] else mantissa;
        var digits: std.ArrayList(u8) = .empty;
        defer digits.deinit(self.heap.allocator);
        for (unsigned) |character| if (character != '.') {
            digits.append(self.heap.allocator, character) catch return self.formatMemoryFailure(line, column);
        };
        const decimal_position_signed = 1 + exponent;
        const decimal_position: usize = if (decimal_position_signed > 0) @intCast(decimal_position_signed) else 0;
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.heap.allocator);
        if (negative) output.append(self.heap.allocator, '-') catch return self.formatMemoryFailure(line, column);
        if (decimal_position_signed <= 0) {
            output.appendSlice(self.heap.allocator, "0.") catch return self.formatMemoryFailure(line, column);
            output.appendNTimes(self.heap.allocator, '0', @intCast(-decimal_position_signed)) catch return self.formatMemoryFailure(line, column);
            output.appendSlice(self.heap.allocator, digits.items) catch return self.formatMemoryFailure(line, column);
        } else if (decimal_position >= digits.items.len) {
            output.appendSlice(self.heap.allocator, digits.items) catch return self.formatMemoryFailure(line, column);
            output.appendNTimes(self.heap.allocator, '0', decimal_position - digits.items.len) catch return self.formatMemoryFailure(line, column);
        } else {
            output.appendSlice(self.heap.allocator, digits.items[0..decimal_position]) catch return self.formatMemoryFailure(line, column);
            output.append(self.heap.allocator, '.') catch return self.formatMemoryFailure(line, column);
            output.appendSlice(self.heap.allocator, digits.items[decimal_position..]) catch return self.formatMemoryFailure(line, column);
        }
        return output.toOwnedSlice(self.heap.allocator) catch self.formatMemoryFailure(line, column);
    }

    fn groupThousands(self: *Runtime, input: []const u8) ?[]u8 {
        const dot = std.mem.indexOfAny(u8, input, ".eE") orelse input.len;
        const sign: usize = if (input.len != 0 and (input[0] == '-' or input[0] == '+')) 1 else 0;
        const integer_digits = dot - sign;
        if (integer_digits <= 3) return self.heap.allocator.dupe(u8, input) catch null;
        const commas = (integer_digits - 1) / 3;
        const total = input.len + commas;
        var output = self.heap.allocator.alloc(u8, total) catch return null;
        var out: usize = 0;
        for (input, 0..) |character, index| {
            if (index >= sign and index < dot and index != sign and (dot - index) % 3 == 0) {
                output[out] = ',';
                out += 1;
            }
            output[out] = character;
            out += 1;
        }
        return output;
    }

    fn remainingSessionBytes(self: *const Runtime) usize {
        return self.session_allocator.max_bytes -| self.session_allocator.live_bytes;
    }

    fn formatMemoryFailure(self: *Runtime, line: u32, column: u32) ?[]u8 {
        self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
        return null;
    }

    fn formatValueError(self: *Runtime, line: u32, column: u32, message: []const u8) ?[]u8 {
        self.setException(.{ .kind = .value_error, .message = message }, line, column, null);
        return null;
    }

    fn formatTypeError(self: *Runtime, line: u32, column: u32, message: []const u8) ?[]u8 {
        self.setException(.{ .kind = .type_error, .message = message }, line, column, null);
        return null;
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

    fn nextIteratorValue(self: *Runtime, selected: *iterator.Iterator, destination: u16, line: u32, column: u32) iterator.NextResult {
        switch (iterator.deferredKind(selected) orelse return iterator.next(&self.heap, selected)) {
            .generator => {
                const owns_work_budget = self.beginSynchronousWork();
                defer self.endSynchronousWork(owns_work_budget);
                return self.resumeGenerator(selected, line, column);
            },
            .map, .filter => |kind| {
                const owns_work_budget = self.beginSynchronousWork();
                defer self.endSynchronousWork(owns_work_budget);
                if (selected.children.len == 0 or selected.values.len != selected.children.len) return .{ .engine_error = .internal_invariant };
                while (true) {
                    if (!self.chargeSynchronousWork(line, column)) return .{ .python_exception = self.last_exception.? };
                    for (selected.children, 0..) |maybe_child, index| {
                        const child = maybe_child orelse return .{ .engine_error = .internal_invariant };
                        switch (self.nextIteratorValue(child, destination, line, column)) {
                            .item => |value| selected.values[index] = value,
                            .done => return .done,
                            .python_exception => |exception| return .{ .python_exception = exception },
                            .engine_error => |failure| return .{ .engine_error = failure },
                        }
                    }
                    if (kind == .filter and selected.callback.tag() == .none) {
                        const keep = self.valueTruthy(selected.values[0], line, column) orelse return .{ .python_exception = self.last_exception.? };
                        if (keep) return .{ .item = selected.values[0] };
                        continue;
                    }
                    const mapped = self.invokeCallableSync(selected.callback, selected.values, destination, line, column) orelse {
                        return .{ .python_exception = self.last_exception orelse .{ .kind = .runtime_error, .message = "iterator callback failed" } };
                    };
                    if (kind == .map) return .{ .item = mapped };
                    const keep = self.valueTruthy(mapped, line, column) orelse return .{ .python_exception = self.last_exception.? };
                    if (keep) return .{ .item = selected.values[0] };
                }
            },
        }
    }

    fn resumeGenerator(self: *Runtime, selected: *iterator.Iterator, line: u32, column: u32) iterator.NextResult {
        const owns_work_budget = self.beginSynchronousWork();
        defer self.endSynchronousWork(owns_work_budget);
        if (selected.generator_done) return .done;
        if (!selected.started) {
            const frame = self.createGeneratorFrame(selected, line, column) orelse return .{ .python_exception = self.last_exception orelse .{ .kind = .runtime_error, .message = "generator frame creation failed" } };
            selected.generator_frame = frame;
            selected.generator_roots = frame.roots;
            selected.generator_frame_destroy = destroyGeneratorFrameOpaque;
            selected.started = true;
        }
        const frame: *Frame = @ptrCast(@alignCast(selected.generator_frame orelse return .{ .engine_error = .internal_invariant }));
        const caller = self.top_frame orelse return .{ .engine_error = .internal_invariant };
        const previous_generator = self.resuming_generator;
        self.resuming_generator = selected;
        defer self.resuming_generator = previous_generator;
        selected.generator_yielded = null;
        frame.previous = caller;
        frame.root_frame.push(&self.heap.roots);
        for (frame.roots) |*root| frame.root_frame.add(root);
        self.top_frame = frame;
        self.activateFrame(frame);
        var steps: usize = 0;
        while (true) : (steps += 1) {
            if (selected.generator_yielded) |value| {
                selected.generator_yielded = null;
                return .{ .item = value };
            }
            if (selected.generator_done) return .done;
            if (steps >= 1_000_000 or !self.chargeSynchronousWork(line, column)) {
                if (self.last_exception == null) self.setException(.{ .kind = .runtime_error, .message = "generator exceeded synchronous work limit" }, line, column, null);
                self.unwindFramesUntil(caller);
                return .{ .python_exception = self.last_exception.? };
            }
            const active = self.top_frame orelse return .{ .engine_error = .internal_invariant };
            if (active.ip >= active.code.instructions.len or active.code.positions.len != active.code.instructions.len) {
                _ = self.engineFault();
                self.unwindFramesUntil(caller);
                return .{ .engine_error = .internal_invariant };
            }
            const position = active.code.positions[active.ip];
            const instruction = active.code.instructions[active.ip];
            active.ip += 1;
            self.activateFrame(active);
            if (!self.execute(instruction, position.line, position.column)) {
                const failure: iterator.NextResult = if (self.engine_failed)
                    .{ .engine_error = .internal_invariant }
                else
                    .{ .python_exception = self.last_exception orelse .{ .kind = .runtime_error, .message = "generator execution failed" } };
                self.unwindFramesUntil(caller);
                return failure;
            }
            if (self.top_frame == active) active.ip = self.instruction_pointer;
        }
    }

    fn createGeneratorFrame(self: *Runtime, selected: *iterator.Iterator, line: u32, column: u32) ?*Frame {
        const caller = self.top_frame orelse {
            _ = self.engineFault();
            return null;
        };
        const function_header = selected.callback.asObject() orelse {
            self.setException(.{ .kind = .type_error, .message = "generator callback is not callable" }, line, column, null);
            return null;
        };
        const function = functions.functionFromHeader(function_header) orelse {
            self.setException(.{ .kind = .type_error, .message = "generator callback is not callable" }, line, column, null);
            return null;
        };
        const code = function.code orelse {
            self.setException(.{ .kind = .type_error, .message = "generator callback must be a Python function" }, line, column, null);
            return null;
        };
        const outer = selected.inner orelse {
            _ = self.engineFault();
            return null;
        };
        const argument = Value.object(&outer.header);
        const allocator = self.heap.allocator;
        const binding = binder.bindFunction(&self.heap, allocator, code.parameter_names, code.parameter_flags, function.defaults, &.{argument}, &.{}) catch |err| {
            self.setBinderException(err, line, column);
            return null;
        };
        defer allocator.free(binding.values);
        if (binding.extra_keywords.len != 0) allocator.free(binding.extra_keywords);
        if (function.cells.len != code.free_names.len) {
            _ = self.engineFault();
            return null;
        }
        const bound_roots = allocator.alloc(gc.Root, binding.values.len) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return null;
        };
        defer allocator.free(bound_roots);
        for (binding.values, 0..) |value, index| bound_roots[index] = .{ .object = value.asObject() };
        var bound_frame = gc.RootFrame{};
        bound_frame.push(&self.heap.roots);
        for (bound_roots) |*root| bound_frame.add(root);
        var bound_roots_active = true;
        defer if (bound_roots_active) bound_frame.pop();
        const frame = self.allocateFrame(code, null) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return null;
        };
        var complete = false;
        defer if (!complete) {
            if (bound_roots_active) {
                bound_frame.pop();
                bound_roots_active = false;
            }
            while (self.top_frame != caller) if (self.popFrame()) |abandoned| {
                self.forgetGeneratorFrame(abandoned);
                self.freeFrameStorage(abandoned);
            } else break;
        };
        frame.root_frame.pop();
        bound_frame.pop();
        bound_roots_active = false;
        frame.root_frame.push(&self.heap.roots);
        for (frame.roots) |*root| frame.root_frame.add(root);
        bound_frame.push(&self.heap.roots);
        for (bound_roots) |*root| bound_frame.add(root);
        bound_roots_active = true;
        for (code.parameter_names, 0..) |name, index| {
            const value = binding.values[index];
            if (indexOfName(code.local_names, name)) |local_index| {
                frame.locals[local_index] = value;
                frame.roots[frame.localRootStart() + local_index].object = value.asObject();
            } else if (indexOfName(code.cell_names, name)) |cell_index| {
                frame.roots[frame.cellRootStart() + cell_index].object = value.asObject();
            } else {
                _ = self.engineFault();
                return null;
            }
        }
        for (function.cells, 0..) |cell, index| {
            frame.free_cells[index] = cell;
            frame.roots[frame.freeRootStart() + index].object = &cell.header;
        }
        for (code.cell_names, 0..) |_, index| {
            const cell = functions.createCell(&self.heap, Value.unboundValue()) catch {
                self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
                return null;
            };
            frame.local_cells[index] = cell;
            frame.roots[frame.cellRootStart() + index].object = &cell.header;
        }
        for (code.parameter_names, 0..) |name, index| if (!self.storeFrameLocal(frame, name, binding.values[index])) {
            _ = self.engineFault();
            return null;
        };
        bound_frame.pop();
        bound_roots_active = false;
        frame.root_frame.pop();
        self.top_frame = caller;
        frame.previous = null;
        self.activateFrame(caller);
        frame.generator_owner = selected;
        complete = true;
        return frame;
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
            switch (self.nextIteratorValue(iterator_value, destination, line, column)) {
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
        const left_numeric = number.isIntegerValue(left) or left.asFloat() != null;
        const right_numeric = number.isIntegerValue(right) or right.asFloat() != null;
        if (left_numeric or right_numeric) {
            if (!left_numeric or !right_numeric) return false;
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
                if (dict_module.dictFromHeader(left_header)) |left_mapping| if (dict_module.dictFromHeader(right_header)) |right_mapping| {
                    if (left_mapping.is_set != right_mapping.is_set or left_mapping.size != right_mapping.size) return false;
                    var context = DictEqualityContext{ .runtime = self, .line = line, .column = column };
                    for (left_mapping.entries.items) |entry| {
                        if (!entry.alive) continue;
                        switch (dict_module.lookup(right_mapping, entry.key, entry.hash, &context, dictKeysEqual)) {
                            .missing => return false,
                            .failed => return null,
                            .found => |index| {
                                if (left_mapping.is_set) continue;
                                const item_equal = self.valuesEqual(entry.value, right_mapping.entries.items[index].value, line, column) orelse return null;
                                if (!item_equal) return false;
                            },
                        }
                    }
                    return true;
                };
            }
            return false;
        }
        if (right.asObject() != null) return false;
        return left.tag() == right.tag();
    }

    fn sortList(self: *Runtime, list: *sequence.List, reverse: bool, line: u32, column: u32) bool {
        const owns_work_budget = self.beginSynchronousWork();
        defer self.endSynchronousWork(owns_work_budget);
        var index: usize = 1;
        while (index < list.items.items.len) : (index += 1) {
            const item = list.items.items[index];
            var position = index;
            while (position > 0) {
                if (!self.chargeSynchronousWork(line, column)) return false;
                const order = self.sortOrder(item, list.items.items[position - 1], line, column) orelse return false;
                const precedes = if (reverse) order == .gt else order == .lt;
                if (!precedes) break;
                list.items.items[position] = list.items.items[position - 1];
                position -= 1;
            }
            list.items.items[position] = item;
        }
        list.version +%= 1;
        return true;
    }

    fn sortListWithKey(self: *Runtime, list: *sequence.List, key: ?Value, reverse: bool, destination: u16, line: u32, column: u32) bool {
        const owns_work_budget = self.beginSynchronousWork();
        defer self.endSynchronousWork(owns_work_budget);
        const callback = key orelse return self.sortList(list, reverse, line, column);
        var list_root = gc.Root{ .object = &list.header };
        var callback_root = gc.Root{ .object = callback.asObject() };
        var stable_roots_frame = gc.RootFrame{};
        stable_roots_frame.push(&self.heap.roots);
        stable_roots_frame.add(&list_root);
        stable_roots_frame.add(&callback_root);
        defer stable_roots_frame.pop();
        const original_version = list.version;
        const original_length = list.items.items.len;
        const allocator = self.heap.allocator;
        const count = list.items.items.len;
        const values = allocator.dupe(Value, list.items.items) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer allocator.free(values);
        const keys = allocator.alloc(Value, count) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer allocator.free(keys);
        const roots = allocator.alloc(gc.Root, count * 2) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer allocator.free(roots);
        for (0..count) |index| {
            roots[index] = .{ .object = values[index].asObject() };
            roots[count + index] = .{ .object = null };
        }
        var value_roots_frame = gc.RootFrame{};
        value_roots_frame.push(&self.heap.roots);
        for (roots) |*root| value_roots_frame.add(root);
        defer value_roots_frame.pop();
        for (values, 0..) |value, index| {
            const returned = self.invokeCallableSync(callback, &.{value}, destination, line, column) orelse return false;
            if (list.version != original_version or list.items.items.len != original_length) {
                self.setException(.{ .kind = .value_error, .message = "list modified during sort" }, line, column, null);
                return false;
            }
            keys[index] = returned;
            roots[count + index].object = returned.asObject();
        }
        var order = allocator.alloc(usize, count) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer allocator.free(order);
        for (order, 0..) |*position, index| position.* = index;
        var index: usize = 1;
        while (index < count) : (index += 1) {
            const selected = order[index];
            var position = index;
            while (position > 0) {
                if (!self.chargeSynchronousWork(line, column)) return false;
                const compared = self.sortOrder(keys[selected], keys[order[position - 1]], line, column) orelse return false;
                if (!(if (reverse) compared == .gt else compared == .lt)) break;
                order[position] = order[position - 1];
                position -= 1;
            }
            order[position] = selected;
        }
        if (list.version != original_version or list.items.items.len != original_length) {
            self.setException(.{ .kind = .value_error, .message = "list modified during sort" }, line, column, null);
            return false;
        }
        for (order, 0..) |source_index, target_index| list.items.items[target_index] = values[source_index];
        list.version +%= 1;
        return true;
    }

    fn isCallable(self: *const Runtime, value: Value) bool {
        _ = self;
        const header = value.asObject() orelse return false;
        const function = functions.functionFromHeader(header) orelse return false;
        return function.native != null or function.code != null;
    }

    fn beginSynchronousWork(self: *Runtime) bool {
        if (self.synchronous_work_remaining != null) return false;
        self.synchronous_work_remaining = 1_000_000;
        return true;
    }

    fn endSynchronousWork(self: *Runtime, owns_budget: bool) void {
        if (owns_budget) self.synchronous_work_remaining = null;
    }

    fn chargeSynchronousWork(self: *Runtime, line: u32, column: u32) bool {
        const remaining = self.synchronous_work_remaining orelse return true;
        if (remaining == 0) {
            self.setException(.{ .kind = .runtime_error, .message = "synchronous operation exceeded work limit" }, line, column, null);
            return false;
        }
        self.synchronous_work_remaining = remaining - 1;
        return true;
    }

    fn invokeCallableSync(self: *Runtime, callable: Value, args: []const Value, destination: u16, line: u32, column: u32) ?Value {
        const header = callable.asObject() orelse {
            self.setException(.{ .kind = .type_error, .message = "object is not callable" }, line, column, null);
            return null;
        };
        const function = functions.functionFromHeader(header) orelse {
            self.setException(.{ .kind = .type_error, .message = "object is not callable" }, line, column, null);
            return null;
        };
        if (function.native) |native| {
            if (!self.executeNativeCall(destination, native, function.bound_self, args, &.{}, line, column)) return null;
            return self.registers[destination];
        }
        return self.invokePythonSync(callable, args, destination, line, column);
    }

    fn invokePythonSync(self: *Runtime, callable: Value, args: []const Value, destination: u16, line: u32, column: u32) ?Value {
        const owns_work_budget = self.beginSynchronousWork();
        defer self.endSynchronousWork(owns_work_budget);
        const header = callable.asObject() orelse {
            self.setException(.{ .kind = .type_error, .message = "object is not callable" }, line, column, null);
            return null;
        };
        const function = functions.functionFromHeader(header) orelse {
            self.setException(.{ .kind = .type_error, .message = "object is not callable" }, line, column, null);
            return null;
        };
        const function_code = function.code orelse {
            self.setException(.{ .kind = .type_error, .message = "native callbacks are not supported here" }, line, column, null);
            return null;
        };
        const caller = self.top_frame orelse {
            _ = self.engineFault();
            return null;
        };
        const allocator = self.heap.allocator;
        const binding = binder.bindFunction(&self.heap, allocator, function_code.parameter_names, function_code.parameter_flags, function.defaults, args, &.{}) catch |err| {
            self.setBinderException(err, line, column);
            return null;
        };
        defer allocator.free(binding.values);
        if (binding.extra_keywords.len != 0) allocator.free(binding.extra_keywords);
        const bound_roots = allocator.alloc(gc.Root, binding.values.len) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return null;
        };
        defer allocator.free(bound_roots);
        for (binding.values, 0..) |value, index| bound_roots[index] = .{ .object = value.asObject() };
        var bound_frame = gc.RootFrame{};
        bound_frame.push(&self.heap.roots);
        for (bound_roots) |*root| bound_frame.add(root);
        var bound_active = true;
        defer if (bound_active) bound_frame.pop();
        const frame = self.allocateFrame(function_code, destination) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return null;
        };
        var complete = false;
        defer if (!complete) {
            if (bound_active) {
                bound_frame.pop();
                bound_active = false;
            }
            self.unwindFramesUntil(caller);
        };
        frame.root_frame.pop();
        bound_frame.pop();
        bound_active = false;
        frame.root_frame.push(&self.heap.roots);
        for (frame.roots) |*root| frame.root_frame.add(root);
        bound_frame.push(&self.heap.roots);
        for (bound_roots) |*root| bound_frame.add(root);
        bound_active = true;
        if (function.cells.len != function_code.free_names.len) {
            _ = self.engineFault();
            return null;
        }
        for (function.cells, 0..) |cell, index| {
            frame.free_cells[index] = cell;
            frame.roots[frame.freeRootStart() + index].object = &cell.header;
        }
        for (function_code.cell_names, 0..) |_, index| {
            const cell = functions.createCell(&self.heap, Value.unboundValue()) catch {
                self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
                return null;
            };
            frame.local_cells[index] = cell;
            frame.roots[frame.cellRootStart() + index].object = &cell.header;
        }
        for (function_code.parameter_names, 0..) |name, index| {
            if (!self.storeFrameLocal(frame, name, binding.values[index])) {
                _ = self.engineFault();
                return null;
            }
        }
        bound_frame.pop();
        bound_active = false;
        var steps: usize = 0;
        while (self.top_frame != caller) : (steps += 1) {
            if (steps >= 1_000_000 or !self.chargeSynchronousWork(line, column)) {
                if (self.last_exception == null) self.setException(.{ .kind = .runtime_error, .message = "synchronous callback exceeded work limit" }, line, column, null);
                return null;
            }
            const active = self.top_frame orelse return null;
            if (active.ip >= active.code.instructions.len or active.code.positions.len != active.code.instructions.len) {
                _ = self.engineFault();
                return null;
            }
            const position = active.code.positions[active.ip];
            const instruction = active.code.instructions[active.ip];
            active.ip += 1;
            self.activateFrame(active);
            if (!self.execute(instruction, position.line, position.column)) {
                return null;
            }
            if (self.top_frame == active) active.ip = self.instruction_pointer;
        }
        complete = true;
        return self.registers[destination];
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
                if (frame.generator_owner != null) {
                    self.forgetGeneratorFrame(frame);
                    self.freeFrameStorage(frame);
                    return true;
                }
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
            .list_append_value => {
                if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b())) return self.engineFault();
                const header = self.registers[instruction.a()].asObject() orelse return self.engineFault();
                const list = sequence.listFromHeader(header) orelse return self.engineFault();
                return switch (sequence.append(&self.heap, list, self.registers[instruction.b()])) {
                    .value => true,
                    .python_exception => |exception| blk: { self.setException(exception, line, column, null); break :blk false; },
                    .engine_error => self.engineFault(),
                };
            },
            .format_value => {
                if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b())) return self.engineFault();
                const site: usize = instruction.c();
                if (site >= code.format_sites.len) return self.engineFault();
                return self.executeFormatValue(instruction.a(), self.registers[instruction.b()], code.format_sites[site].spec, instruction.flags(), line, column);
            },
            .make_generator => {
                if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b()) or !self.validRegister(instruction.c())) return self.engineFault();
                const created = iterator.createGenerator(&self.heap, self.registers[instruction.b()], self.registers[instruction.c()]);
                return self.storeIteratorOutcome(instruction.a(), created, line, column);
            },
            .yield_value => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                const selected = self.resuming_generator orelse return self.engineFault();
                const frame = self.top_frame orelse return self.engineFault();
                if (frame.generator_owner != selected) return self.engineFault();
                selected.generator_yielded = self.registers[instruction.a()];
                if (frame.root_frame.stack != null) frame.root_frame.pop();
                self.top_frame = frame.previous;
                frame.previous = null;
                if (self.top_frame) |caller| self.activateFrame(caller) else return self.engineFault();
            },
            .make_mapping => return self.executeMakeMapping(instruction, line, column),
            .mapping_set => return self.executeMappingSet(instruction, line, column),
            .mapping_update => return self.executeMappingUpdate(instruction, line, column),
            .materialize_dstar => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                return self.executeMaterializeDstar(instruction.a(), instruction.index32(), line, column);
            },
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
                switch (self.nextIteratorValue(loop_iterator, instruction.a(), line, column)) {
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

    fn executeMakeMapping(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
        if (!self.validRegister(instruction.a()) or instruction.flags() > 1) return self.engineFault();
        return switch (dict_module.create(&self.heap, instruction.flags() == 1)) {
            .value => |mapping| blk: {
                self.setRegister(instruction.a(), Value.object(&mapping.header));
                break :blk true;
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => self.engineFault(),
        };
    }

    fn executeMappingSet(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
        if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b())) return self.engineFault();
        const header = self.registers[instruction.a()].asObject() orelse return self.engineFault();
        const mapping = dict_module.dictFromHeader(header) orelse return self.engineFault();
        const key = self.registers[instruction.b()];
        const value = if (mapping.is_set) Value.noneValue() else blk: {
            if (!self.validRegister(instruction.c())) return self.engineFault();
            break :blk self.registers[instruction.c()];
        };
        return self.setMappingValue(mapping, key, value, line, column);
    }

    fn executeMappingUpdate(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
        if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b())) return self.engineFault();
        const target_header = self.registers[instruction.a()].asObject() orelse return self.engineFault();
        const source_header = self.registers[instruction.b()].asObject() orelse {
            self.setException(.{ .kind = .type_error, .message = "dictionary unpacking requires a mapping" }, line, column, null);
            return false;
        };
        const target = dict_module.dictFromHeader(target_header) orelse return self.engineFault();
        const source = dict_module.dictFromHeader(source_header) orelse {
            self.setException(.{ .kind = .type_error, .message = "dictionary unpacking requires a mapping" }, line, column, null);
            return false;
        };
        if (target.is_set or source.is_set) return self.nativeTypeError(line, column, "dictionary unpacking requires dictionaries");
        for (source.entries.items) |entry| {
            if (!entry.alive) continue;
            if (!self.setMappingValueWithHash(target, entry.key, entry.value, entry.hash, line, column)) return false;
        }
        return true;
    }

    fn executeMaterializeDstar(self: *Runtime, register: u16, site_index: u32, line: u32, column: u32) bool {
        const code = self.activeCode() orelse return self.engineFault();
        if (site_index >= code.dstar_sites.len) return self.engineFault();
        const site = code.dstar_sites[site_index];
        const previous_start: usize = site.previous_start;
        const previous_count: usize = site.previous_count;
        if (previous_start > code.dstar_previous_arguments.len or previous_count > code.dstar_previous_arguments.len - previous_start) return self.engineFault();
        const source_value = self.registers[register];
        const source_header = source_value.asObject() orelse return self.nativeTypeError(line, column, "argument after ** must be a mapping");
        const source = dict_module.dictFromHeader(source_header) orelse return self.nativeTypeError(line, column, "argument after ** must be a mapping");
        if (source.is_set) return self.nativeTypeError(line, column, "argument after ** must be a mapping");
        var source_root = gc.Root{ .object = &source.header };
        var snapshot_root = gc.Root{ .object = null };
        var roots = gc.RootFrame{};
        roots.push(&self.heap.roots);
        roots.add(&source_root);
        roots.add(&snapshot_root);
        defer roots.pop();
        const created = dict_module.create(&self.heap, false);
        const snapshot = switch (created) {
            .value => |mapping| mapping,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        snapshot_root.object = &snapshot.header;
        for (source.entries.items) |entry| {
            if (!entry.alive) continue;
            if (!self.setMappingValueWithHash(snapshot, entry.key, entry.value, entry.hash, line, column)) return false;
        }
        for (code.dstar_previous_arguments[previous_start..][0..previous_count]) |previous| {
            if (previous.double_starred) {
                if (!self.validRegister(previous.register)) return self.engineFault();
                const previous_header = self.registers[previous.register].asObject() orelse return self.engineFault();
                const previous_mapping = dict_module.dictFromHeader(previous_header) orelse return self.engineFault();
                for (previous_mapping.entries.items) |entry| {
                    if (!entry.alive) continue;
                    const previous_key_header = entry.key.asObject() orelse continue;
                    const previous_key = string.fromHeader(previous_key_header) orelse continue;
                    if (self.mappingHasStringKey(snapshot, string.content(previous_key))) return self.duplicateCallKeyword(line, column);
                }
            } else if (previous.keyword_name != std.math.maxInt(u32)) {
                const name = self.codeName(previous.keyword_name) orelse return self.engineFault();
                if (self.mappingHasStringKey(snapshot, name)) return self.duplicateCallKeyword(line, column);
            }
        }
        self.setRegister(register, Value.object(&snapshot.header));
        return true;
    }

    fn mappingHasStringKey(self: *Runtime, mapping: *dict_module.Dict, name: []const u8) bool {
        _ = self;
        for (mapping.entries.items) |entry| {
            if (!entry.alive) continue;
            const header = entry.key.asObject() orelse continue;
            const text = string.fromHeader(header) orelse continue;
            if (std.mem.eql(u8, string.content(text), name)) return true;
        }
        return false;
    }

    fn duplicateCallKeyword(self: *Runtime, line: u32, column: u32) bool {
        self.setException(.{ .kind = .type_error, .message = "got multiple values for keyword argument" }, line, column, null);
        return false;
    }

    fn setMappingValue(self: *Runtime, mapping: *dict_module.Dict, key: Value, value: Value, line: u32, column: u32) bool {
        const key_hash = self.pythonHash(key, line, column) orelse return false;
        return self.setMappingValueWithHash(mapping, key, value, key_hash, line, column);
    }

    fn setMappingValueWithHash(self: *Runtime, mapping: *dict_module.Dict, key: Value, value: Value, key_hash: u64, line: u32, column: u32) bool {
        var context = DictEqualityContext{ .runtime = self, .line = line, .column = column };
        return switch (dict_module.set(&self.heap, mapping, key, value, key_hash, &context, dictKeysEqual)) {
            .value => true,
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => if (self.last_exception != null) false else self.engineFault(),
        };
    }

    fn pythonHash(self: *Runtime, value: Value, line: u32, column: u32) ?u64 {
        return switch (hash_module.pythonHash(&self.heap, value, self.hash_seed)) {
            .value => |value_hash| value_hash,
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

    fn mappingContains(self: *Runtime, mapping: *dict_module.Dict, key: Value, line: u32, column: u32) ?bool {
        const key_hash = self.pythonHash(key, line, column) orelse return null;
        var context = DictEqualityContext{ .runtime = self, .line = line, .column = column };
        return switch (dict_module.lookup(mapping, key, key_hash, &context, dictKeysEqual)) {
            .found => true,
            .missing => false,
            .failed => null,
        };
    }

    fn storeSetOperation(self: *Runtime, destination: u16, left: *dict_module.Dict, right: *dict_module.Dict, operation: u8, line: u32, column: u32) bool {
        const created = dict_module.create(&self.heap, true);
        const result = switch (created) {
            .value => |mapping| mapping,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        var root = gc.Root{ .object = &result.header };
        var roots = gc.RootFrame{};
        roots.push(&self.heap.roots);
        roots.add(&root);
        defer roots.pop();
        for (left.entries.items) |entry| {
            if (!entry.alive) continue;
            const in_right = self.mappingContains(right, entry.key, line, column) orelse return false;
            const include = if (operation == 1) !in_right else if (operation == 7) in_right else true;
            if (include and !self.setMappingValueWithHash(result, entry.key, Value.noneValue(), entry.hash, line, column)) return false;
        }
        if (operation == 8) for (right.entries.items) |entry| {
            if (!entry.alive) continue;
            if (!self.setMappingValueWithHash(result, entry.key, Value.noneValue(), entry.hash, line, column)) return false;
        };
        self.setRegister(destination, Value.object(&result.header));
        return true;
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
        if (dict_module.dictFromHeader(header)) |mapping| {
            if (mapping.is_set) return self.nativeTypeError(line, column, "'set' object is not subscriptable");
            const key_hash = self.pythonHash(index_value, line, column) orelse return false;
            var context = DictEqualityContext{ .runtime = self, .line = line, .column = column };
            return switch (dict_module.get(mapping, index_value, key_hash, &context, dictKeysEqual)) {
                .value => |value| blk: {
                    self.setRegister(instruction.a(), value);
                    break :blk true;
                },
                .missing => blk: {
                    self.setException(.{ .kind = .key_error, .message = "mapping key not found" }, line, column, null);
                    break :blk false;
                },
                .failed => self.last_exception == null and self.engineFault(),
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
        if (dict_module.dictFromHeader(container)) |mapping| {
            if (mapping.is_set) return self.nativeTypeError(line, column, "'set' object does not support item assignment");
            return self.setMappingValue(mapping, self.registers[instruction.c()], self.registers[instruction.a()], line, column);
        }
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
        list.version +%= 1;
        return true;
    }

    fn executeDeleteItem(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
        if (!self.validRegister(instruction.b()) or !self.validRegister(instruction.c())) return self.engineFault();
        const container = self.registers[instruction.b()].asObject() orelse {
            self.setException(.{ .kind = .type_error, .message = "object does not support item deletion" }, line, column, null);
            return false;
        };
        if (dict_module.dictFromHeader(container)) |mapping| {
            if (mapping.is_set) return self.nativeTypeError(line, column, "'set' object does not support item deletion");
            const key = self.registers[instruction.c()];
            const key_hash = self.pythonHash(key, line, column) orelse return false;
            var context = DictEqualityContext{ .runtime = self, .line = line, .column = column };
            return switch (dict_module.delete(mapping, key, key_hash, &context, dictKeysEqual)) {
                .found => true,
                .missing => blk: {
                    self.setException(.{ .kind = .key_error, .message = "mapping key not found" }, line, column, null);
                    break :blk false;
                },
                .failed => self.last_exception == null and self.engineFault(),
            };
        }
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
        list.version +%= 1;
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
        if (operation == 5) if (left.asObject()) |header| if (string.fromHeader(header)) |template| return self.executePercentFormat(destination, template, right, line, column);
        if (operation == 1 or operation == 7 or operation == 8) {
            const left_header = left.asObject() orelse null;
            const right_header = right.asObject() orelse null;
            if (left_header) |left_object| if (dict_module.dictFromHeader(left_object)) |left_mapping| {
                if (right_header) |right_object| if (dict_module.dictFromHeader(right_object)) |right_mapping| {
                    if (left_mapping.is_set and right_mapping.is_set) return self.storeSetOperation(destination, left_mapping, right_mapping, operation, line, column);
                };
            };
        }
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
                    if (byte_module.fromHeader(left_object)) |left_bytes| {
                        if (byte_module.fromHeader(right_object)) |right_bytes| {
                            const total = std.math.add(usize, left_bytes.data.len, right_bytes.data.len) catch {
                                self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
                                return false;
                            };
                            const joined_data = self.heap.allocator.alloc(u8, total) catch {
                                self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
                                return false;
                            };
                            defer self.heap.allocator.free(joined_data);
                            @memcpy(joined_data[0..left_bytes.data.len], left_bytes.data);
                            @memcpy(joined_data[left_bytes.data.len..], right_bytes.data);
                            return switch (byte_module.create(&self.heap, joined_data)) {
                                .value => |joined| blk: { self.setRegister(destination, Value.object(&joined.header)); break :blk true; },
                                .python_exception => |exception| blk: { self.setException(exception, line, column, null); break :blk false; },
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

    fn executePercentFormat(self: *Runtime, destination: u16, template: *string.Str, arguments_value: Value, line: u32, column: u32) bool {
        const arguments: []const Value = if (arguments_value.asObject()) |header| if (sequence.tupleFromHeader(header)) |tuple| tuple.items else &.{arguments_value} else &.{arguments_value};
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.heap.allocator);
        const input = string.content(template);
        var index: usize = 0;
        var argument_index: usize = 0;
        while (index < input.len) {
            if (input[index] != '%') {
                output.append(self.heap.allocator, input[index]) catch { _ = self.formatMemoryFailure(line, column); return false; };
                index += 1;
                continue;
            }
            index += 1;
            if (index < input.len and input[index] == '%') {
                output.append(self.heap.allocator, '%') catch { _ = self.formatMemoryFailure(line, column); return false; };
                index += 1;
                continue;
            }
            const spec_start = index;
            while (index < input.len and std.mem.indexOfScalar(u8, "#0-+ ", input[index]) != null) : (index += 1) {}
            while (index < input.len and std.ascii.isDigit(input[index])) : (index += 1) {}
            if (index < input.len and input[index] == '.') {
                index += 1;
                while (index < input.len and std.ascii.isDigit(input[index])) : (index += 1) {}
            }
            if (index >= input.len) return self.nativeTypeError(line, column, "incomplete format");
            const kind = input[index];
            index += 1;
            if (std.mem.indexOfScalar(u8, "sradiuxXof", kind) == null) { _ = self.formatValueError(line, column, "unsupported format character"); return false; }
            if (argument_index >= arguments.len) return self.nativeTypeError(line, column, "not enough arguments for format string");
            const argument = arguments[argument_index];
            argument_index += 1;
            const conversion: u8 = if (kind == 's') 1 else if (kind == 'r') 2 else if (kind == 'a') 3 else 0;
            const fmt_kind = if (conversion != 0) 's' else if (kind == 'i' or kind == 'u') 'd' else kind;
            const fmt_spec = std.fmt.allocPrint(self.heap.allocator, "{s}{c}", .{ input[spec_start .. index - 1], fmt_kind }) catch { _ = self.formatMemoryFailure(line, column); return false; };
            defer self.heap.allocator.free(fmt_spec);
            const formatted = self.makeFormattedText(argument, fmt_spec, conversion, line, column) orelse return false;
            defer self.heap.allocator.free(formatted);
            output.appendSlice(self.heap.allocator, formatted) catch { _ = self.formatMemoryFailure(line, column); return false; };
        }
        if (argument_index < arguments.len) return self.nativeTypeError(line, column, "not all arguments converted during string formatting");
        const owned = output.toOwnedSlice(self.heap.allocator) catch { _ = self.formatMemoryFailure(line, column); return false; };
        defer self.heap.allocator.free(owned);
        return self.storeStringResult(destination, string.create(&self.heap, owned), line, column);
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
            if (dict_module.dictFromHeader(header)) |mapping| return self.appendMapping(header, mapping, line, column);
            if (dict_module.viewFromHeader(header)) |view| return self.appendMappingView(header, view, line, column);
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

    fn appendMapping(self: *Runtime, header: *gc.Header, mapping: *dict_module.Dict, line: u32, column: u32) bool {
        for (self.repr_path.items) |ancestor| {
            if (ancestor == header) return self.appendOutput("{...}");
        }
        if (self.repr_path.items.len >= 128) {
            self.setException(.{ .kind = .recursion_error, .message = "maximum recursion depth exceeded while getting the repr of an object" }, line, column, null);
            return false;
        }
        if (mapping.is_set and mapping.size == 0) return self.appendOutput("set()");
        self.repr_path.append(self.heap.allocator, header) catch return false;
        defer _ = self.repr_path.pop();
        if (!self.appendOutput("{")) return false;
        var first = true;
        for (mapping.entries.items) |entry| {
            if (!entry.alive) continue;
            if (!first and !self.appendOutput(", ")) return false;
            first = false;
            if (!self.appendValueMode(entry.key, true, line, column)) return false;
            if (!mapping.is_set) {
                if (!self.appendOutput(": ") or !self.appendValueMode(entry.value, true, line, column)) return false;
            }
        }
        return self.appendOutput("}");
    }

    fn appendMappingView(self: *Runtime, header: *gc.Header, view: *dict_module.View, line: u32, column: u32) bool {
        for (self.repr_path.items) |ancestor| if (ancestor == header) return self.appendOutput("...");
        if (self.repr_path.items.len >= 128) {
            self.setException(.{ .kind = .recursion_error, .message = "maximum recursion depth exceeded while getting the repr of an object" }, line, column, null);
            return false;
        }
        self.repr_path.append(self.heap.allocator, header) catch return false;
        defer _ = self.repr_path.pop();
        const prefix = switch (view.kind) {
            .keys => "dict_keys([",
            .values => "dict_values([",
            .items => "dict_items([",
        };
        if (!self.appendOutput(prefix)) return false;
        var first = true;
        for (view.owner.entries.items) |entry| {
            if (!entry.alive) continue;
            if (!first and !self.appendOutput(", ")) return false;
            first = false;
            switch (view.kind) {
                .keys => if (!self.appendValueMode(entry.key, true, line, column)) return false,
                .values => if (!self.appendValueMode(entry.value, true, line, column)) return false,
                .items => {
                    if (!self.appendOutput("(")) return false;
                    if (!self.appendValueMode(entry.key, true, line, column) or !self.appendOutput(", ") or !self.appendValueMode(entry.value, true, line, column) or !self.appendOutput(")")) return false;
                },
            }
        }
        return self.appendOutput("])");
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
            if (dict_module.sizeOf(value)) |count| return count != 0;
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

    fn normalizeSearchBound(self: *Runtime, value: Value, length: usize, line: u32, column: u32) ?usize {
        if (!number.isIntegerValue(value)) {
            self.setException(.{ .kind = .type_error, .message = "slice indices must be integers" }, line, column, null);
            return null;
        }
        const len = std.math.cast(i64, length) orelse std.math.maxInt(i64);
        const converted = number.toInt(i64, value) orelse {
            const order = number.compare(value, Value.fromSmallInt(0).?);
            return switch (order) {
                .value => |comparison| if (comparison == .less) 0 else length,
                .python_exception => |exception| blk: { self.setException(exception, line, column, null); break :blk null; },
                .engine_error => blk: { _ = self.engineFault(); break :blk null; },
            };
        };
        const adjusted = if (converted < 0) converted + len else converted;
        return @intCast(@max(0, @min(len, adjusted)));
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
                    if (dict_module.dictFromHeader(left_header)) |_| if (dict_module.dictFromHeader(right_header)) |_| {
                        const equal = self.valuesEqual(left, right, line, column) orelse return null;
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
        if (dict_module.dictFromHeader(header)) |mapping| return self.mappingContains(mapping, item, line, column);
        if (dict_module.viewFromHeader(header)) |view| {
            const mapping_iterator = switch (dict_module.createIterator(&self.heap, view.owner, view.kind)) {
                .value => |selected| selected,
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return null;
                },
                .engine_error => {
                    _ = self.engineFault();
                    return null;
                },
            };
            var root = gc.Root{ .object = &mapping_iterator.header };
            var roots = gc.RootFrame{};
            roots.push(&self.heap.roots);
            roots.add(&root);
            defer roots.pop();
            while (true) switch (dict_module.next(&self.heap, mapping_iterator)) {
                .item => |candidate| {
                    const equal = self.valuesEqual(candidate, item, line, column) orelse return null;
                    if (equal) return true;
                },
                .done => return false,
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return null;
                },
            };
        }
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

const DictEqualityContext = struct {
    runtime: *Runtime,
    line: u32,
    column: u32,
};

fn dictKeysEqual(raw_context: *anyopaque, left: Value, right: Value) ?bool {
    const context: *DictEqualityContext = @ptrCast(@alignCast(raw_context));
    return context.runtime.valuesEqual(left, right, context.line, context.column);
}

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
        .key_error => "KeyError",
        .runtime_error => "RuntimeError",
        .unicode_decode_error => "UnicodeDecodeError",
        .attribute_error => "AttributeError",
        .stop_iteration => "StopIteration",
    };
}

fn indexOfName(names: []const []const u8, name: []const u8) ?usize {
    for (names, 0..) |candidate, index| if (std.mem.eql(u8, candidate, name)) return index;
    return null;
}

fn truncateUtf8(input: []const u8, codepoints: usize) []const u8 {
    var byte_index: usize = 0;
    var seen: usize = 0;
    while (byte_index < input.len and seen < codepoints) : (seen += 1) {
        const width = std.unicode.utf8ByteSequenceLength(input[byte_index]) catch 1;
        byte_index = @min(input.len, byte_index + width);
    }
    return input[0..byte_index];
}

fn trimFloatZeros(input: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, input, '.') orelse return input;
    var end = input.len;
    while (end > dot + 1 and input[end - 1] == '0') end -= 1;
    if (end == dot + 1) end = dot;
    return input[0..end];
}

fn roundDecimalTieEven(value: f64, precision: usize) f64 {
    if (!std.math.isFinite(value) or precision > 15) return value;
    const scale = std.math.pow(f64, 10, @floatFromInt(precision));
    const magnitude = @abs(value) * scale;
    if (!std.math.isFinite(magnitude)) return value;
    const whole = @floor(magnitude);
    if (magnitude - whole != 0.5 or @rem(whole, 2.0) != 0) return value;
    const bits: u64 = @bitCast(value);
    return @bitCast(if (value < 0) bits + 1 else bits - 1);
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

fn isAlign(character: u8) bool {
    return character == '<' or character == '>' or character == '^';
}

fn builtinNative(name: []const u8) ?functions.Native {
    if (std.mem.eql(u8, name, "str")) return .str_constructor;
    if (std.mem.eql(u8, name, "format")) return .format_builtin;
    if (std.mem.eql(u8, name, "sorted")) return .sorted;
    if (std.mem.eql(u8, name, "map")) return .map;
    if (std.mem.eql(u8, name, "filter")) return .filter;
    if (std.mem.eql(u8, name, "dict")) return .dict;
    if (std.mem.eql(u8, name, "set")) return .set;
    if (std.mem.eql(u8, name, "hash")) return .hash;
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
    if (dict_module.dictFromHeader(header)) |mapping| {
        if (mapping.is_set) {
            if (std.mem.eql(u8, name, "add")) return .set_add;
            if (std.mem.eql(u8, name, "remove")) return .set_remove;
            if (std.mem.eql(u8, name, "discard")) return .set_discard;
            if (std.mem.eql(u8, name, "pop")) return .set_pop;
            if (std.mem.eql(u8, name, "update")) return .set_update;
            if (std.mem.eql(u8, name, "clear")) return .set_clear;
            if (std.mem.eql(u8, name, "copy")) return .set_copy;
        } else {
            if (std.mem.eql(u8, name, "get")) return .dict_get;
            if (std.mem.eql(u8, name, "keys")) return .dict_keys;
            if (std.mem.eql(u8, name, "values")) return .dict_values;
            if (std.mem.eql(u8, name, "items")) return .dict_items;
            if (std.mem.eql(u8, name, "pop")) return .dict_pop;
            if (std.mem.eql(u8, name, "setdefault")) return .dict_setdefault;
            if (std.mem.eql(u8, name, "update")) return .dict_update;
            if (std.mem.eql(u8, name, "clear")) return .dict_clear;
            if (std.mem.eql(u8, name, "copy")) return .dict_copy;
        }
    }
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
        if (std.mem.eql(u8, name, "format")) return .str_format;
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
