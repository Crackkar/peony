const std = @import("std");
const gc = @import("runtime_gc");
const Value = @import("runtime_value").Value;
const number = @import("runtime_number");
const string = @import("runtime_string");
const bytes = @import("runtime_bytes");
const sequence = @import("runtime_sequence");
const iterator = @import("runtime_iterator");
const functions = @import("runtime_function");
const binder = @import("runtime_binder");
const state = @import("state.zig");
const Runtime = @import("runtime.zig").Runtime;

pub fn nativeByName(name: []const u8) ?functions.Native {
    const entries = .{
        .{ "abs", functions.Native.abs_builtin }, .{ "all", .all_builtin }, .{ "any", .any_builtin },
        .{ "ascii", .ascii_builtin }, .{ "bin", .bin_builtin }, .{ "chr", .chr_builtin },
        .{ "divmod", .divmod_builtin }, .{ "hex", .hex_builtin }, .{ "max", .max_builtin },
        .{ "min", .min_builtin }, .{ "oct", .oct_builtin }, .{ "ord", .ord_builtin },
        .{ "pow", .pow_builtin }, .{ "round", .round_builtin }, .{ "sum", .sum_builtin },
    };
    inline for (entries) |entry| if (std.mem.eql(u8, name, entry[0])) return entry[1];
    return null;
}

pub fn isTailNative(native: functions.Native) bool {
    return switch (native) {
        .abs_builtin, .all_builtin, .any_builtin, .ascii_builtin, .bin_builtin, .bytes_constructor,
        .chr_builtin, .divmod_builtin, .hex_builtin, .max_builtin, .min_builtin, .oct_builtin,
        .ord_builtin, .pow_builtin, .round_builtin, .sum_builtin => true,
        else => false,
    };
}

pub fn execute(self: *Runtime, destination: u16, native: functions.Native, positional: []const Value, keywords: []const binder.Keyword, line: u32, column: u32) bool {
    return switch (native) {
        .all_builtin, .any_builtin, .min_builtin, .max_builtin, .sum_builtin => startReduction(self, destination, native, positional, keywords, line, column),
        .bytes_constructor => executeBytes(self, destination, positional, keywords, line, column),
        .abs_builtin => unaryNumber(self, destination, positional, keywords, line, column),
        .ascii_builtin => asciiBuiltin(self, destination, positional, keywords, line, column),
        .bin_builtin => baseBuiltin(self, destination, positional, keywords, 2, "0b", line, column),
        .oct_builtin => baseBuiltin(self, destination, positional, keywords, 8, "0o", line, column),
        .hex_builtin => baseBuiltin(self, destination, positional, keywords, 16, "0x", line, column),
        .chr_builtin => chrBuiltin(self, destination, positional, keywords, line, column),
        .ord_builtin => ordBuiltin(self, destination, positional, keywords, line, column),
        .divmod_builtin => divmodBuiltin(self, destination, positional, keywords, line, column),
        .pow_builtin => powBuiltin(self, destination, positional, keywords, line, column),
        .round_builtin => roundBuiltin(self, destination, positional, keywords, line, column),
        else => self.engineFault(),
    };
}

fn exact(positional: []const Value, keywords: []const binder.Keyword, count: usize) bool {
    return positional.len == count and keywords.len == 0;
}

fn unaryNumber(self: *Runtime, destination: u16, positional: []const Value, keywords: []const binder.Keyword, line: u32, column: u32) bool {
    if (!exact(positional, keywords, 1)) return self.nativeArity(line, column);
    const value = positional[0];
    if (value.asFloat()) |float_value| {
        self.setRegister(destination, Value.fromFloat(@abs(float_value)));
        return true;
    }
    if (!number.isIntegerValue(value)) return self.nativeTypeError(line, column, "bad operand type for abs()");
    const order = number.compare(value, Value.fromSmallInt(0).?);
    return switch (order) {
        .value => |selected| self.storeValueResult(destination, if (selected == .less) number.negative(&self.heap, value) else .{ .value = value }, line, column),
        .python_exception => |exception| fail(self, exception, line, column),
        .engine_error => self.engineFault(),
    };
}

