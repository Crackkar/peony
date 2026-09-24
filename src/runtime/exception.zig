const std = @import("std");
const gc = @import("runtime_gc");

pub const PythonExceptionKind = enum {
    base_exception,
    generator_exit,
    keyboard_interrupt,
    system_exit,
    exception,
    arithmetic_error,
    zero_division_error,
    overflow_error,
    assertion_error,
    attribute_error,
    eof_error,
    import_error,
    module_not_found_error,
    index_error,
    key_error,
    lookup_error,
    name_error,
    unbound_local_error,
    os_error,
    file_not_found_error,
    file_exists_error,
    permission_error,
    timeout_error,
    runtime_error,
    recursion_error,
    memory_error,
    not_implemented_error,
    stop_iteration,
    unicode_error,
    unicode_encode_error,
    unicode_decode_error,
    syntax_error,
    indentation_error,
    tab_error,
    type_error,
    value_error,
};

pub const allKinds = [_]PythonExceptionKind{
    .base_exception,       .generator_exit,        .keyboard_interrupt,     .system_exit,     .exception,
    .arithmetic_error,     .zero_division_error,   .overflow_error,         .assertion_error, .attribute_error,
    .eof_error,            .import_error,          .module_not_found_error, .index_error,     .key_error,
    .lookup_error,         .name_error,            .unbound_local_error,    .os_error,        .file_not_found_error,
    .file_exists_error,    .permission_error,      .timeout_error,          .runtime_error,   .recursion_error,
    .memory_error,         .not_implemented_error, .stop_iteration,         .unicode_error,   .unicode_encode_error,
    .unicode_decode_error, .syntax_error,          .indentation_error,      .tab_error,       .type_error,
    .value_error,
};

/// Allocation-safe transport for Python faults. Messages are static until the runtime adds owned strings.
pub const PythonException = struct {
    kind: PythonExceptionKind,
    message: []const u8,
};

pub const TracebackFrame = struct {
    filename: []const u8,
    function_name: []const u8,
    line: u32,
    column: u32,
    source_line: []const u8,
};

pub const ExceptionClass = struct {
    header: gc.Header align(8),
    kind: PythonExceptionKind,
};

pub const ExceptionInstance = struct {
    header: gc.Header align(8),
    allocator: std.mem.Allocator,
    kind: PythonExceptionKind,
    message: []u8,
    cause: ?*ExceptionInstance = null,
    context: ?*ExceptionInstance = null,
    suppress_context: bool = false,
    frames: std.ArrayList(TracebackFrame) = .empty,
};

const class_kind = gc.Kind{};
const instance_kind = gc.Kind{ .trace = traceInstance, .destroy = destroyInstance };

pub fn classFromHeader(header: *gc.Header) ?*ExceptionClass {
    if (header.kind != &class_kind) return null;
    return @ptrCast(@alignCast(header));
}

pub fn instanceFromHeader(header: *gc.Header) ?*ExceptionInstance {
    if (header.kind != &instance_kind) return null;
    return @ptrCast(@alignCast(header));
}

pub fn createClass(heap: *gc.Heap, kind: PythonExceptionKind) Result(*ExceptionClass) {
    const class = heap.createObject(ExceptionClass, &class_kind) catch return .{ .python_exception = memoryError() };
    class.* = .{ .header = class.header, .kind = kind };
    return .{ .value = class };
}

pub fn createInstance(heap: *gc.Heap, kind: PythonExceptionKind, message: []const u8) Result(*ExceptionInstance) {
    const owned_message = heap.allocator.dupe(u8, message) catch return .{ .python_exception = memoryError() };
    const instance = heap.createObject(ExceptionInstance, &instance_kind) catch {
        heap.allocator.free(owned_message);
        return .{ .python_exception = memoryError() };
    };
    instance.* = .{
        .header = instance.header,
        .allocator = heap.allocator,
        .kind = kind,
        .message = owned_message,
    };
    return .{ .value = instance };
}

