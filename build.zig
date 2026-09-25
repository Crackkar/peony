const std = @import("std");

const abi_exports = [_][]const u8{
    "peony_abi_version",
    "peony_transfer_alloc",
    "peony_transfer_free",
    "peony_session_new",
    "peony_session_destroy",
    "peony_compile_and_start",
    "peony_compile_and_start_argv",
    "peony_run",
    "peony_resume",
    "peony_cancel",
    "peony_reset",
    "peony_vfs_mount",
    "peony_vfs_write",
    "peony_vfs_read",
    "peony_vfs_list",
    "peony_vfs_dirs",
    "peony_vfs_mkdir",
    "peony_vfs_data_ptr",
    "peony_vfs_data_len",
    "peony_event_ptr",
    "peony_event_len",
    "peony_instruction_count",
    "peony_work_count",
    "peony_stdout_ptr",
    "peony_stdout_len",
    "peony_stdout_consume",
    "peony_stderr_ptr",
    "peony_stderr_len",
    "peony_stderr_consume",
    "peony_error_ptr",
    "peony_error_len",
    "peony_traceback_ptr",
    "peony_traceback_len",
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
    const bytecode_module = b.createModule(.{
        .root_source_file = b.path("src/frontend/bytecode.zig"),
        .target = target,
        .optimize = optimize,
    });
    bytecode_module.addImport("runtime_gc", native_runtime.gc);
    bytecode_module.addImport("runtime_value", native_runtime.value);
    const native_function_module = createRuntimeFunctionModule(b, target, optimize, native_runtime, bytecode_module);
    native_runtime.class.addImport("runtime_function", native_function_module);
    const native_binder_module = createRuntimeBinderModule(b, target, optimize, native_runtime);
    const compiler_module = b.createModule(.{
        .root_source_file = b.path("src/frontend/compiler.zig"),
        .target = target,
        .optimize = optimize,
    });
    compiler_module.addImport("frontend_bytecode", bytecode_module);
    compiler_module.addImport("frontend_parser", frontend_modules.parser);
    compiler_module.addImport("frontend_ast", frontend_modules.ast);
    compiler_module.addImport("frontend_scope", frontend_modules.scope);
    compiler_module.addImport("runtime_gc", native_runtime.gc);
    compiler_module.addImport("runtime_value", native_runtime.value);
    compiler_module.addImport("runtime_number", native_runtime.number);
    compiler_module.addImport("runtime_string", native_runtime.string);
    compiler_module.addImport("runtime_bytes", native_runtime.bytes);
    compiler_module.addImport("runtime_exception", native_runtime.exception);
    const native_iterator_module = createRuntimeIteratorModule(b, target, optimize, native_runtime);
    const native_format_rules_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/format.zig"),
        .target = target,
        .optimize = optimize,
    });
    const runtime_vm_module = b.createModule(.{
        .root_source_file = b.path("src/engine.zig"),
        .target = target,
        .optimize = optimize,
    });
    runtime_vm_module.addImport("frontend_bytecode", bytecode_module);
    runtime_vm_module.addImport("frontend_compiler", compiler_module);
    runtime_vm_module.addImport("frontend_ast", frontend_modules.ast);
    runtime_vm_module.addImport("runtime_gc", native_runtime.gc);
    runtime_vm_module.addImport("runtime_value", native_runtime.value);
    runtime_vm_module.addImport("runtime_number", native_runtime.number);
    runtime_vm_module.addImport("runtime_string", native_runtime.string);
    runtime_vm_module.addImport("runtime_bytes", native_runtime.bytes);
    runtime_vm_module.addImport("runtime_sequence", native_runtime.sequence);
    runtime_vm_module.addImport("runtime_dict", native_runtime.dict);
    runtime_vm_module.addImport("runtime_hash", native_runtime.hash);
    runtime_vm_module.addImport("runtime_slice", native_runtime.slice);
    runtime_vm_module.addImport("runtime_exception", native_runtime.exception);
    runtime_vm_module.addImport("runtime_iterator", native_iterator_module);
    runtime_vm_module.addImport("runtime_function", native_function_module);
    runtime_vm_module.addImport("runtime_class", native_runtime.class);
    runtime_vm_module.addImport("runtime_binder", native_binder_module);
    runtime_vm_module.addImport("runtime_host", native_runtime.host);
    runtime_vm_module.addImport("runtime_vfs", native_runtime.vfs);
    runtime_vm_module.addImport("runtime_file", native_runtime.file);
    runtime_vm_module.addImport("runtime_module", native_runtime.module);
    runtime_vm_module.addImport("runtime_format_rules", native_format_rules_module);
    const native_regex_core = b.createModule(.{
        .root_source_file = b.path("src/regex/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    runtime_vm_module.addImport("regex_core", native_regex_core);
    runtime_vm_module.addImport("runtime_unicode", native_runtime.unicode);
    const compiler_vm_test_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/compiler_vm.zig"),
        .target = target,
        .optimize = optimize,
    });
    compiler_vm_test_module.addImport("frontend_bytecode", bytecode_module);
    compiler_vm_test_module.addImport("frontend_compiler", compiler_module);
    compiler_vm_test_module.addImport("runtime_vm", runtime_vm_module);
    compiler_vm_test_module.addImport("runtime_exception", native_runtime.exception);
    const control_flow_test_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/control_flow.zig"),
        .target = target,
        .optimize = optimize,
    });
    control_flow_test_module.addImport("runtime_vm", runtime_vm_module);
    control_flow_test_module.addImport("runtime_exception", native_runtime.exception);
    const functions_test_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/functions.zig"),
        .target = target,
        .optimize = optimize,
    });
    functions_test_module.addImport("runtime_vm", runtime_vm_module);
    const sequence_test_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/sequences.zig"),
        .target = target,
        .optimize = optimize,
    });
    sequence_test_module.addImport("runtime_vm", runtime_vm_module);
    sequence_test_module.addImport("frontend_bytecode", bytecode_module);
    sequence_test_module.addImport("runtime_exception", native_runtime.exception);
    sequence_test_module.addImport("runtime_gc", native_runtime.gc);
    sequence_test_module.addImport("runtime_value", native_runtime.value);
    sequence_test_module.addImport("runtime_number", native_runtime.number);
    sequence_test_module.addImport("runtime_iterator", native_iterator_module);
    sequence_test_module.addImport("runtime_slice", native_runtime.slice);
    const mapping_test_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/mappings.zig"),
        .target = target,
        .optimize = optimize,
    });
    mapping_test_module.addImport("runtime_vm", runtime_vm_module);
    mapping_test_module.addImport("runtime_exception", native_runtime.exception);
    mapping_test_module.addImport("runtime_gc", native_runtime.gc);
    mapping_test_module.addImport("runtime_dict", native_runtime.dict);
    mapping_test_module.addImport("runtime_value", native_runtime.value);
    mapping_test_module.addImport("runtime_string", native_runtime.string);
    const comprehension_test_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/comprehensions.zig"),
        .target = target,
        .optimize = optimize,
    });
    comprehension_test_module.addImport("runtime_vm", runtime_vm_module);
    comprehension_test_module.addImport("runtime_exception", native_runtime.exception);
    comprehension_test_module.addImport("runtime_host", native_runtime.host);
    const formatting_test_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/formatting.zig"),
        .target = target,
        .optimize = optimize,
    });
    formatting_test_module.addImport("runtime_vm", runtime_vm_module);
    formatting_test_module.addImport("runtime_exception", native_runtime.exception);
    const exceptions_test_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/exceptions.zig"),
        .target = target,
        .optimize = optimize,
    });
    exceptions_test_module.addImport("runtime_vm", runtime_vm_module);
    exceptions_test_module.addImport("runtime_exception", native_runtime.exception);
    exceptions_test_module.addImport("runtime_value", native_runtime.value);
    const host_test_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/host.zig"),
        .target = target,
        .optimize = optimize,
    });
    host_test_module.addImport("runtime_vm", runtime_vm_module);
    host_test_module.addImport("runtime_host", native_runtime.host);
    const host_codec_test_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/host_codec.zig"),
        .target = target,
        .optimize = optimize,
    });
    host_codec_test_module.addImport("runtime_host", native_runtime.host);
    const vfs_test_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/vfs.zig"),
        .target = target,
        .optimize = optimize,
    });
    vfs_test_module.addImport("runtime_vm", runtime_vm_module);
    vfs_test_module.addImport("runtime_exception", native_runtime.exception);
    const files_test_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/files.zig"),
        .target = target,
        .optimize = optimize,
    });
    files_test_module.addImport("runtime_vm", runtime_vm_module);
    files_test_module.addImport("runtime_exception", native_runtime.exception);
    const classes_test_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/classes.zig"),
        .target = target,
        .optimize = optimize,
    });
    classes_test_module.addImport("runtime_vm", runtime_vm_module);
    classes_test_module.addImport("runtime_host", native_runtime.host);
    classes_test_module.addImport("frontend_parser", frontend_modules.parser);
    classes_test_module.addImport("frontend_ast", frontend_modules.ast);
    classes_test_module.addImport("frontend_scope", frontend_modules.scope);
    const generators_test_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/generators.zig"),
        .target = target,
        .optimize = optimize,
    });
    generators_test_module.addImport("runtime_vm", runtime_vm_module);
    generators_test_module.addImport("runtime_host", native_runtime.host);
    const annotations_test_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/annotations.zig"),
        .target = target,
        .optimize = optimize,
    });
    annotations_test_module.addImport("runtime_vm", runtime_vm_module);
    const match_test_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/match.zig"),
        .target = target,
        .optimize = optimize,
    });
    match_test_module.addImport("runtime_vm", runtime_vm_module);
    const imports_test_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/imports.zig"),
        .target = target,
        .optimize = optimize,
    });
    imports_test_module.addImport("runtime_vm", runtime_vm_module);
    imports_test_module.addImport("runtime_exception", native_runtime.exception);
    imports_test_module.addImport("runtime_host", native_runtime.host);
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
    const library_bridge_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/library_bridge.zig"),
        .target = target,
        .optimize = optimize,
    });
    library_bridge_module.addImport("runtime_vm", runtime_vm_module);
    library_bridge_module.addImport("runtime_host", native_runtime.host);
    const library_regex_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/library_regex.zig"),
        .target = target,
        .optimize = optimize,
    });
    library_regex_module.addImport("runtime_vm", runtime_vm_module);
    library_regex_module.addImport("runtime_host", native_runtime.host);
    const library_http_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/library_http.zig"),
        .target = target,
        .optimize = optimize,
    });
    library_http_module.addImport("runtime_vm", runtime_vm_module);
    library_http_module.addImport("runtime_host", native_runtime.host);
    const library_numeric_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/library_numeric.zig"),
        .target = target,
        .optimize = optimize,
    });
    library_numeric_module.addImport("runtime_vm", runtime_vm_module);
    library_numeric_module.addImport("runtime_exception", native_runtime.exception);
    const library_data_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/library_data.zig"),
        .target = target,
        .optimize = optimize,
    });
    library_data_module.addImport("runtime_vm", runtime_vm_module);
    library_data_module.addImport("runtime_host", native_runtime.host);
    const library_vfs_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/library_vfs.zig"),
        .target = target,
        .optimize = optimize,
    });
    library_vfs_module.addImport("runtime_vm", runtime_vm_module);
    library_vfs_module.addImport("runtime_host", native_runtime.host);
    const library_collections_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/library_collections.zig"),
        .target = target,
        .optimize = optimize,
    });
    library_collections_module.addImport("runtime_vm", runtime_vm_module);
    library_collections_module.addImport("runtime_host", native_runtime.host);
    const unit_test_root = b.createModule(.{
        .root_source_file = b.path("tests/unit/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = true,
    });
    unit_test_root.addImport("abi", abi_module);
    unit_test_root.addImport("runtime_gc_tests", gc_test_module);
    unit_test_root.addImport("value_number_tests", value_number_test_module);
    unit_test_root.addImport("string_bytes_tests", string_bytes_test_module);
    unit_test_root.addImport("lexer_tests", lexer_test_module);
    unit_test_root.addImport("parser_tests", parser_test_module);
    unit_test_root.addImport("scope_tests", scope_test_module);
    unit_test_root.addImport("compiler_vm_tests", compiler_vm_test_module);
    unit_test_root.addImport("control_flow_tests", control_flow_test_module);
    unit_test_root.addImport("functions_tests", functions_test_module);
    unit_test_root.addImport("sequence_tests", sequence_test_module);
    unit_test_root.addImport("mapping_tests", mapping_test_module);
    unit_test_root.addImport("comprehension_tests", comprehension_test_module);
    unit_test_root.addImport("formatting_tests", formatting_test_module);
    unit_test_root.addImport("exception_tests", exceptions_test_module);
    unit_test_root.addImport("host_tests", host_test_module);
    unit_test_root.addImport("host_codec_tests", host_codec_test_module);
    unit_test_root.addImport("vfs_tests", vfs_test_module);
    unit_test_root.addImport("file_tests", files_test_module);
    unit_test_root.addImport("class_tests", classes_test_module);
    unit_test_root.addImport("generator_tests", generators_test_module);
    unit_test_root.addImport("annotation_tests", annotations_test_module);
    unit_test_root.addImport("match_tests", match_test_module);
    unit_test_root.addImport("import_tests", imports_test_module);
    unit_test_root.addImport("library_bridge_tests", library_bridge_module);
    unit_test_root.addImport("library_regex_tests", library_regex_module);
    unit_test_root.addImport("library_http_tests", library_http_module);
    unit_test_root.addImport("library_numeric_tests", library_numeric_module);
    unit_test_root.addImport("library_data_tests", library_data_module);
    unit_test_root.addImport("library_vfs_tests", library_vfs_module);
    unit_test_root.addImport("library_collections_tests", library_collections_module);
    const unit_tests = b.addTest(.{ .root_module = unit_test_root });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run native Peony unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const library_bridge_root = b.createModule(.{
        .root_source_file = b.path("tests/unit/library_bridge_root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = true,
    });
    library_bridge_root.addImport("library_bridge_tests", library_bridge_module);
    library_bridge_root.addImport("runtime_vm", runtime_vm_module);
    const library_bridge_tests = b.addTest(.{ .root_module = library_bridge_root });
    const run_library_bridge_tests = b.addRunArtifact(library_bridge_tests);
    const bridge_step = b.step("test-bridge", "Run focused native library bridge tests");
    bridge_step.dependOn(&run_library_bridge_tests.step);
    const library_b_root = b.createModule(.{
        .root_source_file = b.path("tests/unit/library_b_root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = true,
    });
    library_b_root.addImport("library_regex_tests", library_regex_module);
    library_b_root.addImport("library_http_tests", library_http_module);
    const library_b_tests = b.addTest(.{ .root_module = library_b_root });
    const run_library_b_tests = b.addRunArtifact(library_b_tests);
    const library_b_step = b.step("test-library-b", "Run focused native regex/HTTP library tests");
    library_b_step.dependOn(&run_library_b_tests.step);
    const library_a_root = b.createModule(.{
        .root_source_file = b.path("tests/unit/library_a_root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = true,
    });
    library_a_root.addImport("library_numeric_tests", library_numeric_module);
    library_a_root.addImport("library_data_tests", library_data_module);
    library_a_root.addImport("library_vfs_tests", library_vfs_module);
    library_a_root.addImport("library_collections_tests", library_collections_module);
    const library_a_tests = b.addTest(.{ .root_module = library_a_root });
    const run_library_a_tests = b.addRunArtifact(library_a_tests);
    const library_a_step = b.step("test-library-a", "Run focused native numeric/data/VFS/collections library tests");
    library_a_step.dependOn(&run_library_a_tests.step);

    const json_choice_root = b.createModule(.{
        .root_source_file = b.path("tests/bench/json_choice.zig"),
        .target = target,
        .optimize = optimize,
        .strip = true,
    });
    json_choice_root.addImport("runtime_vm", runtime_vm_module);
    json_choice_root.addImport("runtime_gc", native_runtime.gc);
    json_choice_root.addImport("runtime_dict", native_runtime.dict);
    json_choice_root.addImport("runtime_number", native_runtime.number);
    json_choice_root.addImport("runtime_sequence", native_runtime.sequence);
    const json_choice_exe = b.addExecutable(.{ .name = "peony-json-choice", .root_module = json_choice_root });
    const json_choice_run = b.addRunArtifact(json_choice_exe);
    const json_choice_step = b.step("bench-json-choice", "Compare native Value JSON paths with std.json DOM conversion");
    json_choice_step.dependOn(&json_choice_run.step);

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
    const wasm_runtime = createRuntimeModules(b, wasm_target, .ReleaseSmall);
    const wasm_frontend = createFrontendModules(b, wasm_target, .ReleaseSmall);
    const wasm_vm = createExecutionVmModule(b, wasm_target, .ReleaseSmall, wasm_runtime, wasm_frontend);
    wasm_module.addImport("runtime_vm", wasm_vm);
    addRuntimeImports(wasm_module, wasm_runtime);
    wasm_module.export_symbol_names = abi_exports[0..];

    const wasm = b.addExecutable(.{
        .name = "peony",
        .root_module = wasm_module,
        .use_llvm = true,
    });
    wasm.entry = .disabled;
    wasm.export_memory = true;

    const install_wasm = b.addInstallFile(wasm.getEmittedBin(), "peony.wasm");
    b.getInstallStep().dependOn(&install_wasm.step);
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
        .root_source_file = b.path(b.fmt(".zig-cache/size-probes/{s}-root.zig", .{name})),
        .target = target,
        .optimize = .ReleaseSmall,
        .single_threaded = true,
        .strip = true,
    });
    const runtime = createRuntimeModules(b, target, .ReleaseSmall);
    const frontend = createFrontendModules(b, target, .ReleaseSmall);
    module.addImport("runtime_vm", createExecutionVmModule(b, target, .ReleaseSmall, runtime, frontend));
    addRuntimeImports(module, runtime);
    module.export_symbol_names = exports;

    const exe = b.addExecutable(.{
        .name = b.fmt("peony-probe-{s}", .{name}),
        .root_module = module,
        .use_llvm = true,
    });
    exe.entry = .disabled;
    exe.export_memory = true;

    const install = b.addInstallFile(exe.getEmittedBin(), b.fmt("peony-probe-{s}.wasm", .{name}));
    const step = b.step(b.fmt("probe-{s}", .{name}), b.fmt("Build the {s} feature-size probe", .{name}));
    step.dependOn(&install.step);
}

fn createExecutionVmModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    runtime: RuntimeModules,
    frontend: FrontendModules,
) *std.Build.Module {
    const iterator_module = createRuntimeIteratorModule(b, target, optimize, runtime);
    const bytecode_module = b.createModule(.{
        .root_source_file = b.path("src/frontend/bytecode.zig"),
        .target = target,
        .optimize = optimize,
    });
    bytecode_module.addImport("runtime_gc", runtime.gc);
    bytecode_module.addImport("runtime_value", runtime.value);
    const function_module = createRuntimeFunctionModule(b, target, optimize, runtime, bytecode_module);
    runtime.class.addImport("runtime_function", function_module);
    const binder_module = createRuntimeBinderModule(b, target, optimize, runtime);
    const format_rules_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/format.zig"),
        .target = target,
        .optimize = optimize,
    });
    const compiler_module = b.createModule(.{
        .root_source_file = b.path("src/frontend/compiler.zig"),
        .target = target,
        .optimize = optimize,
    });
    compiler_module.addImport("frontend_bytecode", bytecode_module);
    compiler_module.addImport("frontend_parser", frontend.parser);
    compiler_module.addImport("frontend_ast", frontend.ast);
    compiler_module.addImport("frontend_scope", frontend.scope);
    compiler_module.addImport("runtime_gc", runtime.gc);
    compiler_module.addImport("runtime_value", runtime.value);
    compiler_module.addImport("runtime_number", runtime.number);
    compiler_module.addImport("runtime_string", runtime.string);
    compiler_module.addImport("runtime_bytes", runtime.bytes);
    compiler_module.addImport("runtime_exception", runtime.exception);
    const vm_module = b.createModule(.{
        .root_source_file = b.path("src/engine.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = target.result.cpu.arch == .wasm32,
    });
    vm_module.addImport("frontend_bytecode", bytecode_module);
    vm_module.addImport("frontend_compiler", compiler_module);
    vm_module.addImport("frontend_ast", frontend.ast);
    vm_module.addImport("runtime_gc", runtime.gc);
    vm_module.addImport("runtime_value", runtime.value);
    vm_module.addImport("runtime_number", runtime.number);
    vm_module.addImport("runtime_string", runtime.string);
    vm_module.addImport("runtime_bytes", runtime.bytes);
    vm_module.addImport("runtime_sequence", runtime.sequence);
    vm_module.addImport("runtime_dict", runtime.dict);
    vm_module.addImport("runtime_hash", runtime.hash);
    vm_module.addImport("runtime_slice", runtime.slice);
    vm_module.addImport("runtime_exception", runtime.exception);
    vm_module.addImport("runtime_iterator", iterator_module);
    vm_module.addImport("runtime_function", function_module);
    vm_module.addImport("runtime_class", runtime.class);
    vm_module.addImport("runtime_binder", binder_module);
    vm_module.addImport("runtime_host", runtime.host);
    vm_module.addImport("runtime_vfs", runtime.vfs);
    vm_module.addImport("runtime_file", runtime.file);
    vm_module.addImport("runtime_module", runtime.module);
    vm_module.addImport("runtime_format_rules", format_rules_module);
    const regex_core = b.createModule(.{
        .root_source_file = b.path("src/regex/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    vm_module.addImport("regex_core", regex_core);
    vm_module.addImport("runtime_unicode", runtime.unicode);
    return vm_module;
}

fn createRuntimeFunctionModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    runtime: RuntimeModules,
    bytecode: *std.Build.Module,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/runtime/function.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("runtime_gc", runtime.gc);
    module.addImport("runtime_value", runtime.value);
    module.addImport("runtime_exception", runtime.exception);
    module.addImport("frontend_bytecode", bytecode);
    return module;
}

fn createRuntimeBinderModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    runtime: RuntimeModules,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/runtime/binder.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("runtime_value", runtime.value);
    module.addImport("runtime_gc", runtime.gc);
    module.addImport("runtime_sequence", runtime.sequence);
    module.addImport("runtime_exception", runtime.exception);
    return module;
}

fn createRuntimeIteratorModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    runtime: RuntimeModules,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/runtime/iterator.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = target.result.cpu.arch == .wasm32,
    });
    module.addImport("runtime_gc", runtime.gc);
    module.addImport("runtime_value", runtime.value);
    module.addImport("runtime_number", runtime.number);
    module.addImport("runtime_string", runtime.string);
    module.addImport("runtime_bytes", runtime.bytes);
    module.addImport("runtime_sequence", runtime.sequence);
    module.addImport("runtime_dict", runtime.dict);
    module.addImport("runtime_slice", runtime.slice);
    module.addImport("runtime_exception", runtime.exception);
    module.addImport("runtime_file", runtime.file);
    return module;
}