fn asciiBuiltin(self: *Runtime, destination: u16, positional: []const Value, keywords: []const binder.Keyword, line: u32, column: u32) bool {
    if (!exact(positional, keywords, 1)) return self.nativeArity(line, column);
    const rendered = self.renderValueOwned(positional[0], true, line, column) orelse return false;
    defer self.heap.allocator.free(rendered);
    const escaped = self.asciiEscape(rendered) orelse return memoryFailure(self, line, column);
    defer self.heap.allocator.free(escaped);
    return self.storeStringResult(destination, string.create(&self.heap, escaped), line, column);
}

fn baseBuiltin(self: *Runtime, destination: u16, positional: []const Value, keywords: []const binder.Keyword, base: u8, prefix: []const u8, line: u32, column: u32) bool {
    if (!exact(positional, keywords, 1)) return self.nativeArity(line, column);
    const formatted = number.formatIntegerBase(&self.heap, positional[0], base, .lower) orelse return self.nativeTypeError(line, column, "integer argument expected");
    const digits = switch (formatted) {
        .value => |value| value,
        .python_exception => |exception| return fail(self, exception, line, column),
        .engine_error => return self.engineFault(),
    };
    defer self.heap.allocator.free(digits);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(self.heap.allocator);
    if (digits.len != 0 and digits[0] == '-') {
        output.append(self.heap.allocator, '-') catch return memoryFailure(self, line, column);
        output.appendSlice(self.heap.allocator, prefix) catch return memoryFailure(self, line, column);
        output.appendSlice(self.heap.allocator, digits[1..]) catch return memoryFailure(self, line, column);
    } else {
        output.appendSlice(self.heap.allocator, prefix) catch return memoryFailure(self, line, column);
        output.appendSlice(self.heap.allocator, digits) catch return memoryFailure(self, line, column);
    }
    return self.storeStringResult(destination, string.create(&self.heap, output.items), line, column);
}

fn chrBuiltin(self: *Runtime, destination: u16, positional: []const Value, keywords: []const binder.Keyword, line: u32, column: u32) bool {
    if (!exact(positional, keywords, 1)) return self.nativeArity(line, column);
    const scalar = number.toInt(u21, positional[0]) orelse {
        if (!number.isIntegerValue(positional[0])) return self.nativeTypeError(line, column, "an integer is required");
        self.setException(.{ .kind = .value_error, .message = "chr() arg not in range(0x110000)" }, line, column, null);
        return false;
    };
    var buffer: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(scalar, &buffer) catch {
        self.setException(.{ .kind = .value_error, .message = "chr() arg not in range(0x110000)" }, line, column, null);
        return false;
    };
    return self.storeStringResult(destination, string.create(&self.heap, buffer[0..length]), line, column);
}

fn ordBuiltin(self: *Runtime, destination: u16, positional: []const Value, keywords: []const binder.Keyword, line: u32, column: u32) bool {
    if (!exact(positional, keywords, 1)) return self.nativeArity(line, column);
    if (positional[0].asObject()) |header| {
        if (string.fromHeader(header)) |text| {
            const content = string.content(text);
            if (std.unicode.utf8CountCodepoints(content) catch 0 != 1) return self.nativeTypeError(line, column, "ord() expected a character");
            const scalar = std.unicode.utf8Decode(content) catch return self.nativeTypeError(line, column, "ord() expected a character");
            return self.storeValueResult(destination, number.fromInt(&self.heap, scalar), line, column);
        }
        if (bytes.fromHeader(header)) |data| {
            if (data.data.len != 1) return self.nativeTypeError(line, column, "ord() expected a character");
            self.setRegister(destination, Value.fromSmallInt(data.data[0]).?);
            return true;
        }
    }
    return self.nativeTypeError(line, column, "ord() expected string of length 1");
}

fn divmodBuiltin(self: *Runtime, destination: u16, positional: []const Value, keywords: []const binder.Keyword, line: u32, column: u32) bool {
    if (!exact(positional, keywords, 2)) return self.nativeArity(line, column);
    const quotient = takeValue(self, number.floorDiv(&self.heap, positional[0], positional[1]), line, column) orelse return false;
    var quotient_root = gc.Root{ .object = quotient.asObject() };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&quotient_root);
    defer roots.pop();
    const remainder = takeValue(self, number.modulo(&self.heap, positional[0], positional[1]), line, column) orelse return false;
    return self.storeTupleResult(destination, sequence.createTuple(&self.heap, &.{ quotient, remainder }), line, column);
}

