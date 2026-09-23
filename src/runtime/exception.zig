pub const PythonExceptionKind = enum {
    base_exception,
    exception,
    memory_error,
    zero_division_error,
    value_error,
    overflow_error,
    type_error,
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
        .memory_error, .zero_division_error, .value_error, .overflow_error, .type_error => base == .exception,
    };
}
