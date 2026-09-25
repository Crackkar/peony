const std = @import("std");
const binder = @import("runtime_binder");
const gc = @import("runtime_gc");
const number = @import("runtime_number");
const sequence = @import("runtime_sequence");
const types = @import("types.zig");

const Value = types.Value;
const positional_only = binder.parameter_flags_module.positional_only;

const Function = enum(u16) {
    sqrt = 1,
    pow,
    exp,
    log,
    log2,
    log10,
    sin,
    cos,
    tan,
    asin,
    acos,
    atan,
    atan2,
    floor,
    ceil,
    trunc,
    fabs,
    factorial,
    gcd,
    lcm,
    isfinite,
    isinf,
    isnan,
    radians,
    degrees,
};

pub const functions = [_]types.FunctionSpec{
    unarySpec(.sqrt, "sqrt"),
    binarySpec(.pow, "pow"),
    unarySpec(.exp, "exp"),
    .{ .id = @intFromEnum(Function.log), .name = "log", .params = &.{
        .{ .name = "x", .flags = positional_only },
        .{ .name = "base", .flags = positional_only, .default = .none },
    } },
    unarySpec(.log2, "log2"),
    unarySpec(.log10, "log10"),
    unarySpec(.sin, "sin"),
    unarySpec(.cos, "cos"),
    unarySpec(.tan, "tan"),
    unarySpec(.asin, "asin"),
    unarySpec(.acos, "acos"),
    unarySpec(.atan, "atan"),
    binarySpec(.atan2, "atan2"),
    unarySpec(.floor, "floor"),
    unarySpec(.ceil, "ceil"),
    unarySpec(.trunc, "trunc"),
    unarySpec(.fabs, "fabs"),
    unarySpec(.factorial, "factorial"),
    variadicSpec(.gcd, "gcd"),
    variadicSpec(.lcm, "lcm"),
    unarySpec(.isfinite, "isfinite"),
    unarySpec(.isinf, "isinf"),
    unarySpec(.isnan, "isnan"),
    unarySpec(.radians, "radians"),
    unarySpec(.degrees, "degrees"),
};

fn unarySpec(comptime function: Function, comptime name: []const u8) types.FunctionSpec {
    return .{ .id = @intFromEnum(function), .name = name, .params = &.{.{ .name = "x", .flags = positional_only }} };
}

fn binarySpec(comptime function: Function, comptime name: []const u8) types.FunctionSpec {
    return .{ .id = @intFromEnum(function), .name = name, .params = &.{
        .{ .name = "x", .flags = positional_only },
        .{ .name = "y", .flags = positional_only },
    } };
}

fn variadicSpec(comptime function: Function, comptime name: []const u8) types.FunctionSpec {
    return .{ .id = @intFromEnum(function), .name = name, .params = &.{.{ .name = "integers", .flags = binder.parameter_flags_module.var_positional }} };
}

pub fn populate(comptime Runtime: type, self: *Runtime, environment: *gc.Header, line: u32, column: u32) bool {
    return store(self, environment, "pi", Value.fromFloat(std.math.pi), line, column) and
        store(self, environment, "e", Value.fromFloat(std.math.e), line, column) and
        store(self, environment, "tau", Value.fromFloat(std.math.tau), line, column) and
        store(self, environment, "inf", Value.fromFloat(std.math.inf(f64)), line, column) and
        store(self, environment, "nan", Value.fromFloat(std.math.nan(f64)), line, column);
}

fn store(self: anytype, environment: *gc.Header, name: []const u8, value: Value, line: u32, column: u32) bool {
    if (self.environmentStore(environment, name, value)) return true;
    self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
    return false;
}

