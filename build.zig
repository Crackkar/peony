const std = @import("std");

const abi_exports = [_][]const u8{
    "peony_abi_version",
    "peony_transfer_alloc",
    "peony_transfer_free",
    "peony_session_new",
    "peony_session_destroy",
    "peony_compile_and_start",
    "peony_run",
    "peony_resume",
    "peony_cancel",
    "peony_event_ptr",
    "peony_event_len",
    "peony_stdout_ptr",
    "peony_stdout_len",
    "peony_stdout_consume",
    "peony_stderr_ptr",
    "peony_stderr_len",
    "peony_stderr_consume",
    "peony_error_ptr",
    "peony_error_len",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const abi_module = b.createModule(.{
        .root_source_file = b.path("src/abi.zig"),
        .target = target,
        .optimize = optimize,
    });
    const native_runtime = createRuntimeModules(b, target, optimize);
    const gc_test_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/runtime_gc.zig"),
        .target = target,
        .optimize = optimize,
    });
    gc_test_module.addImport("runtime_gc", native_runtime.gc);
    const value_number_test_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/value_number.zig"),
        .target = target,
        .optimize = optimize,
    });
    value_number_test_module.addImport("runtime_value", native_runtime.value);
    value_number_test_module.addImport("runtime_number", native_runtime.number);
    const string_bytes_test_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/string_bytes.zig"),
        .target = target,
        .optimize = optimize,
    });
    string_bytes_test_module.addImport("runtime_number", native_runtime.number);
    string_bytes_test_module.addImport("runtime_string", native_runtime.string);
    string_bytes_test_module.addImport("runtime_bytes", native_runtime.bytes);
    string_bytes_test_module.addImport("runtime_unicode", native_runtime.unicode);
    const lexer_test_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/lexer.zig"),
        .target = target,
        .optimize = optimize,
    });
    const frontend_modules = createFrontendModules(b, target, optimize);
    lexer_test_module.addImport("frontend_lexer", frontend_modules.lexer);
    lexer_test_module.addImport("frontend_token", frontend_modules.token);
    const parser_test_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    parser_test_module.addImport("frontend_parser", frontend_modules.parser);
    parser_test_module.addImport("frontend_ast", frontend_modules.ast);
    const scope_test_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/scope.zig"),
        .target = target,
        .optimize = optimize,
    });
    scope_test_module.addImport("frontend_parser", frontend_modules.parser);
    scope_test_module.addImport("frontend_ast", frontend_modules.ast);
    scope_test_module.addImport("frontend_scope", frontend_modules.scope);
    const unit_test_root = b.createModule(.{
        .root_source_file = b.path("tests/unit/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_test_root.addImport("abi", abi_module);
    unit_test_root.addImport("runtime_gc_tests", gc_test_module);
    unit_test_root.addImport("value_number_tests", value_number_test_module);
    unit_test_root.addImport("string_bytes_tests", string_bytes_test_module);
    unit_test_root.addImport("lexer_tests", lexer_test_module);
    unit_test_root.addImport("parser_tests", parser_test_module);
    unit_test_root.addImport("scope_tests", scope_test_module);
    const unit_tests = b.addTest(.{ .root_module = unit_test_root });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run native Peony unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm_module = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .single_threaded = true,
        .strip = true,
    });
    addRuntimeImports(wasm_module, createRuntimeModules(b, wasm_target, .ReleaseSmall));
    wasm_module.export_symbol_names = abi_exports[0..];

    const wasm = b.addExecutable(.{
        .name = "peony",
        .root_module = wasm_module,
        .use_llvm = true,
    });
    wasm.entry = .disabled;
    wasm.export_memory = true;

    const install_wasm = b.addInstallArtifact(wasm, .{});
    b.installArtifact(wasm);
    const wasm_step = b.step("wasm", "Build the stripped ReleaseSmall browser WASM artifact");
    wasm_step.dependOn(&install_wasm.step);

    addProbe(b, wasm_target, "bigint", "peony_probe_bigint");
    addProbe(b, wasm_target, "json", "peony_probe_json");
    addProbe(b, wasm_target, "unicode15", "peony_probe_unicode15");
}

const FrontendModules = struct {
    token: *std.Build.Module,
    lexer: *std.Build.Module,
    ast: *std.Build.Module,
    parser: *std.Build.Module,
    scope: *std.Build.Module,
};