fn powBuiltin(self: *Runtime, destination: u16, positional: []const Value, keywords: []const binder.Keyword, line: u32, column: u32) bool {
    if (keywords.len != 0 or positional.len < 2 or positional.len > 3) return self.nativeArity(line, column);
    if (positional.len == 2) return self.storeValueResult(destination, number.power(&self.heap, positional[0], positional[1]), line, column);
    for (positional) |value| if (!number.isIntegerValue(value)) return self.nativeTypeError(line, column, "pow() 3rd argument not allowed unless all arguments are integers");
    const zero = Value.fromSmallInt(0).?;
    const exponent_order = takeComparison(self, number.compare(positional[1], zero), line, column) orelse return false;
    if (exponent_order == .less) {
        self.setException(.{ .kind = .value_error, .message = "base is not invertible for the given modulus" }, line, column, null);
        return false;
    }
    if (number.isZeroValue(positional[2])) {
        self.setException(.{ .kind = .value_error, .message = "pow() 3rd argument cannot be 0" }, line, column, null);
        return false;
    }
    var values = [_]Value{ Value.fromSmallInt(1).?, positional[0], positional[1], positional[2] };
    var root_values: [4]gc.Root = undefined;
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    defer roots.pop();
    for (&values, 0..) |*value, index| {
        root_values[index] = .{ .object = value.asObject() };
        roots.add(&root_values[index]);
    }
    values[0] = takeValue(self, number.modulo(&self.heap, values[0], values[3]), line, column) orelse return false;
    root_values[0].object = values[0].asObject();
    values[1] = takeValue(self, number.modulo(&self.heap, values[1], values[3]), line, column) orelse return false;
    root_values[1].object = values[1].asObject();
    const two = Value.fromSmallInt(2).?;
    while (!number.isZeroValue(values[2])) {
        if (!self.chargeSynchronousWork(line, column)) return false;
        const odd = takeValue(self, number.modulo(&self.heap, values[2], two), line, column) orelse return false;
        if (!number.isZeroValue(odd)) {
            const product = takeValue(self, number.multiply(&self.heap, values[0], values[1]), line, column) orelse return false;
            values[0] = takeValue(self, number.modulo(&self.heap, product, values[3]), line, column) orelse return false;
            root_values[0].object = values[0].asObject();
        }
        values[2] = takeValue(self, number.floorDiv(&self.heap, values[2], two), line, column) orelse return false;
        root_values[2].object = values[2].asObject();
        const square = takeValue(self, number.multiply(&self.heap, values[1], values[1]), line, column) orelse return false;
        values[1] = takeValue(self, number.modulo(&self.heap, square, values[3]), line, column) orelse return false;
        root_values[1].object = values[1].asObject();
    }
    self.setRegister(destination, values[0]);
    return true;
}

