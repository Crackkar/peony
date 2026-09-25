const std = @import("std");
const binder = @import("runtime_binder");
const exceptions = @import("runtime_exception");
const gc = @import("runtime_gc");
const number = @import("runtime_number");
const types = @import("types.zig");

const Value = types.Value;

pub const CERT_NONE: i64 = 0;
pub const CERT_REQUIRED: i64 = 2;

pub const SettingsError = error{InvalidVerifyMode};

pub const ContextState = struct {
    check_hostname: bool = true,
    verify_mode: i64 = CERT_REQUIRED,

    pub fn setCheckHostname(self: *ContextState, enabled: bool) void {
        self.check_hostname = enabled;
        if (enabled and self.verify_mode == CERT_NONE) self.verify_mode = CERT_REQUIRED;
    }

    pub fn setVerifyMode(self: *ContextState, mode: i64) SettingsError!void {
        if (mode != CERT_NONE and mode != CERT_REQUIRED) return error.InvalidVerifyMode;
        if (mode == CERT_NONE and self.check_hostname) return error.InvalidVerifyMode;
        self.verify_mode = mode;
    }
};

pub const functions = [_]types.FunctionSpec{
    .{ .id = 1, .name = "create_default_context" },
    .{ .id = 2, .name = "__SSLContext_constructor", .exported = false },
};

pub const classes = [_]types.TypeSpec{
    .{ .type_id = .ssl_context, .module = .ssl, .name = "SSLContext", .constructor_id = 2 },
};

pub fn populate(comptime Runtime: type, self: *Runtime, environment: *gc.Header, line: u32, column: u32) bool {
    const class = self.ensureNativeClass(.ssl_context, "SSLContext", line, column) orelse return false;
    if (!storeValue(Runtime, self, environment, "SSLContext", Value.object(&class.header), line, column)) return false;
    if (!storeValue(Runtime, self, environment, "CERT_NONE", Value.fromSmallInt(CERT_NONE).?, line, column)) return false;
    return storeValue(Runtime, self, environment, "CERT_REQUIRED", Value.fromSmallInt(CERT_REQUIRED).?, line, column);
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
    _ = args;
    if (extra.len != 0) return self.nativeTypeError(line, column, "unexpected keyword argument");
    if (function_id != 1 and function_id != 2) return self.engineFault();
    const class = self.ensureNativeClass(.ssl_context, "SSLContext", line, column) orelse return false;
    const object = types.createObject(&self.heap, class, .ssl_context) catch {
        self.setException(exceptions.memoryError(), line, column, null);
        return false;
    };
    var root = gc.Root{ .object = &object.header };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&root);
    defer roots.pop();
    const state = self.heap.allocator.create(ContextState) catch {
        self.setException(exceptions.memoryError(), line, column, null);
        return false;
    };
    state.* = .{};
    object.payload = state;
    object.destroy_payload = destroyContext;
    self.setRegister(destination, Value.object(&object.header));
    return true;
}

pub fn getAttribute(comptime Runtime: type, self: *Runtime, object: *types.NativeObject, name: []const u8, line: u32, column: u32) ?Value {
    _ = self;
    _ = line;
    _ = column;
    const state = contextFromObject(object) orelse return null;
    if (std.mem.eql(u8, name, "check_hostname")) return if (state.check_hostname) Value.trueValue() else Value.falseValue();
    if (std.mem.eql(u8, name, "verify_mode")) return Value.fromSmallInt(state.verify_mode);
    return null;
}

pub fn setAttribute(
    comptime Runtime: type,
    self: *Runtime,
    object: *types.NativeObject,
    name: []const u8,
    value: Value,
    line: u32,
    column: u32,
) bool {
    const state = contextFromObject(object) orelse return self.engineFault();
    if (std.mem.eql(u8, name, "check_hostname")) {
        const enabled = value.asBool() orelse if (number.toInt(i64, value)) |integer| integer != 0 else return self.nativeTypeError(line, column, "check_hostname must be a boolean");
        state.setCheckHostname(enabled);
        return true;
    }
    if (std.mem.eql(u8, name, "verify_mode")) {
        const mode = number.toInt(i64, value) orelse return self.nativeTypeError(line, column, "verify_mode must be an integer");
        state.setVerifyMode(mode) catch {
            self.setException(.{ .kind = .value_error, .message = if (mode == CERT_NONE and state.check_hostname) "Cannot set verify_mode to CERT_NONE when check_hostname is enabled" else "invalid value for verify_mode" }, line, column, null);
            return false;
        };
        return true;
    }
    return self.nativeAttributeError(line, column, "SSLContext attribute is read-only");
}

pub fn isContext(value: Value) bool {
    const header = value.asObject() orelse return false;
    const object = types.fromHeader(header) orelse return false;
    return contextFromObject(object) != null;
}

fn storeValue(comptime Runtime: type, self: *Runtime, environment: *gc.Header, name: []const u8, value: Value, line: u32, column: u32) bool {
    var root = gc.Root{ .object = value.asObject() };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&root);
    defer roots.pop();
    if (self.environmentStore(environment, name, value)) return true;
    self.setException(exceptions.memoryError(), line, column, null);
    return false;
}

fn contextFromObject(object: *types.NativeObject) ?*ContextState {
    if (object.type_id != .ssl_context) return null;
    return @ptrCast(@alignCast(object.payload orelse return null));
}

fn destroyContext(payload: ?*anyopaque, allocator: std.mem.Allocator) void {
    const state: *ContextState = @ptrCast(@alignCast(payload orelse return));
    allocator.destroy(state);
}

test "SSL teaching context preserves safe browser-facing invariants" {
    var context = ContextState{};
    try std.testing.expect(context.check_hostname);
    try std.testing.expectEqual(CERT_REQUIRED, context.verify_mode);
    try std.testing.expectError(error.InvalidVerifyMode, context.setVerifyMode(CERT_NONE));
    context.setCheckHostname(false);
    try context.setVerifyMode(CERT_NONE);
    try std.testing.expectEqual(CERT_NONE, context.verify_mode);
    context.setCheckHostname(true);
    try std.testing.expectEqual(CERT_REQUIRED, context.verify_mode);
    try std.testing.expectError(error.InvalidVerifyMode, context.setVerifyMode(1));
}