fn createFrontendModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) FrontendModules {
    const token_module = b.createModule(.{
        .root_source_file = b.path("src/frontend/token.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lexer_module = b.createModule(.{
        .root_source_file = b.path("src/frontend/lexer.zig"),
        .target = target,
        .optimize = optimize,
    });
    lexer_module.addImport("frontend_token", token_module);
    const ast_module = b.createModule(.{
        .root_source_file = b.path("src/frontend/ast.zig"),
        .target = target,
        .optimize = optimize,
    });
    const parser_module = b.createModule(.{
        .root_source_file = b.path("src/frontend/parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    parser_module.addImport("frontend_token", token_module);
    parser_module.addImport("frontend_lexer", lexer_module);
    parser_module.addImport("frontend_ast", ast_module);
    const scope_module = b.createModule(.{
        .root_source_file = b.path("src/frontend/scope.zig"),
        .target = target,
        .optimize = optimize,
    });
    scope_module.addImport("frontend_ast", ast_module);
    return .{ .token = token_module, .lexer = lexer_module, .ast = ast_module, .parser = parser_module, .scope = scope_module };
}

fn addProbe(b: *std.Build, target: std.Build.ResolvedTarget, name: []const u8, probe_symbol: []const u8) void {
    const exports = b.allocator.alloc([]const u8, abi_exports.len + 1) catch @panic("out of memory");
    @memcpy(exports[0..abi_exports.len], abi_exports[0..]);
    exports[abi_exports.len] = probe_symbol;

    const module = b.createModule(.{
        .root_source_file = b.path(b.fmt("zig-cache/size-probes/{s}-root.zig", .{name})),
        .target = target,
        .optimize = .ReleaseSmall,
        .single_threaded = true,
        .strip = true,
    });
    addRuntimeImports(module, createRuntimeModules(b, target, .ReleaseSmall));
    module.export_symbol_names = exports;

    const exe = b.addExecutable(.{
        .name = b.fmt("peony-probe-{s}", .{name}),
        .root_module = module,
        .use_llvm = true,
    });
    exe.entry = .disabled;
    exe.export_memory = true;

    const install = b.addInstallArtifact(exe, .{});
    const step = b.step(b.fmt("probe-{s}", .{name}), b.fmt("Build the {s} feature-size probe", .{name}));
    step.dependOn(&install.step);
}

const RuntimeModules = struct {
    gc: *std.Build.Module,
    value: *std.Build.Module,
    number: *std.Build.Module,
    exception: *std.Build.Module,
    unicode: *std.Build.Module,
    string: *std.Build.Module,
    bytes: *std.Build.Module,
};

fn createRuntimeModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) RuntimeModules {
    const gc_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/gc.zig"),
        .target = target,
        .optimize = optimize,
    });
    const value_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/value.zig"),
        .target = target,
        .optimize = optimize,
    });
    value_module.addImport("runtime_gc", gc_module);
    const number_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/number.zig"),
        .target = target,
        .optimize = optimize,
    });
    number_module.addImport("runtime_gc", gc_module);
    number_module.addImport("runtime_value", value_module);
    const exception_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/exception.zig"),
        .target = target,
        .optimize = optimize,
    });
    number_module.addImport("runtime_exception", exception_module);

    const unicode_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/unicode.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unicode_blob_module = b.createModule(.{
        .root_source_file = b.path("data/unicode_data.zig"),
        .target = target,
        .optimize = optimize,
    });
    unicode_module.addImport("unicode_blob", unicode_blob_module);
    const string_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/string.zig"),
        .target = target,
        .optimize = optimize,
    });
    string_module.addImport("runtime_gc", gc_module);
    string_module.addImport("runtime_unicode", unicode_module);
    string_module.addImport("runtime_exception", exception_module);
    const bytes_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/bytes.zig"),
        .target = target,
        .optimize = optimize,
    });
    bytes_module.addImport("runtime_gc", gc_module);
    bytes_module.addImport("runtime_string", string_module);
    bytes_module.addImport("runtime_exception", exception_module);
    return .{
        .gc = gc_module,
        .value = value_module,
        .number = number_module,
        .exception = exception_module,
        .unicode = unicode_module,
        .string = string_module,
        .bytes = bytes_module,
    };
}

fn addRuntimeImports(module: *std.Build.Module, runtime: RuntimeModules) void {
    module.addImport("runtime_gc", runtime.gc);
    module.addImport("runtime_value", runtime.value);
    module.addImport("runtime_number", runtime.number);
    module.addImport("runtime_exception", runtime.exception);
    module.addImport("runtime_unicode", runtime.unicode);
    module.addImport("runtime_string", runtime.string);
    module.addImport("runtime_bytes", runtime.bytes);
}