fn roundBuiltin(self: *Runtime, destination: u16, positional: []const Value, keywords: []const binder.Keyword, line: u32, column: u32) bool {
    var value: ?Value = if (positional.len > 0) positional[0] else null;
    var ndigits: ?Value = if (positional.len > 1) positional[1] else null;
    if (positional.len > 2) return self.nativeArity(line, column);
    for (keywords) |keyword| {
        if (std.mem.eql(u8, keyword.name, "number")) {
            if (value != null) return self.nativeTypeError(line, column, "multiple values for number");
            value = keyword.value;
        } else if (std.mem.eql(u8, keyword.name, "ndigits")) {
            if (ndigits != null) return self.nativeTypeError(line, column, "multiple values for ndigits");
            ndigits = keyword.value;
        } else return self.nativeTypeError(line, column, "unexpected keyword argument");
    }
    const input = value orelse return self.nativeArity(line, column);
    const digits: i64 = if (ndigits) |selected| number.toInt(i64, selected) orelse return self.nativeTypeError(line, column, "ndigits must be an integer") else 0;
    if (number.isIntegerValue(input)) {
        if (ndigits == null or digits >= 0) {
            self.setRegister(destination, input);
            return true;
        }
        const places: u32 = @intCast(@min(-@as(i128, digits), 100_000));
        if (places == 100_000) {
            self.setRegister(destination, Value.fromSmallInt(0).?);
            return true;
        }
        const factor = takeValue(self, number.power(&self.heap, Value.fromSmallInt(10).?, Value.fromSmallInt(places).?), line, column) orelse return false;
        var quotient = takeValue(self, number.floorDiv(&self.heap, input, factor), line, column) orelse return false;
        const remainder = takeValue(self, number.modulo(&self.heap, input, factor), line, column) orelse return false;
        const doubled = takeValue(self, number.multiply(&self.heap, remainder, Value.fromSmallInt(2).?), line, column) orelse return false;
        const comparison = takeComparison(self, number.compare(doubled, factor), line, column) orelse return false;
        const q_odd = !number.isZeroValue(takeValue(self, number.modulo(&self.heap, quotient, Value.fromSmallInt(2).?), line, column) orelse return false);
        if (comparison == .greater or (comparison == .equal and q_odd)) quotient = takeValue(self, number.add(&self.heap, quotient, Value.fromSmallInt(1).?), line, column) orelse return false;
        return self.storeValueResult(destination, number.multiply(&self.heap, quotient, factor), line, column);
    }
    const float_value = input.asFloat() orelse return self.nativeTypeError(line, column, "type does not define __round__ method");
    if (!std.math.isFinite(float_value) and ndigits == null) {
        self.setException(.{ .kind = if (std.math.isNan(float_value)) .value_error else .overflow_error, .message = "cannot convert non-finite float to integer" }, line, column, null);
        return false;
    }
    const rounded = roundFloat(float_value, digits);
    if (ndigits != null) {
        self.setRegister(destination, Value.fromFloat(rounded));
        return true;
    }
    return self.storeValueResult(destination, number.fromIntegralFloat(&self.heap, rounded), line, column);
}

fn roundFloat(value: f64, digits: i64) f64 {
    if (!std.math.isFinite(value) or digits > 308 or digits < -308) return if (digits < 0) std.math.copysign(@as(f64, 0), value) else value;
    const scale = pow10Wide(@intCast(if (digits < 0) -digits else digits));
    const scaled: f128 = if (digits >= 0) @as(f128, value) * scale else @as(f128, value) / scale;
    const magnitude = @abs(scaled);
    const whole = @floor(magnitude);
    const fraction = magnitude - whole;
    const rounded = whole + @as(f128, if (fraction > 0.5 or (fraction == 0.5 and @rem(whole, 2) != 0)) 1 else 0);
    const signed = std.math.copysign(rounded, scaled);
    return @floatCast(if (digits >= 0) signed / scale else signed * scale);
}

fn pow10Wide(exponent: u64) f128 {
    var remaining = exponent;
    var base: f128 = 10;
    var result: f128 = 1;
    while (remaining != 0) : (remaining >>= 1) {
        if (remaining & 1 != 0) result *= base;
        base *= base;
    }
    return result;
}

fn executeBytes(self: *Runtime, destination: u16, positional: []const Value, keywords: []const binder.Keyword, line: u32, column: u32) bool {
    if (positional.len > 2) return self.nativeArity(line, column);
    var encoding: ?Value = if (positional.len == 2) positional[1] else null;
    for (keywords) |keyword| {
        if (!std.mem.eql(u8, keyword.name, "encoding")) return self.nativeTypeError(line, column, "unexpected keyword argument");
        if (encoding != null) return self.nativeTypeError(line, column, "multiple values for encoding");
        encoding = keyword.value;
    }
    if (positional.len == 0) {
        if (encoding != null) return self.nativeTypeError(line, column, "encoding without a string argument");
        return storeBytes(self, destination, bytes.create(&self.heap, ""), line, column);
    }
    const source = positional[0];
    if (source.asObject()) |header| if (string.fromHeader(header)) |text| {
        const encoding_value = encoding orelse return self.nativeTypeError(line, column, "string argument without an encoding");
        const encoding_text = self.valueString(encoding_value) orelse return self.nativeTypeError(line, column, "encoding must be a string");
        const kind = encodingKind(encoding_text) orelse {
            self.setException(.{ .kind = .lookup_error, .message = "unknown encoding" }, line, column, null);
            return false;
        };
        const content = string.content(text);
        if (kind == .ascii) for (content) |byte| if (byte >= 0x80) {
            self.setException(.{ .kind = .unicode_encode_error, .message = "ordinal not in range(128)" }, line, column, null);
            return false;
        };
        return storeBytes(self, destination, bytes.create(&self.heap, content), line, column);
    };
    if (encoding != null) return self.nativeTypeError(line, column, "encoding without a string argument");
    if (number.isIntegerValue(source)) {
        const comparison = takeComparison(self, number.compare(source, Value.fromSmallInt(0).?), line, column) orelse return false;
        if (comparison == .less) {
            self.setException(.{ .kind = .value_error, .message = "negative count" }, line, column, null);
            return false;
        }
        const count = number.toInt(usize, source) orelse {
            self.setException(.{ .kind = .overflow_error, .message = "cannot fit count into an index-sized integer" }, line, column, null);
            return false;
        };
        return storeBytes(self, destination, bytes.zeroes(&self.heap, count), line, column);
    }
    if (source.asObject()) |header| if (bytes.fromHeader(header)) |data| return storeBytes(self, destination, bytes.create(&self.heap, data.data), line, column);
    return startBytesTask(self, destination, source, line, column);
}

