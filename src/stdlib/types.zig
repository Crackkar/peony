const std = @import("std");
const gc = @import("runtime_gc");
const value_module = @import("runtime_value");
const class_module = @import("runtime_class");
const exceptions = @import("runtime_exception");
const binder = @import("runtime_binder");
const host = @import("runtime_host");
const iterator = @import("runtime_iterator");
const dict = @import("runtime_dict");

pub const Value = value_module.Value;
pub const NativeNextResult = iterator.NextResult;

pub const ModuleId = enum(u8) {
    sys = 1,
    math,
    random,
    statistics,
    json,
    csv,
    re,
    pathlib,
    os,
    os_path,
    collections,
    copy,
    urllib,
    urllib_request,
    urllib_error,
    requests,
    requests_exceptions,
    time,
};

pub const TypeId = enum(u8) {
    sys_stream,
    path,
    counter,
    defaultdict,
    csv_reader,
    csv_writer,
    csv_dict_reader,
    csv_dict_writer,
    regex_pattern,
    regex_match,
    regex_find_iterator,
    urllib_response,
    requests_response,
    http_headers,
    version_info,
    implementation,
};

pub const Default = union(enum) {
    required,
    none,
    boolean: bool,
    integer: i64,
    text: []const u8,
};

pub const Param = struct {
    name: []const u8,
    flags: u32 = 0,
    default: Default = .required,
};

pub const FunctionSpec = struct {
    id: u16,
    name: []const u8,
    params: []const Param = &.{},
    exported: bool = true,
};

pub const TypeSpec = struct {
    type_id: TypeId,
    module: ModuleId,
    name: []const u8,
    base_primitive: ?class_module.PrimitiveType = null,
    constructor_id: ?u16 = null,
    exported: bool = true,
};

pub const NativeObject = struct {
    header: gc.Header align(8),
    class: *class_module.Class,
    type_id: TypeId,
    payload: ?*anyopaque = null,
    trace_payload: ?*const fn (?*anyopaque, *gc.Tracer) void = null,
    destroy_payload: ?*const fn (?*anyopaque, std.mem.Allocator) void = null,
    ops: ?*const NativeObjectOps = null,
};

pub const NativeObjectOps = struct {
    get_item: ?*const fn (*anyopaque, *NativeObject, Value, u16, u32, u32) ?Value = null,
    set_item: ?*const fn (*anyopaque, *NativeObject, Value, Value, u32, u32) bool = null,
    delete_item: ?*const fn (*anyopaque, *NativeObject, Value, u32, u32) bool = null,
    contains: ?*const fn (*anyopaque, *NativeObject, Value, u32, u32) ?bool = null,
    iter: ?*const fn (*anyopaque, *NativeObject, u32, u32) ?Value = null,
    next: ?*const fn (*anyopaque, *NativeObject, u16, u32, u32) iterator.NextResult = null,
    enter: ?*const fn (*anyopaque, *NativeObject, u32, u32) ?Value = null,
    exit: ?*const fn (*anyopaque, *NativeObject, u32, u32) ?bool = null,
    truth: ?*const fn (*anyopaque, *NativeObject, u32, u32) ?bool = null,
    str: ?*const fn (*anyopaque, *NativeObject, u32, u32) ?[]u8 = null,
    repr: ?*const fn (*anyopaque, *NativeObject, u32, u32) ?[]u8 = null,
    hash: ?*const fn (*anyopaque, *NativeObject, u32, u32) ?u64 = null,
    hashable: bool = true,
    equals: ?*const fn (*anyopaque, *NativeObject, Value, u32, u32) ?bool = null,
    compare: ?*const fn (*anyopaque, *NativeObject, Value, u8, u32, u32) ?bool = null,
    binary: ?*const fn (*anyopaque, *NativeObject, Value, u8, bool, u32, u32) ?Value = null,
    unary: ?*const fn (*anyopaque, *NativeObject, u8, u32, u32) ?Value = null,
    mapping: ?*const fn (*NativeObject) ?*dict.Dict = null,
};

const native_object_kind = gc.Kind{
    .trace = traceObject,
    .destroy = destroyObject,
};

pub fn fromHeader(header: *gc.Header) ?*NativeObject {
    if (header.kind != &native_object_kind) return null;
    return @ptrCast(@alignCast(header));
}

