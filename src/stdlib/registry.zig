const std = @import("std");
const types = @import("types.zig");
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

pub const ModuleId = types.ModuleId;
pub const FunctionSpec = types.FunctionSpec;

pub fn moduleId(name: []const u8) ?ModuleId {
    if (std.mem.eql(u8, name, "sys")) return .sys;
    if (std.mem.eql(u8, name, "math")) return .math;
    if (std.mem.eql(u8, name, "time")) return .time;
    if (std.mem.eql(u8, name, "random")) return .random;
    if (std.mem.eql(u8, name, "statistics")) return .statistics;
    if (std.mem.eql(u8, name, "json")) return .json;
    if (std.mem.eql(u8, name, "re")) return .re;
    if (std.mem.eql(u8, name, "urllib")) return .urllib;
    if (std.mem.eql(u8, name, "urllib.request")) return .urllib_request;
    if (std.mem.eql(u8, name, "urllib.error")) return .urllib_error;
    if (std.mem.eql(u8, name, "requests")) return .requests;
    if (std.mem.eql(u8, name, "requests.exceptions")) return .requests_exceptions;
    if (std.mem.eql(u8, name, "csv")) return .csv;
    if (std.mem.eql(u8, name, "pathlib")) return .pathlib;
    if (std.mem.eql(u8, name, "os")) return .os;
    if (std.mem.eql(u8, name, "os.path")) return .os_path;
    if (std.mem.eql(u8, name, "collections")) return .collections;
    if (std.mem.eql(u8, name, "copy")) return .copy;
    if (std.mem.eql(u8, name, "ssl")) return .ssl;
    return null;
}

pub fn functionSpecs(module_id: ModuleId) []const FunctionSpec {
    return switch (module_id) {
        .sys => &sys.functions,
        .math => &math.functions,
        .time => &time.functions,
        .random => &random.functions,
        .statistics => &statistics.functions,
        .json => &json_values.functions,
        .re => &re.functions,
        .urllib_request => &http.urllib_request_functions,
        .requests => &http.requests_functions,
        .csv => &csv.functions,
        .pathlib => &pathlib.functions,
        .os => &os.functions,
        .os_path => &os.path_functions,
        .collections => &collections.functions,
        .copy => &copy.functions,
        .ssl => &ssl.functions,
        else => &.{},
    };
}

pub fn functionSpec(module_id: ModuleId, function_id: u16) ?*const FunctionSpec {
    return findSpec(functionSpecs(module_id), function_id);
}

pub fn typeSpec(type_id: types.TypeId) ?*const types.TypeSpec {
    for (&ssl.classes) |*spec| if (spec.type_id == type_id) return spec;
    for (&re.classes) |*spec| if (spec.type_id == type_id) return spec;
    for (&http.classes) |*spec| if (spec.type_id == type_id) return spec;
    for (&csv.classes) |*spec| if (spec.type_id == type_id) return spec;
    for (&pathlib.classes) |*spec| if (spec.type_id == type_id) return spec;
    for (&collections.classes) |*spec| if (spec.type_id == type_id) return spec;
    return null;
}

pub fn populate(comptime Runtime: type, self: *Runtime, module_id: ModuleId, environment: *@import("runtime_gc").Header, line: u32, column: u32) bool {
    return switch (module_id) {
        .sys => sys.populate(Runtime, self, environment, line, column),
        .math => math.populate(Runtime, self, environment, line, column),
        .time => time.populate(Runtime, self, environment, line, column),
        .random => random.populate(Runtime, self, environment, line, column),
        .statistics => statistics.populate(Runtime, self, environment, line, column),
        .json => json_values.populate(Runtime, self, environment, line, column),
        .re => re.populate(Runtime, self, environment, line, column),
        .urllib, .urllib_request, .urllib_error, .requests, .requests_exceptions => http.populate(Runtime, self, module_id, environment, line, column),
        .csv => csv.populate(Runtime, self, environment, line, column),
        .pathlib => pathlib.populate(Runtime, self, environment, line, column),
        .os, .os_path => os.populate(Runtime, self, environment, line, column),
        .collections => collections.populate(Runtime, self, environment, line, column),
        .copy => copy.populate(Runtime, self, environment, line, column),
        .ssl => ssl.populate(Runtime, self, environment, line, column),
    };
}

fn findSpec(functions: []const FunctionSpec, function_id: u16) ?*const FunctionSpec {
    for (functions) |*spec| if (spec.id == function_id) return spec;
    return null;
}