const Encoding = enum { utf8, ascii };
fn encodingKind(text: []const u8) ?Encoding {
    var normalized: [8]u8 = undefined;
    var count: usize = 0;
    for (text) |character| {
        if (character == '-' or character == '_') continue;
        if (count == normalized.len) return null;
        normalized[count] = std.ascii.toLower(character);
        count += 1;
    }
    if (std.mem.eql(u8, normalized[0..count], "utf8")) return .utf8;
    if (std.mem.eql(u8, normalized[0..count], "ascii")) return .ascii;
    return null;
}

fn startReduction(self: *Runtime, destination: u16, native: functions.Native, positional: []const Value, keywords: []const binder.Keyword, line: u32, column: u32) bool {
    var source: Value = undefined;
    var callback = Value.noneValue();
    var default_value: ?Value = null;
    var operation: state.SyncTaskOperation = undefined;
    switch (native) {
        .all_builtin, .any_builtin => {
            if (!exact(positional, keywords, 1)) return self.nativeArity(line, column);
            source = positional[0];
            operation = if (native == .all_builtin) .builtin_all else .builtin_any;
        },
        .sum_builtin => {
            if (keywords.len != 0 or positional.len < 1 or positional.len > 2) return self.nativeArity(line, column);
            source = positional[0];
            default_value = if (positional.len == 2) positional[1] else Value.fromSmallInt(0).?;
            operation = .builtin_sum;
        },
        .min_builtin, .max_builtin => {
            if (positional.len == 0) return self.nativeArity(line, column);
            for (keywords) |keyword| {
                if (std.mem.eql(u8, keyword.name, "key")) {
                    if (callback.tag() != .none) return self.nativeTypeError(line, column, "multiple values for key");
                    callback = keyword.value;
                } else if (std.mem.eql(u8, keyword.name, "default")) {
                    if (default_value != null) return self.nativeTypeError(line, column, "multiple values for default");
                    default_value = keyword.value;
                } else return self.nativeTypeError(line, column, "unexpected keyword argument");
            }
            if (positional.len > 1) {
                if (default_value != null) return self.nativeTypeError(line, column, "Cannot specify a default for min()/max() with multiple positional arguments");
                const tuple = switch (sequence.createTuple(&self.heap, positional)) {
                    .value => |value| value,
                    .python_exception => |exception| return fail(self, exception, line, column),
                    .engine_error => return self.engineFault(),
                };
                source = Value.object(&tuple.header);
            } else source = positional[0];
            operation = if (native == .min_builtin) .builtin_min else .builtin_max;
        },
        else => return self.engineFault(),
    }
    return beginTailTask(self, destination, operation, source, callback, default_value, line, column);
}

fn startBytesTask(self: *Runtime, destination: u16, source: Value, line: u32, column: u32) bool {
    return beginTailTask(self, destination, .builtin_bytes, source, Value.noneValue(), null, line, column);
}

