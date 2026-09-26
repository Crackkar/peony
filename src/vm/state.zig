const std = @import("std");
const bytecode = @import("frontend_bytecode");
const gc = @import("runtime_gc");
const value_module = @import("runtime_value");
const iterator = @import("runtime_iterator");
const functions = @import("runtime_function");
const sequence = @import("runtime_sequence");
const exceptions = @import("runtime_exception");
const module_module = @import("runtime_module");
const class_module = @import("runtime_class");
const native_types = @import("../stdlib/types.zig");

const Value = value_module.Value;
const PythonException = exceptions.PythonException;
const PythonExceptionKind = exceptions.PythonExceptionKind;

pub const GlobalEntry = struct {
    name: []const u8,
    value: Value,
};

pub const TryPhase = enum { body, else_body, handler, finally_body };
pub const PendingTransfer = enum { none, return_value, jump, exception };

pub const TryBlock = struct {
    site_index: u32,
    slot_index: usize,
    phase: TryPhase = .body,
    pending: PendingTransfer = .none,
    pending_target: u32 = 0,
    pending_value: Value = Value.noneValue(),
    pending_exception: ?PythonException = null,
    cleanup_name_index: ?u32 = null,
    cleanup_binding: u8 = 0,
};

pub const Environment = struct {
    header: gc.Header align(8),
    entries: std.ArrayList(GlobalEntry) = .empty,
    module_owner: ?*gc.Header = null,
};

pub const TestContextManager = struct {
    header: gc.Header,
    entered: Value,
    label: []u8,
    suppress: bool,
    enter_error: ?PythonExceptionKind,
};

pub const test_context_manager_kind = gc.Kind{
    .trace = traceTestContextManager,
    .destroy = destroyTestContextManager,
};

pub fn traceTestContextManager(header: *gc.Header, tracer: *gc.Tracer) void {
    const manager: *TestContextManager = @ptrCast(@alignCast(header));
    tracer.visit(manager.entered.asObject());
}

pub fn destroyTestContextManager(header: *gc.Header, allocator: std.mem.Allocator) void {
    const manager: *TestContextManager = @ptrCast(@alignCast(header));
    if (manager.label.len != 0) allocator.free(manager.label);
}

pub const Frame = struct {
    code: *bytecode.Code,
    environment: *gc.Header = undefined,
    module_initializing: ?*module_module.Module = null,
    previous: ?*Frame = null,
    return_destination: ?u16 = null,
    generator_owner: ?*iterator.Iterator = null,
    return_override: ?Value = null,
    return_to_task: ?*native_types.Task = null,
    override_requires_none: bool = false,
    ip: usize = 0,
    registers: []Value = &.{},
    locals: []Value = &.{},
    local_cells: []?*functions.Cell = &.{},
    free_cells: []?*functions.Cell = &.{},
    class_namespace: ?*class_module.Class = null,
    roots: []gc.Root = &. {},
    root_frame: gc.RootFrame = .{},
    try_blocks: std.ArrayList(TryBlock) = .empty,
    pending_values: []Value = &.{},

    pub fn localRootStart(self: *const Frame) usize {
        return self.registers.len;
    }

    pub fn cellRootStart(self: *const Frame) usize {
        return self.registers.len + self.locals.len;
    }

    pub fn freeRootStart(self: *const Frame) usize {
        return self.cellRootStart() + self.local_cells.len;
    }

    pub fn classRootIndex(self: *const Frame) usize {
        return self.freeRootStart() + self.free_cells.len;
    }

    pub fn returnOverrideRootIndex(self: *const Frame) usize {
        return self.classRootIndex() + 1;
    }

    pub fn unwindRootStart(self: *const Frame) usize {
        return self.environmentRootIndex() + 1;
    }

    pub fn environmentRootIndex(self: *const Frame) usize {
        return self.returnOverrideRootIndex() + 1;
    }
};

pub const PendingInput = struct {
    frame: *Frame,
    destination: u16,
    request_id: u32,
    line: u32,
    column: u32,
};

pub const SyncTaskOperation = enum {
    materialize, sorted, list_sort, next_value,
    builtin_all, builtin_any, builtin_min, builtin_max, builtin_sum, builtin_bytes,
};
pub const SyncTaskPhase = enum { collect, keys, order };
pub const SyncCallbackResult = union(enum) { value: Value, suspended, failed };

pub const SyncTask = struct {
    frame: *Frame,
    call_ip: usize,
    operation: SyncTaskOperation,
    phase: SyncTaskPhase = .collect,
    destination: u16,
    line: u32,
    column: u32,
    want_tuple: bool = false,
    iterator_value: ?*iterator.Iterator = null,
    target: ?*sequence.List = null,
    callback: Value = Value.noneValue(),
    reverse: bool = false,
    snapshot: ?*sequence.List = null,
    keys: ?*sequence.List = null,
    order: []usize = &.{},
    index: usize = 0,
    position: usize = 0,
    selected_index: usize = 0,
    sort_item_started: bool = false,
    original_version: u64 = 0,
    original_length: usize = 0,
    callback_in_progress: bool = false,
    callback_completed: bool = false,
    callback_failed: bool = false,
    callback_depth_held: bool = false,
    callback_result: Value = Value.noneValue(),
    complete: bool = false,
};

pub fn destroyGeneratorFrameOpaque(pointer: *anyopaque, allocator: std.mem.Allocator) void {
    const frame: *Frame = @ptrCast(@alignCast(pointer));
    if (frame.root_frame.stack != null) frame.root_frame.pop();
    if (frame.roots.len != 0) allocator.free(frame.roots);
    if (frame.free_cells.len != 0) allocator.free(frame.free_cells);
    if (frame.local_cells.len != 0) allocator.free(frame.local_cells);
    frame.try_blocks.deinit(allocator);
    if (frame.pending_values.len != 0) allocator.free(frame.pending_values);
    if (frame.locals.len != 0) allocator.free(frame.locals);
    if (frame.registers.len != 0) allocator.free(frame.registers);
    allocator.destroy(frame);
}

pub const environment_kind = gc.Kind{
    .trace = traceEnvironment,
    .destroy = destroyEnvironment,
};

pub fn traceEnvironment(header: *gc.Header, tracer: *gc.Tracer) void {
    const environment: *Environment = @ptrCast(@alignCast(header));
    for (environment.entries.items) |entry| tracer.visit(entry.value.asObject());
    tracer.visit(environment.module_owner);
}

pub fn destroyEnvironment(header: *gc.Header, allocator: std.mem.Allocator) void {
    const environment: *Environment = @ptrCast(@alignCast(header));
    for (environment.entries.items) |entry| allocator.free(entry.name);
    environment.entries.deinit(allocator);
}