pub fn execute(
    comptime Runtime: type,
    self: *Runtime,
    destination: u16,
    function_id: u16,
    receiver: Value,
    args: []const Value,
    extra: []const binder.Keyword,
    line: u32,
    column: u32,
) bool {
    _ = receiver;
    if (extra.len != 0) return self.nativeTypeError(line, column, "unexpected keyword argument");
    const function = std.enums.fromInt(Function, function_id) orelse return self.engineFault();
    switch (function) {
        .sqrt => return unaryFloat(Runtime, self, destination, args[0], .sqrt, line, column),
        .pow => return powerFloat(Runtime, self, destination, args[0], args[1], line, column),
        .exp => return unaryFloat(Runtime, self, destination, args[0], .exp, line, column),
        .log => return logarithm(Runtime, self, destination, args[0], args[1], line, column),
        .log2 => return unaryFloat(Runtime, self, destination, args[0], .log2, line, column),
        .log10 => return unaryFloat(Runtime, self, destination, args[0], .log10, line, column),
        .sin => return unaryFloat(Runtime, self, destination, args[0], .sin, line, column),
        .cos => return unaryFloat(Runtime, self, destination, args[0], .cos, line, column),
        .tan => return unaryFloat(Runtime, self, destination, args[0], .tan, line, column),
        .asin => return unaryFloat(Runtime, self, destination, args[0], .asin, line, column),
        .acos => return unaryFloat(Runtime, self, destination, args[0], .acos, line, column),
        .atan => return unaryFloat(Runtime, self, destination, args[0], .atan, line, column),
        .atan2 => return atanTwo(Runtime, self, destination, args[0], args[1], line, column),
        .floor => return floatToInteger(Runtime, self, destination, args[0], .floor, line, column),
        .ceil => return floatToInteger(Runtime, self, destination, args[0], .ceil, line, column),
        .trunc => return floatToInteger(Runtime, self, destination, args[0], .trunc, line, column),
        .fabs => return absoluteFloat(Runtime, self, destination, args[0], line, column),
        .factorial => return factorial(Runtime, self, destination, args[0], line, column),
        .gcd => return gcdMany(Runtime, self, destination, args[0], line, column),
        .lcm => return lcmMany(Runtime, self, destination, args[0], line, column),
        .isfinite => return classify(Runtime, self, destination, args[0], .finite, line, column),
        .isinf => return classify(Runtime, self, destination, args[0], .infinite, line, column),
        .isnan => return classify(Runtime, self, destination, args[0], .nan, line, column),
        .radians => return angle(Runtime, self, destination, args[0], false, line, column),
        .degrees => return angle(Runtime, self, destination, args[0], true, line, column),
    }
}

const UnaryFloat = enum { sqrt, exp, log2, log10, sin, cos, tan, asin, acos, atan };

fn unaryFloat(comptime Runtime: type, self: *Runtime, destination: u16, value: Value, operation: UnaryFloat, line: u32, column: u32) bool {
    if ((operation == .log2 or operation == .log10) and number.isIntegerValue(value)) {
        const result = integerLog(Runtime, self, value, if (operation == .log2) .binary else .decimal, line, column) orelse return false;
        self.setRegister(destination, Value.fromFloat(result));
        return true;
    }
    const input = asFloat(Runtime, self, value, line, column) orelse return false;
    const domain_error = switch (operation) {
        .sqrt, .log2, .log10 => !std.math.isNan(input) and input <= 0.0,
        .asin, .acos => !std.math.isNan(input) and (input < -1.0 or input > 1.0),
        .sin, .cos, .tan => std.math.isInf(input),
        .exp, .atan => false,
    };
    if (domain_error) return mathError(Runtime, self, line, column, .value_error, "math domain error");
    const result: f64 = switch (operation) {
        .sqrt => std.math.sqrt(input),
        .exp => @exp(input),
        .log2 => std.math.log2(input),
        .log10 => std.math.log10(input),
        .sin => std.math.sin(input),
        .cos => std.math.cos(input),
        .tan => std.math.tan(input),
        .asin => std.math.asin(input),
        .acos => std.math.acos(input),
        .atan => std.math.atan(input),
    };
    if (operation == .exp and std.math.isFinite(input) and std.math.isInf(result)) return mathError(Runtime, self, line, column, .overflow_error, "math range error");
    self.setRegister(destination, Value.fromFloat(result));
    return true;
}

fn powerFloat(comptime Runtime: type, self: *Runtime, destination: u16, left_value: Value, right_value: Value, line: u32, column: u32) bool {
    const left = asFloat(Runtime, self, left_value, line, column) orelse return false;
    const right = asFloat(Runtime, self, right_value, line, column) orelse return false;
    if (left == 0.0 and right < 0.0) return mathError(Runtime, self, line, column, .value_error, "math domain error");
    if (left < 0.0 and std.math.isFinite(right) and right != @trunc(right)) return mathError(Runtime, self, line, column, .value_error, "math domain error");
    const result = std.math.pow(f64, left, right);
    if (std.math.isNan(result) and !std.math.isNan(left) and !std.math.isNan(right)) return mathError(Runtime, self, line, column, .value_error, "math domain error");
    if (std.math.isInf(result) and std.math.isFinite(left) and std.math.isFinite(right)) return mathError(Runtime, self, line, column, .overflow_error, "math range error");
    self.setRegister(destination, Value.fromFloat(result));
    return true;
}

