const std = @import("std");
const gc = @import("runtime_gc");
const binder = @import("runtime_binder");
const value_module = @import("runtime_value");
const exceptions = @import("runtime_exception");
const types = @import("types.zig");
const registry = @import("registry.zig");
const sys = @import("sys.zig");
const math = @import("math.zig");
const time = @import("time.zig");
const random = @import("random.zig");
const ssl = @import("ssl.zig");
const statistics = @import("statistics.zig");
const json_values = @import("json_values.zig");
const re = @import("re.zig");
const http = @import("http_native.zig");
const csv = @import("csv.zig");
const pathlib = @import("pathlib.zig");
const os = @import("os.zig");
const collections = @import("collections.zig");
const copy = @import("copy.zig");

const Value = value_module.Value;
pub const max_native_parameters = 24;

pub fn pathText(value: Value) ?[]const u8 {
    return pathlib.pathText(value);
}

pub fn call(
    comptime Runtime: type,
    self: *Runtime,
    destination: u16,
    module_id_raw: u8,
    function_id: u16,
    receiver: Value,
    positional: []const Value,
    keywords: []const binder.Keyword,
    line: u32,
    column: u32,
) bool {
    const module_id = std.enums.fromInt(types.ModuleId, module_id_raw) orelse return self.engineFault();
    const spec = registry.functionSpec(module_id, function_id) orelse return self.engineFault();
    if (spec.params.len > max_native_parameters) return self.engineFault();

    var names: [max_native_parameters][]const u8 = undefined;
    var flags: [max_native_parameters]u32 = undefined;
    var defaults: [max_native_parameters]Value = undefined;
    var default_roots: [max_native_parameters]gc.Root = @splat(.{ .object = null });
    var default_frame = gc.RootFrame{};
    default_frame.push(&self.heap.roots);
    for (default_roots[0..spec.params.len]) |*root| default_frame.add(root);
    defer default_frame.pop();
    for (spec.params, 0..) |param, index| {
        names[index] = param.name;
        flags[index] = param.flags;
        defaults[index] = switch (param.default) {
            .required => Value.unboundValue(),
            .none => Value.noneValue(),
            .boolean => |enabled| if (enabled) Value.trueValue() else Value.falseValue(),
            .integer => |integer| Value.fromSmallInt(integer) orelse return self.engineFault(),
            .text => |text| self.createStringValue(text, line, column) orelse return false,
        };
        default_roots[index].object = defaults[index].asObject();
    }

    const bound = binder.bindFunction(
        &self.heap,
        self.heap.allocator,
        names[0..spec.params.len],
        flags[0..spec.params.len],
        defaults[0..spec.params.len],
        positional,
        keywords,
    ) catch |err| {
        self.setBinderException(err, line, column);
        return false;
    };
    defer self.heap.allocator.free(bound.values);
    defer if (bound.extra_keywords.len != 0) self.heap.allocator.free(bound.extra_keywords);
    const roots = self.heap.allocator.alloc(gc.Root, bound.values.len) catch {
        self.setException(exceptions.memoryError(), line, column, null);
        return false;
    };
    defer self.heap.allocator.free(roots);
    for (bound.values, 0..) |value, index| roots[index] = .{ .object = value.asObject() };
    var bound_frame = gc.RootFrame{};
    bound_frame.push(&self.heap.roots);
    for (roots) |*root| bound_frame.add(root);
    defer bound_frame.pop();
    return switch (module_id) {
        .sys => sys.execute(Runtime, self, destination, function_id, receiver, bound.values, bound.extra_keywords, line, column),
        .math => math.execute(Runtime, self, destination, function_id, receiver, bound.values, bound.extra_keywords, line, column),
        .time => time.execute(Runtime, self, destination, function_id, receiver, bound.values, bound.extra_keywords, line, column),
        .random => random.execute(Runtime, self, destination, function_id, receiver, bound.values, bound.extra_keywords, line, column),
        .statistics => statistics.execute(Runtime, self, destination, function_id, receiver, bound.values, bound.extra_keywords, line, column),
        .json => json_values.execute(Runtime, self, destination, function_id, receiver, bound.values, bound.extra_keywords, line, column),
        .re => re.execute(Runtime, self, destination, function_id, receiver, bound.values, bound.extra_keywords, line, column),
        .urllib_request => http.executeUrllib(Runtime, self, destination, function_id, receiver, bound.values, bound.extra_keywords, line, column),
        .requests => http.executeRequests(Runtime, self, destination, function_id, receiver, bound.values, bound.extra_keywords, line, column),
        .csv => csv.execute(Runtime, self, destination, function_id, receiver, bound.values, bound.extra_keywords, line, column),
        .pathlib => pathlib.execute(Runtime, self, destination, function_id, receiver, bound.values, bound.extra_keywords, line, column),
        .os => os.execute(Runtime, self, destination, function_id, receiver, bound.values, bound.extra_keywords, line, column),
        .os_path => os.executePath(Runtime, self, destination, function_id, receiver, bound.values, bound.extra_keywords, line, column),
        .collections => collections.execute(Runtime, self, destination, function_id, receiver, bound.values, bound.extra_keywords, line, column),
        .copy => copy.execute(Runtime, self, destination, function_id, receiver, bound.values, bound.extra_keywords, line, column),
        .ssl => ssl.execute(Runtime, self, destination, function_id, receiver, bound.values, bound.extra_keywords, line, column),
        else => self.engineFault(),
    };
}

pub fn getAttribute(comptime Runtime: type, self: *Runtime, object: *types.NativeObject, name: []const u8, line: u32, column: u32) ?Value {
    return switch (object.type_id) {
        .sys_stream, .implementation, .version_info => sys.getAttribute(Runtime, self, object, name, line, column),
        .ssl_context => ssl.getAttribute(Runtime, self, object, name, line, column),
        .regex_pattern, .regex_match => re.getAttribute(Runtime, self, object, name, line, column),
        .urllib_response, .requests_response, .http_headers => http.getAttribute(Runtime, self, object, name, line, column),
        .csv_reader, .csv_writer, .csv_dict_reader, .csv_dict_writer => csv.getAttribute(Runtime, self, object, name, line, column),
        .path => pathlib.getAttribute(Runtime, self, object, name, line, column),
        .counter, .defaultdict => collections.getAttribute(Runtime, self, object, name, line, column),
        else => null,
    };
}

pub fn setAttribute(comptime Runtime: type, self: *Runtime, object: *types.NativeObject, name: []const u8, value: Value, line: u32, column: u32) bool {
    return switch (object.type_id) {
        .ssl_context => ssl.setAttribute(Runtime, self, object, name, value, line, column),
        .requests_response => http.setAttribute(Runtime, self, object, name, value, line, column),
        .defaultdict => collections.setAttribute(Runtime, self, object, name, value, line, column),
        else => self.nativeAttributeError(line, column, "native attribute is read-only"),
    };
}

pub fn construct(
    comptime Runtime: type,
    self: *Runtime,
    destination: u16,
    type_id: types.TypeId,
    class_value: Value,
    positional: []const Value,
    keywords: []const binder.Keyword,
    line: u32,
    column: u32,
) bool {
    const spec = registry.typeSpec(type_id) orelse return self.nativeTypeError(line, column, "native type is not constructible");
    const constructor_id = spec.constructor_id orelse return self.nativeTypeError(line, column, "native type is not constructible");
    return call(Runtime, self, destination, @intFromEnum(spec.module), constructor_id, class_value, positional, keywords, line, column);
}
