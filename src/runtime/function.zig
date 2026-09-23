const std = @import("std");
const gc = @import("runtime_gc");
const value_module = @import("runtime_value");
const exceptions = @import("runtime_exception");
const bytecode = @import("frontend_bytecode");

const Value = value_module.Value;

pub const Native = enum { print, range };

pub const Cell = struct {
    header: gc.Header align(8),
    value: Value = Value.unboundValue(),
};

pub const Function = struct {
    header: gc.Header align(8),
    allocator: std.mem.Allocator,
    code: ?*bytecode.Code = null,
    globals: ?*gc.Header = null,
    cells: []*Cell = &.{},
    defaults: []Value = &.{},
    annotations: []Value = &.{},
    native: ?Native = null,
};

pub const Result = union(enum) {
    value: *Function,
    python_exception: exceptions.PythonException,
};

const cell_kind = gc.Kind{ .trace = traceCell };
const function_kind = gc.Kind{ .trace = traceFunction, .destroy = destroyFunction };

pub fn cellFromHeader(header: *gc.Header) ?*Cell {
    if (header.kind != &cell_kind) return null;
    return @ptrCast(@alignCast(header));
}

pub fn functionFromHeader(header: *gc.Header) ?*Function {
    if (header.kind != &function_kind) return null;
    return @ptrCast(@alignCast(header));
}

pub fn createCell(heap: *gc.Heap, value: Value) error{OutOfMemory}!*Cell {
    const cell = try heap.createObject(Cell, &cell_kind);
    cell.* = .{ .header = cell.header, .value = value };
    return cell;
}

pub fn createNative(heap: *gc.Heap, native: Native) Result {
    const function = heap.createObject(Function, &function_kind) catch return .{ .python_exception = memoryError() };
    function.* = .{ .header = function.header, .allocator = heap.allocator, .native = native };
    return .{ .value = function };
}

pub fn createPython(
    heap: *gc.Heap,
    code: *bytecode.Code,
    globals: *gc.Header,
    cells: []const *Cell,
    defaults: []const Value,
    annotations: []const Value,
) Result {
    const owned_cells = heap.allocator.dupe(*Cell, cells) catch return .{ .python_exception = memoryError() };
    const owned_defaults = heap.allocator.dupe(Value, defaults) catch {
        heap.allocator.free(owned_cells);
        return .{ .python_exception = memoryError() };
    };
    const owned_annotations = heap.allocator.dupe(Value, annotations) catch {
        heap.allocator.free(owned_defaults);
        heap.allocator.free(owned_cells);
        return .{ .python_exception = memoryError() };
    };
    const function = heap.createObject(Function, &function_kind) catch {
        heap.allocator.free(owned_annotations);
        heap.allocator.free(owned_defaults);
        heap.allocator.free(owned_cells);
        return .{ .python_exception = memoryError() };
    };
    function.* = .{
        .header = function.header,
        .allocator = heap.allocator,
        .code = code,
        .globals = globals,
        .cells = owned_cells,
        .defaults = owned_defaults,
        .annotations = owned_annotations,
    };
    return .{ .value = function };
}

fn traceCell(header: *gc.Header, tracer: *gc.Tracer) void {
    const cell: *Cell = @ptrCast(@alignCast(header));
    tracer.visit(cell.value.asObject());
}

fn traceFunction(header: *gc.Header, tracer: *gc.Tracer) void {
    const function: *Function = @ptrCast(@alignCast(header));
    tracer.visit(function.globals);
    for (function.cells) |cell| tracer.visit(&cell.header);
    for (function.defaults) |value| tracer.visit(value.asObject());
    for (function.annotations) |value| tracer.visit(value.asObject());
}

fn destroyFunction(header: *gc.Header, allocator: std.mem.Allocator) void {
    const function: *Function = @ptrCast(@alignCast(header));
    allocator.free(function.cells);
    allocator.free(function.defaults);
    allocator.free(function.annotations);
}

fn memoryError() exceptions.PythonException {
    return .{ .kind = .memory_error, .message = "session memory limit exceeded" };
}
