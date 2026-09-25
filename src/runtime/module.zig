const std = @import("std");
const gc = @import("runtime_gc");
const exceptions = @import("runtime_exception");

pub const Module = struct {
    header: gc.Header align(8),
    allocator: std.mem.Allocator,
    name: []u8,
    package: []u8,
    filename: []u8,
    search_path: []const u8 = &.{},
    code_roots: []?*gc.Header = &.{},
    environment: *gc.Header,
    is_package: bool = false,
    initialized: bool = false,
};

pub const Result = union(enum) { value: *Module, python_exception: exceptions.PythonException };

const module_kind = gc.Kind{ .trace = traceModule, .destroy = destroyModule };

pub fn fromHeader(header: *gc.Header) ?*Module {
    if (header.kind != &module_kind) return null;
    return @ptrCast(@alignCast(header));
}

pub fn create(
    heap: *gc.Heap,
    name: []const u8,
    package: []const u8,
    filename: []const u8,
    search_path: []const u8,
    environment: *gc.Header,
    is_package: bool,
) Result {
    return .{ .value = createInner(heap, name, package, filename, search_path, environment, is_package) catch return .{ .python_exception = memoryError() } };
}

fn createInner(
    heap: *gc.Heap,
    name: []const u8,
    package: []const u8,
    filename: []const u8,
    search_path: []const u8,
    environment: *gc.Header,
    is_package: bool,
) error{OutOfMemory}!*Module {
    var environment_root = gc.Root{ .object = environment };
    var roots = gc.RootFrame{};
    roots.push(&heap.roots);
    roots.add(&environment_root);
    defer roots.pop();

    const owned_name = try heap.allocator.dupe(u8, name);
    errdefer heap.allocator.free(owned_name);
    const owned_package = try heap.allocator.dupe(u8, package);
    errdefer heap.allocator.free(owned_package);
    const owned_filename = try heap.allocator.dupe(u8, filename);
    errdefer heap.allocator.free(owned_filename);
    const owned_path = if (search_path.len == 0) &.{} else try heap.allocator.dupe(u8, search_path);
    errdefer if (owned_path.len != 0) heap.allocator.free(owned_path);

    const object = try heap.createObject(Module, &module_kind);
    object.* = .{
        .header = object.header,
        .allocator = heap.allocator,
        .name = owned_name,
        .package = owned_package,
        .filename = owned_filename,
        .search_path = owned_path,
        .environment = environment,
        .is_package = is_package,
    };
    return object;
}

fn traceModule(header: *gc.Header, tracer: *gc.Tracer) void {
    const module: *Module = @ptrCast(@alignCast(header));
    tracer.visit(module.environment);
    for (module.code_roots) |root| if (root) |object| tracer.visit(object);
}

fn destroyModule(header: *gc.Header, allocator: std.mem.Allocator) void {
    const module: *Module = @ptrCast(@alignCast(header));
    allocator.free(module.name);
    allocator.free(module.package);
    allocator.free(module.filename);
    if (module.search_path.len != 0) allocator.free(@constCast(module.search_path));
    if (module.code_roots.len != 0) allocator.free(module.code_roots);
}

fn memoryError() exceptions.PythonException {
    return .{ .kind = .memory_error, .message = "session memory limit exceeded" };
}