fn logarithm(comptime Runtime: type, self: *Runtime, destination: u16, value: Value, base_value: Value, line: u32, column: u32) bool {
    const natural = if (number.isIntegerValue(value))
        integerNaturalLog(Runtime, self, value, line, column) orelse return false
    else blk: {
        const input = asFloat(Runtime, self, value, line, column) orelse return false;
        if (!std.math.isNan(input) and input <= 0.0) return mathError(Runtime, self, line, column, .value_error, "math domain error");
        break :blk @log(input);
    };
    if (base_value.tag() == .none) {
        self.setRegister(destination, Value.fromFloat(natural));
        return true;
    }
    const base_log = if (number.isIntegerValue(base_value))
        integerNaturalLog(Runtime, self, base_value, line, column) orelse return false
    else blk: {
        const base = asFloat(Runtime, self, base_value, line, column) orelse return false;
        if (!std.math.isNan(base) and (base <= 0.0 or base == 1.0)) return mathError(Runtime, self, line, column, .value_error, "math domain error");
        break :blk @log(base);
    };
    if (base_log == 0.0) return mathError(Runtime, self, line, column, .value_error, "math domain error");
    self.setRegister(destination, Value.fromFloat(natural / base_log));
    return true;
}

fn integerNaturalLog(comptime Runtime: type, self: *Runtime, value: Value, line: u32, column: u32) ?f64 {
    return integerLog(Runtime, self, value, .natural, line, column);
}

const LogKind = enum { natural, binary, decimal };

fn integerLog(comptime Runtime: type, self: *Runtime, value: Value, kind: LogKind, line: u32, column: u32) ?f64 {
    switch (number.compare(value, Value.fromSmallInt(0).?)) {
        .value => |comparison| if (comparison != .greater) {
            _ = mathError(Runtime, self, line, column, .value_error, "math domain error");
            return null;
        },
        .python_exception => |exception| {
            self.setException(exception, line, column, null);
            return null;
        },
        .engine_error => {
            _ = self.engineFault();
            return null;
        },
    }
    switch (number.toFloat(&self.heap, value)) {
        .value => |converted| return switch (kind) {
            .natural => @log(converted),
            .binary => std.math.log2(converted),
            .decimal => std.math.log10(converted),
        },
        .python_exception => |exception| if (exception.kind != .overflow_error) {
            self.setException(exception, line, column, null);
            return null;
        },
        .engine_error => {
            _ = self.engineFault();
            return null;
        },
    }
    const formatted = number.formatIntegerBase(&self.heap, value, 2, .lower) orelse return null;
    const bits = switch (formatted) {
        .value => |text| text,
        .python_exception => |exception| {
            self.setException(exception, line, column, null);
            return null;
        },
        .engine_error => {
            _ = self.engineFault();
            return null;
        },
    };
    defer self.heap.allocator.free(bits);
    const significant_count = @min(bits.len, 53);
    var significant: u64 = 0;
    for (bits[0..significant_count]) |bit| significant = (significant << 1) | @as(u64, bit - '0');
    const denominator = @as(u64, 1) << @intCast(significant_count - 1);
    const mantissa: f64 = @as(f64, @floatFromInt(significant)) / @as(f64, @floatFromInt(denominator));
    const exponent: f64 = @floatFromInt(bits.len - 1);
    return switch (kind) {
        .natural => @log(mantissa) + exponent * @log(@as(f64, 2.0)),
        .binary => std.math.log2(mantissa) + exponent,
        .decimal => std.math.log10(mantissa) + exponent * std.math.log10(@as(f64, 2.0)),
    };
}

fn atanTwo(comptime Runtime: type, self: *Runtime, destination: u16, y_value: Value, x_value: Value, line: u32, column: u32) bool {
    const y = asFloat(Runtime, self, y_value, line, column) orelse return false;
    const x = asFloat(Runtime, self, x_value, line, column) orelse return false;
    self.setRegister(destination, Value.fromFloat(std.math.atan2(y, x)));
    return true;
}