fn beginTailTask(self: *Runtime, destination: u16, operation: state.SyncTaskOperation, source: Value, callback: Value, initial: ?Value, line: u32, column: u32) bool {
    const selected = switch (self.createVmIterator(source, line, column)) {
        .value => |value| value,
        .python_exception => |exception| return fail(self, exception, line, column),
        .engine_error => return self.engineFault(),
    };
    const frame = self.top_frame orelse return self.engineFault();
    const call_ip = if (frame.ip == 0) return self.engineFault() else frame.ip - 1;
    self.beginSyncTaskRoots();
    self.sync_roots[0].object = &selected.header;
    self.sync_roots[4].object = callback.asObject();
    self.sync_task = .{ .frame = frame, .call_ip = call_ip, .operation = operation, .destination = destination, .line = line, .column = column, .iterator_value = selected, .callback = callback, .want_tuple = initial != null };
    if (operation == .builtin_sum or operation == .builtin_min or operation == .builtin_max or operation == .builtin_bytes) {
        const target = switch (sequence.createList(&self.heap, if (initial) |value| &.{value} else &.{})) {
            .value => |value| value,
            .python_exception => |exception| return fail(self, exception, line, column),
            .engine_error => return self.engineFault(),
        };
        self.sync_roots[1].object = &target.header;
        self.sync_task.?.target = target;
    }
    return self.advanceSyncTask();
}

pub fn isTailTask(operation: state.SyncTaskOperation) bool {
    return switch (operation) { .builtin_all, .builtin_any, .builtin_min, .builtin_max, .builtin_sum, .builtin_bytes => true, else => false };
}

pub fn advanceTask(self: *Runtime, task: *state.SyncTask, remaining: *u32) bool {
    const selected = task.iterator_value orelse return self.engineFault();
    if ((task.operation == .builtin_min or task.operation == .builtin_max) and task.position == 1) {
        const result = self.takeCompletedSyncCallback() orelse return self.continueSyncTaskAfterCallback(task);
        const target = task.target orelse return self.engineFault();
        task.position = 0;
        const item = target.items.pop() orelse return self.engineFault();
        if (!selectExtremum(self, task, item, result)) return false;
    }
    while (remaining.* != 0 and !task.complete) {
        if (!self.chargeSynchronousWork(task.line, task.column)) return false;
        remaining.* -= 1;
        switch (self.nextIteratorValue(selected, task.destination, task.line, task.column)) {
            .item => |item| {
                self.sync_roots[5].object = item.asObject();
                if (!consumeItem(self, task, item)) return false;
                if (task.callback_in_progress) return self.continueSyncTaskAfterCallback(task);
            },
            .done => return finishTask(self, task),
            .suspended => return if (@import("iteration.zig").iteratorHasPendingCallback(selected)) self.continueSyncTaskAfterCallback(task) else self.pauseSyncTask(task),
            .python_exception => |exception| return fail(self, exception, task.line, task.column),
            .engine_error => return self.engineFault(),
        }
        if (task.complete) return true;
        if (self.output_event_pending or self.pending_input != null) return self.pauseSyncTask(task);
    }
    return if (task.complete) true else self.pauseSyncTask(task);
}

fn consumeItem(self: *Runtime, task: *state.SyncTask, item: Value) bool {
    switch (task.operation) {
        .builtin_all, .builtin_any => {
            const truthy = self.valueTruthy(item, task.line, task.column) orelse return false;
            if ((task.operation == .builtin_all and !truthy) or (task.operation == .builtin_any and truthy)) {
                self.setRegister(task.destination, if (truthy) Value.trueValue() else Value.falseValue());
                task.complete = true;
            }
            return true;
        },
        .builtin_sum => {
            const target = task.target orelse return self.engineFault();
            if (target.items.items.len != 1) return self.engineFault();
            const total = takeValue(self, number.add(&self.heap, target.items.items[0], item), task.line, task.column) orelse return false;
            target.items.items[0] = total;
            return true;
        },
        .builtin_bytes => {
            if (!number.isIntegerValue(item)) return self.nativeTypeError(task.line, task.column, "an integer is required");
            const integer = number.toInt(i64, item) orelse return self.nativeTypeError(task.line, task.column, "integer out of range");
            if (integer < 0 or integer > 255) {
                self.setException(.{ .kind = .value_error, .message = "bytes must be in range(0, 256)" }, task.line, task.column, null);
                return false;
            }
            return appendTarget(self, task, item);
        },
        .builtin_min, .builtin_max => return consumeExtremum(self, task, item),
        else => return self.engineFault(),
    }
}