pub fn createObject(
    heap: *gc.Heap,
    class: *class_module.Class,
    type_id: TypeId,
) error{OutOfMemory}!*NativeObject {
    var class_root = gc.Root{ .object = &class.header };
    var roots = gc.RootFrame{};
    roots.push(&heap.roots);
    roots.add(&class_root);
    defer roots.pop();
    const object = try heap.createObject(NativeObject, &native_object_kind);
    object.* = .{ .header = object.header, .class = class, .type_id = type_id };
    return object;
}

fn traceObject(header: *gc.Header, tracer: *gc.Tracer) void {
    const object: *NativeObject = @ptrCast(@alignCast(header));
    tracer.visit(&object.class.header);
    if (object.trace_payload) |trace| trace(object.payload, tracer);
}

fn destroyObject(header: *gc.Header, allocator: std.mem.Allocator) void {
    const object: *NativeObject = @ptrCast(@alignCast(header));
    if (object.destroy_payload) |destroy| destroy(object.payload, allocator);
}

pub const TaskStage = enum { ready, waiting_call, waiting_next, waiting_host };

pub const CallRequest = struct {
    callable: Value,
    positional: []const Value,
    keywords: []const binder.Keyword = &.{},
};

pub const TaskStep = union(enum) {
    complete: Value,
    done,
    raise: exceptions.PythonException,
    propagate,
    yield,
    call: CallRequest,
    next: Value,
    host: host.Packet,
};

pub const TaskOps = struct {
    step: *const fn (*anyopaque, *Task) TaskStep,
    host_reply: ?*const fn (*anyopaque, *Task, *const host.DecodedPacket) bool = null,
    trace_payload: ?*const fn (?*anyopaque, *gc.Tracer) void = null,
    destroy_payload: ?*const fn (?*anyopaque, std.mem.Allocator) void = null,
};

pub const Task = struct {
    header: gc.Header align(8),
    parent: ?*Task,
    owner: ModuleId,
    operation: u16,
    caller_frame: *anyopaque,
    destination: u16,
    item_presence_destination: ?u16 = null,
    line: u32,
    column: u32,
    stage: TaskStage = .ready,
    inputs: []Value,
    payload: ?*anyopaque = null,
    ops: *const TaskOps,
    child_ready: bool = false,
    child_done: bool = false,
    child_value: Value = Value.noneValue(),
    next_iterator: Value = Value.noneValue(),
    sync_next_delivery: bool = false,
    sync_delivery_iterator: Value = Value.noneValue(),
    child_error: ?*exceptions.ExceptionInstance = null,
    constructor_instance: Value = Value.noneValue(),
    request_kind: ?host.Kind = null,
    request_id: u32 = 0,
};

const task_kind = gc.Kind{ .trace = traceTask, .destroy = destroyTask };

pub fn taskFromHeader(header: *gc.Header) ?*Task {
    if (header.kind != &task_kind) return null;
    return @ptrCast(@alignCast(header));
}

pub fn createTask(
    heap: *gc.Heap,
    parent: ?*Task,
    owner: ModuleId,
    operation: u16,
    caller_frame: *anyopaque,
    destination: u16,
    line: u32,
    column: u32,
    inputs: []const Value,
    ops: *const TaskOps,
) error{OutOfMemory}!*Task {
    const owned_inputs = try heap.allocator.dupe(Value, inputs);
    errdefer heap.allocator.free(owned_inputs);
    const task = try heap.createObject(Task, &task_kind);
    task.* = .{
        .header = task.header,
        .parent = parent,
        .owner = owner,
        .operation = operation,
        .caller_frame = caller_frame,
        .destination = destination,
        .line = line,
        .column = column,
        .inputs = owned_inputs,
        .ops = ops,
    };
    return task;
}

fn traceTask(header: *gc.Header, tracer: *gc.Tracer) void {
    const task: *Task = @ptrCast(@alignCast(header));
    if (task.parent) |parent| tracer.visit(&parent.header);
    for (task.inputs) |value| tracer.visit(value.asObject());
    tracer.visit(task.child_value.asObject());
    tracer.visit(task.constructor_instance.asObject());
    tracer.visit(task.next_iterator.asObject());
    tracer.visit(task.sync_delivery_iterator.asObject());
    if (task.child_error) |err| tracer.visit(&err.header);
    if (task.ops.trace_payload) |trace| trace(task.payload, tracer);
}

fn destroyTask(header: *gc.Header, allocator: std.mem.Allocator) void {
    const task: *Task = @ptrCast(@alignCast(header));
    if (task.ops.destroy_payload) |destroy| destroy(task.payload, allocator);
    allocator.free(task.inputs);
}
