pub const PythonExceptionKind = enum {
    base_exception,
    exception,
    memory_error,
    name_error,
    unbound_local_error,
    attribute_error,
    stop_iteration,
    zero_division_error,
    value_error,
    overflow_error,
    recursion_error,
    type_error,
    index_error,
    key_error,
    runtime_error,
    unicode_decode_error,
};

/// Allocation-safe transport for Python faults. Messages are static until the runtime adds owned strings.
pub const PythonException = struct {
    kind: PythonExceptionKind,
    message: []const u8,
};

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
    if (base == .base_exception) return true;
    return switch (kind) {
        .base_exception => false,
        .exception => base == .base_exception,
        .memory_error, .name_error, .attribute_error, .stop_iteration, .zero_division_error, .value_error, .overflow_error, .recursion_error, .type_error, .index_error, .key_error, .runtime_error, .unicode_decode_error => base == .exception,
        .unbound_local_error => base == .name_error or base == .exception,
    };
}
