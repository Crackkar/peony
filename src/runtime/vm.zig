const std = @import("std");
const bytecode = @import("frontend_bytecode");
const compiler = @import("frontend_compiler");
const gc = @import("runtime_gc");
const value_module = @import("runtime_value");
const number = @import("runtime_number");
const string = @import("runtime_string");
const exceptions = @import("runtime_exception");
const iterator = @import("runtime_iterator");

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
    code: ?*Code = null,
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
        self.initialized = true;
    }

    pub fn deinit(self: *Runtime) void {
        if (!self.initialized) return;
        self.resetProgram(false);
        self.stdout_bytes.deinit(self.heap.allocator);
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
                if (self.prepareRegisters(code.register_count)) return .{ .ready = code };
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
        const code = self.code orelse return .completed;
        if (self.last_exception != null) return .python_exception;
        if (self.instruction_pointer > code.instructions.len or code.positions.len != code.instructions.len) {
            _ = self.engineFault();
            return .engine_error;
        }

        const quantum = if (requested_quantum == 0) default_quantum else requested_quantum;
        var executed: u32 = 0;
        while (executed < quantum and self.instruction_pointer < code.instructions.len) : (executed += 1) {
            const current = code.positions[self.instruction_pointer];
            const instruction = code.instructions[self.instruction_pointer];
            self.instruction_pointer += 1;
            if (!self.execute(instruction, current.line, current.column)) {
                return if (self.engine_failed) .engine_error else .python_exception;
            }
        }
        return if (self.instruction_pointer >= code.instructions.len) .completed else .timeslice;
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

    fn prepareRegisters(self: *Runtime, count: u32) bool {
        const length: usize = @intCast(count);
        self.registers = self.heap.allocator.alloc(Value, length) catch return false;
        self.register_roots = self.heap.allocator.alloc(gc.Root, length) catch {
            self.heap.allocator.free(self.registers);
            self.registers = &.{};
            return false;
        };
        @memset(self.registers, Value.unboundValue());
        @memset(self.register_roots, .{ .object = null });
        self.register_frame.push(&self.heap.roots);
        for (self.register_roots, 0..) |*root, index| {
            self.register_frame.add(root);
            _ = index;
        }
        return true;
    }

    fn resetProgram(self: *Runtime, clear_output: bool) void {
        if (self.register_frame.stack != null) self.register_frame.pop();
        if (self.register_roots.len != 0) self.heap.allocator.free(self.register_roots);
        if (self.registers.len != 0) self.heap.allocator.free(self.registers);
        self.register_roots = &.{};
        self.registers = &.{};

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

    fn clearGlobals(self: *Runtime) void {
        for (self.environment.entries.items) |entry| self.heap.allocator.free(entry.name);
        self.environment.entries.clearRetainingCapacity();
    }

    fn execute(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
        const code = self.code orelse return false;
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
                if (self.globalValue(name)) |value| {
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
            .return_value => {},
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
        const code = self.code orelse return false;
        return @as(usize, target) <= code.instructions.len;
    }

    fn codeName(self: *const Runtime, index: u32) ?[]const u8 {
        const code = self.code orelse return null;
        const position: usize = @intCast(index);
        if (position >= code.names.len) return null;
        return code.names[position];
    }

    fn globalValue(self: *const Runtime, name: []const u8) ?Value {
        for (self.environment.entries.items) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.value;
        return null;
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
        if (self.code) |code| return code.filename;
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
        .zero_division_error => "ZeroDivisionError",
        .value_error => "ValueError",
        .overflow_error => "OverflowError",
        .type_error => "TypeError",
        .index_error => "IndexError",
        .unicode_decode_error => "UnicodeDecodeError",
    };
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