fn consumeExtremum(self: *Runtime, task: *state.SyncTask, item: Value) bool {
    const target = task.target orelse return self.engineFault();
    var key = item;
    if (task.callback.tag() != .none) {
        const outcome = self.invokeSyncTaskCallback(task.callback, &.{item}, task.destination, task.line, task.column);
        key = switch (outcome) {
            .value => |value| value,
            .suspended => {
                switch (sequence.append(&self.heap, target, item)) { .value => {}, .python_exception => |exception| return fail(self, exception, task.line, task.column), .engine_error => return self.engineFault() }
                task.position = 1;
                return self.continueSyncTaskAfterCallback(task);
            },
            .failed => return false,
        };
    }
    return selectExtremum(self, task, item, key);
}

fn selectExtremum(self: *Runtime, task: *state.SyncTask, item: Value, key: Value) bool {
    const target = task.target orelse return self.engineFault();
    if (task.index == 0) {
        if (target.items.items.len == 0) {
            if (!appendTarget(self, task, item)) return false;
        } else target.items.items[0] = item;
        if (!appendTarget(self, task, key)) return false;
        task.index = 1;
        return true;
    }
    const order = self.sortOrder(key, target.items.items[1], task.line, task.column) orelse return false;
    const replace = if (task.operation == .builtin_min) order == .lt else order == .gt;
    if (replace) {
        target.items.items[0] = item;
        target.items.items[1] = key;
    }
    task.index += 1;
    return true;
}

fn finishTask(self: *Runtime, task: *state.SyncTask) bool {
    switch (task.operation) {
        .builtin_all => self.setRegister(task.destination, Value.trueValue()),
        .builtin_any => self.setRegister(task.destination, Value.falseValue()),
        .builtin_sum => self.setRegister(task.destination, (task.target orelse return self.engineFault()).items.items[0]),
        .builtin_min, .builtin_max => {
            const target = task.target orelse return self.engineFault();
            if (task.index == 0 and !task.want_tuple) {
                self.setException(.{ .kind = .value_error, .message = if (task.operation == .builtin_min) "min() arg is an empty sequence" else "max() arg is an empty sequence" }, task.line, task.column, null);
                return false;
            }
            self.setRegister(task.destination, target.items.items[0]);
        },
        .builtin_bytes => {
            const target = task.target orelse return self.engineFault();
            const integers = self.heap.allocator.alloc(i64, target.items.items.len) catch return memoryFailure(self, task.line, task.column);
            defer self.heap.allocator.free(integers);
            for (target.items.items, 0..) |value, index| integers[index] = number.toInt(i64, value).?;
            if (!storeBytes(self, task.destination, bytes.fromIntegers(&self.heap, integers), task.line, task.column)) return false;
        },
        else => return self.engineFault(),
    }
    task.complete = true;
    return true;
}

fn appendTarget(self: *Runtime, task: *state.SyncTask, value: Value) bool {
    const target = task.target orelse return self.engineFault();
    return switch (sequence.append(&self.heap, target, value)) { .value => true, .python_exception => |exception| fail(self, exception, task.line, task.column), .engine_error => self.engineFault() };
}

fn takeValue(self: *Runtime, result: number.ValueResult, line: u32, column: u32) ?Value {
    return switch (result) { .value => |value| value, .python_exception => |exception| { _ = fail(self, exception, line, column); return null; }, .engine_error => { _ = self.engineFault(); return null; } };
}
fn takeComparison(self: *Runtime, result: number.ComparisonResult, line: u32, column: u32) ?number.Comparison {
    return switch (result) { .value => |value| value, .python_exception => |exception| { _ = fail(self, exception, line, column); return null; }, .engine_error => { _ = self.engineFault(); return null; } };
}
fn storeBytes(self: *Runtime, destination: u16, result: bytes.BytesResult, line: u32, column: u32) bool {
    return switch (result) { .value => |value| { self.setRegister(destination, Value.object(&value.header)); return true; }, .python_exception => |exception| fail(self, exception, line, column), .engine_error => self.engineFault() };
}
fn fail(self: *Runtime, exception: @import("runtime_exception").PythonException, line: u32, column: u32) bool { self.setException(exception, line, column, null); return false; }
fn memoryFailure(self: *Runtime, line: u32, column: u32) bool { self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null); return false; }