const IntegerRounding = enum { floor, ceil, trunc };

fn floatToInteger(comptime Runtime: type, self: *Runtime, destination: u16, value: Value, operation: IntegerRounding, line: u32, column: u32) bool {
    if (number.isIntegerValue(value)) {
        self.setRegister(destination, value);
        return true;
    }
    const input = asFloat(Runtime, self, value, line, column) orelse return false;
    if (std.math.isNan(input)) return mathError(Runtime, self, line, column, .value_error, "cannot convert float NaN to integer");
    if (std.math.isInf(input)) return mathError(Runtime, self, line, column, .overflow_error, "cannot convert float infinity to integer");
    const integral = switch (operation) {
        .floor => @floor(input),
        .ceil => @ceil(input),
        .trunc => @trunc(input),
    };
    return self.storeNumberResult(destination, number.fromIntegralFloat(&self.heap, integral), line, column);
}

fn absoluteFloat(comptime Runtime: type, self: *Runtime, destination: u16, value: Value, line: u32, column: u32) bool {
    const input = asFloat(Runtime, self, value, line, column) orelse return false;
    self.setRegister(destination, Value.fromFloat(@abs(input)));
    return true;
}

fn factorial(comptime Runtime: type, self: *Runtime, destination: u16, value: Value, line: u32, column: u32) bool {
    if (!number.isIntegerValue(value)) return self.nativeTypeError(line, column, "factorial() only accepts integral values");
    const order = number.compare(value, Value.fromSmallInt(0).?);
    switch (order) {
        .value => |comparison| if (comparison == .less) return mathError(Runtime, self, line, column, .value_error, "factorial() not defined for negative values"),
        .python_exception => |exception| {
            self.setException(exception, line, column, null);
            return false;
        },
        .engine_error => return self.engineFault(),
    }
    const count = number.toInt(u64, value) orelse return mathError(Runtime, self, line, column, .memory_error, "factorial result exceeds session limits");
    var result = Value.fromSmallInt(1).?;
    var result_root = gc.Root{ .object = null };
    var factor_root = gc.Root{ .object = null };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&result_root);
    roots.add(&factor_root);
    defer roots.pop();
    const owns_work = self.beginSynchronousWork();
    defer self.endSynchronousWork(owns_work);
    var factor: u64 = 2;
    while (factor <= count) : (factor += 1) {
        if (!self.chargeSynchronousWork(line, column)) return false;
        const factor_value = number.fromInt(&self.heap, factor);
        const selected = switch (factor_value) {
            .value => |created| created,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        factor_root.object = selected.asObject();
        result = switch (number.multiply(&self.heap, result, selected)) {
            .value => |created| created,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        result_root.object = result.asObject();
        factor_root.object = null;
        if (factor == std.math.maxInt(u64)) break;
    }
    self.setRegister(destination, result);
    return true;
}

fn gcdMany(comptime Runtime: type, self: *Runtime, destination: u16, tuple_value: Value, line: u32, column: u32) bool {
    const values = tupleItems(tuple_value) orelse return self.engineFault();
    if (!validateIntegers(Runtime, self, values, line, column)) return false;
    var result = Value.fromSmallInt(0).?;
    var result_root = gc.Root{ .object = null };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&result_root);
    defer roots.pop();
    const owns_work = self.beginSynchronousWork();
    defer self.endSynchronousWork(owns_work);
    for (values) |item| {
        if (!self.chargeSynchronousWork(line, column)) return false;
        result = gcdTwo(Runtime, self, result, item, line, column) orelse return false;
        result_root.object = result.asObject();
    }
    self.setRegister(destination, result);
    return true;
}

