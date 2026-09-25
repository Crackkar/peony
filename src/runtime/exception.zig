const std = @import("std");
const gc = @import("runtime_gc");
const value_module = @import("runtime_value");
const Value = value_module.Value;

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
    native_class: ?*ExceptionClass = null,
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
    native_name: ?[]u8 = null,
    native_parent: ?*ExceptionClass = null,
};

pub const Attribute = struct { name: []u8, value: Value };

pub const ExceptionInstance = struct {
    header: gc.Header align(8),
    allocator: std.mem.Allocator,
    kind: PythonExceptionKind,
    native_class: ?*ExceptionClass = null,
    message: []u8,
    value: Value = Value.noneValue(),
    cause: ?*ExceptionInstance = null,
    context: ?*ExceptionInstance = null,
    suppress_context: bool = false,
    frames: std.ArrayList(TracebackFrame) = .empty,
    attributes: std.ArrayList(Attribute) = .empty,
};

const class_kind = gc.Kind{ .trace = traceClass, .destroy = destroyClass };
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

pub fn createNativeClass(heap: *gc.Heap, name: []const u8, base_kind: PythonExceptionKind, parent_class: ?*ExceptionClass) Result(*ExceptionClass) {
    const owned_name = heap.allocator.dupe(u8, name) catch return .{ .python_exception = memoryError() };
    var parent_root = gc.Root{ .object = if (parent_class) |base_class| &base_class.header else null };
    var roots = gc.RootFrame{};
    roots.push(&heap.roots);
    roots.add(&parent_root);
    defer roots.pop();
    const class = heap.createObject(ExceptionClass, &class_kind) catch {
        heap.allocator.free(owned_name);
        return .{ .python_exception = memoryError() };
    };
    class.* = .{
        .header = class.header,
        .kind = if (parent_class) |base_class| base_class.kind else base_kind,
        .native_name = owned_name,
        .native_parent = parent_class,
    };
    return .{ .value = class };
}

pub fn createNativeInstance(heap: *gc.Heap, class: *ExceptionClass, message: []const u8) Result(*ExceptionInstance) {
    var class_root = gc.Root{ .object = &class.header };
    var roots = gc.RootFrame{};
    roots.push(&heap.roots);
    roots.add(&class_root);
    defer roots.pop();
    const instance = switch (createInstance(heap, class.kind, message)) {
        .value => |created| created,
        .python_exception => |exception| return .{ .python_exception = exception },
        .engine_error => |failure| return .{ .engine_error = failure },
    };
    instance.native_class = class;
    return .{ .value = instance };
}

pub fn nativeSubclassOf(class: *const ExceptionClass, candidate: *const ExceptionClass) bool {
    if (candidate.native_name == null) return isSubclass(class.kind, candidate.kind);
    var cursor: ?*const ExceptionClass = class;
    while (cursor) |current| {
        if (current == candidate) return true;
        cursor = current.native_parent;
    }
    return false;
}

pub fn instanceMatchesClass(instance: *const ExceptionInstance, candidate: *const ExceptionClass) bool {
    if (candidate.native_name == null) return isSubclass(instance.kind, candidate.kind);
    const actual = instance.native_class orelse return false;
    return nativeSubclassOf(actual, candidate);
}

pub fn setAttribute(heap: *gc.Heap, instance: *ExceptionInstance, name: []const u8, value: Value) error{OutOfMemory}!void {
    for (instance.attributes.items) |*entry| if (std.mem.eql(u8, entry.name, name)) {
        entry.value = value;
        return;
    };
    const owned_name = try heap.allocator.dupe(u8, name);
    errdefer heap.allocator.free(owned_name);
    try instance.attributes.append(heap.allocator, .{ .name = owned_name, .value = value });
}

pub fn getAttribute(instance: *const ExceptionInstance, name: []const u8) ?Value {
    for (instance.attributes.items) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.value;
    return null;
}

pub fn className(class: *const ExceptionClass) []const u8 {
    return class.native_name orelse exceptionName(class.kind);
}

pub fn instanceName(instance: *const ExceptionInstance) []const u8 {
    return if (instance.native_class) |class| className(class) else exceptionName(instance.kind);
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
    if (instance.native_class) |class| tracer.visit(&class.header);
    if (instance.cause) |cause| tracer.visit(&cause.header);
    if (instance.context) |context| tracer.visit(&context.header);
    tracer.visit(instance.value.asObject());
    for (instance.attributes.items) |entry| tracer.visit(entry.value.asObject());
}

fn traceClass(header: *gc.Header, tracer: *gc.Tracer) void {
    const class: *ExceptionClass = @ptrCast(@alignCast(header));
    if (class.native_parent) |parent_class| tracer.visit(&parent_class.header);
}

fn destroyClass(header: *gc.Header, allocator: std.mem.Allocator) void {
    const class: *ExceptionClass = @ptrCast(@alignCast(header));
    if (class.native_name) |name| allocator.free(name);
}

fn destroyInstance(header: *gc.Header, allocator: std.mem.Allocator) void {
    const instance: *ExceptionInstance = @ptrCast(@alignCast(header));
    allocator.free(instance.message);
    instance.frames.deinit(allocator);
    for (instance.attributes.items) |entry| allocator.free(entry.name);
    instance.attributes.deinit(allocator);
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
