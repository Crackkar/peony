const std = @import("std");
const binder = @import("runtime_binder");
const exceptions = @import("runtime_exception");
const gc = @import("runtime_gc");
const host = @import("runtime_host");
const number = @import("runtime_number");
const types = @import("types.zig");

const Value = types.Value;

pub const functions = [_]types.FunctionSpec{
    .{ .id = 1, .name = "time" },
    .{ .id = 2, .name = "monotonic" },
    .{ .id = 3, .name = "sleep", .params = &.{.{ .name = "seconds", .flags = binder.parameter_flags_module.positional_only }} },
};

pub fn populate(comptime Runtime: type, self: *Runtime, environment: *gc.Header, line: u32, column: u32) bool {
    _ = self;
    _ = environment;
    _ = line;
    _ = column;
    return true;
}

const Operation = enum(u16) { wall = 1, monotonic = 2, sleep = 3 };
const Phase = enum { request, complete, failed };

const Payload = struct {
    allocator: std.mem.Allocator,
    operation: Operation,
    phase: Phase = .request,
    duration_bytes: [8]u8 = @splat(0),
    result: f64 = 0,
    sections: [1]host.Section = undefined,
    failure_kind: exceptions.PythonExceptionKind = .os_error,
    failure_message: ?[]u8 = null,
};

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
    return switch (function_id) {
        1 => start(Runtime, self, destination, .wall, 0, args, line, column),
        2 => start(Runtime, self, destination, .monotonic, 0, args, line, column),
        3 => blk: {
            const seconds = asFloat(Runtime, self, args[0], line, column) orelse break :blk false;
            if (!std.math.isFinite(seconds) or seconds < 0) {
                self.setException(.{ .kind = .value_error, .message = "sleep length must be non-negative and finite" }, line, column, null);
                break :blk false;
            }
            break :blk start(Runtime, self, destination, .sleep, seconds, args, line, column);
        },
        else => self.engineFault(),
    };
}

fn start(
    comptime Runtime: type,
    self: *Runtime,
    destination: u16,
    operation: Operation,
    duration: f64,
    inputs: []const Value,
    line: u32,
    column: u32,
) bool {
    const caller = self.top_frame orelse return self.engineFault();
    const payload = self.heap.allocator.create(Payload) catch {
        self.setException(exceptions.memoryError(), line, column, null);
        return false;
    };
    payload.* = .{ .allocator = self.heap.allocator, .operation = operation };
    if (operation == .sleep) std.mem.writeInt(u64, &payload.duration_bytes, @bitCast(duration), .little);
    const task = types.createTask(
        &self.heap,
        self.currentNativeTask(),
        .time,
        @intFromEnum(operation),
        @ptrCast(caller),
        destination,
        line,
        column,
        inputs,
        taskOps(Runtime),
    ) catch {
        self.heap.allocator.destroy(payload);
        self.setException(exceptions.memoryError(), line, column, null);
        return false;
    };
    task.payload = payload;
    return self.startNativeTask(task);
}

fn taskOps(comptime Runtime: type) *const types.TaskOps {
    const Specialized = struct {
        fn step(context: *anyopaque, task: *types.Task) types.TaskStep {
            const self: *Runtime = @ptrCast(@alignCast(context));
            return stepTyped(Runtime, self, task);
        }

        fn hostReply(context: *anyopaque, task: *types.Task, packet: *const host.DecodedPacket) bool {
            const self: *Runtime = @ptrCast(@alignCast(context));
            return hostReplyTyped(Runtime, self, task, packet);
        }

        const ops = types.TaskOps{
            .step = step,
            .host_reply = hostReply,
            .destroy_payload = destroyPayload,
        };
    };
    return &Specialized.ops;
}

fn stepTyped(comptime Runtime: type, self: *Runtime, task: *types.Task) types.TaskStep {
    _ = self;
    const payload = payloadFromTask(task) orelse return .{ .raise = .{ .kind = .runtime_error, .message = "invalid time task state" } };
    return switch (payload.phase) {
        .request => blk: {
            payload.sections[0] = switch (payload.operation) {
                .wall => .{ .kind = .utf8, .bytes = "wall" },
                .monotonic => .{ .kind = .utf8, .bytes = "monotonic" },
                .sleep => .{ .kind = .binary, .bytes = &payload.duration_bytes },
            };
            break :blk .{ .host = .{
                .kind = switch (payload.operation) {
                    .wall, .monotonic => .clock,
                    .sleep => .sleep,
                },
                .request_id = 1,
                .sections = &payload.sections,
            } };
        },
        .complete => .{ .complete = switch (payload.operation) {
            .wall, .monotonic => Value.fromFloat(payload.result),
            .sleep => Value.noneValue(),
        } },
        .failed => .{ .raise = .{ .kind = payload.failure_kind, .message = payload.failure_message orelse "host time operation failed" } },
    };
}

fn hostReplyTyped(comptime Runtime: type, self: *Runtime, task: *types.Task, packet: *const host.DecodedPacket) bool {
    const payload = payloadFromTask(task) orelse return false;
    if (payload.phase != .request) return false;
    if (packet.status == .host_error) {
        const classification = packet.sections[0].bytes;
        const expected_classification: []const u8 = if (payload.operation == .sleep) "sleep" else "clock";
        if (!std.mem.eql(u8, classification, expected_classification)) return false;
        const message = packet.sections[1].bytes;
        const owned = self.heap.allocator.dupe(u8, message) catch {
            payload.phase = .failed;
            payload.failure_kind = .memory_error;
            return true;
        };
        payload.failure_message = owned;
        payload.failure_kind = .os_error;
        payload.phase = .failed;
        return true;
    }
    switch (payload.operation) {
        .wall, .monotonic => {
            const bits = std.mem.readInt(u64, packet.sections[0].bytes[0..8], .little);
            payload.result = @bitCast(bits);
        },
        .sleep => {},
    }
    payload.phase = .complete;
    return true;
}

fn payloadFromTask(task: *types.Task) ?*Payload {
    if (task.owner != .time) return null;
    return @ptrCast(@alignCast(task.payload orelse return null));
}

fn destroyPayload(raw: ?*anyopaque, allocator: std.mem.Allocator) void {
    const payload: *Payload = @ptrCast(@alignCast(raw orelse return));
    if (payload.failure_message) |message| allocator.free(message);
    allocator.destroy(payload);
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