const RuntimeModules = struct {
    gc: *std.Build.Module,
    value: *std.Build.Module,
    number: *std.Build.Module,
    exception: *std.Build.Module,
    unicode: *std.Build.Module,
    string: *std.Build.Module,
    bytes: *std.Build.Module,
    sequence: *std.Build.Module,
    slice: *std.Build.Module,
    dict: *std.Build.Module,
    hash: *std.Build.Module,
    host: *std.Build.Module,
    vfs: *std.Build.Module,
    file: *std.Build.Module,
    module: *std.Build.Module,
    class: *std.Build.Module,
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
    exception_module.addImport("runtime_gc", gc_module);
    exception_module.addImport("runtime_value", value_module);
    number_module.addImport("runtime_exception", exception_module);
    const host_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/host.zig"),
        .target = target,
        .optimize = optimize,
    });
    const vfs_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/vfs.zig"),
        .target = target,
        .optimize = optimize,
    });
    vfs_module.addImport("runtime_gc", gc_module);
    const file_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/file.zig"),
        .target = target,
        .optimize = optimize,
    });
    file_module.addImport("runtime_gc", gc_module);
    file_module.addImport("runtime_value", value_module);
    file_module.addImport("runtime_exception", exception_module);
    file_module.addImport("runtime_vfs", vfs_module);

    const module_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/module.zig"),
        .target = target,
        .optimize = optimize,
    });
    module_module.addImport("runtime_gc", gc_module);
    module_module.addImport("runtime_exception", exception_module);

    const class_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/class.zig"),
        .target = target,
        .optimize = optimize,
    });
    class_module.addImport("runtime_gc", gc_module);
    class_module.addImport("runtime_value", value_module);
    class_module.addImport("runtime_exception", exception_module);

    const slice_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/slice.zig"),
        .target = target,
        .optimize = optimize,
    });
    slice_module.addImport("runtime_gc", gc_module);
    slice_module.addImport("runtime_value", value_module);
    slice_module.addImport("runtime_number", number_module);
    slice_module.addImport("runtime_exception", exception_module);

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
    string_module.addImport("runtime_slice", slice_module);
    const bytes_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/bytes.zig"),
        .target = target,
        .optimize = optimize,
    });
    bytes_module.addImport("runtime_gc", gc_module);
    bytes_module.addImport("runtime_string", string_module);
    bytes_module.addImport("runtime_exception", exception_module);
    bytes_module.addImport("runtime_slice", slice_module);
    const sequence_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/sequence.zig"),
        .target = target,
        .optimize = optimize,
    });
    sequence_module.addImport("runtime_gc", gc_module);
    sequence_module.addImport("runtime_value", value_module);
    sequence_module.addImport("runtime_number", number_module);
    sequence_module.addImport("runtime_exception", exception_module);
    const dict_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/dict.zig"),
        .target = target,
        .optimize = optimize,
    });
    dict_module.addImport("runtime_gc", gc_module);
    dict_module.addImport("runtime_value", value_module);
    dict_module.addImport("runtime_exception", exception_module);
    dict_module.addImport("runtime_sequence", sequence_module);
    const hash_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/hash.zig"),
        .target = target,
        .optimize = optimize,
    });
    hash_module.addImport("runtime_gc", gc_module);
    hash_module.addImport("runtime_value", value_module);
    hash_module.addImport("runtime_number", number_module);
    hash_module.addImport("runtime_string", string_module);
    hash_module.addImport("runtime_bytes", bytes_module);
    hash_module.addImport("runtime_sequence", sequence_module);
    hash_module.addImport("runtime_dict", dict_module);
    hash_module.addImport("runtime_exception", exception_module);
    return .{
        .gc = gc_module,
        .value = value_module,
        .number = number_module,
        .exception = exception_module,
        .host = host_module,
        .unicode = unicode_module,
        .string = string_module,
        .bytes = bytes_module,
        .sequence = sequence_module,
        .slice = slice_module,
        .dict = dict_module,
        .hash = hash_module,
        .vfs = vfs_module,
        .file = file_module,
        .module = module_module,
        .class = class_module,
    };
}

fn addRuntimeImports(module: *std.Build.Module, runtime: RuntimeModules) void {
    module.addImport("runtime_gc", runtime.gc);
    module.addImport("runtime_value", runtime.value);
    module.addImport("runtime_number", runtime.number);
    module.addImport("runtime_exception", runtime.exception);
    module.addImport("runtime_host", runtime.host);
    module.addImport("runtime_unicode", runtime.unicode);
    module.addImport("runtime_string", runtime.string);
    module.addImport("runtime_bytes", runtime.bytes);
    module.addImport("runtime_sequence", runtime.sequence);
    module.addImport("runtime_slice", runtime.slice);
    module.addImport("runtime_vfs", runtime.vfs);
    module.addImport("runtime_file", runtime.file);
    module.addImport("runtime_class", runtime.class);
}
