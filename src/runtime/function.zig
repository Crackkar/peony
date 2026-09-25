const std = @import("std");
const gc = @import("runtime_gc");
const value_module = @import("runtime_value");
const exceptions = @import("runtime_exception");
const bytecode = @import("frontend_bytecode");

const Value = value_module.Value;

pub const Native = enum {
    print,
    input,
    range,
    open,
    dict,
    set,
    hash,
    format_builtin,
    sorted,
    map,
    filter,
    str_constructor,
    len,
    list,
    tuple,
    iter,
    next,
    enumerate,
    zip,
    reversed,
    slice,
    list_append,
    list_extend,
    list_insert,
    list_pop,
    list_remove,
    list_clear,
    list_index,
    list_count,
    list_reverse,
    list_copy,
    list_sort,
    str_find,
    str_index,
    str_split,
    str_join,
    str_strip,
    str_upper,
    str_lower,
    str_replace,
    str_count,
    str_startswith,
    str_endswith,
    str_encode,
    str_format,
    bytes_split,
    bytes_find,
    bytes_decode,
    file_read,
    file_readline,
    file_readlines,
    file_write,
    file_writelines,
    file_seek,
    file_tell,
    file_truncate,
    file_flush,
    file_close,
    dict_get,
    dict_keys,
    dict_values,
    dict_items,
    dict_pop,
    dict_setdefault,
    dict_update,
    dict_clear,
    dict_copy,
    set_add,
    set_remove,
    set_discard,
    set_pop,
    set_update,
    set_clear,
    set_copy,
    type_builtin,
    bool_constructor,
    isinstance_builtin,
    issubclass_builtin,
    getattr_builtin,
    setattr_builtin,
    delattr_builtin,
    hasattr_builtin,
    callable_builtin,
    repr_builtin,
    property_builtin,
    staticmethod_builtin,
    classmethod_builtin,
    super_builtin,
    descriptor_setter,
    descriptor_deleter,
    generator_send,
    generator_close,
};

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
    annotations_dict: Value = Value.noneValue(),
    native: ?Native = null,
    bound_self: Value = Value.noneValue(),
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

pub fn createBoundNative(heap: *gc.Heap, native: Native, bound_self: Value) Result {
    return switch (createNative(heap, native)) {
        .value => |function| blk: {
            function.bound_self = bound_self;
            break :blk .{ .value = function };
        },
        .python_exception => |exception| .{ .python_exception = exception },
    };
}

pub fn createPython(
    heap: *gc.Heap,
    code: *bytecode.Code,
    globals: *gc.Header,
    cells: []const *Cell,
    defaults: []const Value,
    annotations: []const Value,
    annotations_dict: Value,
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
        .annotations_dict = annotations_dict,
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
    tracer.visit(function.annotations_dict.asObject());
    tracer.visit(function.bound_self.asObject());
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