fn lcmMany(comptime Runtime: type, self: *Runtime, destination: u16, tuple_value: Value, line: u32, column: u32) bool {
    const values = tupleItems(tuple_value) orelse return self.engineFault();
    if (!validateIntegers(Runtime, self, values, line, column)) return false;
    var result = Value.fromSmallInt(1).?;
    var result_root = gc.Root{ .object = null };
    var item_root = gc.Root{ .object = null };
    var temporary_root = gc.Root{ .object = null };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&result_root);
    roots.add(&item_root);
    roots.add(&temporary_root);
    defer roots.pop();
    const owns_work = self.beginSynchronousWork();
    defer self.endSynchronousWork(owns_work);
    for (values) |item| {
        if (!self.chargeSynchronousWork(line, column)) return false;
        item_root.object = item.asObject();
        if (number.isZeroValue(result) or number.isZeroValue(item)) {
            result = Value.fromSmallInt(0).?;
            result_root.object = null;
            continue;
        }
        const divisor = gcdTwo(Runtime, self, result, item, line, column) orelse return false;
        temporary_root.object = divisor.asObject();
        const quotient = unwrapValue(Runtime, self, number.floorDiv(&self.heap, result, divisor), line, column) orelse return false;
        temporary_root.object = quotient.asObject();
        const product = unwrapValue(Runtime, self, number.multiply(&self.heap, quotient, item), line, column) orelse return false;
        temporary_root.object = product.asObject();
        result = absoluteInteger(Runtime, self, product, line, column) orelse return false;
        result_root.object = result.asObject();
        temporary_root.object = null;
    }
    self.setRegister(destination, result);
    return true;
}

fn gcdTwo(comptime Runtime: type, self: *Runtime, left_value: Value, right_value: Value, line: u32, column: u32) ?Value {
    var left_root = gc.Root{ .object = left_value.asObject() };
    var right_root = gc.Root{ .object = right_value.asObject() };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&left_root);
    roots.add(&right_root);
    defer roots.pop();
    var left = absoluteInteger(Runtime, self, left_value, line, column) orelse return null;
    left_root.object = left.asObject();
    var right = absoluteInteger(Runtime, self, right_value, line, column) orelse return null;
    right_root.object = right.asObject();
    while (!number.isZeroValue(right)) {
        if (!self.chargeSynchronousWork(line, column)) return null;
        const remainder = unwrapValue(Runtime, self, number.modulo(&self.heap, left, right), line, column) orelse return null;
        left = right;
        left_root.object = left.asObject();
        right = remainder;
        right_root.object = right.asObject();
    }
    return left;
}

fn absoluteInteger(comptime Runtime: type, self: *Runtime, value: Value, line: u32, column: u32) ?Value {
    return switch (number.compare(value, Value.fromSmallInt(0).?)) {
        .value => |comparison| if (comparison == .less) unwrapValue(Runtime, self, number.negative(&self.heap, value), line, column) else value,
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

fn validateIntegers(comptime Runtime: type, self: *Runtime, values: []const Value, line: u32, column: u32) bool {
    for (values) |value| if (!number.isIntegerValue(value)) return self.nativeTypeError(line, column, "integer argument expected");
    return true;
}

const Classification = enum { finite, infinite, nan };

fn classify(comptime Runtime: type, self: *Runtime, destination: u16, value: Value, classification: Classification, line: u32, column: u32) bool {
    if (number.isIntegerValue(value)) {
        self.setRegister(destination, if (classification == .finite) Value.trueValue() else Value.falseValue());
        return true;
    }
    const input = asFloat(Runtime, self, value, line, column) orelse return false;
    const result = switch (classification) {
        .finite => std.math.isFinite(input),
        .infinite => std.math.isInf(input),
        .nan => std.math.isNan(input),
    };
    self.setRegister(destination, if (result) Value.trueValue() else Value.falseValue());
    return true;
}

fn angle(comptime Runtime: type, self: *Runtime, destination: u16, value: Value, to_degrees: bool, line: u32, column: u32) bool {
    const input = asFloat(Runtime, self, value, line, column) orelse return false;
    const result = if (to_degrees) std.math.radiansToDegrees(input) else std.math.degreesToRadians(input);
    self.setRegister(destination, Value.fromFloat(result));
    return true;
}

fn asFloat(comptime Runtime: type, self: *Runtime, value: Value, line: u32, column: u32) ?f64 {
    return switch (number.toFloat(&self.heap, value)) {
        .value => |float_value| float_value,
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

fn unwrapValue(comptime Runtime: type, self: *Runtime, result: number.ValueResult, line: u32, column: u32) ?Value {
    return switch (result) {
        .value => |value| value,
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

fn tupleItems(value: Value) ?[]const Value {
    const header = value.asObject() orelse return null;
    const tuple = sequence.tupleFromHeader(header) orelse return null;
    return tuple.items;
}

fn mathError(comptime Runtime: type, self: *Runtime, line: u32, column: u32, kind: anytype, message: []const u8) bool {
    self.setException(.{ .kind = kind, .message = message }, line, column, null);
    return false;
}