pub fn memoryError() PythonException {
    return .{ .kind = .memory_error, .message = "session memory limit exceeded" };
}

fn traceInstance(header: *gc.Header, tracer: *gc.Tracer) void {
    const instance: *ExceptionInstance = @ptrCast(@alignCast(header));
    if (instance.cause) |cause| tracer.visit(&cause.header);
    if (instance.context) |context| tracer.visit(&context.header);
}

fn destroyInstance(header: *gc.Header, allocator: std.mem.Allocator) void {
    const instance: *ExceptionInstance = @ptrCast(@alignCast(header));
    allocator.free(instance.message);
    instance.frames.deinit(allocator);
}

pub const EngineError = enum {
    internal_invariant,
};

pub fn Result(comptime T: type) type {
    return union(enum) {
        value: T,
        python_exception: PythonException,
        engine_error: EngineError,
    };
}

pub fn isSubclass(kind: PythonExceptionKind, base: PythonExceptionKind) bool {
    if (kind == base) return true;
    var cursor = parent(kind);
    while (cursor) |candidate| {
        if (candidate == base) return true;
        cursor = parent(candidate);
    }
    return false;
}

pub fn parent(kind: PythonExceptionKind) ?PythonExceptionKind {
    return switch (kind) {
        .base_exception => null,
        .generator_exit, .keyboard_interrupt, .system_exit => .base_exception,
        .exception => .base_exception,
        .arithmetic_error, .assertion_error, .attribute_error, .eof_error, .import_error, .lookup_error, .name_error, .os_error, .runtime_error, .memory_error, .not_implemented_error, .stop_iteration, .type_error, .value_error, .syntax_error => .exception,
        .zero_division_error, .overflow_error => .arithmetic_error,
        .module_not_found_error => .import_error,
        .index_error, .key_error => .lookup_error,
        .unbound_local_error => .name_error,
        .file_not_found_error, .file_exists_error, .permission_error, .timeout_error => .os_error,
        .recursion_error => .runtime_error,
        .unicode_error => .value_error,
        .unicode_encode_error, .unicode_decode_error => .unicode_error,
        .indentation_error => .syntax_error,
        .tab_error => .indentation_error,
    };
}

pub fn builtinKind(name: []const u8) ?PythonExceptionKind {
    inline for (allKinds) |kind| {
        if (std.mem.eql(u8, name, exceptionName(kind))) return kind;
    }
    return null;
}

pub fn exceptionName(kind: PythonExceptionKind) []const u8 {
    return switch (kind) {
        .base_exception => "BaseException",
        .generator_exit => "GeneratorExit",
        .keyboard_interrupt => "KeyboardInterrupt",
        .system_exit => "SystemExit",
        .exception => "Exception",
        .arithmetic_error => "ArithmeticError",
        .zero_division_error => "ZeroDivisionError",
        .overflow_error => "OverflowError",
        .assertion_error => "AssertionError",
        .attribute_error => "AttributeError",
        .eof_error => "EOFError",
        .import_error => "ImportError",
        .module_not_found_error => "ModuleNotFoundError",
        .index_error => "IndexError",
        .key_error => "KeyError",
        .lookup_error => "LookupError",
        .name_error => "NameError",
        .unbound_local_error => "UnboundLocalError",
        .os_error => "OSError",
        .file_not_found_error => "FileNotFoundError",
        .file_exists_error => "FileExistsError",
        .permission_error => "PermissionError",
        .timeout_error => "TimeoutError",
        .runtime_error => "RuntimeError",
        .recursion_error => "RecursionError",
        .memory_error => "MemoryError",
        .not_implemented_error => "NotImplementedError",
        .stop_iteration => "StopIteration",
        .unicode_error => "UnicodeError",
        .unicode_encode_error => "UnicodeEncodeError",
        .unicode_decode_error => "UnicodeDecodeError",
        .syntax_error => "SyntaxError",
        .indentation_error => "IndentationError",
        .tab_error => "TabError",
        .type_error => "TypeError",
        .value_error => "ValueError",
    };
}
