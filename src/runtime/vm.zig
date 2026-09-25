const std = @import("std");
const builtin = @import("builtin");
const bytecode = @import("frontend_bytecode");
const compiler = @import("frontend_compiler");
const gc = @import("runtime_gc");
const value_module = @import("runtime_value");
const number = @import("runtime_number");
const string = @import("runtime_string");
const byte_module = @import("runtime_bytes");
const sequence = @import("runtime_sequence");
const dict_module = @import("runtime_dict");
const hash_module = @import("runtime_hash");
const slice = @import("runtime_slice");
const exceptions = @import("runtime_exception");
const iterator = @import("runtime_iterator");
const functions = @import("runtime_function");
const binder = @import("runtime_binder");
const ast_module = @import("frontend_ast");
const format_rules = @import("format.zig");
const host = @import("runtime_host");
const vfs_module = @import("runtime_vfs");
const file_module = @import("runtime_file");
const class_module = @import("runtime_class");

const Value = value_module.Value;
const Code = bytecode.Code;

var session_hash_nonce: u64 = 0;

pub const CompileOutcome = compiler.CompileOutcome;
pub const PythonException = exceptions.PythonException;
pub const PythonExceptionKind = exceptions.PythonExceptionKind;

pub const RunStatus = enum {
    completed,
    python_exception,
    timeslice,
    cancelled,
    engine_error,
    host_request,
    output_event,
    limit,
};

const default_quantum: u32 = 50_000;

const GlobalEntry = struct {
    name: []const u8,
    value: Value,
};

const TryPhase = enum { body, else_body, handler, finally_body };
const PendingTransfer = enum { none, return_value, jump, exception };

const TryBlock = struct {
    site_index: u32,
    slot_index: usize,
    phase: TryPhase = .body,
    pending: PendingTransfer = .none,
    pending_target: u32 = 0,
    pending_value: Value = Value.noneValue(),
    pending_exception: ?PythonException = null,
    cleanup_name_index: ?u32 = null,
    cleanup_binding: u8 = 0,
};

const Environment = struct {
    header: gc.Header,
    entries: std.ArrayList(GlobalEntry) = .empty,
};

const TestContextManager = struct {
    header: gc.Header,
    entered: Value,
    label: []u8,
    suppress: bool,
    enter_error: ?PythonExceptionKind,
};

const test_context_manager_kind = gc.Kind{
    .trace = traceTestContextManager,
    .destroy = destroyTestContextManager,
};

fn traceTestContextManager(header: *gc.Header, tracer: *gc.Tracer) void {
    const manager: *TestContextManager = @ptrCast(@alignCast(header));
    tracer.visit(manager.entered.asObject());
}

fn destroyTestContextManager(header: *gc.Header, allocator: std.mem.Allocator) void {
    const manager: *TestContextManager = @ptrCast(@alignCast(header));
    if (manager.label.len != 0) allocator.free(manager.label);
}

const Frame = struct {
    code: *Code,
    previous: ?*Frame = null,
    return_destination: ?u16 = null,
    generator_owner: ?*iterator.Iterator = null,
    return_override: ?Value = null,
    override_requires_none: bool = false,
    ip: usize = 0,
    registers: []Value = &.{},
    locals: []Value = &.{},
    local_cells: []?*functions.Cell = &.{},
    free_cells: []?*functions.Cell = &.{},
    class_namespace: ?*class_module.Class = null,
    roots: []gc.Root = &.{},
    root_frame: gc.RootFrame = .{},
    try_blocks: std.ArrayList(TryBlock) = .empty,
    pending_values: []Value = &.{},

    fn localRootStart(self: *const Frame) usize {
        return self.registers.len;
    }

    fn cellRootStart(self: *const Frame) usize {
        return self.registers.len + self.locals.len;
    }

    fn freeRootStart(self: *const Frame) usize {
        return self.cellRootStart() + self.local_cells.len;
    }

    fn classRootIndex(self: *const Frame) usize {
        return self.freeRootStart() + self.free_cells.len;
    }

    fn returnOverrideRootIndex(self: *const Frame) usize {
        return self.classRootIndex() + 1;
    }

    fn unwindRootStart(self: *const Frame) usize {
        return self.returnOverrideRootIndex() + 1;
    }
};

const PendingInput = struct {
    frame: *Frame,
    destination: u16,
    request_id: u32,
    line: u32,
    column: u32,
};

const SyncTaskOperation = enum { materialize, sorted, list_sort, next_value };
const SyncTaskPhase = enum { collect, keys, order };
const SyncCallbackResult = union(enum) { value: Value, suspended, failed };

const SyncTask = struct {
    frame: *Frame,
    call_ip: usize,
    operation: SyncTaskOperation,
    phase: SyncTaskPhase = .collect,
    destination: u16,
    line: u32,
    column: u32,
    want_tuple: bool = false,
    iterator_value: ?*iterator.Iterator = null,
    target: ?*sequence.List = null,
    callback: Value = Value.noneValue(),
    reverse: bool = false,
    snapshot: ?*sequence.List = null,
    keys: ?*sequence.List = null,
    order: []usize = &.{},
    index: usize = 0,
    position: usize = 0,
    selected_index: usize = 0,
    sort_item_started: bool = false,
    original_version: u64 = 0,
    original_length: usize = 0,
    callback_in_progress: bool = false,
    callback_completed: bool = false,
    callback_failed: bool = false,
    callback_depth_held: bool = false,
    callback_result: Value = Value.noneValue(),
    complete: bool = false,
};

fn destroyGeneratorFrameOpaque(pointer: *anyopaque, allocator: std.mem.Allocator) void {
    const frame: *Frame = @ptrCast(@alignCast(pointer));
    if (frame.root_frame.stack != null) frame.root_frame.pop();
    if (frame.roots.len != 0) allocator.free(frame.roots);
    if (frame.free_cells.len != 0) allocator.free(frame.free_cells);
    if (frame.local_cells.len != 0) allocator.free(frame.local_cells);
    frame.try_blocks.deinit(allocator);
    if (frame.pending_values.len != 0) allocator.free(frame.pending_values);
    if (frame.locals.len != 0) allocator.free(frame.locals);
    if (frame.registers.len != 0) allocator.free(frame.registers);
    allocator.destroy(frame);
}

const environment_kind = gc.Kind{
    .trace = traceEnvironment,
    .destroy = destroyEnvironment,
};

fn traceEnvironment(header: *gc.Header, tracer: *gc.Tracer) void {
    const environment: *Environment = @ptrCast(@alignCast(header));
    for (environment.entries.items) |entry| tracer.visit(entry.value.asObject());
}

fn destroyEnvironment(header: *gc.Header, allocator: std.mem.Allocator) void {
    const environment: *Environment = @ptrCast(@alignCast(header));
    for (environment.entries.items) |entry| allocator.free(entry.name);
    environment.entries.deinit(allocator);
}

/// One interpreter session. Keep this value at a stable address after init;
/// its heap's allocation hook and root frames point into it.
pub const Runtime = struct {
    session_allocator: gc.SessionAllocator = undefined,
    heap: gc.Heap = .{},
    vfs: vfs_module.Vfs = undefined,
    vfs_output: []const u8 = &.{},
    vfs_output_owned: bool = false,
    environment: *Environment = undefined,
    environment_frame: gc.RootFrame = .{},
    environment_root: gc.Root = .{ .object = null },
    builtin_frame: gc.RootFrame = .{},
    print_builtin_root: gc.Root = .{ .object = null },
    input_builtin_root: gc.Root = .{ .object = null },
    range_builtin_root: gc.Root = .{ .object = null },
    object_class_root: gc.Root = .{ .object = null },
    type_class_root: gc.Root = .{ .object = null },
    exception_frame: gc.RootFrame = .{},
    exception_root: gc.Root = .{ .object = null },
    emergency_exception_root: gc.Root = .{ .object = null },
    active_exception: ?*exceptions.ExceptionInstance = null,
    code: ?*Code = null,
    top_frame: ?*Frame = null,
    registers: []Value = &.{},
    register_roots: []gc.Root = &.{},
    register_frame: gc.RootFrame = .{},
    instruction_pointer: usize = 0,
    resuming_generator: ?*iterator.Iterator = null,
    suspended_exception_frame: ?*Frame = null,
    synchronous_work_remaining: ?usize = null,
    sync_root_frame: gc.RootFrame = .{},
    sync_roots: [8]gc.Root = @splat(.{ .object = null }),
    sync_task: ?SyncTask = null,
    sync_task_quantum: u32 = default_quantum,
    sync_yield_requested: bool = false,
    resumed_exception_pending: bool = false,
    sync_callback_depth: usize = 0,
    pending_input: ?PendingInput = null,
    event_packet: ?[]u8 = null,
    next_host_request_id: u32 = 1,
    output_event_pending: bool = false,
    max_instructions: u64 = 50_000_000,
    instructions_executed: u64 = 0,
    work_executed: u64 = 0,
    limit_reached: bool = false,
    configured_quantum: u32 = default_quantum,
    stdout_bytes: std.ArrayList(u8) = .empty,
    repr_path: std.ArrayList(*gc.Header) = .empty,
    value_equality_depth: usize = 0,
    hash_seed: u64 = 0,
    last_exception: ?PythonException = null,
    error_text_owned: ?[]u8 = null,
    error_text_static: []const u8 = "",
    traceback_json_owned: ?[]u8 = null,
    cancel_requested: bool = false,
    engine_failed: bool = false,
    initialized: bool = false,

    pub fn init(self: *Runtime, backing: std.mem.Allocator, max_bytes: usize) std.mem.Allocator.Error!void {
        const vfs_limit = @min(8 * 1024 * 1024, @max(@as(usize, 1024), max_bytes / 2));
        const file_limit = @min(2 * 1024 * 1024, vfs_limit);
        return self.initWithVfsLimits(backing, max_bytes, vfs_limit, file_limit);
    }

    pub fn initWithConfig(self: *Runtime, backing: std.mem.Allocator, config: host.Config) std.mem.Allocator.Error!void {
        try self.initWithVfsLimits(
            backing,
            @intCast(config.max_memory_bytes),
            @intCast(config.max_vfs_bytes),
            @intCast(config.max_file_bytes),
        );
        self.configureHost(config);
    }

    fn initWithVfsLimits(
        self: *Runtime,
        backing: std.mem.Allocator,
        max_bytes: usize,
        vfs_limit: usize,
        file_limit: usize,
    ) std.mem.Allocator.Error!void {
        self.* = .{};
        session_hash_nonce +%= 1;
        self.hash_seed = hash_module.mixSessionSeed(session_hash_nonce, @intFromPtr(self));
        self.session_allocator = gc.SessionAllocator.init(backing, max_bytes);
        self.heap.init(&self.session_allocator, .{});
        self.vfs = vfs_module.Vfs.init(self.heap.allocator, vfs_limit, file_limit) catch {
            self.heap.deinit();
            self.* = .{};
            return error.OutOfMemory;
        };
        const environment = self.heap.createObject(Environment, &environment_kind) catch {
            self.vfs.deinit();
            self.heap.deinit();
            self.* = .{};
            return error.OutOfMemory;
        };
        environment.entries = .empty;
        self.environment = environment;
        self.environment_root.object = &environment.header;
        self.environment_frame.push(&self.heap.roots);
        self.environment_frame.add(&self.environment_root);
        self.builtin_frame.push(&self.heap.roots);
        self.builtin_frame.add(&self.print_builtin_root);
        self.builtin_frame.add(&self.input_builtin_root);
        self.builtin_frame.add(&self.range_builtin_root);
        self.builtin_frame.add(&self.object_class_root);
        self.builtin_frame.add(&self.type_class_root);
        self.exception_frame.push(&self.heap.roots);
        self.exception_frame.add(&self.exception_root);
        self.exception_frame.add(&self.emergency_exception_root);
        const print_builtin = functions.createNative(&self.heap, .print);
        switch (print_builtin) {
            .value => |function| self.print_builtin_root.object = &function.header,
            .python_exception => {
                self.exception_frame.pop();
                self.builtin_frame.pop();
                self.environment_frame.pop();
                self.vfs.deinit();
                self.heap.deinit();
                self.* = .{};
                return error.OutOfMemory;
            },
        }
        const range_builtin = functions.createNative(&self.heap, .range);
        switch (range_builtin) {
            .value => |function| self.range_builtin_root.object = &function.header,
            .python_exception => {
                self.exception_frame.pop();
                self.builtin_frame.pop();
                self.environment_frame.pop();
                self.vfs.deinit();
                self.heap.deinit();
                self.* = .{};
                return error.OutOfMemory;
            },
        }
        const input_builtin = functions.createNative(&self.heap, .input);
        switch (input_builtin) {
            .value => |function| self.input_builtin_root.object = &function.header,
            .python_exception => {
                self.exception_frame.pop();
                self.builtin_frame.pop();
                self.environment_frame.pop();
                self.vfs.deinit();
                self.heap.deinit();
                self.* = .{};
                return error.OutOfMemory;
            },
        }
        switch (exceptions.createInstance(&self.heap, .memory_error, "session memory limit exceeded")) {
            .value => |instance| self.emergency_exception_root.object = &instance.header,
            .python_exception, .engine_error => {
                self.failInitialization();
                return error.OutOfMemory;
            },
        }
        self.initialized = true;
    }

    pub fn deinit(self: *Runtime) void {
        if (!self.initialized) return;
        self.resetProgram(false);
        self.clearVfsOutput();
        self.vfs.deinit();
        self.stdout_bytes.deinit(self.heap.allocator);
        self.repr_path.deinit(self.heap.allocator);
        if (self.traceback_json_owned) |json| self.heap.allocator.free(json);
        self.traceback_json_owned = null;
        if (self.exception_frame.stack != null) self.exception_frame.pop();
        if (self.builtin_frame.stack != null) self.builtin_frame.pop();
        if (self.environment_frame.stack != null) self.environment_frame.pop();
        self.heap.deinit();
        std.debug.assert(self.session_allocator.live_bytes == 0);
        self.* = .{};
    }

    pub fn compileAndStart(self: *Runtime, source: []const u8, filename: []const u8) CompileOutcome {
        self.vfs.clearTemporary();
        self.clearVfsOutput();
        self.resetProgram(true);
        self.instructions_executed = 0;
        self.work_executed = 0;
        self.limit_reached = false;
        const outcome = compiler.compile(&self.heap, source, filename);
        switch (outcome) {
            .ready => |code| {
                self.code = code;
                if (self.prepareRegisters(code)) return .{ .ready = code };
                code.deinit(&self.heap);
                self.code = null;
                const exception = PythonException{ .kind = .memory_error, .message = "session memory limit exceeded" };
                self.setException(exception, 1, 1, null);
                return .{ .python_exception = exception };
            },
            .syntax_error => |diagnostic| {
                self.setStaticError(diagnostic.message);
                return .{ .syntax_error = diagnostic };
            },
            .unsupported => |diagnostic| {
                self.setStaticError(diagnostic.message);
                return .{ .unsupported = diagnostic };
            },
            .python_exception => |exception| {
                self.setException(exception, 1, 1, null);
                return .{ .python_exception = exception };
            },
        }
    }

    pub fn run(self: *Runtime, requested_quantum: u32) RunStatus {
        // `vfs_output` may borrow an entry's byte storage. A running Python
        // program can replace that entry, so expire any prior VFS view before
        // execution can mutate the filesystem.
        self.clearVfsOutput();
        if (self.engine_failed) return .engine_error;
        if (self.cancel_requested) {
            self.cancel_requested = false;
            self.resetProgram(false);
            return .cancelled;
        }
        if (self.pending_input != null) return .host_request;
        if (self.limit_reached) return .limit;
        if (self.resumed_exception_pending) {
            self.resumed_exception_pending = false;
            if (self.last_exception != null and !self.unwindPythonException()) {
                if (self.engine_failed) return .engine_error;
                self.prepareExceptionDiagnostics();
                return .python_exception;
            }
        }
        if (self.last_exception != null and !self.hasExceptionContinuation()) {
            self.prepareExceptionDiagnostics();
            return .python_exception;
        }
        if (self.top_frame == null) return .completed;

        self.invalidateEvent();
        const quantum = if (requested_quantum == 0) self.configured_quantum else requested_quantum;
        self.sync_task_quantum = quantum;
        self.sync_yield_requested = false;
        var executed: u32 = 0;
        while (executed < quantum) : (executed += 1) {
            const frame = self.top_frame orelse return .completed;
            if (frame.ip >= frame.code.instructions.len or frame.code.positions.len != frame.code.instructions.len) {
                _ = self.engineFault();
                self.unwindFrames();
                return .engine_error;
            }
            const current = frame.code.positions[frame.ip];
            const instruction = frame.code.instructions[frame.ip];
            if (!self.chargeBytecode()) return .limit;
            frame.ip += 1;
            self.activateFrame(frame);
            if (!self.execute(instruction, current.line, current.column)) {
                if (self.limit_reached) {
                    if (self.sync_task) |task| if (!task.callback_in_progress) self.clearSyncTask();
                    return .limit;
                }
                if (self.sync_task) |task| if (!task.callback_in_progress) self.clearSyncTask();
                if (!self.engine_failed and self.last_exception != null and self.unwindPythonException()) {
                    if (self.sync_task) |task| if (task.callback_failed or !task.callback_in_progress) self.clearSyncTask();
                    continue;
                }
                if (self.sync_task) |task| {
                    if (task.callback_in_progress) self.unwindFramesUntil(task.frame);
                    if (self.sync_task != null) self.clearSyncTask();
                }
                self.unwindFrames();
                if (self.engine_failed) return .engine_error;
                self.prepareExceptionDiagnostics();
                return .python_exception;
            }
            if (self.top_frame == frame) {
                frame.ip = self.instruction_pointer;
            }
            if (self.sync_task != null and self.sync_task.?.complete) self.clearSyncTask();
            if (self.limit_reached) {
                if (self.sync_task != null) self.clearSyncTask();
                return .limit;
            }
            if (self.pending_input != null) return .host_request;
            if (self.output_event_pending) {
                self.output_event_pending = false;
                return .output_event;
            }
            if (self.sync_yield_requested) {
                self.sync_yield_requested = false;
                return .timeslice;
            }
            if (self.top_frame == null) return .completed;
        }
        return if (self.top_frame == null) .completed else .timeslice;
    }

    pub fn cancel(self: *Runtime) void {
        self.pending_input = null;
        self.invalidateEvent();
        self.output_event_pending = false;
        self.cancel_requested = true;
    }

    pub fn configureHost(self: *Runtime, config: host.Config) void {
        self.max_instructions = config.max_instructions;
        self.configured_quantum = config.quantum;
        if (config.seed.len != 0) {
            self.hash_seed = hash_module.mixSessionSeed(std.hash.Wyhash.hash(0, config.seed), @intFromPtr(self));
        }
    }

    pub fn instructionCount(self: *const Runtime) u64 {
        return self.instructions_executed;
    }

    pub fn workCount(self: *const Runtime) u64 {
        return self.work_executed;
    }

    pub fn mountCourseFile(self: *Runtime, path: []const u8, bytes: []const u8) vfs_module.Error!void {
        self.clearVfsOutput();
        try self.vfs.mountCourse(path, bytes);
    }

    pub fn writeVfsFile(self: *Runtime, path: []const u8, bytes: []const u8) vfs_module.Error!void {
        self.clearVfsOutput();
        try self.vfs.write(path, bytes, .replace);
    }

    pub fn readVfsFile(self: *Runtime, path: []const u8) vfs_module.Error![]const u8 {
        self.clearVfsOutput();
        self.vfs_output = try self.vfs.read(path);
        return self.vfs_output;
    }

    pub fn listVfsFiles(self: *Runtime, path: []const u8) vfs_module.Error![]const u8 {
        self.clearVfsOutput();
        self.vfs_output = try self.vfs.list(path);
        self.vfs_output_owned = true;
        return self.vfs_output;
    }

    pub fn vfsData(self: *const Runtime) []const u8 {
        return self.vfs_output;
    }

    pub fn clearVfsOutput(self: *Runtime) void {
        if (self.vfs_output_owned and self.vfs_output.len != 0) self.heap.allocator.free(@constCast(self.vfs_output));
        self.vfs_output = &.{};
        self.vfs_output_owned = false;
    }

    pub fn eventBytes(self: *const Runtime) []const u8 {
        return self.event_packet orelse "";
    }

    pub fn pendingInputRequestId(self: *const Runtime) ?u32 {
        const pending = self.pending_input orelse return null;
        return pending.request_id;
    }

    pub fn reset(self: *Runtime) void {
        self.vfs.clearTemporary();
        self.clearVfsOutput();
        self.resetProgram(true);
        self.instructions_executed = 0;
        self.work_executed = 0;
        self.limit_reached = false;
    }

    /// Accepts a fully decoded packet. A false return leaves the suspended input and event untouched.
    pub fn resumeHost(self: *Runtime, packet: *const host.DecodedPacket) bool {
        const pending = self.pending_input orelse return false;
        if (packet.kind != .input or packet.request_id != pending.request_id or packet.flags != 0) return false;
        switch (packet.status) {
            .ok => if (packet.sections.len != 1 or packet.sections[0].kind != .utf8) return false,
            .eof => if (packet.sections.len != 0) return false,
            .host_error => if (packet.sections.len != 1 or packet.sections[0].kind != .utf8) return false,
        }

        self.pending_input = null;
        self.invalidateEvent();
        switch (packet.status) {
            .ok => {
                const line = trimInputEnding(packet.sections[0].bytes);
                const created = string.create(&self.heap, line);
                switch (created) {
                    .value => |text| {
                        const position: usize = pending.destination;
                        if (position >= pending.frame.registers.len or pending.frame.roots.len < pending.frame.registers.len) {
                            _ = self.engineFault();
                            return true;
                        }
                        const value = Value.object(&text.header);
                        pending.frame.registers[position] = value;
                        pending.frame.roots[position].object = &text.header;
                    },
                    .python_exception => |exception| {
                        self.setException(exception, pending.line, pending.column, null);
                        self.resumed_exception_pending = true;
                    },
                    .engine_error => _ = self.engineFault(),
                }
            },
            .eof => {
                self.setException(.{ .kind = .eof_error, .message = "EOF when reading a line" }, pending.line, pending.column, null);
                self.resumed_exception_pending = true;
            },
            .host_error => {
                self.setException(.{ .kind = .os_error, .message = packet.sections[0].bytes }, pending.line, pending.column, null);
                self.resumed_exception_pending = true;
            },
        }
        return true;
    }

    pub fn stdout(self: *const Runtime) []const u8 {
        return self.stdout_bytes.items;
    }

    pub fn consumeStdout(self: *Runtime, length: usize) bool {
        if (length > self.stdout_bytes.items.len) return false;
        self.invalidateEvent();
        const remaining = self.stdout_bytes.items.len - length;
        if (remaining != 0) std.mem.copyForwards(u8, self.stdout_bytes.items[0..remaining], self.stdout_bytes.items[length..]);
        self.stdout_bytes.items.len = remaining;
        return true;
    }

    pub fn pythonException(self: *const Runtime) ?PythonException {
        return self.last_exception;
    }

    pub fn errorText(self: *const Runtime) []const u8 {
        return self.error_text_owned orelse self.error_text_static;
    }

    pub fn tracebackJson(self: *const Runtime) []const u8 {
        return self.traceback_json_owned orelse "";
    }

    /// Installs a synthetic context-manager object for native protocol tests.
    /// The method is deliberately unavailable in product builds and is not part
    /// of Peony's Python or WASM API.
    pub fn installTestContextManager(
        self: *Runtime,
        name: []const u8,
        label: []const u8,
        entered: Value,
        suppress: bool,
        enter_error: ?PythonExceptionKind,
    ) std.mem.Allocator.Error!void {
        if (comptime !builtin.is_test) @compileError("native test helper is unavailable in product builds");
        const manager = try self.heap.createObject(TestContextManager, &test_context_manager_kind);
        const header = manager.header;
        manager.* = .{
            .header = header,
            .entered = entered,
            .label = &.{},
            .suppress = suppress,
            .enter_error = enter_error,
        };
        var root = gc.Root{ .object = &manager.header };
        var roots = gc.RootFrame{};
        roots.push(&self.heap.roots);
        roots.add(&root);
        defer roots.pop();
        manager.label = try self.heap.allocator.dupe(u8, label);
        if (!self.storeGlobal(name, Value.object(&manager.header))) return error.OutOfMemory;
    }

    fn prepareRegisters(self: *Runtime, code: *Code) bool {
        _ = self.allocateFrame(code, null) catch return false;
        return true;
    }

    fn resetProgram(self: *Runtime, clear_output: bool) void {
        self.suspended_exception_frame = null;
        if (self.sync_task) |task| {
            if (task.callback_in_progress) self.unwindFramesUntil(task.frame);
        }
        if (self.sync_task != null) self.clearSyncTask();
        self.unwindFrames();

        self.pending_input = null;
        self.output_event_pending = false;
        self.invalidateEvent();

        self.clearGlobals();
        if (self.code) |code| {
            code.deinit(&self.heap);
            self.code = null;
        }
        self.instruction_pointer = 0;
        self.cancel_requested = false;
        self.engine_failed = false;
        self.last_exception = null;
        self.resumed_exception_pending = false;
        self.active_exception = null;
        self.exception_root.object = null;
        self.clearErrorText();
        if (self.traceback_json_owned) |json| self.heap.allocator.free(json);
        self.traceback_json_owned = null;
        if (clear_output) self.stdout_bytes.clearRetainingCapacity();
        _ = self.heap.collect();
    }

    fn invalidateEvent(self: *Runtime) void {
        if (self.event_packet) |packet| self.heap.allocator.free(packet);
        self.event_packet = null;
    }

    fn createEventPacket(self: *Runtime, packet: host.Packet) bool {
        self.invalidateEvent();
        self.event_packet = host.encode(self.heap.allocator, packet) catch return false;
        return true;
    }

    fn nextEventId(self: *Runtime) u32 {
        const result = self.next_host_request_id;
        self.next_host_request_id +%= 1;
        if (self.next_host_request_id == 0) self.next_host_request_id = 1;
        if (result != 0) return result;
        return self.nextEventId();
    }

    fn beginInputRequest(self: *Runtime, destination: u16, prompt: []const u8, line: u32, column: u32) bool {
        if (!self.appendOutput(prompt)) {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        }
        const request_id = self.nextEventId();
        const sections = [_]host.Section{.{ .kind = .utf8, .bytes = prompt }};
        if (!self.createEventPacket(.{ .kind = .input, .request_id = request_id, .sections = &sections })) {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        }
        const frame = self.top_frame orelse return self.engineFault();
        self.pending_input = .{ .frame = frame, .destination = destination, .request_id = request_id, .line = line, .column = column };
        return true;
    }

    fn beginOutputEvent(self: *Runtime, line: u32, column: u32) bool {
        const event_id = self.nextEventId();
        if (!self.createEventPacket(.{ .kind = .output, .request_id = event_id })) {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        }
        self.output_event_pending = true;
        return true;
    }

    fn allocateFrame(self: *Runtime, code: *Code, return_destination: ?u16) error{OutOfMemory}!*Frame {
        const allocator = self.heap.allocator;
        const frame = allocator.create(Frame) catch return error.OutOfMemory;
        frame.* = .{ .code = code, .return_destination = return_destination };
        errdefer self.freeFrameStorage(frame);
        frame.registers = try allocator.alloc(Value, @intCast(code.register_count));
        @memset(frame.registers, Value.unboundValue());
        frame.locals = try allocator.alloc(Value, code.local_names.len);
        @memset(frame.locals, Value.unboundValue());
        frame.local_cells = try allocator.alloc(?*functions.Cell, code.cell_names.len);
        @memset(frame.local_cells, null);
        frame.free_cells = try allocator.alloc(?*functions.Cell, code.free_names.len);
        @memset(frame.free_cells, null);
        try frame.try_blocks.ensureTotalCapacity(allocator, code.try_sites.len);
        frame.pending_values = try allocator.alloc(Value, code.try_sites.len);
        @memset(frame.pending_values, Value.noneValue());
        const first_roots = std.math.add(usize, frame.registers.len, frame.locals.len) catch return error.OutOfMemory;
        const cell_roots = std.math.add(usize, frame.local_cells.len, frame.free_cells.len) catch return error.OutOfMemory;
        const unwind_root_count = std.math.mul(usize, code.try_sites.len, 2) catch return error.OutOfMemory;
        const root_prefix = std.math.add(usize, first_roots, cell_roots) catch return error.OutOfMemory;
        const with_special_roots = std.math.add(usize, root_prefix, 2) catch return error.OutOfMemory;
        const root_count = std.math.add(usize, with_special_roots, unwind_root_count) catch return error.OutOfMemory;
        frame.roots = try allocator.alloc(gc.Root, root_count);
        @memset(frame.roots, .{ .object = null });
        frame.root_frame.push(&self.heap.roots);
        for (frame.roots) |*root| frame.root_frame.add(root);
        frame.previous = self.top_frame;
        self.top_frame = frame;
        self.activateFrame(frame);
        return frame;
    }

    fn freeFrameStorage(self: *Runtime, frame: *Frame) void {
        const allocator = self.heap.allocator;
        if (frame.roots.len != 0) allocator.free(frame.roots);
        frame.try_blocks.deinit(allocator);
        if (frame.pending_values.len != 0) allocator.free(frame.pending_values);
        if (frame.free_cells.len != 0) allocator.free(frame.free_cells);
        if (frame.local_cells.len != 0) allocator.free(frame.local_cells);
        if (frame.locals.len != 0) allocator.free(frame.locals);
        if (frame.registers.len != 0) allocator.free(frame.registers);
        allocator.destroy(frame);
    }

    fn failInitialization(self: *Runtime) void {
        if (self.exception_frame.stack != null) self.exception_frame.pop();
        if (self.builtin_frame.stack != null) self.builtin_frame.pop();
        if (self.environment_frame.stack != null) self.environment_frame.pop();
        self.clearVfsOutput();
        self.vfs.deinit();
        self.heap.deinit();
        self.* = .{};
    }

    fn activateFrame(self: *Runtime, frame: *Frame) void {
        self.registers = frame.registers;
        self.register_roots = frame.roots[0..frame.registers.len];
        self.instruction_pointer = frame.ip;
    }

    fn popFrame(self: *Runtime) ?*Frame {
        const frame = self.top_frame orelse return null;
        if (self.sync_task) |*task| {
            if (task.callback_in_progress and frame.previous == task.frame) {
                task.callback_in_progress = false;
                task.callback_failed = true;
                self.releaseSyncCallbackDepth(task);
            }
            if (task.callback_failed and frame == task.frame) self.clearSyncTask();
        }
        if (frame.root_frame.stack != null) frame.root_frame.pop();
        self.top_frame = frame.previous;
        const previous = self.top_frame;
        if (previous) |active| {
            self.activateFrame(active);
        } else {
            self.registers = &.{};
            self.register_roots = &.{};
            self.instruction_pointer = 0;
        }
        return frame;
    }

    fn unwindFrames(self: *Runtime) void {
        while (self.popFrame()) |frame| {
            self.forgetGeneratorFrame(frame);
            self.freeFrameStorage(frame);
        }
    }

    fn unwindFramesUntil(self: *Runtime, boundary: *Frame) void {
        while (self.top_frame != boundary) {
            const frame = self.popFrame() orelse break;
            self.forgetGeneratorFrame(frame);
            self.freeFrameStorage(frame);
        }
    }

    fn hasExceptionContinuation(self: *const Runtime) bool {
        if (self.suspended_exception_frame != null) return true;
        var frame = self.top_frame;
        while (frame) |current| : (frame = current.previous) {
            for (current.try_blocks.items) |block| {
                if (block.phase == .handler or (block.phase == .finally_body and block.pending == .exception)) return true;
            }
        }
        return false;
    }

    fn frameHasExceptionContinuation(frame: *const Frame) bool {
        for (frame.try_blocks.items) |block| {
            if (block.phase == .handler or (block.phase == .finally_body and block.pending == .exception)) return true;
        }
        return false;
    }

    fn unwindPythonException(self: *Runtime) bool {
        return self.unwindPythonExceptionUntil(null);
    }

    fn unwindPythonExceptionUntil(self: *Runtime, boundary: ?*Frame) bool {
        while (self.top_frame) |frame| {
            if (boundary != null and frame == boundary.?) return false;
            if (frame.try_blocks.items.len != 0) {
                const block = &frame.try_blocks.items[frame.try_blocks.items.len - 1];
                const site_index: usize = block.site_index;
                if (site_index >= frame.code.try_sites.len) return self.engineFault();
                const site = frame.code.try_sites[site_index];
                switch (block.phase) {
                    .body => {
                        if (site.handler_count != 0) {
                            block.phase = .handler;
                            frame.ip = site.handler_ip;
                            if (self.top_frame == frame) self.instruction_pointer = frame.ip;
                            return true;
                        }
                        if (site.finalizer_ip != std.math.maxInt(u32)) {
                            self.savePendingException(frame, block);
                            block.phase = .finally_body;
                            frame.ip = site.finalizer_ip;
                            if (self.top_frame == frame) self.instruction_pointer = frame.ip;
                            return true;
                        }
                        _ = self.popTryBlock(frame, false);
                    },
                    .else_body, .handler => {
                        if (site.finalizer_ip != std.math.maxInt(u32)) {
                            if (block.phase == .handler and block.cleanup_name_index != null) {
                                self.clearExceptionTarget(frame, block.*);
                                block.cleanup_name_index = null;
                            }
                            self.savePendingException(frame, block);
                            block.phase = .finally_body;
                            frame.ip = site.finalizer_ip;
                            if (self.top_frame == frame) self.instruction_pointer = frame.ip;
                            return true;
                        }
                        _ = self.popTryBlock(frame, false);
                    },
                    .finally_body => {
                        // A new fault in finally replaces the pending transfer.
                        _ = self.popTryBlock(frame, false);
                    },
                }
                continue;
            }

            if (frame.generator_owner != null) {
                if (self.suspended_exception_frame == frame) self.suspended_exception_frame = null;
                return false;
            }
            const caller = frame.previous;
            if (caller == null) return false;
            self.appendTracebackCaller(caller.?);
            const popped = self.popFrame() orelse return self.engineFault();
            self.forgetGeneratorFrame(popped);
            self.freeFrameStorage(popped);
        }
        return false;
    }

    fn appendTracebackCaller(self: *Runtime, caller: *Frame) void {
        const instance = self.active_exception orelse return;
        const position_index = if (caller.ip == 0) 0 else caller.ip - 1;
        if (position_index >= caller.code.positions.len) return;
        const position = caller.code.positions[position_index];
        instance.frames.append(self.heap.allocator, .{
            .filename = caller.code.filename,
            .function_name = caller.code.display_name,
            .line = position.line,
            .column = position.column,
            .source_line = sourceLine(caller.code.source, position.line),
        }) catch {};
    }

    fn tryRootIndex(frame: *const Frame, slot_index: usize, saved_exception: bool) usize {
        return frame.unwindRootStart() + slot_index * 2 + @as(usize, @intFromBool(saved_exception));
    }

    fn savePendingException(self: *Runtime, frame: *Frame, block: *TryBlock) void {
        block.pending = .exception;
        block.pending_exception = self.last_exception;
        frame.roots[tryRootIndex(frame, block.slot_index, false)].object = if (self.active_exception) |active| &active.header else null;
    }

    fn restorePendingException(self: *Runtime, frame: *Frame, block: TryBlock) void {
        const saved = frame.roots[tryRootIndex(frame, block.slot_index, false)].object;
        self.exception_root.object = saved;
        self.active_exception = if (saved) |header| exceptions.instanceFromHeader(header) else null;
        self.last_exception = block.pending_exception;
        self.clearErrorText();
        self.error_text_static = "Python exception";
    }

    fn setFrameInstruction(self: *Runtime, frame: *Frame, target: u32) bool {
        if (@as(usize, target) > frame.code.instructions.len) return self.engineFault();
        frame.ip = target;
        if (self.top_frame == frame) self.instruction_pointer = target;
        return true;
    }

    fn clearExceptionTarget(self: *Runtime, frame: *Frame, block: TryBlock) void {
        const name_index = block.cleanup_name_index orelse return;
        const index: usize = name_index;
        if (index >= frame.code.names.len) {
            self.engine_failed = true;
            return;
        }
        const name = frame.code.names[index];
        switch (block.cleanup_binding) {
            0 => {
                if (indexOfName(frame.code.local_names, name)) |local_index| {
                    frame.locals[local_index] = Value.deletedValue();
                    frame.roots[frame.localRootStart() + local_index].object = null;
                } else self.engine_failed = true;
            },
            1 => {
                if (indexOfName(frame.code.cell_names, name)) |cell_index| {
                    if (frame.local_cells[cell_index]) |cell| cell.value = Value.deletedValue() else self.engine_failed = true;
                } else self.engine_failed = true;
            },
            2 => {
                if (indexOfName(frame.code.free_names, name)) |free_index| {
                    if (frame.free_cells[free_index]) |cell| cell.value = Value.deletedValue() else self.engine_failed = true;
                } else self.engine_failed = true;
            },
            3 => {
                for (self.environment.entries.items, 0..) |entry, global_index| {
                    if (!std.mem.eql(u8, entry.name, name)) continue;
                    self.heap.allocator.free(entry.name);
                    _ = self.environment.entries.orderedRemove(global_index);
                    return;
                }
            },
            else => self.engine_failed = true,
        }
    }

    fn popTryBlock(self: *Runtime, frame: *Frame, restore_exception: bool) ?TryBlock {
        const block = frame.try_blocks.pop() orelse return null;
        self.clearExceptionTarget(frame, block);
        const pending_root_index = tryRootIndex(frame, block.slot_index, false);
        const saved_root_index = tryRootIndex(frame, block.slot_index, true);
        if (restore_exception) {
            const saved = frame.roots[saved_root_index].object;
            self.exception_root.object = saved;
            self.active_exception = if (saved) |header| exceptions.instanceFromHeader(header) else null;
            self.last_exception = null;
            self.clearErrorText();
        }
        frame.roots[pending_root_index].object = null;
        frame.roots[saved_root_index].object = null;
        frame.pending_values[block.slot_index] = Value.noneValue();
        return block;
    }

    fn beginJumpTransfer(self: *Runtime, frame: *Frame, target: u32) bool {
        while (frame.try_blocks.items.len != 0) {
            const block = &frame.try_blocks.items[frame.try_blocks.items.len - 1];
            const site = frame.code.try_sites[block.site_index];
            if (block.phase == .finally_body) {
                if (site.finalizer_ip != std.math.maxInt(u32) and target >= site.finalizer_ip and target < site.end_ip) break;
                _ = self.popTryBlock(frame, true);
                if (self.engine_failed) return false;
                continue;
            }
            const active_end = if (site.finalizer_ip != std.math.maxInt(u32)) site.finalizer_ip else site.end_ip;
            if (target >= site.body_start_ip and target < active_end) break;
            if (block.phase == .handler and block.cleanup_name_index != null) {
                self.clearExceptionTarget(frame, block.*);
                block.cleanup_name_index = null;
            }
            if (site.finalizer_ip != std.math.maxInt(u32)) {
                block.pending = .jump;
                block.pending_target = target;
                block.phase = .finally_body;
                return self.setFrameInstruction(frame, site.finalizer_ip);
            }
            _ = self.popTryBlock(frame, true);
            if (self.engine_failed) return false;
        }
        return self.setFrameInstruction(frame, target);
    }

    fn performReturn(self: *Runtime, result: Value, line: u32, column: u32) bool {
        const returning_frame = self.top_frame orelse return self.engineFault();
        var result_value = result;
        if (returning_frame.return_override) |override| {
            if (returning_frame.override_requires_none and result.tag() != .none) {
                self.setException(.{ .kind = .type_error, .message = "__init__() should return None" }, line, column, null);
                return false;
            }
            _ = override;
            result_value = returning_frame.return_override.?;
        }
        if (self.sync_task) |*task| {
            if (task.callback_in_progress and framePreviousIsTask(self.top_frame, task.frame)) {
                task.callback_result = result_value;
                task.callback_completed = true;
                task.callback_in_progress = false;
                self.sync_roots[6].object = result_value.asObject();
                self.releaseSyncCallbackDepth(task);
            }
        }
        const frame = self.popFrame() orelse return self.engineFault();
        if (frame.generator_owner != null) {
            if (frame.generator_owner) |owner| {
                owner.generator_return_value = result_value;
                owner.generator_return_pending = true;
            }
            self.forgetGeneratorFrame(frame);
            self.freeFrameStorage(frame);
            return true;
        }
        const return_destination = frame.return_destination;
        self.freeFrameStorage(frame);
        if (self.top_frame) |caller| {
            const destination = return_destination orelse return self.engineFault();
            if (!self.validRegister(destination)) return self.engineFault();
            self.setRegister(destination, result_value);
            _ = caller;
        } else if (return_destination != null) return self.engineFault();
        return true;
    }

    fn framePreviousIsTask(selected: ?*Frame, task_frame: *Frame) bool {
        const frame = selected orelse return false;
        return frame.previous == task_frame;
    }

    fn beginReturnTransfer(self: *Runtime, frame: *Frame, result: Value, line: u32, column: u32) bool {
        while (frame.try_blocks.items.len != 0) {
            const block = &frame.try_blocks.items[frame.try_blocks.items.len - 1];
            const site = frame.code.try_sites[block.site_index];
            if (block.phase == .finally_body) {
                _ = self.popTryBlock(frame, true);
                if (self.engine_failed) return false;
                continue;
            }
            if (block.phase == .handler and block.cleanup_name_index != null) {
                self.clearExceptionTarget(frame, block.*);
                block.cleanup_name_index = null;
            }
            if (site.finalizer_ip != std.math.maxInt(u32)) {
                block.pending = .return_value;
                frame.pending_values[block.slot_index] = result;
                frame.roots[tryRootIndex(frame, block.slot_index, false)].object = result.asObject();
                block.phase = .finally_body;
                return self.setFrameInstruction(frame, site.finalizer_ip);
            }
            _ = self.popTryBlock(frame, true);
            if (self.engine_failed) return false;
        }
        return self.performReturn(result, line, column);
    }

    fn enterTry(self: *Runtime, site_index: u32, line: u32, column: u32) bool {
        const frame = self.top_frame orelse return self.engineFault();
        if (site_index >= frame.code.try_sites.len) return self.engineFault();
        const slot: usize = site_index;
        frame.roots[tryRootIndex(frame, slot, false)].object = null;
        frame.roots[tryRootIndex(frame, slot, true)].object = if (self.active_exception) |active| &active.header else null;
        frame.pending_values[slot] = Value.noneValue();
        frame.try_blocks.append(self.heap.allocator, .{ .site_index = site_index, .slot_index = slot }) catch {
            self.setException(exceptions.memoryError(), line, column, null);
            return false;
        };
        return true;
    }

    fn testContextManager(value: Value) ?*TestContextManager {
        const header = value.asObject() orelse return null;
        if (header.kind != &test_context_manager_kind) return null;
        return @ptrCast(@alignCast(header));
    }

    fn executeWithEnter(self: *Runtime, destination: u16, manager_value: Value, line: u32, column: u32) bool {
        if (manager_value.asObject()) |header| {
            if (file_module.fromHeader(header)) |file| {
                if (file.closed) {
                    self.setException(.{ .kind = .value_error, .message = "I/O operation on closed file" }, line, column, null);
                    return false;
                }
                if (!self.validRegister(destination)) return self.engineFault();
                self.setRegister(destination, manager_value);
                return true;
            }
        }
        if (manager_value.asObject()) |header| if (class_module.instanceFromHeader(header) != null) {
            if (self.invokeSpecialSync(manager_value, "__enter__", &.{}, line, column)) |entered| {
                self.setRegister(destination, entered);
                return true;
            }
            if (self.last_exception != null or self.engine_failed) return false;
        };
        const manager = testContextManager(manager_value) orelse {
            self.setException(.{ .kind = .type_error, .message = "object does not support the context manager protocol" }, line, column, null);
            return false;
        };
        if (!self.appendOutput("enter ") or !self.appendOutput(manager.label) or !self.appendOutput("\n")) return false;
        if (manager.enter_error) |kind| {
            self.setException(.{ .kind = kind, .message = "context manager __enter__ failed" }, line, column, null);
            return false;
        }
        if (!self.validRegister(destination)) return self.engineFault();
        self.setRegister(destination, manager.entered);
        return true;
    }

    fn executeWithExit(self: *Runtime, destination: u16, manager_value: Value, line: u32, column: u32) bool {
        const frame = self.top_frame orelse return self.engineFault();
        if (frame.try_blocks.items.len == 0) return self.engineFault();
        const block = &frame.try_blocks.items[frame.try_blocks.items.len - 1];
        if (block.phase != .finally_body) return self.engineFault();
        if (manager_value.asObject()) |header| {
            if (file_module.fromHeader(header)) |file| {
                file_module.close(file);
                return true;
            }
        }
        if (manager_value.asObject()) |header| if (class_module.instanceFromHeader(header) != null) {
            const pending = if (block.pending == .exception) block.pending_exception else null;
            const exc_type = if (pending) |exception| Value.exceptionClass(@intCast(@intFromEnum(exception.kind))) else Value.noneValue();
            const exc_value = if (pending) |exception| blk: {
                if (self.active_exception) |active| {
                    if (active.kind == exception.kind) break :blk Value.object(&active.header);
                }
                break :blk Value.noneValue();
            } else Value.noneValue();
            const arguments = [_]Value{ exc_type, exc_value, Value.noneValue() };
            const saved_active = self.active_exception;
            const saved_exception_root = self.exception_root.object;
            const saved_last = self.last_exception;
            if (pending != null) {
                // Keep the old exception rooted in the try block, but don't let
                // it make successful special-method lookups inside __exit__
                // appear to fail.
                self.last_exception = null;
                self.clearErrorText();
            }
            if (self.invokeSpecialSync(manager_value, "__exit__", &arguments, line, column)) |result| {
                if (pending != null) {
                    const suppress = self.valueTruthy(result, line, column) orelse return false;
                    if (suppress) {
                        block.pending = .none;
                        block.pending_exception = null;
                        frame.roots[tryRootIndex(frame, block.slot_index, false)].object = null;
                        self.active_exception = null;
                        self.exception_root.object = null;
                        self.last_exception = null;
                        self.clearErrorText();
                    } else {
                        self.active_exception = saved_active;
                        self.exception_root.object = saved_exception_root;
                        self.last_exception = saved_last;
                    }
                }
                self.setRegister(destination, result);
                return true;
            }
            if (pending != null and self.last_exception == null) {
                self.active_exception = saved_active;
                self.exception_root.object = saved_exception_root;
                self.last_exception = saved_last;
            }
            if (self.last_exception != null or self.engine_failed) return false;
        };
        const manager = testContextManager(manager_value) orelse {
            self.setException(.{ .kind = .type_error, .message = "object does not support the context manager protocol" }, line, column, null);
            return false;
        };
        const pending_kind = if (block.pending == .exception)
            (block.pending_exception orelse {
                self.engine_failed = true;
                return false;
            }).kind
        else
            null;
        if (!self.appendOutput("exit ") or !self.appendOutput(manager.label) or !self.appendOutput(" ")) return false;
        if (pending_kind) |kind| {
            if (!self.appendOutput(exceptionName(kind))) return false;
        } else if (!self.appendOutput("None")) return false;
        if (!self.appendOutput("\n")) return false;

        if (pending_kind != null and manager.suppress) {
            block.pending = .none;
            block.pending_exception = null;
            frame.roots[tryRootIndex(frame, block.slot_index, false)].object = null;
            self.active_exception = null;
            self.exception_root.object = null;
            self.last_exception = null;
            self.clearErrorText();
        }
        return true;
    }

    fn activeExceptionKind(self: *const Runtime) ?PythonExceptionKind {
        if (self.last_exception) |pending| return pending.kind;
        if (self.active_exception) |active| return active.kind;
        return null;
    }

    fn matchesExceptionType(self: *Runtime, candidate: Value, kind: PythonExceptionKind, line: u32, column: u32) ?bool {
        if (candidate.asExceptionClass()) |class_index| {
            if (class_index >= exceptions.allKinds.len) {
                _ = self.engineFault();
                return null;
            }
            return exceptions.isSubclass(kind, exceptions.allKinds[class_index]);
        }
        const header = candidate.asObject() orelse {
            self.setException(.{ .kind = .type_error, .message = "catching classes that do not inherit from BaseException is not allowed" }, line, column, null);
            return null;
        };
        if (exceptions.classFromHeader(header)) |class| return exceptions.isSubclass(kind, class.kind);
        if (sequence.tupleFromHeader(header)) |tuple| {
            var matched = false;
            for (tuple.items) |entry| {
                if (entry.asExceptionClass()) |class_index| {
                    if (class_index >= exceptions.allKinds.len) {
                        _ = self.engineFault();
                        return null;
                    }
                    matched = matched or exceptions.isSubclass(kind, exceptions.allKinds[class_index]);
                    continue;
                }
                const entry_header = entry.asObject() orelse {
                    self.setException(.{ .kind = .type_error, .message = "catching classes that do not inherit from BaseException is not allowed" }, line, column, null);
                    return null;
                };
                const class = exceptions.classFromHeader(entry_header) orelse {
                    self.setException(.{ .kind = .type_error, .message = "catching classes that do not inherit from BaseException is not allowed" }, line, column, null);
                    return null;
                };
                matched = matched or exceptions.isSubclass(kind, class.kind);
            }
            return matched;
        }
        self.setException(.{ .kind = .type_error, .message = "catching classes that do not inherit from BaseException is not allowed" }, line, column, null);
        return null;
    }

    fn storeBoundValue(self: *Runtime, frame: *Frame, name: []const u8, binding: u8, value: Value, line: u32, column: u32) bool {
        switch (binding) {
            0 => {
                const index = indexOfName(frame.code.local_names, name) orelse return self.engineFault();
                frame.locals[index] = value;
                frame.roots[frame.localRootStart() + index].object = value.asObject();
                return true;
            },
            1 => {
                const index = indexOfName(frame.code.cell_names, name) orelse return self.engineFault();
                const cell = frame.local_cells[index] orelse return self.engineFault();
                cell.value = value;
                return true;
            },
            2 => {
                const index = indexOfName(frame.code.free_names, name) orelse return self.engineFault();
                const cell = frame.free_cells[index] orelse return self.engineFault();
                cell.value = value;
                return true;
            },
            3 => {
                if (self.storeGlobal(name, value)) return true;
                self.setException(exceptions.memoryError(), line, column, null);
                return false;
            },
            else => return self.engineFault(),
        }
    }

    fn acceptCurrentException(self: *Runtime, frame: *Frame, site_index: u32) bool {
        if (frame.try_blocks.items.len == 0) return self.engineFault();
        const block = &frame.try_blocks.items[frame.try_blocks.items.len - 1];
        if (block.site_index != site_index or block.phase != .handler or self.last_exception == null) return self.engineFault();
        self.last_exception = null;
        self.clearErrorText();
        return true;
    }

    fn completeTry(self: *Runtime, frame: *Frame, site_index: u32) bool {
        if (frame.try_blocks.items.len == 0) return self.engineFault();
        const block = &frame.try_blocks.items[frame.try_blocks.items.len - 1];
        if (block.site_index != site_index or site_index >= frame.code.try_sites.len) return self.engineFault();
        const site = frame.code.try_sites[site_index];
        if (block.phase == .handler and block.cleanup_name_index != null) {
            self.clearExceptionTarget(frame, block.*);
            block.cleanup_name_index = null;
        }
        if (site.finalizer_ip != std.math.maxInt(u32)) {
            block.pending = .none;
            block.phase = .finally_body;
            return self.setFrameInstruction(frame, site.finalizer_ip);
        }
        _ = self.popTryBlock(frame, true);
        if (self.engine_failed) return false;
        return self.setFrameInstruction(frame, site.end_ip);
    }

    fn completeFinally(self: *Runtime, frame: *Frame, site_index: u32, line: u32, column: u32) bool {
        if (frame.try_blocks.items.len == 0) return self.engineFault();
        const block_copy = frame.try_blocks.items[frame.try_blocks.items.len - 1];
        if (block_copy.site_index != site_index or block_copy.phase != .finally_body or site_index >= frame.code.try_sites.len) return self.engineFault();
        const site = frame.code.try_sites[site_index];
        const result = frame.pending_values[block_copy.slot_index];
        switch (block_copy.pending) {
            .exception => {
                self.restorePendingException(frame, block_copy);
                _ = self.popTryBlock(frame, false);
                return false;
            },
            .return_value => {
                _ = self.popTryBlock(frame, true);
                if (self.engine_failed) return false;
                return self.beginReturnTransfer(frame, result, line, column);
            },
            .jump => {
                const target = block_copy.pending_target;
                _ = self.popTryBlock(frame, true);
                if (self.engine_failed) return false;
                return self.beginJumpTransfer(frame, target);
            },
            .none => {
                _ = self.popTryBlock(frame, true);
                if (self.engine_failed) return false;
                return self.setFrameInstruction(frame, site.end_ip);
            },
        }
    }

    fn raiseExisting(self: *Runtime, instance: *exceptions.ExceptionInstance, line: u32, column: u32, add_traceback_frame: bool) void {
        const previous = self.active_exception;
        if (previous) |context| {
            if (context != instance and instance.context == null) instance.context = context;
        }
        self.active_exception = instance;
        self.exception_root.object = &instance.header;
        self.last_exception = .{ .kind = instance.kind, .message = instance.message };
        self.clearErrorText();
        if (add_traceback_frame) if (self.top_frame) |frame| {
            instance.frames.append(self.heap.allocator, .{
                .filename = frame.code.filename,
                .function_name = frame.code.display_name,
                .line = line,
                .column = column,
                .source_line = sourceLine(frame.code.source, line),
            }) catch {};
        };
        const error_text = std.fmt.allocPrint(self.heap.allocator, "{s}: {s} ({s}:{d}:{d})", .{ exceptionName(instance.kind), instance.message, self.currentFilename(), line, column }) catch null;
        if (error_text) |owned| self.error_text_owned = owned else self.error_text_static = "Python exception";
    }

    fn executeRaise(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
        if (instruction.opcodeTag() == .raise_current) {
            const instance = self.active_exception orelse {
                self.setException(.{ .kind = .runtime_error, .message = "no active exception to reraise" }, line, column, null);
                return false;
            };
            self.raiseExisting(instance, line, column, false);
            return false;
        }
        if (!self.validRegister(instruction.a())) return self.engineFault();
        const raised = self.registers[instruction.a()];
        var instance: *exceptions.ExceptionInstance = undefined;
        if (raised.asExceptionClass()) |class_index| {
            if (class_index >= exceptions.allKinds.len) return self.engineFault();
            switch (exceptions.createInstance(&self.heap, exceptions.allKinds[class_index], "")) {
                .value => |created| instance = created,
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            }
        } else {
            const raised_header = raised.asObject() orelse {
                self.setException(.{ .kind = .type_error, .message = "exceptions must derive from BaseException" }, line, column, null);
                return false;
            };
            if (exceptions.instanceFromHeader(raised_header)) |existing| {
                instance = existing;
            } else if (exceptions.classFromHeader(raised_header)) |class| {
                switch (exceptions.createInstance(&self.heap, class.kind, "")) {
                    .value => |created| instance = created,
                    .python_exception => |exception| {
                        self.setException(exception, line, column, null);
                        return false;
                    },
                    .engine_error => return self.engineFault(),
                }
            } else {
                self.setException(.{ .kind = .type_error, .message = "exceptions must derive from BaseException" }, line, column, null);
                return false;
            }
        }

        var roots = [_]gc.Root{ .{ .object = &instance.header }, .{ .object = null } };
        var root_frame = gc.RootFrame{};
        root_frame.push(&self.heap.roots);
        for (&roots) |*root| root_frame.add(root);
        defer root_frame.pop();

        if (instruction.flags() & 1 != 0) {
            if (!self.validRegister(instruction.b())) return self.engineFault();
            const cause = self.registers[instruction.b()];
            if (cause.tag() == .none) {
                instance.cause = null;
                instance.suppress_context = true;
            } else if (cause.asExceptionClass()) |class_index| {
                if (class_index >= exceptions.allKinds.len) return self.engineFault();
                switch (exceptions.createInstance(&self.heap, exceptions.allKinds[class_index], "")) {
                    .value => |cause_instance| {
                        roots[1].object = &cause_instance.header;
                        instance.cause = cause_instance;
                        instance.suppress_context = true;
                    },
                    .python_exception => |exception| {
                        self.setException(exception, line, column, null);
                        return false;
                    },
                    .engine_error => return self.engineFault(),
                }
            } else if (cause.asObject()) |cause_header| {
                if (exceptions.instanceFromHeader(cause_header)) |cause_instance| {
                    instance.cause = cause_instance;
                    instance.suppress_context = true;
                } else if (exceptions.classFromHeader(cause_header)) |cause_class| {
                    switch (exceptions.createInstance(&self.heap, cause_class.kind, "")) {
                        .value => |cause_instance| {
                            instance.cause = cause_instance;
                            instance.suppress_context = true;
                        },
                        .python_exception => |exception| {
                            self.setException(exception, line, column, null);
                            return false;
                        },
                        .engine_error => return self.engineFault(),
                    }
                } else {
                    self.setException(.{ .kind = .type_error, .message = "exception causes must derive from BaseException" }, line, column, null);
                    return false;
                }
            } else {
                self.setException(.{ .kind = .type_error, .message = "exception causes must derive from BaseException" }, line, column, null);
                return false;
            }
        }
        self.raiseExisting(instance, line, column, true);
        return false;
    }

    fn forgetGeneratorFrame(self: *Runtime, frame: *Frame) void {
        _ = self;
        if (frame.generator_owner) |owner| {
            if (owner.generator_frame == @as(*anyopaque, @ptrCast(frame))) {
                owner.generator_frame = null;
                owner.generator_roots = &.{};
                owner.generator_done = true;
            }
        }
    }

    fn executeCall(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
        if (self.sync_task) |task| {
            const frame = self.top_frame orelse return self.engineFault();
            if (task.frame == frame and frame.ip != 0 and task.call_ip == frame.ip - 1) return self.advanceSyncTask();
        }
        const code = self.activeCode() orelse return self.engineFault();
        const site_index: usize = instruction.index32();
        if (site_index >= code.call_sites.len) return self.engineFault();
        const site = code.call_sites[site_index];
        const start: usize = site.argument_start;
        const count: usize = site.argument_count;
        if (start > code.call_arguments.len or count > code.call_arguments.len - start) return self.engineFault();

        const allocator = self.heap.allocator;
        const positional_object = switch (sequence.createList(&self.heap, &.{})) {
            .value => |list| list,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        var call_roots = [_]gc.Root{
            .{ .object = &positional_object.header },
            .{ .object = null },
            .{ .object = null },
        };
        var call_root_frame = gc.RootFrame{};
        call_root_frame.push(&self.heap.roots);
        for (&call_roots) |*root| call_root_frame.add(root);
        var call_roots_active = true;
        defer if (call_roots_active) call_root_frame.pop();

        var keyword_capacity = count;
        for (code.call_arguments[start..][0..count]) |argument| {
            if (!argument.double_starred) continue;
            if (!self.validRegister(argument.register)) return self.engineFault();
            const mapping_header = self.registers[argument.register].asObject() orelse return self.engineFault();
            const mapping = dict_module.dictFromHeader(mapping_header) orelse return self.engineFault();
            keyword_capacity = std.math.add(usize, keyword_capacity, mapping.size) catch {
                self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
                return false;
            };
        }
        const keywords = allocator.alloc(binder.Keyword, keyword_capacity) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer allocator.free(keywords);
        var keyword_count: usize = 0;
        for (code.call_arguments[start..][0..count]) |argument| {
            if (!self.validRegister(argument.register)) return self.engineFault();
            const value = self.registers[argument.register];
            if (argument.double_starred) {
                const mapping_header = value.asObject() orelse return self.engineFault();
                const mapping = dict_module.dictFromHeader(mapping_header) orelse return self.engineFault();
                for (mapping.entries.items) |entry| {
                    if (!entry.alive) continue;
                    const key_header = entry.key.asObject() orelse return self.nativeTypeError(line, column, "keywords must be strings");
                    const key = string.fromHeader(key_header) orelse return self.nativeTypeError(line, column, "keywords must be strings");
                    if (!self.appendCallKeyword(keywords, &keyword_count, string.content(key), entry.value, line, column)) return false;
                }
            } else if (argument.keyword_name == std.math.maxInt(u32)) {
                if (argument.starred) {
                    const expanded = switch (iterator.createIterator(&self.heap, value)) {
                        .value => |selected| selected,
                        .python_exception => |exception| {
                            self.setException(exception, line, column, null);
                            return false;
                        },
                        .engine_error => return self.engineFault(),
                    };
                    call_roots[2].object = &expanded.header;
                    while (true) {
                        switch (iterator.next(&self.heap, expanded)) {
                            .item => |item| {
                                call_roots[1].object = item.asObject();
                                switch (sequence.append(&self.heap, positional_object, item)) {
                                    .value => {},
                                    .python_exception => |exception| {
                                        self.setException(exception, line, column, null);
                                        return false;
                                    },
                                    .engine_error => return self.engineFault(),
                                }
                            },
                            .done => break,
                            .suspended => return self.engineFault(),
                            .python_exception => |exception| {
                                self.setException(exception, line, column, null);
                                return false;
                            },
                            .engine_error => return self.engineFault(),
                        }
                    }
                    call_roots[2].object = null;
                } else {
                    call_roots[1].object = value.asObject();
                    switch (sequence.append(&self.heap, positional_object, value)) {
                        .value => {},
                        .python_exception => |exception| {
                            self.setException(exception, line, column, null);
                            return false;
                        },
                        .engine_error => return self.engineFault(),
                    }
                }
            } else {
                const name = self.codeName(argument.keyword_name) orelse return self.engineFault();
                if (!self.appendCallKeyword(keywords, &keyword_count, name, value, line, column)) return false;
            }
        }
        var positional = positional_object.items.items;
        var callee = self.registers[instruction.a()];
        if (callee.asExceptionClass()) |class_index| {
            if (class_index == std.math.maxInt(u8)) return self.nativeTypeError(line, column, "'NotImplementedType' object is not callable");
            if (class_index >= exceptions.allKinds.len) return self.engineFault();
            return self.executeExceptionConstructor(instruction.a(), exceptions.allKinds[class_index], positional, keywords[0..keyword_count], line, column);
        }
        var header = callee.asObject() orelse {
            self.setException(.{ .kind = .type_error, .message = "object is not callable" }, line, column, null);
            return false;
        };
        var constructor_instance: ?Value = null;
        if (class_module.classFromHeader(header)) |user_class| {
            if (self.typeClass()) |type_class| {
                if (user_class == type_class) {
                    if (keyword_count != 0 or positional.len != 1) return self.nativeTypeError(line, column, "type() takes exactly one argument");
                    const type_header = self.type_class_root.object orelse return self.engineFault();
                    const value_header = positional[0].asObject() orelse {
                        self.setRegister(instruction.a(), Value.object(type_header));
                        return true;
                    };
                    if (class_module.instanceFromHeader(value_header)) |instance| {
                        self.setRegister(instruction.a(), Value.object(&instance.class.header));
                        return true;
                    }
                    self.setRegister(instruction.a(), Value.object(type_header));
                    return true;
                }
            }
            const instance_result = class_module.createInstance(&self.heap, user_class);
            const instance = switch (instance_result) {
                .value => |selected| selected,
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            };
            const instance_value = Value.object(&instance.header);
            call_roots[1].object = &instance.header;
            const initializer = class_module.classAttribute(user_class, "__init__") orelse {
                if (positional.len != 0 or keyword_count != 0) return self.nativeTypeError(line, column, "object takes no arguments");
                self.setRegister(instruction.a(), instance_value);
                return true;
            };
            const method = switch (class_module.createBoundMethod(&self.heap, initializer, instance_value)) {
                .value => |selected| selected,
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            };
            self.setRegister(instruction.a(), Value.object(&method.header));
            constructor_instance = instance_value;
            callee = Value.object(&method.header);
            header = &method.header;
        }
        if (exceptions.classFromHeader(header)) |exception_class| {
            if (keyword_count != 0 or positional.len > 1) {
                self.setException(.{ .kind = .type_error, .message = "exception constructor takes at most one message" }, line, column, null);
                return false;
            }
            const message = if (positional.len == 0) "" else self.valueString(positional[0]) orelse {
                self.setException(.{ .kind = .type_error, .message = "exception message must be a string" }, line, column, null);
                return false;
            };
            switch (exceptions.createInstance(&self.heap, exception_class.kind, message)) {
                .value => |instance| self.setRegister(instruction.a(), Value.object(&instance.header)),
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            }
            return true;
        }
        if (class_module.boundMethodFromHeader(header)) |bound_method| {
            positional_object.items.insert(allocator, 0, bound_method.receiver) catch {
                self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
                return false;
            };
            positional = positional_object.items.items;
            header = bound_method.callable.asObject() orelse return self.engineFault();
        }
        if (class_module.instanceFromHeader(header)) |instance| {
            if (class_module.classAttribute(instance.class, "__call__") != null) {
                if (keyword_count != 0) return self.nativeTypeError(line, column, "callable instance keyword arguments are not supported yet");
                const result = self.invokeSpecialSync(Value.object(header), "__call__", positional, line, column) orelse return false;
                self.setRegister(instruction.a(), result);
                return true;
            }
        }
        const function = functions.functionFromHeader(header) orelse {
            self.setException(.{ .kind = .type_error, .message = "object is not callable" }, line, column, null);
            return false;
        };
        if (function.native) |native| {
            const resumable_native = switch (native) {
                .list, .tuple, .sorted, .next, .list_sort, .generator_send => true,
                else => false,
            };
            if (resumable_native and self.sync_callback_depth == 0 and self.resuming_generator == null) {
                call_root_frame.pop();
                call_roots_active = false;
            }
            return self.executeNativeCall(instruction.a(), native, function.bound_self, positional, keywords[0..keyword_count], line, column);
        }

        const function_code = function.code orelse return self.engineFault();
        const binding = binder.bindFunction(
            &self.heap,
            allocator,
            function_code.parameter_names,
            function_code.parameter_flags,
            function.defaults,
            positional,
            keywords[0..keyword_count],
        ) catch |err| {
            self.setBinderException(err, line, column);
            return false;
        };
        const bound = binding.values;
        defer allocator.free(bound);
        defer if (binding.extra_keywords.len != 0) allocator.free(binding.extra_keywords);
        for (function_code.parameter_flags, 0..) |flags, index| {
            if (flags & binder.parameter_flags_module.var_positional != 0) {
                call_roots[1].object = bound[index].asObject();
            }
            if (flags & binder.parameter_flags_module.var_keyword != 0) {
                const created = dict_module.create(&self.heap, false);
                const mapping = switch (created) {
                    .value => |selected| selected,
                    .python_exception => |exception| {
                        self.setException(exception, line, column, null);
                        return false;
                    },
                    .engine_error => return self.engineFault(),
                };
                call_roots[2].object = &mapping.header;
                for (binding.extra_keywords) |keyword| {
                    const key = switch (string.create(&self.heap, keyword.name)) {
                        .value => |selected| Value.object(&selected.header),
                        .python_exception => |exception| {
                            self.setException(exception, line, column, null);
                            return false;
                        },
                        .engine_error => return self.engineFault(),
                    };
                    if (!self.setMappingValue(mapping, key, keyword.value, line, column)) return false;
                }
                bound[index] = Value.object(&mapping.header);
            }
        }
        const bound_roots = allocator.alloc(gc.Root, bound.len) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer allocator.free(bound_roots);
        for (bound, 0..) |value, index| bound_roots[index] = .{ .object = value.asObject() };
        var bound_root_frame = gc.RootFrame{};
        bound_root_frame.push(&self.heap.roots);
        for (bound_roots) |*root| bound_root_frame.add(root);
        var bound_roots_active = true;
        defer if (bound_roots_active) bound_root_frame.pop();
        if (function_code.flags & bytecode.code_flags.generator != 0) {
            if (constructor_instance != null) return self.nativeTypeError(line, column, "__init__() should return None");
            return switch (iterator.createFunctionGenerator(&self.heap, Value.object(&function.header), bound)) {
                .value => |selected| blk: {
                    self.setRegister(instruction.a(), Value.object(&selected.header));
                    break :blk true;
                },
                .python_exception => |exception| blk: {
                    self.setException(exception, line, column, null);
                    break :blk false;
                },
                .engine_error => self.engineFault(),
            };
        }
        const frame = self.allocateFrame(function_code, instruction.a()) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        // Re-link the caller, frame and stable bound-value roots in strict LIFO
        // order. The bound roots stay above the frame until every cell is
        // created and initialized, so later cell allocations cannot sweep a
        // value whose provisional frame root has already become a Cell root.
        frame.root_frame.pop();
        bound_root_frame.pop();
        bound_roots_active = false;
        call_root_frame.pop();
        call_roots_active = false;
        frame.root_frame.push(&self.heap.roots);
        for (frame.roots) |*root| frame.root_frame.add(root);
        if (constructor_instance) |instance| {
            frame.return_override = instance;
            frame.override_requires_none = true;
            frame.roots[frame.returnOverrideRootIndex()].object = instance.asObject();
        }
        bound_root_frame.push(&self.heap.roots);
        for (bound_roots) |*root| bound_root_frame.add(root);
        bound_roots_active = true;
        for (function_code.parameter_names, 0..) |name, index| {
            const value = bound[index];
            if (indexOfName(function_code.local_names, name)) |local_index| {
                frame.locals[local_index] = value;
                frame.roots[frame.localRootStart() + local_index].object = value.asObject();
            } else if (indexOfName(function_code.cell_names, name)) |cell_index| {
                frame.roots[frame.cellRootStart() + cell_index].object = value.asObject();
            } else return self.engineFault();
        }
        if (function.cells.len != function_code.free_names.len) return self.engineFault();
        for (function.cells, 0..) |cell, index| {
            frame.free_cells[index] = cell;
            frame.roots[frame.freeRootStart() + index].object = &cell.header;
        }
        for (function_code.cell_names, 0..) |name, index| {
            const cell = functions.createCell(&self.heap, Value.unboundValue()) catch {
                self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
                return false;
            };
            frame.local_cells[index] = cell;
            frame.roots[frame.cellRootStart() + index].object = &cell.header;
            _ = name;
        }
        for (function_code.parameter_names, 0..) |name, index| {
            if (!self.storeFrameLocal(frame, name, bound[index])) return self.engineFault();
        }
        bound_root_frame.pop();
        bound_roots_active = false;
        return true;
    }

    fn executeExceptionConstructor(self: *Runtime, destination: u16, kind: PythonExceptionKind, positional: []const Value, keywords: []const binder.Keyword, line: u32, column: u32) bool {
        if (keywords.len != 0 or positional.len > 1) {
            self.setException(.{ .kind = .type_error, .message = "exception constructor takes at most one message" }, line, column, null);
            return false;
        }
        const message = if (positional.len == 0) "" else self.valueString(positional[0]) orelse {
            self.setException(.{ .kind = .type_error, .message = "exception message must be a string" }, line, column, null);
            return false;
        };
        switch (exceptions.createInstance(&self.heap, kind, message)) {
            .value => |instance| self.setRegister(destination, Value.object(&instance.header)),
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        }
        return true;
    }

    fn appendCallKeyword(self: *Runtime, keywords: []binder.Keyword, count: *usize, name: []const u8, value: Value, line: u32, column: u32) bool {
        for (keywords[0..count.*]) |previous| {
            if (std.mem.eql(u8, previous.name, name)) {
                self.setException(.{ .kind = .type_error, .message = "got multiple values for keyword argument" }, line, column, null);
                return false;
            }
        }
        if (count.* >= keywords.len) return self.engineFault();
        keywords[count.*] = .{ .name = name, .value = value };
        count.* += 1;
        return true;
    }

    fn executeMaterializeStar(self: *Runtime, register: u16, line: u32, column: u32) bool {
        const source = self.registers[register];
        const created_iterator = iterator.createIterator(&self.heap, source);
        const iter = switch (created_iterator) {
            .value => |selected| selected,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        var iterator_root = gc.Root{ .object = &iter.header };
        var list_root = gc.Root{ .object = null };
        var item_root = gc.Root{ .object = null };
        var roots = gc.RootFrame{};
        roots.push(&self.heap.roots);
        roots.add(&iterator_root);
        roots.add(&list_root);
        roots.add(&item_root);
        defer roots.pop();

        const created_list = sequence.createList(&self.heap, &.{});
        const list = switch (created_list) {
            .value => |selected| selected,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        list_root.object = &list.header;
        while (true) {
            switch (iterator.next(&self.heap, iter)) {
                .item => |item| {
                    item_root.object = item.asObject();
                    switch (sequence.append(&self.heap, list, item)) {
                        .value => {},
                        .python_exception => |exception| {
                            self.setException(exception, line, column, null);
                            return false;
                        },
                        .engine_error => return self.engineFault(),
                    }
                },
                .done => break,
                .suspended => return self.engineFault(),
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            }
        }
        self.setRegister(register, Value.object(&list.header));
        return true;
    }

    fn extendListFromIterable(self: *Runtime, destination: u16, list: *sequence.List, source: Value, line: u32, column: u32) bool {
        var list_root = gc.Root{ .object = &list.header };
        var source_root = gc.Root{ .object = source.asObject() };
        var iterator_root = gc.Root{ .object = null };
        var item_root = gc.Root{ .object = null };
        var roots = gc.RootFrame{};
        roots.push(&self.heap.roots);
        roots.add(&list_root);
        roots.add(&source_root);
        roots.add(&iterator_root);
        roots.add(&item_root);
        defer roots.pop();

        if (source.asObject()) |source_header| {
            if (sequence.listFromHeader(source_header)) |other| {
                return self.storeVoidResult(destination, sequence.extend(&self.heap, list, other.items.items), line, column);
            }
            if (sequence.tupleFromHeader(source_header)) |other| {
                return self.storeVoidResult(destination, sequence.extend(&self.heap, list, other.items), line, column);
            }
        }
        const created = iterator.createIterator(&self.heap, source);
        const iter = switch (created) {
            .value => |selected| selected,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        iterator_root.object = &iter.header;
        while (true) {
            switch (iterator.next(&self.heap, iter)) {
                .item => |value| {
                    item_root.object = value.asObject();
                    switch (sequence.append(&self.heap, list, value)) {
                        .value => {},
                        .python_exception => |exception| {
                            self.setException(exception, line, column, null);
                            return false;
                        },
                        .engine_error => return self.engineFault(),
                    }
                },
                .done => break,
                .suspended => return self.engineFault(),
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            }
        }
        self.setRegister(destination, Value.noneValue());
        return true;
    }

    fn executeNativeCall(
        self: *Runtime,
        destination: u16,
        native: functions.Native,
        bound_self: Value,
        positional: []const Value,
        keywords: []const binder.Keyword,
        line: u32,
        column: u32,
    ) bool {
        switch (native) {
            .print => {
                const arguments = binder.bindPrint(positional, keywords) catch |err| {
                    self.setBinderException(err, line, column);
                    return false;
                };
                var separator: []const u8 = " ";
                var ending: []const u8 = "\n";
                if (arguments.separator) |value| {
                    if (value.tag() != .none) {
                        const header = value.asObject() orelse {
                            self.setException(.{ .kind = .type_error, .message = "sep must be None or a string" }, line, column, null);
                            return false;
                        };
                        const text = string.fromHeader(header) orelse {
                            self.setException(.{ .kind = .type_error, .message = "sep must be None or a string" }, line, column, null);
                            return false;
                        };
                        separator = string.content(text);
                    }
                }
                if (arguments.ending) |value| {
                    if (value.tag() != .none) {
                        const header = value.asObject() orelse {
                            self.setException(.{ .kind = .type_error, .message = "end must be None or a string" }, line, column, null);
                            return false;
                        };
                        const text = string.fromHeader(header) orelse {
                            self.setException(.{ .kind = .type_error, .message = "end must be None or a string" }, line, column, null);
                            return false;
                        };
                        ending = string.content(text);
                    }
                }
                if (!self.executePrintValues(arguments.values, separator, ending, line, column)) return false;
                if (arguments.flush) |flush_value| {
                    const should_flush = self.valueTruthy(flush_value, line, column) orelse return false;
                    if (should_flush and !self.beginOutputEvent(line, column)) return false;
                }
                self.setRegister(destination, Value.noneValue());
                return true;
            },
            .input => {
                if (positional.len > 1 or keywords.len != 0) return self.nativeArity(line, column);
                const prompt = if (positional.len == 0) &.{} else self.renderValueOwned(positional[0], false, line, column) orelse return false;
                defer if (positional.len != 0) self.heap.allocator.free(prompt);
                return self.beginInputRequest(destination, prompt, line, column);
            },
            .range => {
                const arguments = binder.bindRange(positional, keywords) catch |err| {
                    self.setBinderException(err, line, column);
                    return false;
                };
                switch (iterator.createRange(&self.heap, &arguments)) {
                    .value => |range| self.setRegister(destination, Value.object(&range.header)),
                    .python_exception => |exception| {
                        self.setException(exception, line, column, null);
                        return false;
                    },
                    .engine_error => return self.engineFault(),
                }
                return true;
            },
            .open => return self.executeOpen(destination, positional, keywords, line, column),
            else => return self.executeOtherNativeCall(destination, native, bound_self, positional, keywords, line, column),
        }
    }

    fn executeOtherNativeCall(
        self: *Runtime,
        destination: u16,
        native: functions.Native,
        bound_self: Value,
        positional: []const Value,
        keywords: []const binder.Keyword,
        line: u32,
        column: u32,
    ) bool {
        switch (native) {
            .isinstance_builtin => {
                if (positional.len != 2 or keywords.len != 0) return self.nativeArity(line, column);
                const target_header = positional[1].asObject() orelse return self.nativeTypeError(line, column, "isinstance() arg 2 must be a type");
                const target = class_module.classFromHeader(target_header) orelse return self.nativeTypeError(line, column, "isinstance() arg 2 must be a type");
                const actual_header = positional[0].asObject() orelse {
                    const is_exception_type = if (positional[0].asExceptionClass()) |index| index < exceptions.allKinds.len else false;
                    self.setRegister(destination, if (target == self.typeClass() and is_exception_type) Value.trueValue() else Value.falseValue());
                    return true;
                };
                const actual = if (class_module.instanceFromHeader(actual_header)) |instance| instance.class else if (class_module.classFromHeader(actual_header) != null) self.typeClass() else null;
                self.setRegister(destination, if (actual) |selected| if (mroContains(selected, target)) Value.trueValue() else Value.falseValue() else Value.falseValue());
                return true;
            },
            .issubclass_builtin => {
                if (positional.len != 2 or keywords.len != 0) return self.nativeArity(line, column);
                const left_header = positional[0].asObject() orelse return self.nativeTypeError(line, column, "issubclass() arg 1 must be a class");
                const right_header = positional[1].asObject() orelse return self.nativeTypeError(line, column, "issubclass() arg 2 must be a class");
                const left = class_module.classFromHeader(left_header) orelse return self.nativeTypeError(line, column, "issubclass() arg 1 must be a class");
                const right = class_module.classFromHeader(right_header) orelse return self.nativeTypeError(line, column, "issubclass() arg 2 must be a class");
                self.setRegister(destination, if (mroContains(left, right)) Value.trueValue() else Value.falseValue());
                return true;
            },
            .callable_builtin => {
                if (positional.len != 1 or keywords.len != 0) return self.nativeArity(line, column);
                self.setRegister(destination, if (self.isCallable(positional[0])) Value.trueValue() else Value.falseValue());
                return true;
            },
            .bool_constructor => {
                if (positional.len > 1 or keywords.len != 0) return self.nativeArity(line, column);
                const truth = if (positional.len == 0) false else self.valueTruthy(positional[0], line, column) orelse return false;
                self.setRegister(destination, if (truth) Value.trueValue() else Value.falseValue());
                return true;
            },
            .getattr_builtin => {
                if ((positional.len != 2 and positional.len != 3) or keywords.len != 0) return self.nativeArity(line, column);
                const name = self.valueString(positional[1]) orelse return self.nativeTypeError(line, column, "attribute name must be string");
                if (self.lookupAttributeValue(positional[0], name, line, column)) |value| {
                    self.setRegister(destination, value);
                    return true;
                }
                if (self.last_exception) |exception| {
                    if (positional.len != 3 or exception.kind != .attribute_error) return false;
                    self.suppressAttributeError();
                }
                if (positional.len == 3) {
                    self.setRegister(destination, positional[2]);
                    return true;
                }
                return self.nativeAttributeError(line, column, "object has no such attribute");
            },
            .hasattr_builtin => {
                if (positional.len != 2 or keywords.len != 0) return self.nativeArity(line, column);
                const name = self.valueString(positional[1]) orelse return self.nativeTypeError(line, column, "attribute name must be string");
                if (self.lookupAttributeValue(positional[0], name, line, column)) |_| {
                    self.setRegister(destination, Value.trueValue());
                    return true;
                }
                if (self.last_exception) |exception| {
                    if (exception.kind != .attribute_error) return false;
                    self.suppressAttributeError();
                }
                self.setRegister(destination, Value.falseValue());
                return true;
            },
            .setattr_builtin => {
                if (positional.len != 3 or keywords.len != 0) return self.nativeArity(line, column);
                const name = self.valueString(positional[1]) orelse return self.nativeTypeError(line, column, "attribute name must be string");
                if (!self.setUserAttribute(positional[0], name, positional[2], line, column)) return false;
                self.setRegister(destination, Value.noneValue());
                return true;
            },
            .delattr_builtin => {
                if (positional.len != 2 or keywords.len != 0) return self.nativeArity(line, column);
                const name = self.valueString(positional[1]) orelse return self.nativeTypeError(line, column, "attribute name must be string");
                if (!self.deleteUserAttribute(positional[0], name, line, column)) return false;
                self.setRegister(destination, Value.noneValue());
                return true;
            },
            .repr_builtin => {
                if (positional.len != 1 or keywords.len != 0) return self.nativeArity(line, column);
                const owned = self.renderValueOwned(positional[0], true, line, column) orelse return false;
                defer self.heap.allocator.free(owned);
                return self.storeStringResult(destination, string.create(&self.heap, owned), line, column);
            },
            .property_builtin => {
                if (positional.len > 4 or keywords.len != 0) return self.nativeArity(line, column);
                const getter = if (positional.len > 0) positional[0] else Value.noneValue();
                const setter = if (positional.len > 1) positional[1] else Value.noneValue();
                const deleter = if (positional.len > 2) positional[2] else Value.noneValue();
                const descriptor = switch (class_module.createDescriptor(&self.heap, .property, getter)) {
                    .value => |selected| selected,
                    .python_exception => |exception| {
                        self.setException(exception, line, column, null);
                        return false;
                    },
                    .engine_error => return self.engineFault(),
                };
                descriptor.setter = setter;
                descriptor.deleter = deleter;
                self.setRegister(destination, Value.object(&descriptor.header));
                return true;
            },
            .staticmethod_builtin, .classmethod_builtin => {
                if (positional.len != 1 or keywords.len != 0) return self.nativeArity(line, column);
                const kind: class_module.DescriptorKind = if (native == .staticmethod_builtin) .staticmethod else .classmethod;
                return switch (class_module.createDescriptor(&self.heap, kind, positional[0])) {
                    .value => |descriptor| blk: {
                        self.setRegister(destination, Value.object(&descriptor.header));
                        break :blk true;
                    },
                    .python_exception => |exception| blk: {
                        self.setException(exception, line, column, null);
                        break :blk false;
                    },
                    .engine_error => self.engineFault(),
                };
            },
            .descriptor_setter, .descriptor_deleter => {
                if (positional.len != 1 or keywords.len != 0) return self.nativeArity(line, column);
                const descriptor_header = bound_self.asObject() orelse return self.engineFault();
                const descriptor = class_module.descriptorFromHeader(descriptor_header) orelse return self.engineFault();
                if (descriptor.kind != .property) return self.engineFault();
                const copy = class_module.copyProperty(
                    &self.heap,
                    descriptor,
                    if (native == .descriptor_setter) positional[0] else null,
                    if (native == .descriptor_deleter) positional[0] else null,
                );
                return switch (copy) {
                    .value => |selected| blk: {
                        self.setRegister(destination, Value.object(&selected.header));
                        break :blk true;
                    },
                    .python_exception => |exception| blk: {
                        self.setException(exception, line, column, null);
                        break :blk false;
                    },
                    .engine_error => self.engineFault(),
                };
            },
            .super_builtin => {
                if (keywords.len != 0 or (positional.len != 0 and positional.len != 2)) return self.nativeArity(line, column);
                var start_class: *class_module.Class = undefined;
                var receiver: Value = undefined;
                if (positional.len == 2) {
                    const start_header = positional[0].asObject() orelse return self.nativeTypeError(line, column, "super() argument 1 must be a type");
                    start_class = class_module.classFromHeader(start_header) orelse return self.nativeTypeError(line, column, "super() argument 1 must be a type");
                    receiver = positional[1];
                } else {
                    const frame = self.top_frame orelse return self.nativeTypeError(line, column, "super(): no current frame");
                    const class_cell = self.findCell("__class__") orelse return self.nativeTypeError(line, column, "super(): no __class__ cell");
                    const class_header = class_cell.value.asObject() orelse return self.nativeTypeError(line, column, "super(): __class__ is not a type");
                    start_class = class_module.classFromHeader(class_header) orelse return self.nativeTypeError(line, column, "super(): __class__ is not a type");
                    if (frame.code.parameter_names.len == 0) return self.nativeTypeError(line, column, "super(): no arguments");
                    receiver = frameNameValue(frame, frame.code.parameter_names[0]) orelse return self.nativeTypeError(line, column, "super(): first argument is unbound");
                }
                const owner = if (receiver.asObject()) |receiver_header| blk: {
                    if (class_module.instanceFromHeader(receiver_header)) |instance| break :blk instance.class;
                    if (class_module.classFromHeader(receiver_header)) |class| break :blk class;
                    break :blk null;
                } else null;
                const owner_class = owner orelse return self.nativeTypeError(line, column, "super(type, obj): obj must be an instance or subtype of type");
                if (!mroContains(owner_class, start_class)) return self.nativeTypeError(line, column, "super(type, obj): obj must be an instance or subtype of type");
                return switch (class_module.createSuper(&self.heap, start_class, receiver, owner_class)) {
                    .value => |selected| blk: {
                        self.setRegister(destination, Value.object(&selected.header));
                        break :blk true;
                    },
                    .python_exception => |exception| blk: {
                        self.setException(exception, line, column, null);
                        break :blk false;
                    },
                    .engine_error => self.engineFault(),
                };
            },
            .hash => {
                if (positional.len != 1 or keywords.len != 0) return self.nativeArity(line, column);
                const key_hash = self.pythonHash(positional[0], line, column) orelse return false;
                const signed: i64 = @bitCast(key_hash);
                const value = number.fromInt(&self.heap, signed);
                return self.storeValueResult(destination, value, line, column);
            },
            .str_constructor => {
                if (positional.len > 1 or keywords.len != 0) return self.nativeArity(line, column);
                const owned = if (positional.len == 0) blk: {
                    break :blk self.heap.allocator.dupe(u8, "") catch {
                        self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
                        return false;
                    };
                } else self.renderValueOwned(positional[0], false, line, column) orelse return false;
                defer self.heap.allocator.free(owned);
                return self.storeStringResult(destination, string.create(&self.heap, owned), line, column);
            },
            .format_builtin => {
                if (positional.len == 0 or positional.len > 2 or keywords.len != 0) return self.nativeArity(line, column);
                const spec = if (positional.len == 2) self.valueString(positional[1]) orelse return self.nativeTypeError(line, column, "format specifier must be a string") else "";
                return self.executeFormatValue(destination, positional[0], spec, 0, line, column);
            },
            .map, .filter => {
                if (keywords.len != 0 or (native == .filter and positional.len != 2) or (native == .map and positional.len < 2)) return self.nativeArity(line, column);
                const created = iterator.createMapFilter(&self.heap, native == .filter, positional[0], positional[1..]);
                return self.storeIteratorOutcome(destination, created, line, column);
            },
            .sorted => {
                if (positional.len != 1 or keywords.len > 2) return self.nativeArity(line, column);
                var reverse = false;
                var key: ?Value = null;
                for (keywords) |keyword| {
                    if (std.mem.eql(u8, keyword.name, "reverse")) reverse = self.valueTruthy(keyword.value, line, column) orelse return false else if (std.mem.eql(u8, keyword.name, "key")) {
                        if (keyword.value.tag() != .none and !self.isCallable(keyword.value)) return self.nativeTypeError(line, column, "key must be callable or None");
                        if (keyword.value.tag() != .none) key = keyword.value;
                    } else return self.nativeTypeError(line, column, "unexpected keyword argument");
                }
                if (self.sync_callback_depth == 0 and self.resuming_generator == null) {
                    return self.startSortedTask(destination, positional[0], key, reverse, line, column);
                }
                const list_result = sequence.createList(&self.heap, &.{});
                const list = switch (list_result) {
                    .value => |selected| selected,
                    .python_exception => |exception| {
                        self.setException(exception, line, column, null);
                        return false;
                    },
                    .engine_error => return self.engineFault(),
                };
                var list_root = gc.Root{ .object = &list.header };
                var root_frame = gc.RootFrame{};
                root_frame.push(&self.heap.roots);
                root_frame.add(&list_root);
                defer root_frame.pop();
                if (!self.extendListFromIterable(destination, list, positional[0], line, column)) return false;
                if (!self.sortListWithKey(list, key, reverse, destination, line, column)) return false;
                self.setRegister(destination, Value.object(&list.header));
                return true;
            },
            .dict, .set => return self.executeMappingConstructor(destination, native == .set, positional, keywords, line, column),
            .dict_get,
            .dict_keys,
            .dict_values,
            .dict_items,
            .dict_pop,
            .dict_setdefault,
            .dict_update,
            .dict_clear,
            .dict_copy,
            .set_add,
            .set_remove,
            .set_discard,
            .set_pop,
            .set_update,
            .set_clear,
            .set_copy,
            => return self.executeMappingMethod(destination, native, bound_self, positional, keywords, line, column),
            .list_append, .list_extend, .list_insert, .list_pop, .list_remove, .list_clear, .list_index, .list_count, .list_reverse, .list_copy, .list_sort => {
                const header = bound_self.asObject() orelse return self.engineFault();
                const list = sequence.listFromHeader(header) orelse return self.engineFault();
                if (native == .list_sort) {
                    if (positional.len != 0 or keywords.len > 2) return self.nativeTypeError(line, column, "invalid list.sort arguments");
                    var reverse = false;
                    var key: ?Value = null;
                    for (keywords) |keyword| {
                        if (std.mem.eql(u8, keyword.name, "reverse")) {
                            reverse = self.valueTruthy(keyword.value, line, column) orelse return false;
                        } else if (std.mem.eql(u8, keyword.name, "key")) {
                            if (keyword.value.tag() != .none and !self.isCallable(keyword.value)) return self.nativeTypeError(line, column, "key must be callable or None");
                            if (keyword.value.tag() != .none) key = keyword.value;
                        } else return self.nativeTypeError(line, column, "invalid list.sort arguments");
                    }
                    if (self.sync_callback_depth == 0 and self.resuming_generator == null) {
                        return self.startListSortTask(destination, list, key, reverse, line, column);
                    }
                    if (!self.sortListWithKey(list, key, reverse, destination, line, column)) return false;
                    self.setRegister(destination, Value.noneValue());
                    return true;
                }
                if (keywords.len != 0) return self.nativeTypeError(line, column, "list method does not accept keyword arguments");
                switch (native) {
                    .list_append => {
                        if (positional.len != 1) return self.nativeArity(line, column);
                        return self.storeVoidResult(destination, sequence.append(&self.heap, list, positional[0]), line, column);
                    },
                    .list_extend => {
                        if (positional.len != 1) return self.nativeArity(line, column);
                        return self.extendListFromIterable(destination, list, positional[0], line, column);
                    },
                    .list_insert => {
                        if (positional.len != 2) return self.nativeArity(line, column);
                        return self.storeVoidResult(destination, sequence.insert(&self.heap, list, positional[0], positional[1]), line, column);
                    },
                    .list_pop => {
                        if (positional.len > 1) return self.nativeArity(line, column);
                        const index_value = if (positional.len == 0) Value.fromSmallInt(-1).? else positional[0];
                        if (!number.isIntegerValue(index_value)) return self.nativeTypeError(line, column, "'pop' index must be an integer");
                        if (index_value.asBool() == null and number.toInt(i64, index_value) == null) {
                            self.setException(.{ .kind = .overflow_error, .message = "Python int too large to convert to C ssize_t" }, line, column, null);
                            return false;
                        }
                        const index = sequence.getIndex(list.items.items.len, index_value);
                        const position = switch (index) {
                            .value => |value| value,
                            .python_exception => |exception| {
                                self.setException(exception, line, column, null);
                                return false;
                            },
                            .engine_error => return self.engineFault(),
                        };
                        return self.storeValueResult(destination, sequence.pop(list, position), line, column);
                    },
                    .list_remove => {
                        if (positional.len != 1) return self.nativeArity(line, column);
                        const index = self.findListItem(list, positional[0], line, column) orelse return false;
                        return self.storeVoidResult(destination, sequence.remove(&self.heap, list, index), line, column);
                    },
                    .list_clear => {
                        if (positional.len != 0) return self.nativeArity(line, column);
                        sequence.clear(&self.heap, list);
                        self.setRegister(destination, Value.noneValue());
                        return true;
                    },
                    .list_index, .list_count => {
                        if ((native == .list_count and positional.len != 1) or (native == .list_index and (positional.len < 1 or positional.len > 3))) return self.nativeArity(line, column);
                        const length = list.items.items.len;
                        const start = if (native == .list_index and positional.len >= 2) self.normalizeSearchBound(positional[1], length, line, column) orelse return false else 0;
                        const stop = if (native == .list_index and positional.len >= 3) self.normalizeSearchBound(positional[2], length, line, column) orelse return false else length;
                        var count: usize = 0;
                        var found: ?usize = null;
                        for (list.items.items[start..@max(start, stop)], start..) |value, index| {
                            const equal = self.valuesEqual(value, positional[0], line, column) orelse return false;
                            if (equal) {
                                count += 1;
                                if (found == null) found = index;
                            }
                        }
                        if (native == .list_index and found == null) {
                            self.setException(.{ .kind = .value_error, .message = "value is not in list" }, line, column, null);
                            return false;
                        }
                        self.setRegister(destination, Value.fromSmallInt(@intCast(if (native == .list_count) count else found.?)).?);
                        return true;
                    },
                    .list_reverse => {
                        if (positional.len != 0) return self.nativeArity(line, column);
                        sequence.reverse(list);
                        self.setRegister(destination, Value.noneValue());
                        return true;
                    },
                    .list_copy => {
                        if (positional.len != 0) return self.nativeArity(line, column);
                        return self.storeListResult(destination, sequence.copy(&self.heap, list), line, column);
                    },
                    else => return self.engineFault(),
                }
            },
            .str_find, .str_index, .str_split, .str_join, .str_strip, .str_upper, .str_lower, .str_replace, .str_count, .str_startswith, .str_endswith, .str_encode, .str_format => {
                const header = bound_self.asObject() orelse return self.engineFault();
                const text = string.fromHeader(header) orelse return self.engineFault();
                if (native == .str_format) return self.executeStrFormat(destination, text, positional, keywords, line, column);
                return self.executeStringNative(destination, native, text, positional, keywords, line, column);
            },
            .bytes_split, .bytes_find, .bytes_decode => {
                const header = bound_self.asObject() orelse return self.engineFault();
                const data = byte_module.fromHeader(header) orelse return self.engineFault();
                return self.executeBytesNative(destination, native, data, positional, keywords, line, column);
            },
            .file_read,
            .file_readline,
            .file_readlines,
            .file_write,
            .file_writelines,
            .file_seek,
            .file_tell,
            .file_truncate,
            .file_flush,
            .file_close,
            => return self.executeFileNative(destination, native, bound_self, positional, keywords, line, column),
            .len => {
                if (positional.len != 1 or keywords.len != 0) return self.nativeArity(line, column);
                const value = positional[0];
                if (sequence.length(value)) |length_value| return self.setSmallInt(destination, length_value, line, column);
                if (value.asObject()) |value_header| if (class_module.instanceFromHeader(value_header) != null) {
                    const result = self.invokeSpecialSync(value, "__len__", &.{}, line, column) orelse {
                        if (self.last_exception == null) return self.nativeTypeError(line, column, "object has no length");
                        return false;
                    };
                    if (!number.isIntegerValue(result)) return self.nativeTypeError(line, column, "'__len__' should return an integer");
                    self.setRegister(destination, result);
                    return true;
                };
                if (dict_module.sizeOf(value)) |mapping_length| {
                    const length_value = std.math.cast(i64, mapping_length) orelse {
                        self.setException(.{ .kind = .overflow_error, .message = "Python int too large to convert to C ssize_t" }, line, column, null);
                        return false;
                    };
                    return self.setSmallInt(destination, length_value, line, column);
                }
                if (value.asObject()) |header| {
                    if (string.fromHeader(header)) |text| return self.setSmallInt(destination, string.length(text), line, column);
                    if (byte_module.fromHeader(header)) |data| return self.setSmallInt(destination, data.data.len, line, column);
                    if (iterator.rangeFromHeader(header)) |range| {
                        const count = iterator.rangeLength(&self.heap, range);
                        const length_value = switch (count) {
                            .value => |result| result,
                            .python_exception => |exception| {
                                self.setException(exception, line, column, null);
                                return false;
                            },
                            .engine_error => return self.engineFault(),
                        };
                        if (number.toInt(i64, length_value) == null) {
                            self.setException(.{ .kind = .overflow_error, .message = "Python int too large to convert to C ssize_t" }, line, column, null);
                            return false;
                        }
                        self.setRegister(destination, length_value);
                        return true;
                    }
                }
                return self.nativeTypeError(line, column, "object has no length");
            },
            .list, .tuple => {
                if (keywords.len != 0 or positional.len > 1) return self.nativeArity(line, column);
                if (positional.len == 0) {
                    if (native == .list) return self.storeListResult(destination, sequence.createList(&self.heap, &.{}), line, column);
                    return self.storeTupleResult(destination, sequence.createTuple(&self.heap, &.{}), line, column);
                }
                if (positional[0].asObject()) |source_header| if (class_module.instanceFromHeader(source_header)) |source_instance| {
                    if (class_module.classAttribute(source_instance.class, "__iter__") != null) return self.materializeSequenceImmediate(destination, positional[0], native == .tuple, line, column);
                };
                if (self.sync_callback_depth != 0 or self.resuming_generator != null) {
                    return self.materializeSequenceImmediate(destination, positional[0], native == .tuple, line, column);
                }
                return self.materializeSequence(destination, positional[0], native == .tuple, line, column);
            },
            .iter => {
                if (positional.len != 1 or keywords.len != 0) return self.nativeArity(line, column);
                return self.createIteratorResult(destination, positional[0], line, column);
            },
            .next => {
                if (positional.len != 1 or keywords.len != 0) return self.nativeArity(line, column);
                const header = positional[0].asObject() orelse return self.nativeTypeError(line, column, "object is not an iterator");
                const loop_iterator = iterator.iteratorFromHeader(header) orelse return self.nativeTypeError(line, column, "object is not an iterator");
                if (self.sync_callback_depth == 0 and self.resuming_generator == null) return self.startNextTask(destination, loop_iterator, line, column);
                return switch (self.nextIteratorValue(loop_iterator, destination, line, column)) {
                    .item => |value| blk: {
                        self.setRegister(destination, value);
                        break :blk true;
                    },
                    .suspended => self.engineFault(),
                    .done => blk: {
                        break :blk self.setIteratorStopIteration(loop_iterator, line, column);
                    },
                    .python_exception => |exception| blk: {
                        self.setException(exception, line, column, null);
                        break :blk false;
                    },
                    .engine_error => self.engineFault(),
                };
            },
            .generator_send => return self.executeGeneratorSend(destination, bound_self, positional, keywords, line, column),
            .generator_close => return self.executeGeneratorClose(destination, bound_self, positional, keywords, line, column),
            .slice => return self.executeSliceBuiltin(destination, positional, keywords, line, column),
            .enumerate => {
                if (keywords.len != 0 or positional.len == 0 or positional.len > 2) return self.nativeArity(line, column);
                const start = if (positional.len == 2) positional[1] else Value.fromSmallInt(0).?;
                return self.storeIteratorOutcome(destination, iterator.createEnumerate(&self.heap, positional[0], start), line, column);
            },
            .zip => {
                if (keywords.len != 0) return self.nativeArity(line, column);
                return self.storeIteratorOutcome(destination, iterator.createZip(&self.heap, positional), line, column);
            },
            .reversed => {
                if (keywords.len != 0 or positional.len != 1) return self.nativeArity(line, column);
                return self.storeIteratorOutcome(destination, iterator.createReversed(&self.heap, positional[0]), line, column);
            },
            else => return self.engineFault(),
        }
    }

    fn executeGeneratorSend(
        self: *Runtime,
        destination: u16,
        bound_self: Value,
        positional: []const Value,
        keywords: []const binder.Keyword,
        line: u32,
        column: u32,
    ) bool {
        if (keywords.len != 0 or positional.len != 1) return self.nativeArity(line, column);
        const header = bound_self.asObject() orelse return self.engineFault();
        const selected = iterator.iteratorFromHeader(header) orelse return self.engineFault();
        if (selected.mode != .generator) return self.engineFault();
        if (!selected.started and positional[0].tag() != .none) return self.nativeTypeError(line, column, "can't send non-None value to a just-started generator");
        selected.generator_send_value = positional[0];
        if (self.sync_callback_depth == 0 and self.resuming_generator == null) return self.startNextTask(destination, selected, line, column);
        return switch (self.nextIteratorValue(selected, destination, line, column)) {
            .item => |value| blk: {
                self.setRegister(destination, value);
                break :blk true;
            },
            .done => self.setIteratorStopIteration(selected, line, column),
            .suspended => self.engineFault(),
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => self.engineFault(),
        };
    }

    fn executeGeneratorClose(
        self: *Runtime,
        destination: u16,
        bound_self: Value,
        positional: []const Value,
        keywords: []const binder.Keyword,
        line: u32,
        column: u32,
    ) bool {
        if (keywords.len != 0 or positional.len != 0) return self.nativeArity(line, column);
        const header = bound_self.asObject() orelse return self.engineFault();
        const selected = iterator.iteratorFromHeader(header) orelse return self.engineFault();
        if (selected.mode != .generator) return self.engineFault();
        if (selected.generator_done or !selected.started) {
            selected.generator_done = true;
            self.setRegister(destination, Value.noneValue());
            return true;
        }
        const saved_active = self.active_exception;
        const saved_root = self.exception_root.object;
        const saved_last = self.last_exception;
        selected.generator_closing = true;
        const result = self.resumeGenerator(selected, line, column);
        selected.generator_closing = false;
        switch (result) {
            .done => {
                self.active_exception = saved_active;
                self.exception_root.object = saved_root;
                self.last_exception = saved_last;
                if (saved_last == null) self.clearErrorText();
                self.setRegister(destination, Value.noneValue());
                return true;
            },
            .python_exception => |exception| {
                if (exception.kind == .generator_exit) {
                    self.active_exception = saved_active;
                    self.exception_root.object = saved_root;
                    self.last_exception = saved_last;
                    if (saved_last == null) self.clearErrorText();
                    self.setRegister(destination, Value.noneValue());
                    return true;
                }
                self.setException(exception, line, column, null);
                return false;
            },
            .item => {
                self.setException(.{ .kind = .runtime_error, .message = "generator ignored GeneratorExit" }, line, column, null);
                return false;
            },
            .suspended => return self.engineFault(),
            .engine_error => return self.engineFault(),
        }
    }

    fn executeOpen(self: *Runtime, destination: u16, positional: []const Value, keywords: []const binder.Keyword, line: u32, column: u32) bool {
        if (positional.len == 0 or positional.len > 2) return self.nativeArity(line, column);
        const path = self.valueString(positional[0]) orelse return self.nativeTypeError(line, column, "open() path must be a string");
        var mode: []const u8 = "r";
        var mode_supplied = positional.len > 1;
        if (mode_supplied) mode = self.valueString(positional[1]) orelse return self.nativeTypeError(line, column, "open() mode must be a string");
        var encoding: ?[]const u8 = null;
        var newline: ?[]const u8 = null;
        for (keywords) |keyword| {
            if (std.mem.eql(u8, keyword.name, "mode")) {
                if (mode_supplied) return self.nativeTypeError(line, column, "open() got multiple values for mode");
                mode = self.valueString(keyword.value) orelse return self.nativeTypeError(line, column, "open() mode must be a string");
                mode_supplied = true;
            } else if (std.mem.eql(u8, keyword.name, "encoding")) {
                if (keyword.value.tag() != .none) encoding = self.valueString(keyword.value) orelse return self.nativeTypeError(line, column, "encoding must be a string or None");
            } else if (std.mem.eql(u8, keyword.name, "newline")) {
                if (keyword.value.tag() != .none) newline = self.valueString(keyword.value) orelse return self.nativeTypeError(line, column, "newline must be a string or None");
            } else {
                return self.nativeTypeError(line, column, "unsupported open() argument");
            }
        }
        return switch (file_module.open(&self.heap, &self.vfs, path, mode, encoding, newline)) {
            .value => |file| blk: {
                self.setRegister(destination, Value.object(&file.header));
                break :blk true;
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => self.engineFault(),
        };
    }

    fn executeFileNative(
        self: *Runtime,
        destination: u16,
        native: functions.Native,
        bound_self: Value,
        positional: []const Value,
        keywords: []const binder.Keyword,
        line: u32,
        column: u32,
    ) bool {
        if (keywords.len != 0) return self.nativeTypeError(line, column, "file method does not accept keyword arguments");
        const header = bound_self.asObject() orelse return self.engineFault();
        const file = file_module.fromHeader(header) orelse return self.engineFault();
        var file_root = gc.Root{ .object = &file.header };
        var roots = gc.RootFrame{};
        roots.push(&self.heap.roots);
        roots.add(&file_root);
        defer roots.pop();

        switch (native) {
            .file_read, .file_readline => {
                if (positional.len > 1) return self.nativeArity(line, column);
                const size = if (positional.len == 0) null else self.fileInteger(positional[0], line, column) orelse return false;
                const result = file_module.readBuffer(&self.heap, file.fs, file, size, native == .file_readline);
                const contents = switch (result) {
                    .value => |selected| selected,
                    .python_exception => |exception| {
                        self.setException(exception, line, column, null);
                        return false;
                    },
                    .engine_error => return self.engineFault(),
                };
                defer if (contents.len != 0) self.heap.allocator.free(contents);
                if (file.mode.binary) return self.storeBytesResult(destination, byte_module.create(&self.heap, contents), line, column);
                return self.storeStringResult(destination, string.create(&self.heap, contents), line, column);
            },
            .file_readlines => {
                if (positional.len > 1) return self.nativeArity(line, column);
                const hint: i64 = if (positional.len == 0) -1 else self.fileInteger(positional[0], line, column) orelse return false;
                const created = sequence.createList(&self.heap, &.{});
                const list = switch (created) {
                    .value => |selected| selected,
                    .python_exception => |exception| {
                        self.setException(exception, line, column, null);
                        return false;
                    },
                    .engine_error => return self.engineFault(),
                };
                var list_root = gc.Root{ .object = &list.header };
                var item_root = gc.Root{ .object = null };
                roots.add(&list_root);
                roots.add(&item_root);
                const owns_work_budget = self.beginSynchronousWork();
                defer self.endSynchronousWork(owns_work_budget);
                var total: usize = 0;
                while (true) {
                    if (!self.chargeSynchronousWork(line, column)) return false;
                    const result = file_module.readBuffer(&self.heap, file.fs, file, null, true);
                    const contents = switch (result) {
                        .value => |selected| selected,
                        .python_exception => |exception| {
                            self.setException(exception, line, column, null);
                            return false;
                        },
                        .engine_error => return self.engineFault(),
                    };
                    if (contents.len == 0) {
                        self.heap.allocator.free(contents);
                        break;
                    }
                    const line_size = if (file.mode.binary) contents.len else std.unicode.utf8CountCodepoints(contents) catch {
                        self.heap.allocator.free(contents);
                        self.setException(.{ .kind = .unicode_decode_error, .message = "invalid UTF-8 data in file" }, line, column, null);
                        return false;
                    };
                    const item: Value = if (file.mode.binary) blk: {
                        const created_item = byte_module.create(&self.heap, contents);
                        self.heap.allocator.free(contents);
                        break :blk switch (created_item) {
                            .value => |selected| Value.object(&selected.header),
                            .python_exception => |exception| {
                                self.setException(exception, line, column, null);
                                return false;
                            },
                            .engine_error => return self.engineFault(),
                        };
                    } else blk: {
                        const created_item = string.create(&self.heap, contents);
                        self.heap.allocator.free(contents);
                        break :blk switch (created_item) {
                            .value => |selected| Value.object(&selected.header),
                            .python_exception => |exception| {
                                self.setException(exception, line, column, null);
                                return false;
                            },
                            .engine_error => return self.engineFault(),
                        };
                    };
                    item_root.object = item.asObject();
                    const append = sequence.append(&self.heap, list, item);
                    switch (append) {
                        .value => {},
                        .python_exception => |exception| {
                            self.setException(exception, line, column, null);
                            return false;
                        },
                        .engine_error => return self.engineFault(),
                    }
                    total += line_size;
                    if (hint > 0 and total >= @as(usize, @intCast(hint))) break;
                }
                self.setRegister(destination, Value.object(&list.header));
                return true;
            },
            .file_write => {
                if (positional.len != 1) return self.nativeArity(line, column);
                const bytes = if (file.mode.binary)
                    self.valueBytes(positional[0]) orelse return self.nativeTypeError(line, column, "a bytes-like object is required")
                else
                    self.valueString(positional[0]) orelse return self.nativeTypeError(line, column, "write() argument must be str");
                return switch (file_module.writeBuffer(&self.heap, file.fs, file, bytes)) {
                    .value => |count| self.setSmallInt(destination, count, line, column),
                    .python_exception => |exception| blk: {
                        self.setException(exception, line, column, null);
                        break :blk false;
                    },
                    .engine_error => self.engineFault(),
                };
            },
            .file_writelines => {
                if (positional.len != 1) return self.nativeArity(line, column);
                const created = iterator.createIterator(&self.heap, positional[0]);
                const iter = switch (created) {
                    .value => |selected| selected,
                    .python_exception => |exception| {
                        self.setException(exception, line, column, null);
                        return false;
                    },
                    .engine_error => return self.engineFault(),
                };
                var iterator_root = gc.Root{ .object = &iter.header };
                var item_root = gc.Root{ .object = null };
                roots.add(&iterator_root);
                roots.add(&item_root);
                const owns_work_budget = self.beginSynchronousWork();
                defer self.endSynchronousWork(owns_work_budget);
                while (true) {
                    if (!self.chargeSynchronousWork(line, column)) return false;
                    const next = self.nextIteratorValue(iter, destination, line, column);
                    const item = switch (next) {
                        .item => |selected| selected,
                        .done => break,
                        .suspended => return self.nativeTypeError(line, column, "writelines does not support a suspended iterator in this runtime slice"),
                        .python_exception => |exception| {
                            self.setException(exception, line, column, null);
                            return false;
                        },
                        .engine_error => return self.engineFault(),
                    };
                    item_root.object = item.asObject();
                    const bytes = if (file.mode.binary)
                        self.valueBytes(item) orelse return self.nativeTypeError(line, column, "writelines() argument must contain bytes")
                    else
                        self.valueString(item) orelse return self.nativeTypeError(line, column, "writelines() argument must contain strings");
                    switch (file_module.writeBuffer(&self.heap, file.fs, file, bytes)) {
                        .value => {},
                        .python_exception => |exception| {
                            self.setException(exception, line, column, null);
                            return false;
                        },
                        .engine_error => return self.engineFault(),
                    }
                }
                self.setRegister(destination, Value.noneValue());
                return true;
            },
            .file_seek => {
                if (positional.len == 0 or positional.len > 2) return self.nativeArity(line, column);
                const offset = self.fileInteger(positional[0], line, column) orelse return false;
                const whence = if (positional.len == 2) self.fileInteger(positional[1], line, column) orelse return false else 0;
                return switch (file_module.seek(file.fs, file, offset, whence)) {
                    .value => |position| self.setSmallInt(destination, @as(i64, @intCast(position)), line, column),
                    .python_exception => |exception| blk: {
                        self.setException(exception, line, column, null);
                        break :blk false;
                    },
                    .engine_error => self.engineFault(),
                };
            },
            .file_tell => {
                if (positional.len != 0) return self.nativeArity(line, column);
                if (file.closed) {
                    self.setException(.{ .kind = .value_error, .message = "I/O operation on closed file" }, line, column, null);
                    return false;
                }
                return self.setSmallInt(destination, @as(i64, @intCast(file.cursor)), line, column);
            },
            .file_truncate => {
                if (positional.len > 1) return self.nativeArity(line, column);
                const size: ?i64 = if (positional.len == 0) null else self.fileInteger(positional[0], line, column) orelse return false;
                return switch (file_module.truncate(&self.heap, file.fs, file, size)) {
                    .value => |count| self.setSmallInt(destination, @as(i64, @intCast(count)), line, column),
                    .python_exception => |exception| blk: {
                        self.setException(exception, line, column, null);
                        break :blk false;
                    },
                    .engine_error => self.engineFault(),
                };
            },
            .file_flush => {
                if (positional.len != 0) return self.nativeArity(line, column);
                return self.storeVoidResult(destination, file_module.flush(file), line, column);
            },
            .file_close => {
                if (positional.len != 0) return self.nativeArity(line, column);
                file_module.close(file);
                self.setRegister(destination, Value.noneValue());
                return true;
            },
            else => return self.engineFault(),
        }
    }

    fn fileInteger(self: *Runtime, value: Value, line: u32, column: u32) ?i64 {
        if (value.asBool()) |boolean| return if (boolean) 1 else 0;
        if (!number.isIntegerValue(value)) {
            _ = self.nativeTypeError(line, column, "integer argument expected");
            return null;
        }
        return number.toInt(i64, value) orelse blk: {
            self.setException(.{ .kind = .overflow_error, .message = "Python int too large to convert to C ssize_t" }, line, column, null);
            break :blk null;
        };
    }

    fn executeMappingConstructor(self: *Runtime, destination: u16, is_set: bool, positional: []const Value, keywords: []const binder.Keyword, line: u32, column: u32) bool {
        if (positional.len > 1 or (is_set and keywords.len != 0)) return self.nativeArity(line, column);
        const created = dict_module.create(&self.heap, is_set);
        const mapping = switch (created) {
            .value => |selected| selected,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        var root = gc.Root{ .object = &mapping.header };
        var roots = gc.RootFrame{};
        roots.push(&self.heap.roots);
        roots.add(&root);
        defer roots.pop();
        if (positional.len == 1) {
            if (is_set) {
                if (!self.updateSetFromIterable(mapping, positional[0], line, column)) return false;
            } else if (!self.updateDictFromValue(mapping, positional[0], line, column)) return false;
        }
        if (!is_set) for (keywords) |keyword| {
            const key = switch (string.create(&self.heap, keyword.name)) {
                .value => |selected| Value.object(&selected.header),
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            };
            if (!self.setMappingValue(mapping, key, keyword.value, line, column)) return false;
        };
        self.setRegister(destination, Value.object(&mapping.header));
        return true;
    }

    fn updateDictFromValue(self: *Runtime, mapping: *dict_module.Dict, source_value: Value, line: u32, column: u32) bool {
        if (source_value.asObject()) |source_header| if (dict_module.dictFromHeader(source_header)) |source| {
            if (!source.is_set) {
                for (source.entries.items) |entry| {
                    if (entry.alive and !self.setMappingValueWithHash(mapping, entry.key, entry.value, entry.hash, line, column)) return false;
                }
                return true;
            }
        };
        var roots: [7]gc.Root = [_]gc.Root{.{ .object = null }} ** 7;
        roots[0].object = &mapping.header;
        roots[1].object = source_value.asObject();
        var root_frame = gc.RootFrame{};
        root_frame.push(&self.heap.roots);
        for (&roots) |*root| root_frame.add(root);
        defer root_frame.pop();
        const created_iterator = iterator.createIterator(&self.heap, source_value);
        const source_iterator = switch (created_iterator) {
            .value => |selected| selected,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        roots[2].object = &source_iterator.header;
        while (true) {
            const next_pair = iterator.next(&self.heap, source_iterator);
            const pair = switch (next_pair) {
                .item => |selected| selected,
                .done => break,
                .suspended => return self.engineFault(),
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            };
            roots[3].object = pair.asObject();
            const pair_iterator_result = iterator.createIterator(&self.heap, pair);
            const pair_iterator = switch (pair_iterator_result) {
                .value => |selected| selected,
                .python_exception => {
                    self.setException(.{ .kind = .value_error, .message = "dictionary update sequence element is not a pair" }, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            };
            roots[4].object = &pair_iterator.header;
            const first = iterator.next(&self.heap, pair_iterator);
            roots[5].object = switch (first) {
                .item => |value| value.asObject(),
                .done => {
                    self.setException(.{ .kind = .value_error, .message = "dictionary update sequence element has length 0; 2 is required" }, line, column, null);
                    return false;
                },
                .suspended => return self.engineFault(),
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            };
            const first_value = switch (first) {
                .item => |value| value,
                else => unreachable,
            };
            const second = iterator.next(&self.heap, pair_iterator);
            roots[6].object = switch (second) {
                .item => |value| value.asObject(),
                .done => {
                    self.setException(.{ .kind = .value_error, .message = "dictionary update sequence element has length 1; 2 is required" }, line, column, null);
                    return false;
                },
                .suspended => return self.engineFault(),
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            };
            const second_value = switch (second) {
                .item => |value| value,
                else => unreachable,
            };
            switch (iterator.next(&self.heap, pair_iterator)) {
                .done => {},
                .item => {
                    self.setException(.{ .kind = .value_error, .message = "dictionary update sequence element has length greater than 2" }, line, column, null);
                    return false;
                },
                .suspended => return self.engineFault(),
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            }
            if (!self.setMappingValue(mapping, first_value, second_value, line, column)) return false;
        }
        return true;
    }

    fn updateSetFromIterable(self: *Runtime, target: *dict_module.Dict, source: Value, line: u32, column: u32) bool {
        var roots: [4]gc.Root = .{ .{ .object = &target.header }, .{ .object = source.asObject() }, .{ .object = null }, .{ .object = null } };
        var root_frame = gc.RootFrame{};
        root_frame.push(&self.heap.roots);
        for (&roots) |*root| root_frame.add(root);
        defer root_frame.pop();
        const created_iterator = iterator.createIterator(&self.heap, source);
        const source_iterator = switch (created_iterator) {
            .value => |selected| selected,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        roots[2].object = &source_iterator.header;
        while (true) switch (iterator.next(&self.heap, source_iterator)) {
            .item => |item| {
                roots[3].object = item.asObject();
                if (!self.setMappingValue(target, item, Value.noneValue(), line, column)) return false;
            },
            .done => return true,
            .suspended => return self.engineFault(),
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
    }

    fn executeMappingMethod(self: *Runtime, destination: u16, native: functions.Native, bound_self: Value, positional: []const Value, keywords: []const binder.Keyword, line: u32, column: u32) bool {
        const header = bound_self.asObject() orelse return self.engineFault();
        const mapping = dict_module.dictFromHeader(header) orelse return self.engineFault();
        if (mapping.is_set != (native == .set_add or native == .set_remove or native == .set_discard or native == .set_pop or native == .set_update or native == .set_clear or native == .set_copy)) return self.engineFault();
        if (native == .dict_update) {
            if (positional.len > 1) return self.nativeArity(line, column);
            if (positional.len == 1 and !self.updateDictFromValue(mapping, positional[0], line, column)) return false;
            for (keywords) |keyword| {
                const key = switch (string.create(&self.heap, keyword.name)) {
                    .value => |selected| Value.object(&selected.header),
                    .python_exception => |exception| {
                        self.setException(exception, line, column, null);
                        return false;
                    },
                    .engine_error => return self.engineFault(),
                };
                if (!self.setMappingValue(mapping, key, keyword.value, line, column)) return false;
            }
            self.setRegister(destination, Value.noneValue());
            return true;
        }
        if (native == .set_update) {
            if (keywords.len != 0) return self.nativeTypeError(line, column, "set.update does not accept keyword arguments");
            for (positional) |source| if (!self.updateSetFromIterable(mapping, source, line, column)) return false;
            self.setRegister(destination, Value.noneValue());
            return true;
        }
        if (keywords.len != 0) return self.nativeTypeError(line, column, "mapping method does not accept keyword arguments");
        switch (native) {
            .dict_get => {
                if (positional.len < 1 or positional.len > 2) return self.nativeArity(line, column);
                const key_hash = self.pythonHash(positional[0], line, column) orelse return false;
                var context = DictEqualityContext{ .runtime = self, .line = line, .column = column };
                return switch (dict_module.get(mapping, positional[0], key_hash, &context, dictKeysEqual)) {
                    .value => |value| blk: {
                        self.setRegister(destination, value);
                        break :blk true;
                    },
                    .missing => blk: {
                        self.setRegister(destination, if (positional.len == 2) positional[1] else Value.noneValue());
                        break :blk true;
                    },
                    .failed => self.last_exception == null and self.engineFault(),
                };
            },
            .dict_keys, .dict_values, .dict_items => {
                if (positional.len != 0) return self.nativeArity(line, column);
                const kind: dict_module.ViewKind = if (native == .dict_keys) .keys else if (native == .dict_values) .values else .items;
                return switch (dict_module.createView(&self.heap, mapping, kind)) {
                    .value => |view| blk: {
                        self.setRegister(destination, Value.object(&view.header));
                        break :blk true;
                    },
                    .python_exception => |exception| blk: {
                        self.setException(exception, line, column, null);
                        break :blk false;
                    },
                    .engine_error => self.engineFault(),
                };
            },
            .dict_pop, .dict_setdefault => {
                if (positional.len < 1 or positional.len > (if (native == .dict_pop) @as(usize, 2) else 2)) return self.nativeArity(line, column);
                const key = positional[0];
                const key_hash = self.pythonHash(key, line, column) orelse return false;
                var context = DictEqualityContext{ .runtime = self, .line = line, .column = column };
                const lookup_result = dict_module.lookup(mapping, key, key_hash, &context, dictKeysEqual);
                switch (lookup_result) {
                    .failed => return self.last_exception == null and self.engineFault(),
                    .found => |index| {
                        const old_value = mapping.entries.items[index].value;
                        if (native == .dict_pop) {
                            _ = dict_module.delete(mapping, key, key_hash, &context, dictKeysEqual);
                        }
                        self.setRegister(destination, old_value);
                        return true;
                    },
                    .missing => {
                        if (native == .dict_pop) {
                            if (positional.len == 2) {
                                self.setRegister(destination, positional[1]);
                                return true;
                            }
                            self.setException(.{ .kind = .key_error, .message = "mapping key not found" }, line, column, null);
                            return false;
                        }
                        const value = if (positional.len == 2) positional[1] else Value.noneValue();
                        if (!self.setMappingValueWithHash(mapping, key, value, key_hash, line, column)) return false;
                        self.setRegister(destination, value);
                        return true;
                    },
                }
            },
            .dict_clear, .set_clear => {
                if (positional.len != 0) return self.nativeArity(line, column);
                dict_module.clear(&self.heap, mapping);
                self.setRegister(destination, Value.noneValue());
                return true;
            },
            .dict_copy, .set_copy => {
                if (positional.len != 0) return self.nativeArity(line, column);
                const copied = dict_module.copy(&self.heap, mapping);
                return self.storeDictResult(destination, copied, line, column);
            },
            .set_add => {
                if (positional.len != 1) return self.nativeArity(line, column);
                return self.storeVoidResult(destination, self.setMappingResult(mapping, positional[0], line, column), line, column);
            },
            .set_remove, .set_discard => {
                if (positional.len != 1) return self.nativeArity(line, column);
                const key_hash = self.pythonHash(positional[0], line, column) orelse return false;
                var context = DictEqualityContext{ .runtime = self, .line = line, .column = column };
                return switch (dict_module.delete(mapping, positional[0], key_hash, &context, dictKeysEqual)) {
                    .found => blk: {
                        self.setRegister(destination, Value.noneValue());
                        break :blk true;
                    },
                    .missing => blk: {
                        if (native == .set_remove) {
                            self.setException(.{ .kind = .key_error, .message = "element not found" }, line, column, null);
                            break :blk false;
                        }
                        self.setRegister(destination, Value.noneValue());
                        break :blk true;
                    },
                    .failed => self.last_exception == null and self.engineFault(),
                };
            },
            .set_pop => {
                if (positional.len != 0) return self.nativeArity(line, column);
                for (mapping.entries.items) |entry| if (entry.alive) {
                    var context = DictEqualityContext{ .runtime = self, .line = line, .column = column };
                    _ = dict_module.delete(mapping, entry.key, entry.hash, &context, dictKeysEqual);
                    self.setRegister(destination, entry.key);
                    return true;
                };
                self.setException(.{ .kind = .key_error, .message = "pop from an empty set" }, line, column, null);
                return false;
            },
            else => return self.engineFault(),
        }
    }

    fn setMappingResult(self: *Runtime, mapping: *dict_module.Dict, key: Value, line: u32, column: u32) exceptions.Result(void) {
        const key_hash = self.pythonHash(key, line, column) orelse return .{ .python_exception = self.last_exception.? };
        var context = DictEqualityContext{ .runtime = self, .line = line, .column = column };
        return dict_module.set(&self.heap, mapping, key, Value.noneValue(), key_hash, &context, dictKeysEqual);
    }

    fn storeDictResult(self: *Runtime, destination: u16, result: exceptions.Result(*dict_module.Dict), line: u32, column: u32) bool {
        return switch (result) {
            .value => |mapping| blk: {
                self.setRegister(destination, Value.object(&mapping.header));
                break :blk true;
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => self.engineFault(),
        };
    }

    fn executeStringNative(self: *Runtime, destination: u16, native: functions.Native, text: *string.Str, positional: []const Value, keywords: []const binder.Keyword, line: u32, column: u32) bool {
        if (keywords.len != 0) return self.nativeTypeError(line, column, "string method does not accept keyword arguments");
        switch (native) {
            .str_find, .str_index => {
                if (positional.len != 1) return self.nativeArity(line, column);
                const needle = self.valueString(positional[0]) orelse return self.nativeTypeError(line, column, "substring must be a string");
                const found = string.find(text, needle);
                if (native == .str_index and found == null) {
                    self.setException(.{ .kind = .value_error, .message = "substring not found" }, line, column, null);
                    return false;
                }
                const found_index: i64 = if (found) |index| std.math.cast(i64, index) orelse return self.nativeTypeError(line, column, "string is too large to search") else -1;
                return self.setSmallInt(destination, found_index, line, column);
            },
            .str_count => {
                if (positional.len != 1) return self.nativeArity(line, column);
                const needle = self.valueString(positional[0]) orelse return self.nativeTypeError(line, column, "substring must be a string");
                return self.setSmallInt(destination, string.count(text, needle), line, column);
            },
            .str_startswith, .str_endswith => {
                if (positional.len != 1) return self.nativeArity(line, column);
                const needle = self.valueString(positional[0]) orelse return self.nativeTypeError(line, column, "prefix/suffix must be a string");
                const yes = if (native == .str_startswith) string.startsWith(text, needle) else string.endsWith(text, needle);
                self.setRegister(destination, if (yes) Value.trueValue() else Value.falseValue());
                return true;
            },
            .str_strip, .str_upper, .str_lower => {
                if ((native == .str_strip and positional.len > 1) or (native != .str_strip and positional.len != 0)) return self.nativeArity(line, column);
                const result = switch (native) {
                    .str_strip => string.strip(&self.heap, text, if (positional.len == 0 or positional[0].tag() == .none) null else self.valueString(positional[0]) orelse return self.nativeTypeError(line, column, "strip characters must be a string")),
                    .str_upper => string.upper(&self.heap, text),
                    .str_lower => string.lower(&self.heap, text),
                    else => unreachable,
                };
                return self.storeStringResult(destination, result, line, column);
            },
            .str_replace => {
                if (positional.len < 2 or positional.len > 3) return self.nativeArity(line, column);
                const old = self.valueString(positional[0]) orelse return self.nativeTypeError(line, column, "replace arguments must be strings");
                const replacement = self.valueString(positional[1]) orelse return self.nativeTypeError(line, column, "replace arguments must be strings");
                var max_count: ?usize = null;
                if (positional.len == 3) {
                    if (!number.isIntegerValue(positional[2])) return self.nativeTypeError(line, column, "count must be an integer");
                    const count = number.toInt(i128, positional[2]) orelse std.math.maxInt(i128);
                    max_count = if (count < 0) null else std.math.cast(usize, count) orelse std.math.maxInt(usize);
                }
                return self.storeStringResult(destination, string.replace(&self.heap, text, old, replacement, max_count), line, column);
            },
            .str_encode => {
                if (positional.len > 1) return self.nativeArity(line, column);
                if (positional.len == 1 and !self.valueIsUtf8(positional[0])) return self.nativeTypeError(line, column, "only UTF-8 encoding is supported");
                return self.storeBytesResult(destination, byte_module.encode(&self.heap, text), line, column);
            },
            .str_split => {
                if (positional.len == 0) return self.splitStringWhitespaceResult(destination, text, line, column);
                if (positional.len != 1) return self.nativeArity(line, column);
                const separator = self.valueString(positional[0]) orelse return self.nativeTypeError(line, column, "separator must be a string");
                return self.splitStringResult(destination, text, separator, line, column);
            },
            .str_join => {
                if (positional.len != 1) return self.nativeArity(line, column);
                return self.joinStringResult(destination, text, positional[0], line, column);
            },
            else => return self.engineFault(),
        }
    }

    fn executeFormatValue(self: *Runtime, destination: u16, value: Value, spec: []const u8, conversion: u8, line: u32, column: u32) bool {
        const rendered = self.makeFormattedText(value, spec, conversion, line, column) orelse return false;
        defer self.heap.allocator.free(rendered);
        return self.storeStringResult(destination, string.create(&self.heap, rendered), line, column);
    }

    fn executeStrFormat(self: *Runtime, destination: u16, template: *string.Str, positional: []const Value, keywords: []const binder.Keyword, line: u32, column: u32) bool {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.heap.allocator);
        const source = string.content(template);
        var index: usize = 0;
        var automatic: usize = 0;
        var numbering_mode: enum { unset, automatic, manual } = .unset;
        while (index < source.len) {
            if (index + 1 < source.len and source[index] == '{' and source[index + 1] == '{') {
                output.append(self.heap.allocator, '{') catch {
                    _ = self.formatMemoryFailure(line, column);
                    return false;
                };
                index += 2;
                continue;
            }
            if (index + 1 < source.len and source[index] == '}' and source[index + 1] == '}') {
                output.append(self.heap.allocator, '}') catch {
                    _ = self.formatMemoryFailure(line, column);
                    return false;
                };
                index += 2;
                continue;
            }
            if (source[index] == '}') {
                _ = self.formatValueError(line, column, "single '}' encountered in format string");
                return false;
            }
            if (source[index] != '{') {
                output.append(self.heap.allocator, source[index]) catch {
                    _ = self.formatMemoryFailure(line, column);
                    return false;
                };
                index += 1;
                continue;
            }
            const close = std.mem.indexOfScalarPos(u8, source, index + 1, '}') orelse {
                _ = self.formatValueError(line, column, "unmatched '{' in format string");
                return false;
            };
            const field = source[index + 1 .. close];
            const colon = std.mem.indexOfScalar(u8, field, ':');
            const name = if (colon) |at| field[0..at] else field;
            const spec = if (colon) |at| field[at + 1 ..] else "";
            var value: ?Value = null;
            if (name.len == 0) {
                if (numbering_mode == .manual) {
                    _ = self.formatValueError(line, column, "cannot switch from manual field specification to automatic field numbering");
                    return false;
                }
                numbering_mode = .automatic;
                if (automatic >= positional.len) {
                    _ = self.formatValueError(line, column, "replacement index out of range");
                    return false;
                }
                value = positional[automatic];
                automatic += 1;
            } else if (std.fmt.parseInt(usize, name, 10) catch null) |position| {
                if (numbering_mode == .automatic) {
                    _ = self.formatValueError(line, column, "cannot switch from automatic field numbering to manual field specification");
                    return false;
                }
                numbering_mode = .manual;
                if (position >= positional.len) {
                    _ = self.formatValueError(line, column, "replacement index out of range");
                    return false;
                }
                value = positional[position];
            } else {
                for (keywords) |keyword| if (std.mem.eql(u8, keyword.name, name)) {
                    value = keyword.value;
                    break;
                };
            }
            const selected = value orelse {
                self.setException(.{ .kind = .key_error, .message = "format key is missing" }, line, column, null);
                return false;
            };
            const formatted = self.makeFormattedText(selected, spec, 0, line, column) orelse return false;
            defer self.heap.allocator.free(formatted);
            output.appendSlice(self.heap.allocator, formatted) catch {
                _ = self.formatMemoryFailure(line, column);
                return false;
            };
            index = close + 1;
        }
        const owned = output.toOwnedSlice(self.heap.allocator) catch {
            _ = self.formatMemoryFailure(line, column);
            return false;
        };
        defer self.heap.allocator.free(owned);
        return self.storeStringResult(destination, string.create(&self.heap, owned), line, column);
    }

    fn makeFormattedText(self: *Runtime, value: Value, spec: []const u8, conversion: u8, line: u32, column: u32) ?[]u8 {
        var text: []u8 = undefined;
        if (conversion == 2 or conversion == 3) {
            text = self.renderValueOwned(value, true, line, column) orelse return null;
        } else if ((conversion == 0 or conversion == 1) and value.asObject() != null) {
            if (string.fromHeader(value.asObject().?)) |string_value| {
                text = self.heap.allocator.dupe(u8, string.content(string_value)) catch return self.formatMemoryFailure(line, column);
            } else {
                text = self.renderValueOwned(value, conversion == 2, line, column) orelse return null;
            }
        } else {
            text = self.renderValueOwned(value, false, line, column) orelse return null;
        }
        defer self.heap.allocator.free(text);
        if (conversion == 3) {
            const ascii = self.asciiEscape(text) orelse return self.formatMemoryFailure(line, column);
            self.heap.allocator.free(text);
            text = ascii;
        }
        if (spec.len == 0) return self.heap.allocator.dupe(u8, text) catch self.formatMemoryFailure(line, column);
        const is_string = conversion != 0 or (value.asObject() != null and string.fromHeader(value.asObject().?) != null);
        return self.applyFormatSpec(value, text, spec, line, column, is_string);
    }

    fn renderValueOwned(self: *Runtime, value: Value, nested: bool, line: u32, column: u32) ?[]u8 {
        const saved = self.stdout_bytes;
        self.stdout_bytes = .empty;
        const ok = self.appendValueMode(value, nested, line, column);
        const rendered = self.stdout_bytes.toOwnedSlice(self.heap.allocator) catch null;
        self.stdout_bytes = saved;
        if (!ok or rendered == null) {
            if (rendered) |owned| self.heap.allocator.free(owned);
            if (self.last_exception == null) self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return null;
        }
        return rendered.?;
    }

    fn asciiEscape(self: *Runtime, input: []const u8) ?[]u8 {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.heap.allocator);
        var index: usize = 0;
        while (index < input.len) {
            const first = input[index];
            if (first < 0x80) {
                output.append(self.heap.allocator, first) catch return null;
                index += 1;
                continue;
            }
            const width = std.unicode.utf8ByteSequenceLength(first) catch 1;
            const slice_bytes = input[index..@min(input.len, index + width)];
            const scalar = std.unicode.utf8Decode(slice_bytes) catch first;
            var escaped: []u8 = undefined;
            if (scalar <= 0xff) {
                escaped = std.fmt.allocPrint(self.heap.allocator, "\\x{x:0>2}", .{scalar}) catch return null;
            } else if (scalar <= 0xffff) {
                escaped = std.fmt.allocPrint(self.heap.allocator, "\\u{x:0>4}", .{scalar}) catch return null;
            } else {
                escaped = std.fmt.allocPrint(self.heap.allocator, "\\U{x:0>8}", .{scalar}) catch return null;
            }
            defer self.heap.allocator.free(escaped);
            output.appendSlice(self.heap.allocator, escaped) catch return null;
            index += width;
        }
        return output.toOwnedSlice(self.heap.allocator) catch null;
    }

    fn applyFormatSpec(self: *Runtime, value: Value, text: []const u8, spec: []const u8, line: u32, column: u32, force_string: bool) ?[]u8 {
        const parsed = format_rules.parse(spec) catch |err| return switch (err) {
            error.Overflow => self.formatMemoryFailure(line, column),
            error.MissingPrecisionDigits => self.formatValueError(line, column, "precision requires digits"),
            error.Invalid => self.formatValueError(line, column, "invalid format specifier"),
        };
        const kind = parsed.kind;
        const is_string = force_string or (value.asObject() != null and string.fromHeader(value.asObject().?) != null);
        if (is_string) {
            if ((kind != 0 and kind != 's') or parsed.sign_specified or parsed.alternate or parsed.comma or parsed.alignment == '=') return self.formatValueError(line, column, "invalid format specifier for string");
            const selected = if (parsed.precision) |precision| truncateUtf8(text, precision) else text;
            return self.padFormatted(selected, parsed.width, parsed.fill, parsed.alignment, 0, line, column);
        }
        if (kind == 'c') {
            if (!number.isIntegerValue(value)) return self.formatTypeError(line, column, "'c' requires an integer");
            if (parsed.sign_specified or parsed.alternate or parsed.comma or parsed.precision != null or parsed.alignment == '=') return self.formatValueError(line, column, "invalid format specifier with 'c'");
            const scalar = number.toInt(u21, value) orelse return self.formatValueError(line, column, "character argument not in range(0x110000)");
            var encoded: [4]u8 = undefined;
            const length = std.unicode.utf8Encode(scalar, &encoded) catch return self.formatValueError(line, column, "character argument not in range(0x110000)");
            return self.padFormatted(encoded[0..length], parsed.width, parsed.fill, parsed.alignment, 0, line, column);
        }
        const is_float_kind = kind == 'e' or kind == 'E' or kind == 'f' or kind == 'F' or kind == 'g' or kind == 'G' or kind == '%';
        const use_float = is_float_kind or (kind == 0 and value.asFloat() != null);
        if (use_float) {
            const float_value = switch (number.toFloat(&self.heap, value)) {
                .value => |selected| selected,
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return null;
                },
                .engine_error => {
                    _ = self.engineFault();
                    return null;
                },
            };
            if (kind == 0) {
                var default_text = if (parsed.precision) |precision|
                    self.formatFloat(float_value, precision, 'g', parsed.alternate, line, column) orelse return null
                else
                    self.heap.allocator.dupe(u8, text) catch return self.formatMemoryFailure(line, column);
                if (parsed.comma) {
                    const grouped = self.groupThousands(default_text) orelse {
                        self.heap.allocator.free(default_text);
                        return self.formatMemoryFailure(line, column);
                    };
                    self.heap.allocator.free(default_text);
                    default_text = grouped;
                }
                defer self.heap.allocator.free(default_text);
                return self.padSignedNumeric(default_text, parsed, line, column);
            }
            if (parsed.alternate and kind != 'g' and kind != 'G') return self.formatValueError(line, column, "alternate form is not supported for this float format");
            if (parsed.comma and (kind == 'e' or kind == 'E' or kind == 'g' or kind == 'G')) return self.formatValueError(line, column, "grouping is not supported for this float format");
            const actual_kind: u8 = if (kind == 0) 'g' else kind;
            const precision = parsed.precision orelse 6;
            const scaled = if (actual_kind == '%') float_value * 100 else float_value;
            var float_text = self.formatFloat(scaled, precision, actual_kind, parsed.alternate, line, column) orelse return null;
            if (parsed.comma) {
                const grouped = self.groupThousands(float_text) orelse {
                    self.heap.allocator.free(float_text);
                    return self.formatMemoryFailure(line, column);
                };
                self.heap.allocator.free(float_text);
                float_text = grouped;
            }
            defer self.heap.allocator.free(float_text);
            if (actual_kind == '%') {
                const percent = self.heap.allocator.dupeZ(u8, float_text) catch return self.formatMemoryFailure(line, column);
                defer self.heap.allocator.free(percent);
                var composed: std.ArrayList(u8) = .empty;
                defer composed.deinit(self.heap.allocator);
                composed.appendSlice(self.heap.allocator, percent) catch return self.formatMemoryFailure(line, column);
                composed.append(self.heap.allocator, '%') catch return self.formatMemoryFailure(line, column);
                const result = composed.toOwnedSlice(self.heap.allocator) catch return self.formatMemoryFailure(line, column);
                defer self.heap.allocator.free(result);
                return self.padSignedNumeric(result, parsed, line, column);
            }
            return self.padSignedNumeric(float_text, parsed, line, column);
        }
        if (kind != 0 and kind != 'd' and kind != 'b' and kind != 'o' and kind != 'x' and kind != 'X') return self.formatValueError(line, column, "invalid format specifier");
        if (!number.isIntegerValue(value)) return self.formatTypeError(line, column, "integer format requires an integer");
        if (parsed.precision != null or (parsed.comma and kind != 0 and kind != 'd')) return self.formatValueError(line, column, "invalid format specifier for integer");
        const base: u8 = if (kind == 'b') 2 else if (kind == 'o') 8 else if (kind == 'x' or kind == 'X') 16 else 10;
        const digits_result = number.formatIntegerBase(&self.heap, value, base, if (kind == 'X') .upper else .lower) orelse return self.formatTypeError(line, column, "integer format requires an integer");
        var digits_owned = switch (digits_result) {
            .value => |selected| selected,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return null;
            },
            .engine_error => {
                _ = self.engineFault();
                return null;
            },
        };
        defer self.heap.allocator.free(digits_owned);
        const negative = digits_owned.len != 0 and digits_owned[0] == '-';
        const digit_start: usize = @intFromBool(negative);
        var digit_slice = digits_owned[digit_start..];
        if (parsed.comma) {
            const grouped = self.groupThousands(digit_slice) orelse return self.formatMemoryFailure(line, column);
            self.heap.allocator.free(digits_owned);
            digits_owned = grouped;
            digit_slice = digits_owned;
        }
        const prefix: []const u8 = if (parsed.alternate and base == 16) (if (kind == 'X') "0X" else "0x") else if (parsed.alternate and base == 8) "0o" else if (parsed.alternate and base == 2) "0b" else "";
        const sign: []const u8 = if (negative) "-" else if (parsed.sign == '+') "+" else if (parsed.sign == ' ') " " else "";
        var composed: std.ArrayList(u8) = .empty;
        defer composed.deinit(self.heap.allocator);
        composed.appendSlice(self.heap.allocator, sign) catch return self.formatMemoryFailure(line, column);
        composed.appendSlice(self.heap.allocator, prefix) catch return self.formatMemoryFailure(line, column);
        composed.appendSlice(self.heap.allocator, digit_slice) catch return self.formatMemoryFailure(line, column);
        const numeric = composed.toOwnedSlice(self.heap.allocator) catch return self.formatMemoryFailure(line, column);
        defer self.heap.allocator.free(numeric);
        return self.padFormatted(numeric, parsed.width, parsed.fill, parsed.alignment, sign.len + prefix.len, line, column);
    }

    fn padSignedNumeric(self: *Runtime, text: []const u8, spec: format_rules.Spec, line: u32, column: u32) ?[]u8 {
        const has_minus = text.len != 0 and text[0] == '-';
        const has_sign = has_minus or spec.sign_specified;
        const sign: []const u8 = if (has_minus) "-" else if (spec.sign == '+') "+" else if (spec.sign == ' ') " " else "";
        if (!has_sign) return self.padFormatted(text, spec.width, spec.fill, spec.alignment, 0, line, column);
        var combined: std.ArrayList(u8) = .empty;
        defer combined.deinit(self.heap.allocator);
        combined.appendSlice(self.heap.allocator, sign) catch return self.formatMemoryFailure(line, column);
        if (has_minus) combined.appendSlice(self.heap.allocator, text[1..]) catch return self.formatMemoryFailure(line, column) else combined.appendSlice(self.heap.allocator, text) catch return self.formatMemoryFailure(line, column);
        const signed = combined.toOwnedSlice(self.heap.allocator) catch return self.formatMemoryFailure(line, column);
        defer self.heap.allocator.free(signed);
        return self.padFormatted(signed, spec.width, spec.fill, spec.alignment, sign.len, line, column);
    }

    fn padFormatted(self: *Runtime, text: []const u8, width: usize, fill: u8, requested_align: u8, head_len: usize, line: u32, column: u32) ?[]u8 {
        const length = std.unicode.utf8CountCodepoints(text) catch text.len;
        if (width <= length) return self.heap.allocator.dupe(u8, text) catch self.formatMemoryFailure(line, column);
        const padding = width - length;
        if (padding > self.remainingSessionBytes()) return self.formatMemoryFailure(line, column);
        const alignment = if (requested_align == 0) '>' else requested_align;
        const left = if (alignment == '<') 0 else if (alignment == '^') padding / 2 else padding;
        const right = padding - left;
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.heap.allocator);
        const internal = alignment == '=' and head_len != 0;
        if (!internal) output.appendNTimes(self.heap.allocator, fill, left) catch return self.formatMemoryFailure(line, column);
        if (internal) {
            output.appendSlice(self.heap.allocator, text[0..@min(head_len, text.len)]) catch return self.formatMemoryFailure(line, column);
            output.appendNTimes(self.heap.allocator, fill, padding) catch return self.formatMemoryFailure(line, column);
            output.appendSlice(self.heap.allocator, text[@min(head_len, text.len)..]) catch return self.formatMemoryFailure(line, column);
        } else output.appendSlice(self.heap.allocator, text) catch return self.formatMemoryFailure(line, column);
        if (!internal) output.appendNTimes(self.heap.allocator, fill, right) catch return self.formatMemoryFailure(line, column);
        return output.toOwnedSlice(self.heap.allocator) catch self.formatMemoryFailure(line, column);
    }

    fn formatFloat(self: *Runtime, value: f64, precision: usize, kind: u8, alternate: bool, line: u32, column: u32) ?[]u8 {
        if (precision > 256 or precision > self.remainingSessionBytes()) return self.formatMemoryFailure(line, column);
        const upper = kind == 'E' or kind == 'F' or kind == 'G';
        if (kind == 'g' or kind == 'G') return self.formatGeneralFloat(value, precision, alternate, upper, line, column);
        const scientific = kind == 'e' or kind == 'E';
        const rendered_value = if (scientific) value else roundDecimalTieEven(value, precision);
        const mode: std.fmt.float.Mode = if (scientific) .scientific else .decimal;
        var buffer: [std.fmt.float.bufferSize(.decimal, f64)]u8 = undefined;
        const rendered = std.fmt.float.render(&buffer, rendered_value, .{ .mode = mode, .precision = precision }) catch return self.formatMemoryFailure(line, column);
        if (scientific) {
            const marker = std.mem.indexOfScalar(u8, rendered, 'e') orelse return self.formatValueError(line, column, "float formatter omitted exponent");
            const mantissa = rendered[0..marker];
            const parsed_exponent = std.fmt.parseInt(i32, rendered[marker + 1 ..], 10) catch return self.formatValueError(line, column, "invalid float exponent");
            return self.normalizedScientific(mantissa, parsed_exponent, upper, line, column);
        }
        const owned = self.heap.allocator.dupe(u8, rendered) catch return self.formatMemoryFailure(line, column);
        if (upper) {
            for (@constCast(owned)) |*character| character.* = std.ascii.toUpper(character.*);
        }
        return owned;
    }

    fn formatGeneralFloat(self: *Runtime, value: f64, precision: usize, alternate: bool, upper: bool, line: u32, column: u32) ?[]u8 {
        const significant = if (precision == 0) 1 else precision;
        var buffer: [std.fmt.float.bufferSize(.decimal, f64)]u8 = undefined;
        const rendered = std.fmt.float.render(&buffer, value, .{ .mode = .scientific, .precision = significant - 1 }) catch return self.formatMemoryFailure(line, column);
        const marker = std.mem.indexOfScalar(u8, rendered, 'e') orelse {
            const special = self.heap.allocator.dupe(u8, rendered) catch return self.formatMemoryFailure(line, column);
            if (upper) {
                for (@constCast(special)) |*character| character.* = std.ascii.toUpper(character.*);
            }
            return special;
        };
        const exponent = std.fmt.parseInt(i32, rendered[marker + 1 ..], 10) catch return self.formatValueError(line, column, "invalid float exponent");
        const mantissa = if (alternate) rendered[0..marker] else trimFloatZeros(rendered[0..marker]);
        if (exponent < -4 or exponent >= @as(i32, @intCast(significant))) {
            return self.normalizedScientific(mantissa, exponent, upper, line, column);
        }
        return self.scientificMantissaToFixed(mantissa, exponent, line, column);
    }

    fn normalizedScientific(self: *Runtime, mantissa: []const u8, exponent: i32, upper: bool, line: u32, column: u32) ?[]u8 {
        const marker: u8 = if (upper) 'E' else 'e';
        const sign: u8 = if (exponent < 0) '-' else '+';
        const magnitude: u32 = @intCast(@abs(exponent));
        const result = std.fmt.allocPrint(self.heap.allocator, "{s}{c}{c}{d:0>2}", .{ mantissa, marker, sign, magnitude }) catch return self.formatMemoryFailure(line, column);
        return result;
    }

    fn scientificMantissaToFixed(self: *Runtime, mantissa: []const u8, exponent: i32, line: u32, column: u32) ?[]u8 {
        const negative = mantissa.len != 0 and mantissa[0] == '-';
        const unsigned = if (negative) mantissa[1..] else mantissa;
        var digits: std.ArrayList(u8) = .empty;
        defer digits.deinit(self.heap.allocator);
        for (unsigned) |character| if (character != '.') {
            digits.append(self.heap.allocator, character) catch return self.formatMemoryFailure(line, column);
        };
        const decimal_position_signed = 1 + exponent;
        const decimal_position: usize = if (decimal_position_signed > 0) @intCast(decimal_position_signed) else 0;
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.heap.allocator);
        if (negative) output.append(self.heap.allocator, '-') catch return self.formatMemoryFailure(line, column);
        if (decimal_position_signed <= 0) {
            output.appendSlice(self.heap.allocator, "0.") catch return self.formatMemoryFailure(line, column);
            output.appendNTimes(self.heap.allocator, '0', @intCast(-decimal_position_signed)) catch return self.formatMemoryFailure(line, column);
            output.appendSlice(self.heap.allocator, digits.items) catch return self.formatMemoryFailure(line, column);
        } else if (decimal_position >= digits.items.len) {
            output.appendSlice(self.heap.allocator, digits.items) catch return self.formatMemoryFailure(line, column);
            output.appendNTimes(self.heap.allocator, '0', decimal_position - digits.items.len) catch return self.formatMemoryFailure(line, column);
        } else {
            output.appendSlice(self.heap.allocator, digits.items[0..decimal_position]) catch return self.formatMemoryFailure(line, column);
            output.append(self.heap.allocator, '.') catch return self.formatMemoryFailure(line, column);
            output.appendSlice(self.heap.allocator, digits.items[decimal_position..]) catch return self.formatMemoryFailure(line, column);
        }
        return output.toOwnedSlice(self.heap.allocator) catch self.formatMemoryFailure(line, column);
    }

    fn groupThousands(self: *Runtime, input: []const u8) ?[]u8 {
        const dot = std.mem.indexOfAny(u8, input, ".eE") orelse input.len;
        const sign: usize = if (input.len != 0 and (input[0] == '-' or input[0] == '+')) 1 else 0;
        const integer_digits = dot - sign;
        if (integer_digits <= 3) return self.heap.allocator.dupe(u8, input) catch null;
        const commas = (integer_digits - 1) / 3;
        const total = input.len + commas;
        var output = self.heap.allocator.alloc(u8, total) catch return null;
        var out: usize = 0;
        for (input, 0..) |character, index| {
            if (index >= sign and index < dot and index != sign and (dot - index) % 3 == 0) {
                output[out] = ',';
                out += 1;
            }
            output[out] = character;
            out += 1;
        }
        return output;
    }

    fn remainingSessionBytes(self: *const Runtime) usize {
        return self.session_allocator.max_bytes -| self.session_allocator.live_bytes;
    }

    fn formatMemoryFailure(self: *Runtime, line: u32, column: u32) ?[]u8 {
        self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
        return null;
    }

    fn formatValueError(self: *Runtime, line: u32, column: u32, message: []const u8) ?[]u8 {
        self.setException(.{ .kind = .value_error, .message = message }, line, column, null);
        return null;
    }

    fn formatTypeError(self: *Runtime, line: u32, column: u32, message: []const u8) ?[]u8 {
        self.setException(.{ .kind = .type_error, .message = message }, line, column, null);
        return null;
    }

    fn executeBytesNative(self: *Runtime, destination: u16, native: functions.Native, data: *byte_module.Bytes, positional: []const Value, keywords: []const binder.Keyword, line: u32, column: u32) bool {
        if (keywords.len != 0) return self.nativeTypeError(line, column, "bytes method does not accept keyword arguments");
        switch (native) {
            .bytes_find => {
                if (positional.len != 1) return self.nativeArity(line, column);
                const needle = self.valueBytes(positional[0]) orelse return self.nativeTypeError(line, column, "a bytes-like object is required");
                const found: i64 = if (std.mem.indexOf(u8, data.data, needle)) |index| std.math.cast(i64, index) orelse return self.nativeTypeError(line, column, "bytes object is too large to search") else -1;
                return self.setSmallInt(destination, found, line, column);
            },
            .bytes_decode => {
                if (positional.len > 1) return self.nativeArity(line, column);
                if (positional.len == 1 and !self.valueIsUtf8(positional[0])) return self.nativeTypeError(line, column, "only UTF-8 decoding is supported");
                return self.storeStringResult(destination, byte_module.decode(&self.heap, data), line, column);
            },
            .bytes_split => {
                if (positional.len != 1) return self.nativeArity(line, column);
                const sep = self.valueBytes(positional[0]) orelse return self.nativeTypeError(line, column, "separator must be bytes");
                return self.splitBytesResult(destination, data, sep, line, column);
            },
            else => return self.engineFault(),
        }
    }

    fn nativeTypeError(self: *Runtime, line: u32, column: u32, message: []const u8) bool {
        self.setException(.{ .kind = .type_error, .message = message }, line, column, null);
        return false;
    }

    fn nativeAttributeError(self: *Runtime, line: u32, column: u32, message: []const u8) bool {
        self.setException(.{ .kind = .attribute_error, .message = message }, line, column, null);
        return false;
    }

    fn suppressAttributeError(self: *Runtime) void {
        const handled = if (self.active_exception) |suppressed| suppressed.context else null;
        self.last_exception = null;
        self.active_exception = handled;
        self.exception_root.object = if (handled) |instance| &instance.header else null;
        self.clearErrorText();
    }

    fn nativeArity(self: *Runtime, line: u32, column: u32) bool {
        return self.nativeTypeError(line, column, "incorrect number of arguments");
    }

    fn storeVoidResult(self: *Runtime, destination: u16, result: exceptions.Result(void), line: u32, column: u32) bool {
        return switch (result) {
            .value => {
                self.setRegister(destination, Value.noneValue());
                return true;
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => self.engineFault(),
        };
    }

    fn storeValueResult(self: *Runtime, destination: u16, result: exceptions.Result(Value), line: u32, column: u32) bool {
        return switch (result) {
            .value => |value| blk: {
                self.setRegister(destination, value);
                break :blk true;
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => self.engineFault(),
        };
    }

    fn storeListResult(self: *Runtime, destination: u16, result: sequence.ListResult, line: u32, column: u32) bool {
        return switch (result) {
            .value => |list| blk: {
                self.setRegister(destination, Value.object(&list.header));
                break :blk true;
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => self.engineFault(),
        };
    }

    fn storeTupleResult(self: *Runtime, destination: u16, result: sequence.TupleResult, line: u32, column: u32) bool {
        return switch (result) {
            .value => |tuple| blk: {
                self.setRegister(destination, Value.object(&tuple.header));
                break :blk true;
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => self.engineFault(),
        };
    }

    fn setSmallInt(self: *Runtime, destination: u16, input: anytype, line: u32, column: u32) bool {
        const integer: i128 = @intCast(input);
        const narrowed = std.math.cast(i64, integer) orelse {
            self.setException(.{ .kind = .overflow_error, .message = "integer result exceeds machine bound" }, line, column, null);
            return false;
        };
        const value = Value.fromSmallInt(narrowed) orelse {
            self.setException(.{ .kind = .overflow_error, .message = "integer result exceeds tagged integer range" }, line, column, null);
            return false;
        };
        self.setRegister(destination, value);
        return true;
    }

    fn createIteratorResult(self: *Runtime, destination: u16, value: Value, line: u32, column: u32) bool {
        return self.storeIteratorOutcome(destination, self.createVmIterator(value, line, column), line, column);
    }

    fn createVmIterator(self: *Runtime, value: Value, line: u32, column: u32) exceptions.Result(*iterator.Iterator) {
        if (value.asObject()) |header| if (class_module.instanceFromHeader(header) != null) {
            const iterated = self.invokeSpecialSync(value, "__iter__", &.{}, line, column) orelse {
                if (self.last_exception) |exception| return .{ .python_exception = exception };
                return .{ .python_exception = .{ .kind = .type_error, .message = "object is not iterable" } };
            };
            if (iterated.asObject()) |iterated_header| {
                if (iterator.iteratorFromHeader(iterated_header)) |selected| return .{ .value = selected };
                if (class_module.instanceFromHeader(iterated_header) != null and class_module.classAttribute(class_module.instanceFromHeader(iterated_header).?.class, "__next__") != null) {
                    return iterator.createUserIterator(&self.heap, iterated);
                }
            }
            return .{ .python_exception = .{ .kind = .type_error, .message = "iter() returned a non-iterator" } };
        };
        return iterator.createIterator(&self.heap, value);
    }

    fn storeIteratorOutcome(self: *Runtime, destination: u16, outcome: exceptions.Result(*iterator.Iterator), line: u32, column: u32) bool {
        return switch (outcome) {
            .value => |object| blk: {
                self.setRegister(destination, Value.object(&object.header));
                break :blk true;
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => self.engineFault(),
        };
    }

    fn nextIteratorValue(self: *Runtime, selected: *iterator.Iterator, destination: u16, line: u32, column: u32) iterator.NextResult {
        if (selected.user_object) |user| {
            const item = self.invokeSpecialSync(user, "__next__", &.{}, line, column) orelse {
                if (self.last_exception) |exception| {
                    if (exception.kind == .stop_iteration) {
                        self.last_exception = null;
                        self.active_exception = null;
                        self.exception_root.object = null;
                        self.clearErrorText();
                        selected.finished = true;
                        return .done;
                    }
                    return .{ .python_exception = exception };
                }
                return .{ .engine_error = .internal_invariant };
            };
            return .{ .item = item };
        }
        switch (selected.mode) {
            .enumerate => return self.nextEnumerateIteratorValue(selected, destination, line, column),
            .zip => return self.nextZipIteratorValue(selected, destination, line, column),
            else => {},
        }
        switch (iterator.deferredKind(selected) orelse return iterator.next(&self.heap, selected)) {
            .generator => {
                const owns_work_budget = self.beginSynchronousWork();
                defer self.endSynchronousWork(owns_work_budget);
                return self.resumeGenerator(selected, line, column);
            },
            .map, .filter => |kind| {
                const owns_work_budget = self.beginSynchronousWork();
                defer self.endSynchronousWork(owns_work_budget);
                if (selected.children.len == 0 or selected.values.len != selected.children.len) return .{ .engine_error = .internal_invariant };
                if (selected.finished) return .done;
                while (true) {
                    if (!self.chargeSynchronousWork(line, column)) return .{ .python_exception = self.last_exception.? };
                    if (selected.callback_pending) {
                        const mapped = self.takeCompletedSyncCallback() orelse return .suspended;
                        selected.callback_pending = false;
                        if (kind == .map) return .{ .item = mapped };
                        const keep = self.valueTruthy(mapped, line, column) orelse return .{ .python_exception = self.last_exception.? };
                        if (keep) return .{ .item = selected.values[0] };
                        continue;
                    }
                    while (selected.child_index < selected.children.len) {
                        const index = selected.child_index;
                        const maybe_child = selected.children[index];
                        const child = maybe_child orelse return .{ .engine_error = .internal_invariant };
                        switch (self.nextIteratorValue(child, destination, line, column)) {
                            .item => |value| {
                                selected.values[index] = value;
                                selected.child_index += 1;
                            },
                            .done => {
                                selected.child_index = 0;
                                selected.finished = true;
                                return .done;
                            },
                            .suspended => return .suspended,
                            .python_exception => |exception| return .{ .python_exception = exception },
                            .engine_error => |failure| return .{ .engine_error = failure },
                        }
                    }
                    selected.child_index = 0;
                    if (kind == .filter and selected.callback.tag() == .none) {
                        const keep = self.valueTruthy(selected.values[0], line, column) orelse return .{ .python_exception = self.last_exception.? };
                        if (keep) return .{ .item = selected.values[0] };
                        if (self.sync_task != null and self.sync_callback_depth == 0 and self.resuming_generator == null) return .suspended;
                        continue;
                    }
                    const callback_result = self.invokeSyncTaskCallback(selected.callback, selected.values, destination, line, column);
                    const mapped = switch (callback_result) {
                        .value => |value| value,
                        .suspended => {
                            selected.callback_pending = true;
                            return .suspended;
                        },
                        .failed => return .{ .python_exception = self.last_exception orelse .{ .kind = .runtime_error, .message = "iterator callback failed" } },
                    };
                    if (kind == .map) return .{ .item = mapped };
                    const keep = self.valueTruthy(mapped, line, column) orelse return .{ .python_exception = self.last_exception.? };
                    if (keep) return .{ .item = selected.values[0] };
                    if (self.sync_task != null and self.sync_callback_depth == 0 and self.resuming_generator == null) return .suspended;
                }
            },
        }
    }

    fn nextEnumerateIteratorValue(self: *Runtime, selected: *iterator.Iterator, destination: u16, line: u32, column: u32) iterator.NextResult {
        const owns_work_budget = self.beginSynchronousWork();
        defer self.endSynchronousWork(owns_work_budget);
        if (!self.chargeSynchronousWork(line, column)) return .{ .python_exception = self.last_exception orelse .{ .kind = .runtime_error, .message = "iterator work limit reached" } };
        if (selected.finished) return .done;
        const inner = selected.inner orelse return .{ .engine_error = .internal_invariant };
        switch (self.nextIteratorValue(inner, destination, line, column)) {
            .item => |item| {
                selected.enumerate_values[0] = selected.enumerate_index;
                selected.enumerate_values[1] = item;
                const advanced = switch (number.add(&self.heap, selected.enumerate_index, Value.fromSmallInt(1).?)) {
                    .value => |value| value,
                    .python_exception => |exception| return .{ .python_exception = exception },
                    .engine_error => |failure| return .{ .engine_error = failure },
                };
                selected.enumerate_index = advanced;
                const tuple = sequence.createTuple(&self.heap, &selected.enumerate_values);
                selected.enumerate_values = .{ Value.noneValue(), Value.noneValue() };
                return switch (tuple) {
                    .value => |value| .{ .item = Value.object(&value.header) },
                    .python_exception => |exception| .{ .python_exception = exception },
                    .engine_error => |failure| .{ .engine_error = failure },
                };
            },
            .done => {
                selected.finished = true;
                return .done;
            },
            .suspended => return .suspended,
            .python_exception => |exception| return .{ .python_exception = exception },
            .engine_error => |failure| return .{ .engine_error = failure },
        }
    }

    fn nextZipIteratorValue(self: *Runtime, selected: *iterator.Iterator, destination: u16, line: u32, column: u32) iterator.NextResult {
        const owns_work_budget = self.beginSynchronousWork();
        defer self.endSynchronousWork(owns_work_budget);
        if (selected.finished) return .done;
        if (selected.values.len != selected.children.len) return .{ .engine_error = .internal_invariant };
        if (selected.children.len == 0) {
            selected.finished = true;
            return .done;
        }
        while (selected.child_index < selected.children.len) {
            if (!self.chargeSynchronousWork(line, column)) return .{ .python_exception = self.last_exception orelse .{ .kind = .runtime_error, .message = "iterator work limit reached" } };
            const index = selected.child_index;
            const child = selected.children[index] orelse return .{ .engine_error = .internal_invariant };
            switch (self.nextIteratorValue(child, destination, line, column)) {
                .item => |item| {
                    selected.values[index] = item;
                    selected.child_index += 1;
                },
                .done => {
                    selected.child_index = 0;
                    selected.finished = true;
                    @memset(selected.values, Value.noneValue());
                    return .done;
                },
                .suspended => return .suspended,
                .python_exception => |exception| return .{ .python_exception = exception },
                .engine_error => |failure| return .{ .engine_error = failure },
            }
        }
        const tuple = sequence.createTuple(&self.heap, selected.values);
        selected.child_index = 0;
        @memset(selected.values, Value.noneValue());
        return switch (tuple) {
            .value => |value| .{ .item = Value.object(&value.header) },
            .python_exception => |exception| .{ .python_exception = exception },
            .engine_error => |failure| .{ .engine_error = failure },
        };
    }

    fn resumeGenerator(self: *Runtime, selected: *iterator.Iterator, line: u32, column: u32) iterator.NextResult {
        const owns_work_budget = self.beginSynchronousWork();
        defer self.endSynchronousWork(owns_work_budget);
        if (selected.generator_done) return .done;
        if (!selected.started) {
            const frame = self.createGeneratorFrame(selected, line, column) orelse return .{ .python_exception = self.last_exception orelse .{ .kind = .runtime_error, .message = "generator frame creation failed" } };
            selected.generator_frame = frame;
            selected.generator_roots = frame.roots;
            selected.generator_frame_destroy = destroyGeneratorFrameOpaque;
            selected.started = true;
        }
        const frame: *Frame = @ptrCast(@alignCast(selected.generator_frame orelse return .{ .engine_error = .internal_invariant }));
        if (self.suspended_exception_frame == frame) self.suspended_exception_frame = null;
        const caller = self.top_frame orelse return .{ .engine_error = .internal_invariant };
        const previous_generator = self.resuming_generator;
        self.resuming_generator = selected;
        defer self.resuming_generator = previous_generator;
        selected.generator_yielded = null;
        frame.previous = caller;
        frame.root_frame.push(&self.heap.roots);
        for (frame.roots) |*root| frame.root_frame.add(root);
        self.top_frame = frame;
        self.activateFrame(frame);
        if (selected.generator_yield_register) |register| {
            const slot: usize = register;
            if (slot >= frame.registers.len or slot >= frame.roots.len) return .{ .engine_error = .internal_invariant };
            frame.registers[slot] = selected.generator_send_value;
            frame.roots[slot].object = selected.generator_send_value.asObject();
            selected.generator_yield_register = null;
        }
        selected.generator_send_value = Value.noneValue();
        if (selected.generator_closing) {
            self.setException(.{ .kind = .generator_exit, .message = "" }, line, column, null);
            if (!self.unwindPythonExceptionUntil(caller)) {
                const failure: exceptions.PythonException = self.last_exception orelse .{ .kind = .generator_exit, .message = "" };
                self.unwindFramesUntil(caller);
                return .{ .python_exception = failure };
            }
        }
        var executed: u32 = 0;
        while (true) {
            if (selected.generator_yielded) |value| {
                selected.generator_yielded = null;
                if (selected.generator_closing) {
                    selected.generator_yield_register = null;
                    selected.generator_frame = null;
                    selected.generator_roots = &.{};
                    selected.generator_done = true;
                    self.freeFrameStorage(frame);
                    self.setException(.{ .kind = .runtime_error, .message = "generator ignored GeneratorExit" }, line, column, null);
                    return .{ .python_exception = self.last_exception.? };
                }
                return .{ .item = value };
            }
            if (selected.generator_done) return .done;
            if (!self.chargeSynchronousWork(line, column) or !self.chargeNestedInstruction()) {
                self.unwindFramesUntil(caller);
                return if (self.engine_failed) .{ .engine_error = .internal_invariant } else .done;
            }
            const active = self.top_frame orelse return .{ .engine_error = .internal_invariant };
            if (active.ip >= active.code.instructions.len or active.code.positions.len != active.code.instructions.len) {
                _ = self.engineFault();
                self.unwindFramesUntil(caller);
                return .{ .engine_error = .internal_invariant };
            }
            const position = active.code.positions[active.ip];
            const instruction = active.code.instructions[active.ip];
            active.ip += 1;
            self.activateFrame(active);
            if (!self.execute(instruction, position.line, position.column)) {
                if (!self.engine_failed and self.last_exception != null and self.unwindPythonExceptionUntil(caller)) continue;
                const failure: iterator.NextResult = if (self.engine_failed)
                    .{ .engine_error = .internal_invariant }
                else
                    .{ .python_exception = self.last_exception orelse .{ .kind = .runtime_error, .message = "generator execution failed" } };
                if (!self.engine_failed) self.appendTracebackCaller(caller);
                self.unwindFramesUntil(caller);
                return failure;
            }
            if (self.top_frame == active) active.ip = self.instruction_pointer;
            executed += 1;
            if (self.sync_task != null and self.sync_callback_depth == 0 and self.top_frame == frame and executed >= @max(self.sync_task_quantum, 1)) {
                self.suspended_exception_frame = if (frameHasExceptionContinuation(frame)) frame else null;
                if (frame.root_frame.stack != null) frame.root_frame.pop();
                self.top_frame = caller;
                frame.previous = null;
                self.activateFrame(caller);
                return .suspended;
            }
        }
    }

    fn setIteratorStopIteration(self: *Runtime, selected: *iterator.Iterator, line: u32, column: u32) bool {
        var iterator_root = gc.Root{ .object = &selected.header };
        var root_frame = gc.RootFrame{};
        root_frame.push(&self.heap.roots);
        root_frame.add(&iterator_root);
        defer root_frame.pop();
        const return_value = if (selected.generator_return_pending) selected.generator_return_value else Value.noneValue();
        self.setException(.{ .kind = .stop_iteration, .message = "" }, line, column, null);
        if (self.last_exception) |fault| {
            if (fault.kind == .stop_iteration) if (self.active_exception) |instance| {
                instance.value = return_value;
                selected.generator_return_value = Value.noneValue();
                selected.generator_return_pending = false;
            };
        }
        return false;
    }

    fn createGeneratorFrame(self: *Runtime, selected: *iterator.Iterator, line: u32, column: u32) ?*Frame {
        const caller = self.top_frame orelse {
            _ = self.engineFault();
            return null;
        };
        const function_header = selected.callback.asObject() orelse {
            self.setException(.{ .kind = .type_error, .message = "generator callback is not callable" }, line, column, null);
            return null;
        };
        const function = functions.functionFromHeader(function_header) orelse {
            self.setException(.{ .kind = .type_error, .message = "generator callback is not callable" }, line, column, null);
            return null;
        };
        const code = function.code orelse {
            self.setException(.{ .kind = .type_error, .message = "generator callback must be a Python function" }, line, column, null);
            return null;
        };
        const allocator = self.heap.allocator;
        var owned_values: ?[]Value = null;
        const bound_values = if (selected.generator_function) selected.values else blk: {
            const outer = selected.inner orelse {
                _ = self.engineFault();
                return null;
            };
            const argument = Value.object(&outer.header);
            const binding = binder.bindFunction(&self.heap, allocator, code.parameter_names, code.parameter_flags, function.defaults, &.{argument}, &.{}) catch |err| {
                self.setBinderException(err, line, column);
                return null;
            };
            if (binding.extra_keywords.len != 0) allocator.free(binding.extra_keywords);
            owned_values = binding.values;
            break :blk binding.values;
        };
        defer if (owned_values) |values| allocator.free(values);
        if (function.cells.len != code.free_names.len) {
            _ = self.engineFault();
            return null;
        }
        const bound_roots = allocator.alloc(gc.Root, bound_values.len) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return null;
        };
        defer allocator.free(bound_roots);
        for (bound_values, 0..) |value, index| bound_roots[index] = .{ .object = value.asObject() };
        var bound_frame = gc.RootFrame{};
        bound_frame.push(&self.heap.roots);
        for (bound_roots) |*root| bound_frame.add(root);
        var bound_roots_active = true;
        defer if (bound_roots_active) bound_frame.pop();
        const frame = self.allocateFrame(code, null) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return null;
        };
        var complete = false;
        defer if (!complete) {
            if (bound_roots_active) {
                bound_frame.pop();
                bound_roots_active = false;
            }
            while (self.top_frame != caller) if (self.popFrame()) |abandoned| {
                self.forgetGeneratorFrame(abandoned);
                self.freeFrameStorage(abandoned);
            } else break;
        };
        frame.root_frame.pop();
        bound_frame.pop();
        bound_roots_active = false;
        frame.root_frame.push(&self.heap.roots);
        for (frame.roots) |*root| frame.root_frame.add(root);
        bound_frame.push(&self.heap.roots);
        for (bound_roots) |*root| bound_frame.add(root);
        bound_roots_active = true;
        for (code.parameter_names, 0..) |name, index| {
            const value = bound_values[index];
            if (indexOfName(code.local_names, name)) |local_index| {
                frame.locals[local_index] = value;
                frame.roots[frame.localRootStart() + local_index].object = value.asObject();
            } else if (indexOfName(code.cell_names, name)) |cell_index| {
                frame.roots[frame.cellRootStart() + cell_index].object = value.asObject();
            } else {
                _ = self.engineFault();
                return null;
            }
        }
        for (function.cells, 0..) |cell, index| {
            frame.free_cells[index] = cell;
            frame.roots[frame.freeRootStart() + index].object = &cell.header;
        }
        for (code.cell_names, 0..) |_, index| {
            const cell = functions.createCell(&self.heap, Value.unboundValue()) catch {
                self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
                return null;
            };
            frame.local_cells[index] = cell;
            frame.roots[frame.cellRootStart() + index].object = &cell.header;
        }
        for (code.parameter_names, 0..) |name, index| if (!self.storeFrameLocal(frame, name, bound_values[index])) {
            _ = self.engineFault();
            return null;
        };
        bound_frame.pop();
        bound_roots_active = false;
        frame.root_frame.pop();
        self.top_frame = caller;
        frame.previous = null;
        self.activateFrame(caller);
        frame.generator_owner = selected;
        complete = true;
        return frame;
    }

    fn beginSyncTaskRoots(self: *Runtime) void {
        self.sync_roots = @splat(.{ .object = null });
        self.sync_root_frame.push(&self.heap.roots);
        for (&self.sync_roots) |*root| self.sync_root_frame.add(root);
    }

    fn releaseSyncCallbackDepth(self: *Runtime, task: *SyncTask) void {
        if (!task.callback_depth_held) return;
        task.callback_depth_held = false;
        self.sync_callback_depth -|= 1;
    }

    fn takeCompletedSyncCallback(self: *Runtime) ?Value {
        const task = if (self.sync_task) |*active| active else return null;
        if (!task.callback_completed) return null;
        const result = task.callback_result;
        task.callback_result = Value.noneValue();
        task.callback_completed = false;
        self.sync_roots[6].object = null;
        return result;
    }

    fn invokeSyncTaskCallback(self: *Runtime, callable: Value, args: []const Value, destination: u16, line: u32, column: u32) SyncCallbackResult {
        if (self.takeCompletedSyncCallback()) |result| return .{ .value = result };
        if (self.sync_task) |task| if (task.callback_in_progress) return .suspended;
        if (self.invokeCallableSync(callable, args, destination, line, column)) |result| return .{ .value = result };
        if (self.sync_task) |task| if (task.callback_in_progress) return .suspended;
        return .failed;
    }

    fn clearSyncTask(self: *Runtime) void {
        if (self.sync_task) |*task| self.releaseSyncCallbackDepth(task);
        if (self.sync_root_frame.stack != null) self.sync_root_frame.pop();
        if (self.sync_task) |task| if (task.order.len != 0) self.heap.allocator.free(task.order);
        self.sync_roots = @splat(.{ .object = null });
        self.sync_task = null;
        self.suspended_exception_frame = null;
        self.sync_yield_requested = false;
    }

    fn pauseSyncTask(self: *Runtime, task: *SyncTask) bool {
        task.frame.ip = task.call_ip;
        self.instruction_pointer = task.call_ip;
        self.sync_yield_requested = true;
        return true;
    }

    fn continueSyncTaskAfterCallback(self: *Runtime, task: *SyncTask) bool {
        task.frame.ip = task.call_ip;
        self.instruction_pointer = task.call_ip;
        return true;
    }

    fn iteratorHasPendingCallback(selected: *iterator.Iterator) bool {
        if (selected.callback_pending) return true;
        if (selected.inner) |inner| if (iteratorHasPendingCallback(inner)) return true;
        for (selected.children) |maybe_child| if (maybe_child) |child| {
            if (iteratorHasPendingCallback(child)) return true;
        };
        return false;
    }

    fn startSortedTask(self: *Runtime, destination: u16, source: Value, callback: ?Value, reverse: bool, line: u32, column: u32) bool {
        const frame = self.top_frame orelse return self.engineFault();
        const call_ip = if (frame.ip == 0) return self.engineFault() else frame.ip - 1;
        if (self.sync_task) |task| {
            if (task.frame != frame or task.call_ip != call_ip or task.operation != .sorted) return self.engineFault();
            return self.advanceSyncTask();
        }
        const selected = switch (self.createVmIterator(source, line, column)) {
            .value => |object| object,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        self.beginSyncTaskRoots();
        self.sync_roots[0].object = &selected.header;
        self.sync_task = .{
            .frame = frame,
            .call_ip = call_ip,
            .operation = .sorted,
            .destination = destination,
            .line = line,
            .column = column,
            .callback = callback orelse Value.noneValue(),
            .reverse = reverse,
        };
        self.sync_roots[4].object = if (callback) |value| value.asObject() else null;
        const list = switch (sequence.createList(&self.heap, &.{})) {
            .value => |object| object,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        self.sync_roots[1].object = &list.header;
        self.sync_task.?.target = list;
        self.sync_task.?.iterator_value = selected;
        return self.advanceSyncTask();
    }

    fn startListSortTask(self: *Runtime, destination: u16, list: *sequence.List, callback: ?Value, reverse: bool, line: u32, column: u32) bool {
        const frame = self.top_frame orelse return self.engineFault();
        const call_ip = if (frame.ip == 0) return self.engineFault() else frame.ip - 1;
        if (self.sync_task) |task| {
            if (task.frame != frame or task.call_ip != call_ip or task.operation != .list_sort) return self.engineFault();
            return self.advanceSyncTask();
        }
        self.beginSyncTaskRoots();
        self.sync_roots[1].object = &list.header;
        self.sync_roots[4].object = if (callback) |value| value.asObject() else null;
        self.sync_task = .{
            .frame = frame,
            .call_ip = call_ip,
            .operation = .list_sort,
            .phase = .order,
            .destination = destination,
            .line = line,
            .column = column,
            .target = list,
            .callback = callback orelse Value.noneValue(),
            .reverse = reverse,
            .original_version = list.version,
            .original_length = list.items.items.len,
        };
        if (!self.prepareSyncSort(&self.sync_task.?)) return false;
        return self.advanceSyncTask();
    }

    fn startNextTask(self: *Runtime, destination: u16, selected: *iterator.Iterator, line: u32, column: u32) bool {
        const frame = self.top_frame orelse return self.engineFault();
        const call_ip = if (frame.ip == 0) return self.engineFault() else frame.ip - 1;
        if (self.sync_task) |task| {
            if (task.frame != frame or task.call_ip != call_ip or task.operation != .next_value) return self.engineFault();
            return self.advanceSyncTask();
        }
        self.beginSyncTaskRoots();
        self.sync_roots[0].object = &selected.header;
        self.sync_task = .{
            .frame = frame,
            .call_ip = call_ip,
            .operation = .next_value,
            .destination = destination,
            .line = line,
            .column = column,
            .iterator_value = selected,
        };
        return self.advanceSyncTask();
    }

    fn prepareSyncSort(self: *Runtime, task: *SyncTask) bool {
        const target = task.target orelse return self.engineFault();
        const snapshot = switch (sequence.createList(&self.heap, target.items.items)) {
            .value => |object| object,
            .python_exception => |exception| {
                self.setException(exception, task.line, task.column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        task.snapshot = snapshot;
        self.sync_roots[2].object = &snapshot.header;
        if (task.callback.tag() != .none) {
            const keys = switch (sequence.createList(&self.heap, &.{})) {
                .value => |object| object,
                .python_exception => |exception| {
                    self.setException(exception, task.line, task.column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            };
            task.keys = keys;
            self.sync_roots[3].object = &keys.header;
            task.phase = .keys;
            task.index = 0;
            task.position = 0;
        } else {
            task.phase = .order;
            task.index = 1;
            task.position = 1;
        }
        task.order = self.heap.allocator.alloc(usize, snapshot.items.items.len) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, task.line, task.column, null);
            return false;
        };
        for (task.order, 0..) |*entry, index| entry.* = index;
        return true;
    }

    fn completeSyncTask(self: *Runtime, task: *SyncTask) bool {
        const target = task.target orelse return self.engineFault();
        if (task.want_tuple) {
            switch (sequence.createTuple(&self.heap, target.items.items)) {
                .value => |tuple| self.setRegister(task.destination, Value.object(&tuple.header)),
                .python_exception => |exception| {
                    self.setException(exception, task.line, task.column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            }
        } else if (task.operation == .list_sort) {
            self.setRegister(task.destination, Value.noneValue());
        } else {
            self.setRegister(task.destination, Value.object(&target.header));
        }
        task.complete = true;
        return true;
    }

    fn finishSyncSort(self: *Runtime, task: *SyncTask) bool {
        const target = task.target orelse return self.engineFault();
        const snapshot = task.snapshot orelse return self.engineFault();
        if (task.operation == .list_sort and (target.version != task.original_version or target.items.items.len != task.original_length)) {
            self.setException(.{ .kind = .value_error, .message = "list modified during sort" }, task.line, task.column, null);
            return false;
        }
        for (task.order, 0..) |source_index, target_index| target.items.items[target_index] = snapshot.items.items[source_index];
        if (task.operation == .list_sort) target.version +%= 1;
        if (task.operation == .list_sort) {
            self.setRegister(task.destination, Value.noneValue());
        } else {
            self.setRegister(task.destination, Value.object(&target.header));
        }
        task.complete = true;
        return true;
    }

    fn advanceSyncTask(self: *Runtime) bool {
        const task = if (self.sync_task) |*active| active else return self.engineFault();
        const owns_budget = self.beginSynchronousWork();
        defer self.endSynchronousWork(owns_budget);
        var remaining = @max(self.sync_task_quantum, 1);
        while (remaining != 0 and !task.complete) {
            if (task.operation == .next_value) {
                if (!self.chargeSynchronousWork(task.line, task.column)) return false;
                remaining -= 1;
                const selected = task.iterator_value orelse return self.engineFault();
                switch (self.nextIteratorValue(selected, task.destination, task.line, task.column)) {
                    .item => |item| {
                        self.setRegister(task.destination, item);
                        task.complete = true;
                        return true;
                    },
                    .done => {
                        return self.setIteratorStopIteration(selected, task.line, task.column);
                    },
                    .suspended => {
                        if (iteratorHasPendingCallback(selected)) return self.continueSyncTaskAfterCallback(task);
                        return self.pauseSyncTask(task);
                    },
                    .python_exception => |exception| {
                        self.setException(exception, task.line, task.column, null);
                        return false;
                    },
                    .engine_error => return self.engineFault(),
                }
            }
            const target = task.target orelse return self.engineFault();
            switch (task.phase) {
                .collect => {
                    if (!self.chargeSynchronousWork(task.line, task.column)) return false;
                    remaining -= 1;
                    const selected = task.iterator_value orelse return self.engineFault();
                    switch (self.nextIteratorValue(selected, task.destination, task.line, task.column)) {
                        .item => |item| {
                            self.sync_roots[5].object = item.asObject();
                            switch (sequence.append(&self.heap, target, item)) {
                                .value => {},
                                .python_exception => |exception| {
                                    self.setException(exception, task.line, task.column, null);
                                    return false;
                                },
                                .engine_error => return self.engineFault(),
                            }
                        },
                        .done => {
                            if (task.operation == .materialize) return self.completeSyncTask(task);
                            if (!self.prepareSyncSort(task)) return false;
                        },
                        .suspended => {
                            if (iteratorHasPendingCallback(selected)) return self.continueSyncTaskAfterCallback(task);
                            return self.pauseSyncTask(task);
                        },
                        .python_exception => |exception| {
                            self.setException(exception, task.line, task.column, null);
                            return false;
                        },
                        .engine_error => return self.engineFault(),
                    }
                },
                .keys => {
                    const snapshot = task.snapshot orelse return self.engineFault();
                    const keys = task.keys orelse return self.engineFault();
                    if (task.index >= snapshot.items.items.len) {
                        task.phase = .order;
                        task.index = 1;
                        task.position = 1;
                        task.sort_item_started = false;
                        continue;
                    }
                    if (!self.chargeSynchronousWork(task.line, task.column)) return false;
                    remaining -= 1;
                    const value = snapshot.items.items[task.index];
                    const callback_result = self.invokeSyncTaskCallback(task.callback, &.{value}, task.destination, task.line, task.column);
                    const returned = switch (callback_result) {
                        .value => |result| result,
                        .suspended => return self.continueSyncTaskAfterCallback(task),
                        .failed => return false,
                    };
                    const target_after_call = task.target orelse return self.engineFault();
                    if (task.operation == .list_sort and (target_after_call.version != task.original_version or target_after_call.items.items.len != task.original_length)) {
                        self.setException(.{ .kind = .value_error, .message = "list modified during sort" }, task.line, task.column, null);
                        return false;
                    }
                    self.sync_roots[5].object = returned.asObject();
                    switch (sequence.append(&self.heap, keys, returned)) {
                        .value => {},
                        .python_exception => |exception| {
                            self.setException(exception, task.line, task.column, null);
                            return false;
                        },
                        .engine_error => return self.engineFault(),
                    }
                    task.index += 1;
                },
                .order => {
                    const snapshot = task.snapshot orelse return self.engineFault();
                    if (task.index >= task.order.len) return self.finishSyncSort(task);
                    if (!self.chargeSynchronousWork(task.line, task.column)) return false;
                    remaining -= 1;
                    if (!task.sort_item_started) {
                        task.selected_index = task.order[task.index];
                        task.position = task.index;
                        task.sort_item_started = true;
                    }
                    if (task.position == 0) {
                        task.order[0] = task.selected_index;
                        task.index += 1;
                        task.sort_item_started = false;
                        continue;
                    }
                    const left_items = if (task.keys) |keys| keys.items.items else snapshot.items.items;
                    const order = self.sortOrder(left_items[task.selected_index], left_items[task.order[task.position - 1]], task.line, task.column) orelse return false;
                    const precedes = if (task.reverse) order == .gt else order == .lt;
                    if (precedes) {
                        task.order[task.position] = task.order[task.position - 1];
                        task.position -= 1;
                    } else {
                        task.order[task.position] = task.selected_index;
                        task.index += 1;
                        task.sort_item_started = false;
                    }
                },
            }
            if (self.output_event_pending or self.pending_input != null) return self.pauseSyncTask(task);
        }
        if (!task.complete) return self.pauseSyncTask(task);
        return true;
    }

    fn materializeSequence(self: *Runtime, destination: u16, source: Value, want_tuple: bool, line: u32, column: u32) bool {
        if (self.sync_callback_depth != 0 or self.resuming_generator != null) {
            return self.materializeSequenceImmediate(destination, source, want_tuple, line, column);
        }
        const frame = self.top_frame orelse return self.engineFault();
        const call_ip = if (frame.ip == 0) return self.engineFault() else frame.ip - 1;
        if (self.sync_task) |task| {
            if (task.frame != frame or task.call_ip != call_ip or task.operation != .materialize) return self.engineFault();
            return self.advanceSyncTask();
        }
        const iterator_value = switch (self.createVmIterator(source, line, column)) {
            .value => |object| object,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        self.beginSyncTaskRoots();
        self.sync_roots[0].object = &iterator_value.header;
        self.sync_task = .{
            .frame = frame,
            .call_ip = call_ip,
            .operation = .materialize,
            .destination = destination,
            .line = line,
            .column = column,
            .want_tuple = want_tuple,
        };
        const list = switch (sequence.createList(&self.heap, &.{})) {
            .value => |object| object,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        self.sync_roots[1].object = &list.header;
        self.sync_task.?.target = list;
        self.sync_task.?.iterator_value = iterator_value;
        return self.advanceSyncTask();
    }

    fn materializeSequenceImmediate(self: *Runtime, destination: u16, source: Value, want_tuple: bool, line: u32, column: u32) bool {
        const owns_work_budget = self.beginSynchronousWork();
        defer self.endSynchronousWork(owns_work_budget);
        if (source.asObject()) |header| {
            if (iterator.rangeFromHeader(header)) |range| {
                const count = switch (iterator.rangeLength(&self.heap, range)) {
                    .value => |value| value,
                    .python_exception => |exception| {
                        self.setException(exception, line, column, null);
                        return false;
                    },
                    .engine_error => return self.engineFault(),
                };
                const item_count = number.toInt(usize, count) orelse {
                    self.setException(.{ .kind = .memory_error, .message = "iterable is too large to materialize" }, line, column, null);
                    return false;
                };
                const estimated = std.math.mul(usize, item_count, @sizeOf(Value)) catch {
                    self.setException(.{ .kind = .memory_error, .message = "iterable is too large to materialize" }, line, column, null);
                    return false;
                };
                const remaining = self.session_allocator.max_bytes -| self.session_allocator.live_bytes;
                if (estimated > remaining) {
                    self.setException(.{ .kind = .memory_error, .message = "iterable is too large to materialize" }, line, column, null);
                    return false;
                }
            }
        }

        const iterator_value = switch (self.createVmIterator(source, line, column)) {
            .value => |object| object,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        var roots_frame = gc.RootFrame{};
        var roots = [_]gc.Root{
            .{ .object = &iterator_value.header },
            .{ .object = null },
            .{ .object = null },
        };
        roots_frame.push(&self.heap.roots);
        for (&roots) |*root| roots_frame.add(root);
        defer roots_frame.pop();

        const list = switch (sequence.createList(&self.heap, &.{})) {
            .value => |object| object,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        roots[1].object = &list.header;
        while (true) {
            if (!self.chargeSynchronousWork(line, column)) return false;
            switch (self.nextIteratorValue(iterator_value, destination, line, column)) {
                .item => |item| {
                    roots[2].object = item.asObject();
                    switch (sequence.append(&self.heap, list, item)) {
                        .value => {},
                        .python_exception => |exception| {
                            self.setException(exception, line, column, null);
                            return false;
                        },
                        .engine_error => return self.engineFault(),
                    }
                },
                .done => break,
                .suspended => return self.engineFault(),
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            }
        }
        if (!want_tuple) {
            self.setRegister(destination, Value.object(&list.header));
            return true;
        }
        return self.storeTupleResult(destination, sequence.createTuple(&self.heap, list.items.items), line, column);
    }

    fn executeSliceBuiltin(self: *Runtime, destination: u16, positional: []const Value, keywords: []const binder.Keyword, line: u32, column: u32) bool {
        if (keywords.len != 0 or positional.len == 0 or positional.len > 3) return self.nativeArity(line, column);
        const none = Value.noneValue();
        const start = if (positional.len == 1) none else positional[0];
        const stop = if (positional.len == 1) positional[0] else positional[1];
        const step = if (positional.len == 3) positional[2] else none;
        return switch (slice.create(&self.heap, start, stop, step)) {
            .value => |object| blk: {
                self.setRegister(destination, Value.object(&object.header));
                break :blk true;
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => self.engineFault(),
        };
    }

    fn valueString(_: *Runtime, value: Value) ?[]const u8 {
        const header = value.asObject() orelse return null;
        const text = string.fromHeader(header) orelse return null;
        return string.content(text);
    }

    fn valueBytes(_: *Runtime, value: Value) ?[]const u8 {
        const header = value.asObject() orelse return null;
        const data = byte_module.fromHeader(header) orelse return null;
        return data.data;
    }

    fn valueIsUtf8(self: *Runtime, value: Value) bool {
        const text = self.valueString(value) orelse return false;
        return std.mem.eql(u8, text, "utf-8") or std.mem.eql(u8, text, "utf8");
    }

    fn findListItem(self: *Runtime, list: *sequence.List, needle: Value, line: u32, column: u32) ?usize {
        for (list.items.items, 0..) |value, index| {
            const equal = self.valuesEqual(value, needle, line, column) orelse return null;
            if (equal) return index;
        }
        return null;
    }

    fn valuesEqual(self: *Runtime, left: Value, right: Value, line: u32, column: u32) ?bool {
        if (left.identical(right)) return true;
        if (self.value_equality_depth >= 128) {
            self.setException(.{ .kind = .recursion_error, .message = "maximum recursion depth exceeded in comparison" }, line, column, null);
            return null;
        }
        self.value_equality_depth += 1;
        defer self.value_equality_depth -= 1;
        const left_numeric = number.isIntegerValue(left) or left.asFloat() != null;
        const right_numeric = number.isIntegerValue(right) or right.asFloat() != null;
        if (left_numeric or right_numeric) {
            if (!left_numeric) {
                if (left.asObject()) |header| if (class_module.instanceFromHeader(header) != null) return self.compareWithUserEquality(left, right, line, column);
                return false;
            }
            if (!right_numeric) {
                if (right.asObject()) |header| if (class_module.instanceFromHeader(header) != null) return self.compareWithUserEquality(right, left, line, column);
                return false;
            }
            return switch (number.equal(left, right)) {
                .value => |equal| equal,
                .python_exception => |exception| blk: {
                    self.setException(exception, line, column, null);
                    break :blk null;
                },
                .engine_error => blk: {
                    _ = self.engineFault();
                    break :blk null;
                },
            };
        }
        if (left.asObject()) |left_header| if (class_module.instanceFromHeader(left_header) != null) {
            if (self.invokeSpecialSync(left, "__eq__", &.{right}, line, column)) |result| {
                if (result.asExceptionClass() == null or result.asExceptionClass().? != std.math.maxInt(u8)) return self.valueTruthy(result, line, column);
            } else if (self.last_exception != null) return null;
            if (right.asObject()) |right_header| if (class_module.instanceFromHeader(right_header) != null) {
                if (self.invokeSpecialSync(right, "__eq__", &.{left}, line, column)) |result| {
                    if (result.asExceptionClass() == null or result.asExceptionClass().? != std.math.maxInt(u8)) return self.valueTruthy(result, line, column);
                } else if (self.last_exception != null) return null;
            };
            return false;
        };
        if (left.asObject()) |left_header| {
            if (right.asObject()) |right_header| {
                if (string.fromHeader(left_header)) |left_text| if (string.fromHeader(right_header)) |right_text| return string.equal(left_text, right_text);
                if (byte_module.fromHeader(left_header)) |left_bytes| if (byte_module.fromHeader(right_header)) |right_bytes| return byte_module.equal(left_bytes, right_bytes);
                if (sequence.listFromHeader(left_header)) |left_list| if (sequence.listFromHeader(right_header)) |right_list| {
                    if (left_list.items.items.len != right_list.items.items.len) return false;
                    for (left_list.items.items, right_list.items.items) |a, b| {
                        const equal = self.valuesEqual(a, b, line, column) orelse return null;
                        if (!equal) return false;
                    }
                    return true;
                };
                if (sequence.tupleFromHeader(left_header)) |left_tuple| if (sequence.tupleFromHeader(right_header)) |right_tuple| {
                    if (left_tuple.items.len != right_tuple.items.len) return false;
                    for (left_tuple.items, right_tuple.items) |a, b| {
                        const equal = self.valuesEqual(a, b, line, column) orelse return null;
                        if (!equal) return false;
                    }
                    return true;
                };
                if (dict_module.dictFromHeader(left_header)) |left_mapping| if (dict_module.dictFromHeader(right_header)) |right_mapping| {
                    if (left_mapping.is_set != right_mapping.is_set or left_mapping.size != right_mapping.size) return false;
                    var context = DictEqualityContext{ .runtime = self, .line = line, .column = column };
                    for (left_mapping.entries.items) |entry| {
                        if (!entry.alive) continue;
                        switch (dict_module.lookup(right_mapping, entry.key, entry.hash, &context, dictKeysEqual)) {
                            .missing => return false,
                            .failed => return null,
                            .found => |index| {
                                if (left_mapping.is_set) continue;
                                const item_equal = self.valuesEqual(entry.value, right_mapping.entries.items[index].value, line, column) orelse return null;
                                if (!item_equal) return false;
                            },
                        }
                    }
                    return true;
                };
                if (class_module.instanceFromHeader(right_header) != null) return self.compareWithUserEquality(right, left, line, column);
            }
            return false;
        }
        if (right.asObject()) |right_header| {
            if (class_module.instanceFromHeader(right_header) != null) return self.compareWithUserEquality(right, left, line, column);
            return false;
        }
        return left.tag() == right.tag();
    }

    fn compareWithUserEquality(self: *Runtime, instance: Value, other: Value, line: u32, column: u32) ?bool {
        if (self.invokeSpecialSync(instance, "__eq__", &.{other}, line, column)) |result| {
            if (result.asExceptionClass() != null and result.asExceptionClass().? == std.math.maxInt(u8)) return false;
            return self.valueTruthy(result, line, column);
        }
        if (self.last_exception != null) return null;
        return false;
    }

    fn sortList(self: *Runtime, list: *sequence.List, reverse: bool, line: u32, column: u32) bool {
        const owns_work_budget = self.beginSynchronousWork();
        defer self.endSynchronousWork(owns_work_budget);
        var index: usize = 1;
        while (index < list.items.items.len) : (index += 1) {
            const item = list.items.items[index];
            var position = index;
            while (position > 0) {
                if (!self.chargeSynchronousWork(line, column)) return false;
                const order = self.sortOrder(item, list.items.items[position - 1], line, column) orelse return false;
                const precedes = if (reverse) order == .gt else order == .lt;
                if (!precedes) break;
                list.items.items[position] = list.items.items[position - 1];
                position -= 1;
            }
            list.items.items[position] = item;
        }
        list.version +%= 1;
        return true;
    }

    fn sortListWithKey(self: *Runtime, list: *sequence.List, key: ?Value, reverse: bool, destination: u16, line: u32, column: u32) bool {
        const owns_work_budget = self.beginSynchronousWork();
        defer self.endSynchronousWork(owns_work_budget);
        const callback = key orelse return self.sortList(list, reverse, line, column);
        var list_root = gc.Root{ .object = &list.header };
        var callback_root = gc.Root{ .object = callback.asObject() };
        var stable_roots_frame = gc.RootFrame{};
        stable_roots_frame.push(&self.heap.roots);
        stable_roots_frame.add(&list_root);
        stable_roots_frame.add(&callback_root);
        defer stable_roots_frame.pop();
        const original_version = list.version;
        const original_length = list.items.items.len;
        const allocator = self.heap.allocator;
        const count = list.items.items.len;
        const values = allocator.dupe(Value, list.items.items) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer allocator.free(values);
        const keys = allocator.alloc(Value, count) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer allocator.free(keys);
        const roots = allocator.alloc(gc.Root, count * 2) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer allocator.free(roots);
        for (0..count) |index| {
            roots[index] = .{ .object = values[index].asObject() };
            roots[count + index] = .{ .object = null };
        }
        var value_roots_frame = gc.RootFrame{};
        value_roots_frame.push(&self.heap.roots);
        for (roots) |*root| value_roots_frame.add(root);
        defer value_roots_frame.pop();
        for (values, 0..) |value, index| {
            const returned = self.invokeCallableSync(callback, &.{value}, destination, line, column) orelse return false;
            if (list.version != original_version or list.items.items.len != original_length) {
                self.setException(.{ .kind = .value_error, .message = "list modified during sort" }, line, column, null);
                return false;
            }
            keys[index] = returned;
            roots[count + index].object = returned.asObject();
        }
        var order = allocator.alloc(usize, count) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer allocator.free(order);
        for (order, 0..) |*position, index| position.* = index;
        var index: usize = 1;
        while (index < count) : (index += 1) {
            const selected = order[index];
            var position = index;
            while (position > 0) {
                if (!self.chargeSynchronousWork(line, column)) return false;
                const compared = self.sortOrder(keys[selected], keys[order[position - 1]], line, column) orelse return false;
                if (!(if (reverse) compared == .gt else compared == .lt)) break;
                order[position] = order[position - 1];
                position -= 1;
            }
            order[position] = selected;
        }
        if (list.version != original_version or list.items.items.len != original_length) {
            self.setException(.{ .kind = .value_error, .message = "list modified during sort" }, line, column, null);
            return false;
        }
        for (order, 0..) |source_index, target_index| list.items.items[target_index] = values[source_index];
        list.version +%= 1;
        return true;
    }

    fn isCallable(self: *const Runtime, value: Value) bool {
        _ = self;
        const header = value.asObject() orelse return false;
        if (class_module.classFromHeader(header) != null or class_module.boundMethodFromHeader(header) != null) return true;
        if (class_module.instanceFromHeader(header)) |instance| return class_module.classAttribute(instance.class, "__call__") != null;
        const function = functions.functionFromHeader(header) orelse return false;
        return function.native != null or function.code != null;
    }

    fn beginSynchronousWork(self: *Runtime) bool {
        if (self.synchronous_work_remaining != null) return false;
        self.synchronous_work_remaining = std.math.cast(usize, self.max_instructions -| self.work_executed) orelse std.math.maxInt(usize);
        return true;
    }

    fn endSynchronousWork(self: *Runtime, owns_budget: bool) void {
        if (owns_budget) self.synchronous_work_remaining = null;
    }

    fn chargeSynchronousWork(self: *Runtime, line: u32, column: u32) bool {
        const remaining = self.synchronous_work_remaining orelse return true;
        if (remaining == 0) {
            _ = line;
            _ = column;
            self.limit_reached = true;
            return false;
        }
        self.synchronous_work_remaining = remaining - 1;
        self.work_executed +%= 1;
        return true;
    }

    fn chargeBulkWork(self: *Runtime, amount: usize) bool {
        const amount_u64 = std.math.cast(u64, amount) orelse {
            self.limit_reached = true;
            return false;
        };
        if (amount_u64 > self.max_instructions -| self.work_executed) {
            self.limit_reached = true;
            return false;
        }
        if (self.synchronous_work_remaining) |remaining| {
            if (amount > remaining) {
                self.limit_reached = true;
                return false;
            }
            self.synchronous_work_remaining = remaining - amount;
        }
        self.work_executed += amount_u64;
        return true;
    }

    fn repeatResultFitsSessionHeap(self: *Runtime, estimated_bytes: usize) bool {
        if (estimated_bytes > self.session_allocator.max_bytes -| self.session_allocator.live_bytes) _ = self.heap.collect();
        return estimated_bytes <= self.session_allocator.max_bytes -| self.session_allocator.live_bytes;
    }

    fn executeSequenceRepeat(self: *Runtime, destination: u16, sequence_value: Value, multiplier: Value, line: u32, column: u32) bool {
        if (sequence.repeatWorkCost(sequence_value, multiplier)) |cost| {
            // Reproduce MemoryError when the result buffers cannot fit the
            // session heap; only charge native work for viable allocations.
            if (sequence.repeatAllocationEstimate(sequence_value, cost)) |estimated_bytes| {
                if (self.repeatResultFitsSessionHeap(estimated_bytes) and !self.chargeBulkWork(cost)) return false;
            }
        }
        return self.storeValueResult(destination, sequence.repeat(&self.heap, sequence_value, multiplier), line, column);
    }

    fn chargeBytecode(self: *Runtime) bool {
        if (self.instructions_executed >= self.max_instructions or self.work_executed >= self.max_instructions) {
            self.limit_reached = true;
            return false;
        }
        self.instructions_executed += 1;
        self.work_executed +%= 1;
        return true;
    }

    fn chargeNestedInstruction(self: *Runtime) bool {
        if (self.instructions_executed >= self.max_instructions) {
            self.limit_reached = true;
            return false;
        }
        self.instructions_executed += 1;
        return true;
    }

    fn invokeCallableSync(self: *Runtime, callable: Value, args: []const Value, destination: u16, line: u32, column: u32) ?Value {
        const header = callable.asObject() orelse {
            self.setException(.{ .kind = .type_error, .message = "object is not callable" }, line, column, null);
            return null;
        };
        if (class_module.boundMethodFromHeader(header)) |bound| {
            const allocator = self.heap.allocator;
            const expanded = allocator.alloc(Value, args.len + 1) catch {
                self.setException(exceptions.memoryError(), line, column, null);
                return null;
            };
            defer allocator.free(expanded);
            expanded[0] = bound.receiver;
            @memcpy(expanded[1..], args);
            return self.invokeCallableSync(bound.callable, expanded, destination, line, column);
        }
        const function = functions.functionFromHeader(header) orelse {
            self.setException(.{ .kind = .type_error, .message = "object is not callable" }, line, column, null);
            return null;
        };
        if (function.native) |native| {
            if (!self.executeNativeCall(destination, native, function.bound_self, args, &.{}, line, column)) return null;
            return self.registers[destination];
        }
        return self.invokePythonSync(callable, args, destination, line, column);
    }

    fn invokeSpecialSync(self: *Runtime, receiver: Value, name: []const u8, arguments: []const Value, line: u32, column: u32) ?Value {
        const header = receiver.asObject() orelse return null;
        const instance = class_module.instanceFromHeader(header) orelse return null;
        const callable = class_module.classAttribute(instance.class, name) orelse return null;
        const caller = self.top_frame orelse {
            _ = self.engineFault();
            return null;
        };
        const scratch: u16 = if (caller.code.register_count == 0) return null else @intCast(caller.code.register_count - 1);
        const saved = self.registers[scratch];
        var roots = [_]gc.Root{
            .{ .object = saved.asObject() },
            .{ .object = receiver.asObject() },
            .{ .object = callable.asObject() },
            .{ .object = null },
        };
        var frame = gc.RootFrame{};
        frame.push(&self.heap.roots);
        for (&roots) |*root| frame.add(root);
        defer frame.pop();
        const allocator = self.heap.allocator;
        const expanded = allocator.alloc(Value, arguments.len + 1) catch {
            self.setException(exceptions.memoryError(), line, column, null);
            return null;
        };
        defer allocator.free(expanded);
        expanded[0] = receiver;
        @memcpy(expanded[1..], arguments);
        const result = self.invokeCallableSync(callable, expanded, scratch, line, column) orelse {
            self.restoreFrameRegister(caller, scratch, saved);
            return null;
        };
        roots[3].object = result.asObject();
        self.restoreFrameRegister(caller, scratch, saved);
        return result;
    }

    fn invokeValueSync(self: *Runtime, callable: Value, arguments: []const Value, line: u32, column: u32) ?Value {
        const caller = self.top_frame orelse {
            _ = self.engineFault();
            return null;
        };
        if (caller.code.register_count == 0) {
            _ = self.engineFault();
            return null;
        }
        const scratch: u16 = @intCast(caller.code.register_count - 1);
        const saved = self.registers[scratch];
        var roots = [_]gc.Root{ .{ .object = saved.asObject() }, .{ .object = callable.asObject() }, .{ .object = null } };
        var frame = gc.RootFrame{};
        frame.push(&self.heap.roots);
        for (&roots) |*root| frame.add(root);
        defer frame.pop();
        const result = self.invokeCallableSync(callable, arguments, scratch, line, column) orelse {
            self.restoreFrameRegister(caller, scratch, saved);
            return null;
        };
        roots[2].object = result.asObject();
        self.restoreFrameRegister(caller, scratch, saved);
        return result;
    }

    fn restoreFrameRegister(self: *Runtime, frame: *Frame, index: u16, value: Value) void {
        const position: usize = index;
        if (position >= frame.registers.len or position >= frame.roots.len) {
            _ = self.engineFault();
            return;
        }
        frame.registers[position] = value;
        frame.roots[position].object = value.asObject();
        if (self.top_frame == frame) self.activateFrame(frame);
    }

    fn invokePythonSync(self: *Runtime, callable: Value, args: []const Value, destination: u16, line: u32, column: u32) ?Value {
        const owns_work_budget = self.beginSynchronousWork();
        defer self.endSynchronousWork(owns_work_budget);
        const previous_callback_depth = self.sync_callback_depth;
        self.sync_callback_depth += 1;
        var retain_callback_depth = false;
        defer {
            if (!retain_callback_depth) self.sync_callback_depth -= 1;
        }
        const header = callable.asObject() orelse {
            self.setException(.{ .kind = .type_error, .message = "object is not callable" }, line, column, null);
            return null;
        };
        const function = functions.functionFromHeader(header) orelse {
            self.setException(.{ .kind = .type_error, .message = "object is not callable" }, line, column, null);
            return null;
        };
        const function_code = function.code orelse {
            self.setException(.{ .kind = .type_error, .message = "native callbacks are not supported here" }, line, column, null);
            return null;
        };
        const caller = self.top_frame orelse {
            _ = self.engineFault();
            return null;
        };
        const allocator = self.heap.allocator;
        const binding = binder.bindFunction(&self.heap, allocator, function_code.parameter_names, function_code.parameter_flags, function.defaults, args, &.{}) catch |err| {
            self.setBinderException(err, line, column);
            return null;
        };
        defer allocator.free(binding.values);
        if (binding.extra_keywords.len != 0) allocator.free(binding.extra_keywords);
        const bound_roots = allocator.alloc(gc.Root, binding.values.len) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return null;
        };
        defer allocator.free(bound_roots);
        for (binding.values, 0..) |value, index| bound_roots[index] = .{ .object = value.asObject() };
        var bound_frame = gc.RootFrame{};
        bound_frame.push(&self.heap.roots);
        for (bound_roots) |*root| bound_frame.add(root);
        var bound_active = true;
        defer if (bound_active) bound_frame.pop();
        const frame = self.allocateFrame(function_code, destination) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return null;
        };
        var complete = false;
        var suspended = false;
        defer if (!complete) {
            if (!suspended) {
                if (bound_active) {
                    bound_frame.pop();
                    bound_active = false;
                }
                self.unwindFramesUntil(caller);
            }
        };
        frame.root_frame.pop();
        bound_frame.pop();
        bound_active = false;
        frame.root_frame.push(&self.heap.roots);
        for (frame.roots) |*root| frame.root_frame.add(root);
        bound_frame.push(&self.heap.roots);
        for (bound_roots) |*root| bound_frame.add(root);
        bound_active = true;
        if (function.cells.len != function_code.free_names.len) {
            _ = self.engineFault();
            return null;
        }
        if (function_code.flags & bytecode.code_flags.class_body != 0) {
            const class_header = function.bound_self.asObject() orelse {
                _ = self.engineFault();
                return null;
            };
            const class = class_module.classFromHeader(class_header) orelse {
                _ = self.engineFault();
                return null;
            };
            frame.class_namespace = class;
            frame.roots[frame.classRootIndex()].object = &class.header;
        }
        for (function.cells, 0..) |cell, index| {
            frame.free_cells[index] = cell;
            frame.roots[frame.freeRootStart() + index].object = &cell.header;
        }
        for (function_code.cell_names, 0..) |_, index| {
            const cell = functions.createCell(&self.heap, Value.unboundValue()) catch {
                self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
                return null;
            };
            frame.local_cells[index] = cell;
            frame.roots[frame.cellRootStart() + index].object = &cell.header;
        }
        for (function_code.parameter_names, 0..) |name, index| {
            if (!self.storeFrameLocal(frame, name, binding.values[index])) {
                _ = self.engineFault();
                return null;
            }
        }
        bound_frame.pop();
        bound_active = false;
        if (self.sync_task) |*task| {
            if (previous_callback_depth == 0 and self.resuming_generator == null) {
                task.callback_in_progress = true;
                task.callback_failed = false;
                task.frame.ip = task.call_ip;
                self.instruction_pointer = task.call_ip;
                task.callback_depth_held = true;
                retain_callback_depth = true;
                suspended = true;
                return null;
            }
        }
        while (self.top_frame != caller) {
            if (!self.chargeSynchronousWork(line, column) or !self.chargeNestedInstruction()) {
                return null;
            }
            const active = self.top_frame orelse return null;
            if (active.ip >= active.code.instructions.len or active.code.positions.len != active.code.instructions.len) {
                _ = self.engineFault();
                return null;
            }
            const position = active.code.positions[active.ip];
            const instruction = active.code.instructions[active.ip];
            active.ip += 1;
            self.activateFrame(active);
            if (!self.execute(instruction, position.line, position.column)) {
                if (self.limit_reached) return null;
                if (!self.engine_failed and self.last_exception != null and self.unwindPythonExceptionUntil(caller)) continue;
                return null;
            }
            if (self.top_frame == active) active.ip = self.instruction_pointer;
        }
        complete = true;
        return self.registers[destination];
    }

    fn sortOrder(self: *Runtime, left: Value, right: Value, line: u32, column: u32) ?std.math.Order {
        if (left.asObject()) |left_header| if (right.asObject()) |right_header| {
            if (string.fromHeader(left_header)) |left_text| if (string.fromHeader(right_header)) |right_text| return std.mem.order(u8, string.content(left_text), string.content(right_text));
        };
        return switch (number.compare(left, right)) {
            .value => |order| switch (order) {
                .less => .lt,
                .equal => .eq,
                .greater => .gt,
                .unordered => null,
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk null;
            },
            .engine_error => blk: {
                _ = self.engineFault();
                break :blk null;
            },
        };
    }

    fn splitStringResult(self: *Runtime, destination: u16, text: *string.Str, separator: []const u8, line: u32, column: u32) bool {
        const split = string.split(text, separator);
        const iterator_value = switch (split) {
            .value => |value| value,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        return self.splitStringIteratorResult(destination, text, iterator_value, line, column);
    }

    fn splitStringWhitespaceResult(self: *Runtime, destination: u16, text: *string.Str, line: u32, column: u32) bool {
        return self.splitStringIteratorResult(destination, text, string.splitWhitespace(text), line, column);
    }

    fn splitStringIteratorResult(
        self: *Runtime,
        destination: u16,
        text: *string.Str,
        iterator_value: string.SplitIterator,
        line: u32,
        column: u32,
    ) bool {
        var counter = iterator_value;
        var count: usize = 0;
        while (counter.next() != null) count += 1;
        const values = self.heap.allocator.alloc(Value, count) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer self.heap.allocator.free(values);
        const roots = self.heap.allocator.alloc(gc.Root, count) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer self.heap.allocator.free(roots);
        @memset(roots, .{ .object = null });
        var frame = gc.RootFrame{};
        frame.push(&self.heap.roots);
        var text_root = gc.Root{ .object = &text.header };
        frame.add(&text_root);
        for (roots) |*root| frame.add(root);
        defer frame.pop();
        var index: usize = 0;
        var parts = iterator_value;
        while (parts.next()) |part| {
            const created = string.create(&self.heap, part);
            const object = switch (created) {
                .value => |value| value,
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            };
            values[index] = Value.object(&object.header);
            roots[index].object = &object.header;
            index += 1;
        }
        return self.storeListResult(destination, sequence.createList(&self.heap, values[0..index]), line, column);
    }

    fn splitBytesResult(self: *Runtime, destination: u16, data: *byte_module.Bytes, separator: []const u8, line: u32, column: u32) bool {
        if (separator.len == 0) return self.nativeTypeError(line, column, "empty separator");
        var count: usize = 1;
        var cursor: usize = 0;
        while (std.mem.indexOf(u8, data.data[cursor..], separator)) |relative| {
            cursor += relative + separator.len;
            count += 1;
        }
        const values = self.heap.allocator.alloc(Value, count) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer self.heap.allocator.free(values);
        const roots = self.heap.allocator.alloc(gc.Root, count) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer self.heap.allocator.free(roots);
        @memset(roots, .{ .object = null });
        var frame = gc.RootFrame{};
        frame.push(&self.heap.roots);
        for (roots) |*root| frame.add(root);
        defer frame.pop();
        var offset: usize = 0;
        var parts: usize = 0;
        while (parts < count) : (parts += 1) {
            const relative = std.mem.indexOf(u8, data.data[offset..], separator);
            const end = if (relative) |found| offset + found else data.data.len;
            const created = byte_module.create(&self.heap, data.data[offset..end]);
            const object = switch (created) {
                .value => |value| value,
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            };
            values[parts] = Value.object(&object.header);
            roots[parts].object = &object.header;
            if (relative) |found| offset = end + found - found + separator.len else offset = data.data.len;
        }
        return self.storeListResult(destination, sequence.createList(&self.heap, values), line, column);
    }

    fn joinStringResult(self: *Runtime, destination: u16, separator: *string.Str, iterable: Value, line: u32, column: u32) bool {
        const count = sequence.length(iterable) orelse return self.nativeTypeError(line, column, "join expects a list or tuple");
        const parts = self.heap.allocator.alloc([]const u8, count) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer self.heap.allocator.free(parts);
        for (0..count) |index| {
            const value = sequence.itemAt(iterable, index) orelse return self.engineFault();
            parts[index] = self.valueString(value) orelse return self.nativeTypeError(line, column, "sequence item is not a string");
        }
        return self.storeStringResult(destination, string.join(&self.heap, separator.data, parts), line, column);
    }

    fn executeMakeFunction(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
        const code = self.activeCode() orelse return self.engineFault();
        const site_index: usize = instruction.index32();
        if (site_index >= code.function_sites.len) return self.engineFault();
        const site = code.function_sites[site_index];
        const nested_index: usize = site.code_index;
        if (nested_index >= code.nested_codes.len) return self.engineFault();
        const nested_code = code.nested_codes[nested_index];
        const start: usize = site.value_start;
        const default_count: usize = site.default_count;
        const annotation_count: usize = site.annotation_count + @as(usize, @intFromBool(site.has_return_annotation));
        const value_count = default_count + annotation_count;
        if (start > code.argument_registers.len or value_count > code.argument_registers.len - start) return self.engineFault();
        const allocator = self.heap.allocator;
        const defaults = allocator.alloc(Value, nested_code.parameter_names.len) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer allocator.free(defaults);
        @memset(defaults, Value.unboundValue());
        var default_index: usize = 0;
        for (nested_code.parameter_flags, 0..) |flags, parameter_index| {
            if (flags & ast_module.parameter_flags.has_default == 0) continue;
            if (default_index >= default_count) return self.engineFault();
            const register = code.argument_registers[start + default_index];
            if (!self.validRegister(register)) return self.engineFault();
            defaults[parameter_index] = self.registers[register];
            default_index += 1;
        }
        if (default_index != default_count) return self.engineFault();
        const annotations = allocator.alloc(Value, annotation_count) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer allocator.free(annotations);
        for (annotations, 0..) |*annotation, index| {
            const register = code.argument_registers[start + default_count + index];
            if (!self.validRegister(register)) return self.engineFault();
            annotation.* = self.registers[register];
        }
        const annotation_dict = switch (dict_module.create(&self.heap, false)) {
            .value => |mapping| mapping,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        var annotation_dict_root = gc.Root{ .object = &annotation_dict.header };
        var annotation_root_frame = gc.RootFrame{};
        annotation_root_frame.push(&self.heap.roots);
        annotation_root_frame.add(&annotation_dict_root);
        defer annotation_root_frame.pop();
        var annotation_value_index: usize = 0;
        for (nested_code.parameter_flags, 0..) |flags, parameter_index| {
            if (flags & ast_module.parameter_flags.has_annotation == 0) continue;
            if (annotation_value_index >= site.annotation_count or annotation_value_index >= annotations.len) return self.engineFault();
            const key = switch (string.create(&self.heap, nested_code.parameter_names[parameter_index])) {
                .value => |value| value,
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            };
            if (!self.setMappingValue(annotation_dict, Value.object(&key.header), annotations[annotation_value_index], line, column)) return false;
            annotation_value_index += 1;
        }
        if (site.has_return_annotation) {
            if (annotation_value_index >= annotations.len) return self.engineFault();
            const key = switch (string.create(&self.heap, "return")) {
                .value => |value| value,
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            };
            if (!self.setMappingValue(annotation_dict, Value.object(&key.header), annotations[annotation_value_index], line, column)) return false;
        }
        const captured = allocator.alloc(*functions.Cell, nested_code.free_names.len) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer allocator.free(captured);
        for (nested_code.free_names, 0..) |name, index| {
            captured[index] = self.findCell(name) orelse return self.engineFault();
        }
        switch (functions.createPython(&self.heap, nested_code, &self.environment.header, captured, defaults, annotations, Value.object(&annotation_dict.header))) {
            .value => |function| self.setRegister(instruction.a(), Value.object(&function.header)),
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
        }
        return true;
    }

    fn executeMakeClass(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
        const parent_code = self.activeCode() orelse return self.engineFault();
        if (!self.validRegister(instruction.a())) return self.engineFault();
        const site_index: usize = instruction.index32();
        if (site_index >= parent_code.class_sites.len) return self.engineFault();
        const site = parent_code.class_sites[site_index];
        if (site.code_index >= parent_code.nested_codes.len or site.name_index >= parent_code.names.len) return self.engineFault();
        const body_code = parent_code.nested_codes[site.code_index];
        const name = parent_code.names[site.name_index];
        const base_start: usize = site.base_start;
        const base_count: usize = site.base_count;
        if (base_start > parent_code.argument_registers.len or base_count > parent_code.argument_registers.len - base_start) return self.engineFault();
        const bases = self.heap.allocator.alloc(*class_module.Class, base_count) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer self.heap.allocator.free(bases);
        for (parent_code.argument_registers[base_start..][0..base_count], 0..) |register, index| {
            if (!self.validRegister(register)) return self.engineFault();
            const header = self.registers[register].asObject() orelse return self.nativeTypeError(line, column, "class bases must be types");
            bases[index] = class_module.classFromHeader(header) orelse return self.nativeTypeError(line, column, "class bases must be types");
        }
        if (!self.ensureBuiltinClasses(line, column)) return false;
        const object_header = self.object_class_root.object orelse return self.engineFault();
        const object_class = class_module.classFromHeader(object_header) orelse return self.engineFault();
        const created_class = class_module.createClass(&self.heap, name, bases, object_class);
        const class = switch (created_class) {
            .value => |selected| selected,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        const class_value = Value.object(&class.header);
        self.setRegister(instruction.a(), class_value);

        const captured = self.heap.allocator.alloc(*functions.Cell, body_code.free_names.len) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer self.heap.allocator.free(captured);
        for (body_code.free_names, 0..) |free_name, index| {
            captured[index] = self.findCell(free_name) orelse return self.engineFault();
        }
        const frame = self.allocateFrame(body_code, instruction.a()) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        frame.class_namespace = class;
        frame.return_override = class_value;
        frame.roots[frame.classRootIndex()].object = &class.header;
        frame.roots[frame.returnOverrideRootIndex()].object = &class.header;
        for (captured, 0..) |cell, index| {
            frame.free_cells[index] = cell;
            frame.roots[frame.freeRootStart() + index].object = &cell.header;
        }
        for (body_code.cell_names, 0..) |cell_name, index| {
            const cell = functions.createCell(&self.heap, if (std.mem.eql(u8, cell_name, "__class__")) class_value else Value.unboundValue()) catch {
                self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
                return false;
            };
            frame.local_cells[index] = cell;
            frame.roots[frame.cellRootStart() + index].object = &cell.header;
            if (std.mem.eql(u8, cell_name, "__class__")) class.class_cell = cell;
        }
        return true;
    }

    fn setBinderException(self: *Runtime, err: anyerror, line: u32, column: u32) void {
        const message: []const u8 = if (err == error.TooManyPositional) "too many positional arguments" else if (err == error.MissingArgument) "missing required argument" else if (err == error.MultipleValues) "multiple values for an argument" else if (err == error.PositionalOnlyAsKeyword) "positional-only argument passed as a keyword" else if (err == error.UnexpectedKeyword) "unexpected keyword argument" else if (err == error.OutOfMemory) "session memory limit exceeded" else "invalid call arguments";
        const kind: PythonExceptionKind = if (err == error.OutOfMemory) .memory_error else .type_error;
        self.setException(.{ .kind = kind, .message = message }, line, column, null);
    }

    fn storeFrameLocal(self: *Runtime, frame: *Frame, name: []const u8, value: Value) bool {
        if (indexOfName(frame.code.cell_names, name)) |index| {
            const cell = frame.local_cells[index] orelse return false;
            cell.value = value;
            return true;
        }
        const index = indexOfName(frame.code.local_names, name) orelse return false;
        frame.locals[index] = value;
        frame.roots[frame.localRootStart() + index].object = value.asObject();
        _ = self;
        return true;
    }

    fn findCell(self: *Runtime, name: []const u8) ?*functions.Cell {
        var frame = self.top_frame;
        while (frame) |active| : (frame = active.previous) {
            if (indexOfName(active.code.cell_names, name)) |index| return active.local_cells[index];
            if (indexOfName(active.code.free_names, name)) |index| return active.free_cells[index];
        }
        return null;
    }

    fn loadLocal(self: *Runtime, destination: u16, name: []const u8, binding: u8, line: u32, column: u32) bool {
        const frame = self.top_frame orelse return self.engineFault();
        const kind: bytecode.LocalBinding = switch (binding) {
            0 => .local,
            1 => .cell,
            2 => .free,
            else => return self.engineFault(),
        };
        const value = switch (kind) {
            .local => blk: {
                const index = indexOfName(frame.code.local_names, name) orelse return self.engineFault();
                break :blk frame.locals[index];
            },
            .cell => blk: {
                const index = indexOfName(frame.code.cell_names, name) orelse return self.engineFault();
                const cell = frame.local_cells[index] orelse return self.engineFault();
                break :blk cell.value;
            },
            .free => blk: {
                const index = indexOfName(frame.code.free_names, name) orelse return self.engineFault();
                const cell = frame.free_cells[index] orelse return self.engineFault();
                break :blk cell.value;
            },
        };
        if (value.tag() == .unbound or value.tag() == .deleted) {
            if (frame.class_namespace) |class| {
                if (class_module.ownClassAttribute(class, name)) |class_value| {
                    self.setRegister(destination, class_value);
                    return true;
                }
                if (self.globalValue(name)) |fallback| {
                    self.setRegister(destination, fallback);
                    return true;
                }
                if (std.mem.eql(u8, name, "object") or std.mem.eql(u8, name, "type")) {
                    if (!self.ensureBuiltinClasses(line, column)) return false;
                    const root = if (std.mem.eql(u8, name, "object")) self.object_class_root.object else self.type_class_root.object;
                    self.setRegister(destination, Value.object(root orelse return self.engineFault()));
                    return true;
                }
                if (self.builtinValue(name)) |fallback| {
                    self.setRegister(destination, fallback);
                    return true;
                }
                if (builtinNative(name)) |native| {
                    return switch (functions.createNative(&self.heap, native)) {
                        .value => |function| blk: {
                            self.setRegister(destination, Value.object(&function.header));
                            break :blk true;
                        },
                        .python_exception => |exception| blk: {
                            self.setException(exception, line, column, null);
                            break :blk false;
                        },
                    };
                }
                if (exceptions.builtinKind(name)) |exception_kind| {
                    self.setRegister(destination, Value.exceptionClass(@intCast(@intFromEnum(exception_kind))));
                    return true;
                }
                self.setException(.{ .kind = .name_error, .message = "name is not defined" }, line, column, name);
                return false;
            }
            const kind_error: PythonExceptionKind = if (kind == .free) .name_error else .unbound_local_error;
            self.setException(.{ .kind = kind_error, .message = "local variable is not bound" }, line, column, null);
            return false;
        }
        self.setRegister(destination, value);
        return true;
    }

    fn storeLocal(self: *Runtime, source: u16, name: []const u8, binding: u8, line: u32, column: u32) bool {
        const frame = self.top_frame orelse return self.engineFault();
        const kind: bytecode.LocalBinding = switch (binding) {
            0 => .local,
            1 => .cell,
            2 => .free,
            else => return self.engineFault(),
        };
        const value = self.registers[source];
        switch (kind) {
            .local => {
                const index = indexOfName(frame.code.local_names, name) orelse return self.engineFault();
                if (frame.class_namespace) |class| {
                    class_module.setClassAttribute(&self.heap, class, name, value) catch {
                        self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
                        return false;
                    };
                }
                frame.locals[index] = value;
                frame.roots[frame.localRootStart() + index].object = value.asObject();
            },
            .cell => {
                const index = indexOfName(frame.code.cell_names, name) orelse return self.engineFault();
                const cell = frame.local_cells[index] orelse return self.engineFault();
                cell.value = value;
            },
            .free => {
                const index = indexOfName(frame.code.free_names, name) orelse return self.engineFault();
                const cell = frame.free_cells[index] orelse return self.engineFault();
                cell.value = value;
            },
        }
        return true;
    }

    fn clearGlobals(self: *Runtime) void {
        for (self.environment.entries.items) |entry| self.heap.allocator.free(entry.name);
        self.environment.entries.clearRetainingCapacity();
    }

    fn execute(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
        const code = self.activeCode() orelse return false;
        const op = instruction.opcodeTag() orelse return self.engineFault();
        switch (op) {
            .load_const => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                const index: usize = @intCast(instruction.index32());
                if (index >= code.constants.len) return self.engineFault();
                self.setRegister(instruction.a(), code.constants[index]);
            },
            .load_none => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                self.setRegister(instruction.a(), Value.noneValue());
            },
            .enter_try => return self.enterTry(instruction.index32(), line, column),
            .with_enter => {
                if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b())) return self.engineFault();
                return self.executeWithEnter(instruction.a(), self.registers[instruction.b()], line, column);
            },
            .with_exit => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                return self.executeWithExit(instruction.a(), self.registers[instruction.a()], line, column);
            },
            .try_else => {
                const frame = self.top_frame orelse return self.engineFault();
                if (frame.try_blocks.items.len == 0) return self.engineFault();
                const block = &frame.try_blocks.items[frame.try_blocks.items.len - 1];
                if (block.site_index != instruction.index32() or block.phase != .body) return self.engineFault();
                block.phase = .else_body;
            },
            .try_complete => {
                const frame = self.top_frame orelse return self.engineFault();
                return self.completeTry(frame, instruction.index32());
            },
            .try_unhandled => {
                const frame = self.top_frame orelse return self.engineFault();
                if (frame.try_blocks.items.len == 0) return self.engineFault();
                const block = &frame.try_blocks.items[frame.try_blocks.items.len - 1];
                if (block.site_index != instruction.index32() or self.last_exception == null) return self.engineFault();
                const site = frame.code.try_sites[block.site_index];
                if (site.finalizer_ip != std.math.maxInt(u32)) {
                    self.savePendingException(frame, block);
                    block.phase = .finally_body;
                    return self.setFrameInstruction(frame, site.finalizer_ip);
                }
                _ = self.popTryBlock(frame, false);
                return false;
            },
            .load_exception => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                const active = self.active_exception orelse {
                    self.setException(exceptions.memoryError(), line, column, null);
                    return false;
                };
                self.setRegister(instruction.a(), Value.object(&active.header));
            },
            .match_exception => {
                if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b())) return self.engineFault();
                const kind = self.activeExceptionKind() orelse return self.engineFault();
                const matched = self.matchesExceptionType(self.registers[instruction.b()], kind, line, column) orelse return false;
                self.setRegister(instruction.a(), if (matched) Value.trueValue() else Value.falseValue());
            },
            .bind_exception => {
                const frame = self.top_frame orelse return self.engineFault();
                if (instruction.index32() >= frame.code.names.len or frame.try_blocks.items.len == 0) return self.engineFault();
                const active = self.active_exception orelse return self.engineFault();
                const name = frame.code.names[instruction.index32()];
                if (!self.storeBoundValue(frame, name, instruction.flags(), Value.object(&active.header), line, column)) return false;
                const block = &frame.try_blocks.items[frame.try_blocks.items.len - 1];
                block.cleanup_name_index = instruction.index32();
                block.cleanup_binding = instruction.flags();
            },
            .accept_exception => {
                const frame = self.top_frame orelse return self.engineFault();
                return self.acceptCurrentException(frame, instruction.index32());
            },
            .raise_value, .raise_current => return self.executeRaise(instruction, line, column),
            .assert_failed => {
                var message: []const u8 = "";
                var owned: ?[]u8 = null;
                if (instruction.flags() & 1 != 0) {
                    if (!self.validRegister(instruction.a())) return self.engineFault();
                    owned = self.renderValueOwned(self.registers[instruction.a()], false, line, column) orelse return false;
                    message = owned.?;
                }
                defer if (owned) |text| self.heap.allocator.free(text);
                self.setException(.{ .kind = .assertion_error, .message = message }, line, column, null);
                return false;
            },
            .end_finally => {
                const frame = self.top_frame orelse return self.engineFault();
                return self.completeFinally(frame, instruction.index32(), line, column);
            },
            .load_global => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                const name = self.codeName(instruction.index32()) orelse return self.engineFault();
                if (self.globalValue(name)) |value| {
                    self.setRegister(instruction.a(), value);
                } else if (std.mem.eql(u8, name, "object") or std.mem.eql(u8, name, "type")) {
                    if (!self.ensureBuiltinClasses(line, column)) return false;
                    const root = if (std.mem.eql(u8, name, "object")) self.object_class_root.object else self.type_class_root.object;
                    self.setRegister(instruction.a(), Value.object(root orelse return self.engineFault()));
                } else if (self.builtinValue(name)) |value| {
                    self.setRegister(instruction.a(), value);
                } else if (builtinNative(name)) |native| {
                    switch (functions.createNative(&self.heap, native)) {
                        .value => |function| self.setRegister(instruction.a(), Value.object(&function.header)),
                        .python_exception => |exception| {
                            self.setException(exception, line, column, null);
                            return false;
                        },
                    }
                } else if (exceptions.builtinKind(name)) |kind| {
                    self.setRegister(instruction.a(), Value.exceptionClass(@intCast(@intFromEnum(kind))));
                } else {
                    self.setException(.{ .kind = .name_error, .message = "name is not defined" }, line, column, name);
                    return false;
                }
            },
            .store_global => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                const name = self.codeName(instruction.index32()) orelse return self.engineFault();
                if (!self.storeGlobal(name, self.registers[instruction.a()])) {
                    self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
                    return false;
                }
            },
            .store_annotation => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                const name = self.codeName(instruction.index32()) orelse return self.engineFault();
                return self.storeAnnotation(name, self.registers[instruction.a()], instruction.flags() != 0, line, column);
            },
            .load_local => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                const name = self.codeName(instruction.index32()) orelse return self.engineFault();
                if (!self.loadLocal(instruction.a(), name, instruction.flags(), line, column)) return false;
            },
            .store_local => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                const name = self.codeName(instruction.index32()) orelse return self.engineFault();
                if (!self.storeLocal(instruction.a(), name, instruction.flags(), line, column)) return false;
            },
            .move => {
                if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b())) return self.engineFault();
                self.setRegister(instruction.a(), self.registers[instruction.b()]);
            },
            .unary => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                const input = self.registers[instruction.a()];
                if (instruction.flags() == 3) {
                    const truth = self.valueTruthy(input, line, column) orelse return false;
                    self.setRegister(instruction.a(), if (truth) Value.falseValue() else Value.trueValue());
                    return true;
                }
                const result = switch (@as(u8, instruction.flags())) {
                    0 => number.positive(&self.heap, input),
                    1 => number.negative(&self.heap, input),
                    2 => number.bitNot(&self.heap, input),
                    else => return self.engineFault(),
                };
                if (!self.storeNumberResult(instruction.a(), result, line, column)) return false;
            },
            .binary => {
                if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b())) return self.engineFault();
                const left = self.registers[instruction.a()];
                const right = self.registers[instruction.b()];
                if (!self.executeBinary(instruction.a(), left, right, instruction.flags(), line, column)) return false;
            },
            .print => {
                if (self.globalValue("print") != null) {
                    self.setException(.{ .kind = .type_error, .message = "'int' object is not callable" }, line, column, null);
                    return false;
                }
                const start: usize = @intCast(instruction.index32());
                const count: usize = instruction.a();
                if (start > code.argument_registers.len or count > code.argument_registers.len - start) return self.engineFault();
                for (code.argument_registers[start..][0..count]) |register| if (!self.validRegister(register)) return self.engineFault();
                if (!self.executePrint(code.argument_registers[start..][0..count], line, column)) return false;
            },
            .return_value => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                const result = self.registers[instruction.a()];
                const frame = self.top_frame orelse return self.engineFault();
                return self.beginReturnTransfer(frame, result, line, column);
            },
            .call => {
                if (!self.validRegister(instruction.a()) or !self.executeCall(instruction, line, column)) return false;
            },
            .make_function => {
                if (!self.validRegister(instruction.a()) or !self.executeMakeFunction(instruction, line, column)) return false;
            },
            .make_class => {
                if (!self.validRegister(instruction.a()) or !self.executeMakeClass(instruction, line, column)) return false;
            },
            .make_sequence => return self.executeMakeSequence(instruction, line, column),
            .list_append_value => {
                if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b())) return self.engineFault();
                const header = self.registers[instruction.a()].asObject() orelse return self.engineFault();
                const list = sequence.listFromHeader(header) orelse return self.engineFault();
                return switch (sequence.append(&self.heap, list, self.registers[instruction.b()])) {
                    .value => true,
                    .python_exception => |exception| blk: {
                        self.setException(exception, line, column, null);
                        break :blk false;
                    },
                    .engine_error => self.engineFault(),
                };
            },
            .format_value => {
                if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b())) return self.engineFault();
                const site: usize = instruction.c();
                if (site >= code.format_sites.len) return self.engineFault();
                return self.executeFormatValue(instruction.a(), self.registers[instruction.b()], code.format_sites[site].spec, instruction.flags(), line, column);
            },
            .make_generator => {
                if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b()) or !self.validRegister(instruction.c())) return self.engineFault();
                const created = iterator.createGenerator(&self.heap, self.registers[instruction.b()], self.registers[instruction.c()]);
                return self.storeIteratorOutcome(instruction.a(), created, line, column);
            },
            .yield_value => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                const selected = self.resuming_generator orelse return self.engineFault();
                const frame = self.top_frame orelse return self.engineFault();
                if (frame.generator_owner != selected) return self.engineFault();
                selected.generator_yielded = self.registers[instruction.a()];
                selected.generator_yield_register = instruction.a();
                if (frame.root_frame.stack != null) frame.root_frame.pop();
                self.top_frame = frame.previous;
                frame.previous = null;
                if (self.top_frame) |caller| self.activateFrame(caller) else return self.engineFault();
            },
            .make_mapping => return self.executeMakeMapping(instruction, line, column),
            .mapping_set => return self.executeMappingSet(instruction, line, column),
            .mapping_update => return self.executeMappingUpdate(instruction, line, column),
            .materialize_dstar => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                return self.executeMaterializeDstar(instruction.a(), instruction.index32(), line, column);
            },
            .make_slice => return self.executeMakeSlice(instruction, line, column),
            .get_attribute => return self.executeGetAttribute(instruction, line, column),
            .set_attribute => return self.executeSetAttribute(instruction, line, column),
            .delete_attribute => return self.executeDeleteAttribute(instruction, line, column),
            .get_item => return self.executeGetItem(instruction, line, column),
            .set_item => return self.executeSetItem(instruction, line, column),
            .delete_item => return self.executeDeleteItem(instruction, line, column),
            .delete_local => {
                const name = self.codeName(instruction.index32()) orelse return self.engineFault();
                return self.executeDeleteLocal(name, instruction.flags(), line, column);
            },
            .delete_global => {
                const name = self.codeName(instruction.index32()) orelse return self.engineFault();
                return self.executeDeleteGlobal(name, line, column);
            },
            .unpack => return self.executeUnpack(instruction, line, column),
            .materialize_star => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                return self.executeMaterializeStar(instruction.a(), line, column);
            },
            .jump => {
                if (!self.validJump(instruction.index32())) return self.engineFault();
                self.instruction_pointer = instruction.index32();
            },
            .unwind_jump => {
                const frame = self.top_frame orelse return self.engineFault();
                return self.beginJumpTransfer(frame, instruction.index32());
            },
            .jump_if_false, .jump_if_true => {
                if (!self.validRegister(instruction.a()) or !self.validJump(instruction.index32())) return self.engineFault();
                const truth = self.valueTruthy(self.registers[instruction.a()], line, column) orelse return false;
                if ((op == .jump_if_false and !truth) or (op == .jump_if_true and truth)) self.instruction_pointer = instruction.index32();
            },
            .truth => {
                if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b())) return self.engineFault();
                const truth = self.valueTruthy(self.registers[instruction.b()], line, column) orelse return false;
                self.setRegister(instruction.a(), if (truth) Value.trueValue() else Value.falseValue());
            },
            .compare => {
                if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b()) or !self.validRegister(instruction.c())) return self.engineFault();
                const result = self.compareValues(self.registers[instruction.b()], self.registers[instruction.c()], instruction.flags(), line, column) orelse return false;
                self.setRegister(instruction.a(), if (result) Value.trueValue() else Value.falseValue());
            },
            .make_range => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                const start: usize = @intCast(instruction.index32());
                const count: usize = instruction.flags();
                if (start > code.argument_registers.len or count > code.argument_registers.len - start) return self.engineFault();
                for (code.argument_registers[start..][0..count]) |register| if (!self.validRegister(register)) return self.engineFault();
                if (self.globalValue("range") != null) {
                    self.setException(.{ .kind = .type_error, .message = "'int' object is not callable" }, line, column, null);
                    return false;
                }
                if (count == 0 or count > 3) {
                    self.setException(.{ .kind = .type_error, .message = "range expected 1 to 3 arguments" }, line, column, null);
                    return false;
                }
                var args: [3]Value = undefined;
                for (code.argument_registers[start..][0..count], 0..) |register, index| args[index] = self.registers[register];
                switch (iterator.createRange(&self.heap, args[0..count])) {
                    .value => |range| self.setRegister(instruction.a(), Value.object(&range.header)),
                    .python_exception => |exception| {
                        self.setException(exception, line, column, null);
                        return false;
                    },
                    .engine_error => return self.engineFault(),
                }
            },
            .get_iterator => {
                if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b())) return self.engineFault();
                return self.storeIteratorOutcome(instruction.a(), self.createVmIterator(self.registers[instruction.b()], line, column), line, column);
            },
            .for_next => {
                if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b()) or !self.validRegister(instruction.c())) return self.engineFault();
                const header = self.registers[instruction.b()].asObject() orelse return self.engineFault();
                const loop_iterator = iterator.iteratorFromHeader(header) orelse return self.engineFault();
                switch (self.nextIteratorValue(loop_iterator, instruction.a(), line, column)) {
                    .item => |item| {
                        self.setRegister(instruction.a(), item);
                        self.setRegister(instruction.c(), Value.trueValue());
                    },
                    .done => self.setRegister(instruction.c(), Value.falseValue()),
                    .suspended => return self.engineFault(),
                    .python_exception => |exception| {
                        self.setException(exception, line, column, null);
                        return false;
                    },
                    .engine_error => return self.engineFault(),
                }
            },
        }
        return true;
    }

    fn executeMakeSequence(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
        const code = self.activeCode() orelse return self.engineFault();
        const site_index: usize = instruction.index32();
        if (!self.validRegister(instruction.a()) or site_index >= code.sequence_sites.len) return self.engineFault();
        const site = code.sequence_sites[site_index];
        const start: usize = site.argument_start;
        const count: usize = site.argument_count;
        if (start > code.argument_registers.len or count > code.argument_registers.len - start) return self.engineFault();
        const values = self.heap.allocator.alloc(Value, count) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer self.heap.allocator.free(values);
        for (code.argument_registers[start..][0..count], 0..) |register, index| {
            if (!self.validRegister(register)) return self.engineFault();
            values[index] = self.registers[register];
        }
        if (site.is_tuple) {
            return switch (sequence.createTuple(&self.heap, values)) {
                .value => |tuple| blk: {
                    self.setRegister(instruction.a(), Value.object(&tuple.header));
                    break :blk true;
                },
                .python_exception => |exception| blk: {
                    self.setException(exception, line, column, null);
                    break :blk false;
                },
                .engine_error => self.engineFault(),
            };
        }
        return switch (sequence.createList(&self.heap, values)) {
            .value => |list| blk: {
                self.setRegister(instruction.a(), Value.object(&list.header));
                break :blk true;
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => self.engineFault(),
        };
    }

    fn executeMakeMapping(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
        if (!self.validRegister(instruction.a()) or instruction.flags() > 1) return self.engineFault();
        return switch (dict_module.create(&self.heap, instruction.flags() == 1)) {
            .value => |mapping| blk: {
                self.setRegister(instruction.a(), Value.object(&mapping.header));
                break :blk true;
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => self.engineFault(),
        };
    }

    fn executeMappingSet(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
        if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b())) return self.engineFault();
        const header = self.registers[instruction.a()].asObject() orelse return self.engineFault();
        const mapping = dict_module.dictFromHeader(header) orelse return self.engineFault();
        const key = self.registers[instruction.b()];
        const value = if (mapping.is_set) Value.noneValue() else blk: {
            if (!self.validRegister(instruction.c())) return self.engineFault();
            break :blk self.registers[instruction.c()];
        };
        return self.setMappingValue(mapping, key, value, line, column);
    }

    fn executeMappingUpdate(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
        if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b())) return self.engineFault();
        const target_header = self.registers[instruction.a()].asObject() orelse return self.engineFault();
        const source_header = self.registers[instruction.b()].asObject() orelse {
            self.setException(.{ .kind = .type_error, .message = "dictionary unpacking requires a mapping" }, line, column, null);
            return false;
        };
        const target = dict_module.dictFromHeader(target_header) orelse return self.engineFault();
        const source = dict_module.dictFromHeader(source_header) orelse {
            self.setException(.{ .kind = .type_error, .message = "dictionary unpacking requires a mapping" }, line, column, null);
            return false;
        };
        if (target.is_set or source.is_set) return self.nativeTypeError(line, column, "dictionary unpacking requires dictionaries");
        for (source.entries.items) |entry| {
            if (!entry.alive) continue;
            if (!self.setMappingValueWithHash(target, entry.key, entry.value, entry.hash, line, column)) return false;
        }
        return true;
    }

    fn executeMaterializeDstar(self: *Runtime, register: u16, site_index: u32, line: u32, column: u32) bool {
        const code = self.activeCode() orelse return self.engineFault();
        if (site_index >= code.dstar_sites.len) return self.engineFault();
        const site = code.dstar_sites[site_index];
        const previous_start: usize = site.previous_start;
        const previous_count: usize = site.previous_count;
        if (previous_start > code.dstar_previous_arguments.len or previous_count > code.dstar_previous_arguments.len - previous_start) return self.engineFault();
        const source_value = self.registers[register];
        const source_header = source_value.asObject() orelse return self.nativeTypeError(line, column, "argument after ** must be a mapping");
        const source = dict_module.dictFromHeader(source_header) orelse return self.nativeTypeError(line, column, "argument after ** must be a mapping");
        if (source.is_set) return self.nativeTypeError(line, column, "argument after ** must be a mapping");
        var source_root = gc.Root{ .object = &source.header };
        var snapshot_root = gc.Root{ .object = null };
        var roots = gc.RootFrame{};
        roots.push(&self.heap.roots);
        roots.add(&source_root);
        roots.add(&snapshot_root);
        defer roots.pop();
        const created = dict_module.create(&self.heap, false);
        const snapshot = switch (created) {
            .value => |mapping| mapping,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        snapshot_root.object = &snapshot.header;
        for (source.entries.items) |entry| {
            if (!entry.alive) continue;
            if (!self.setMappingValueWithHash(snapshot, entry.key, entry.value, entry.hash, line, column)) return false;
        }
        for (code.dstar_previous_arguments[previous_start..][0..previous_count]) |previous| {
            if (previous.double_starred) {
                if (!self.validRegister(previous.register)) return self.engineFault();
                const previous_header = self.registers[previous.register].asObject() orelse return self.engineFault();
                const previous_mapping = dict_module.dictFromHeader(previous_header) orelse return self.engineFault();
                for (previous_mapping.entries.items) |entry| {
                    if (!entry.alive) continue;
                    const previous_key_header = entry.key.asObject() orelse continue;
                    const previous_key = string.fromHeader(previous_key_header) orelse continue;
                    if (self.mappingHasStringKey(snapshot, string.content(previous_key))) return self.duplicateCallKeyword(line, column);
                }
            } else if (previous.keyword_name != std.math.maxInt(u32)) {
                const name = self.codeName(previous.keyword_name) orelse return self.engineFault();
                if (self.mappingHasStringKey(snapshot, name)) return self.duplicateCallKeyword(line, column);
            }
        }
        self.setRegister(register, Value.object(&snapshot.header));
        return true;
    }

    fn mappingHasStringKey(self: *Runtime, mapping: *dict_module.Dict, name: []const u8) bool {
        _ = self;
        for (mapping.entries.items) |entry| {
            if (!entry.alive) continue;
            const header = entry.key.asObject() orelse continue;
            const text = string.fromHeader(header) orelse continue;
            if (std.mem.eql(u8, string.content(text), name)) return true;
        }
        return false;
    }

    fn duplicateCallKeyword(self: *Runtime, line: u32, column: u32) bool {
        self.setException(.{ .kind = .type_error, .message = "got multiple values for keyword argument" }, line, column, null);
        return false;
    }

    fn setMappingValue(self: *Runtime, mapping: *dict_module.Dict, key: Value, value: Value, line: u32, column: u32) bool {
        const key_hash = self.pythonHash(key, line, column) orelse return false;
        return self.setMappingValueWithHash(mapping, key, value, key_hash, line, column);
    }

    fn storeAnnotation(self: *Runtime, name: []const u8, annotation: Value, class_scope: bool, line: u32, column: u32) bool {
        const class = if (class_scope) (self.top_frame orelse return self.engineFault()).class_namespace else null;
        if (class_scope and class == null) return self.engineFault();
        var mapping: *dict_module.Dict = undefined;
        if (class) |selected_class| {
            if (class_module.ownClassAttribute(selected_class, "__annotations__")) |existing| {
                const header = existing.asObject() orelse return self.nativeTypeError(line, column, "'__annotations__' must be a dict");
                mapping = dict_module.dictFromHeader(header) orelse return self.nativeTypeError(line, column, "'__annotations__' must be a dict");
            } else {
                mapping = switch (dict_module.create(&self.heap, false)) {
                    .value => |created| created,
                    .python_exception => |exception| {
                        self.setException(exception, line, column, null);
                        return false;
                    },
                    .engine_error => return self.engineFault(),
                };
                var roots = [_]gc.Root{ .{ .object = &selected_class.header }, .{ .object = &mapping.header } };
                var root_frame = gc.RootFrame{};
                root_frame.push(&self.heap.roots);
                for (&roots) |*root| root_frame.add(root);
                defer root_frame.pop();
                class_module.setClassAttribute(&self.heap, selected_class, "__annotations__", Value.object(&mapping.header)) catch {
                    self.setException(exceptions.memoryError(), line, column, null);
                    return false;
                };
                return self.storeAnnotationEntry(mapping, name, annotation, line, column);
            }
        } else if (self.globalValue("__annotations__")) |existing| {
            const header = existing.asObject() orelse return self.nativeTypeError(line, column, "'__annotations__' must be a dict");
            mapping = dict_module.dictFromHeader(header) orelse return self.nativeTypeError(line, column, "'__annotations__' must be a dict");
        } else {
            mapping = switch (dict_module.create(&self.heap, false)) {
                .value => |created| created,
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            };
            var roots = [_]gc.Root{ .{ .object = &mapping.header }, .{ .object = annotation.asObject() } };
            var root_frame = gc.RootFrame{};
            root_frame.push(&self.heap.roots);
            for (&roots) |*root| root_frame.add(root);
            defer root_frame.pop();
            if (!self.storeGlobal("__annotations__", Value.object(&mapping.header))) {
                self.setException(exceptions.memoryError(), line, column, null);
                return false;
            }
            return self.storeAnnotationEntry(mapping, name, annotation, line, column);
        }
        return self.storeAnnotationEntry(mapping, name, annotation, line, column);
    }

    fn storeAnnotationEntry(self: *Runtime, mapping: *dict_module.Dict, name: []const u8, annotation: Value, line: u32, column: u32) bool {
        var roots = [_]gc.Root{ .{ .object = &mapping.header }, .{ .object = annotation.asObject() }, .{ .object = null } };
        var root_frame = gc.RootFrame{};
        root_frame.push(&self.heap.roots);
        for (&roots) |*root| root_frame.add(root);
        defer root_frame.pop();
        const key = switch (string.create(&self.heap, name)) {
            .value => |value| value,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        roots[2].object = &key.header;
        return self.setMappingValue(mapping, Value.object(&key.header), annotation, line, column);
    }

    fn setMappingValueWithHash(self: *Runtime, mapping: *dict_module.Dict, key: Value, value: Value, key_hash: u64, line: u32, column: u32) bool {
        var context = DictEqualityContext{ .runtime = self, .line = line, .column = column };
        return switch (dict_module.set(&self.heap, mapping, key, value, key_hash, &context, dictKeysEqual)) {
            .value => true,
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => if (self.last_exception != null) false else self.engineFault(),
        };
    }

    fn pythonHash(self: *Runtime, value: Value, line: u32, column: u32) ?u64 {
        if (value.asObject()) |header| if (class_module.instanceFromHeader(header)) |instance| {
            if (class_module.ownClassAttribute(instance.class, "__eq__") != null and
                class_module.ownClassAttribute(instance.class, "__hash__") == null)
            {
                self.setException(.{ .kind = .type_error, .message = "unhashable type: 'instance'" }, line, column, null);
                return null;
            }
            if (class_module.classAttribute(instance.class, "__hash__")) |hash_method| {
                if (hash_method.tag() == .none) {
                    self.setException(.{ .kind = .type_error, .message = "unhashable type: 'instance'" }, line, column, null);
                    return null;
                }
                const result = self.invokeValueSync(hash_method, &.{value}, line, column) orelse return null;
                if (!number.isIntegerValue(result)) {
                    self.setException(.{ .kind = .type_error, .message = "__hash__ method should return an integer" }, line, column, null);
                    return null;
                }
                if (number.toInt(i64, result)) |signed_hash| {
                    const normalized_hash = if (signed_hash == -1) @as(i64, -2) else signed_hash;
                    return @bitCast(normalized_hash);
                }
                return switch (hash_module.pythonHash(&self.heap, result, self.hash_seed)) {
                    .value => |hash_value| hash_value,
                    .python_exception => |exception| blk: {
                        self.setException(exception, line, column, null);
                        break :blk null;
                    },
                    .engine_error => blk: {
                        _ = self.engineFault();
                        break :blk null;
                    },
                };
            }
            if (class_module.classAttribute(instance.class, "__eq__") != null) {
                self.setException(.{ .kind = .type_error, .message = "unhashable type: 'instance'" }, line, column, null);
                return null;
            }
        };
        return switch (hash_module.pythonHash(&self.heap, value, self.hash_seed)) {
            .value => |value_hash| value_hash,
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk null;
            },
            .engine_error => blk: {
                _ = self.engineFault();
                break :blk null;
            },
        };
    }

    fn mappingContains(self: *Runtime, mapping: *dict_module.Dict, key: Value, line: u32, column: u32) ?bool {
        const key_hash = self.pythonHash(key, line, column) orelse return null;
        var context = DictEqualityContext{ .runtime = self, .line = line, .column = column };
        return switch (dict_module.lookup(mapping, key, key_hash, &context, dictKeysEqual)) {
            .found => true,
            .missing => false,
            .failed => null,
        };
    }

    fn storeSetOperation(self: *Runtime, destination: u16, left: *dict_module.Dict, right: *dict_module.Dict, operation: u8, line: u32, column: u32) bool {
        const created = dict_module.create(&self.heap, true);
        const result = switch (created) {
            .value => |mapping| mapping,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        var root = gc.Root{ .object = &result.header };
        var roots = gc.RootFrame{};
        roots.push(&self.heap.roots);
        roots.add(&root);
        defer roots.pop();
        for (left.entries.items) |entry| {
            if (!entry.alive) continue;
            const in_right = self.mappingContains(right, entry.key, line, column) orelse return false;
            const include = if (operation == 1) !in_right else if (operation == 7) in_right else true;
            if (include and !self.setMappingValueWithHash(result, entry.key, Value.noneValue(), entry.hash, line, column)) return false;
        }
        if (operation == 8) for (right.entries.items) |entry| {
            if (!entry.alive) continue;
            if (!self.setMappingValueWithHash(result, entry.key, Value.noneValue(), entry.hash, line, column)) return false;
        };
        self.setRegister(destination, Value.object(&result.header));
        return true;
    }

    fn executeMakeSlice(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
        const code = self.activeCode() orelse return self.engineFault();
        const site_index: usize = instruction.index32();
        if (!self.validRegister(instruction.a()) or site_index >= code.slice_sites.len) return self.engineFault();
        const site = code.slice_sites[site_index];
        if (!self.validRegister(site.start) or !self.validRegister(site.stop) or !self.validRegister(site.step)) return self.engineFault();
        return switch (slice.create(&self.heap, self.registers[site.start], self.registers[site.stop], self.registers[site.step])) {
            .value => |object| blk: {
                self.setRegister(instruction.a(), Value.object(&object.header));
                break :blk true;
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => self.engineFault(),
        };
    }

    fn lookupAttributeValue(self: *Runtime, receiver: Value, name: []const u8, line: u32, column: u32) ?Value {
        const header = receiver.asObject() orelse return null;
        if (functions.functionFromHeader(header)) |function| {
            if (std.mem.eql(u8, name, "__annotations__")) return function.annotations_dict;
        }
        if (exceptions.instanceFromHeader(header)) |instance| {
            if (instance.kind == .stop_iteration and std.mem.eql(u8, name, "value")) return instance.value;
        }
        if (file_module.fromHeader(header)) |file| {
            if (std.mem.eql(u8, name, "closed")) return if (file.closed) Value.trueValue() else Value.falseValue();
            if (std.mem.eql(u8, name, "name")) return self.stringValueResult(string.create(&self.heap, file.path), line, column);
            if (std.mem.eql(u8, name, "mode")) return self.stringValueResult(string.create(&self.heap, file.mode_text), line, column);
            if (std.mem.eql(u8, name, "encoding")) {
                if (file.mode.binary) return Value.noneValue();
                return self.stringValueResult(string.create(&self.heap, "UTF-8"), line, column);
            }
        }
        if (class_module.superFromHeader(header)) |super_value| {
            const attribute = class_module.superClassAttribute(super_value.owner_class, super_value.start_class, name) orelse return null;
            if (attribute.asObject()) |attribute_header| {
                if (class_module.descriptorFromHeader(attribute_header)) |descriptor| {
                    if (descriptor.kind == .property) {
                        if (descriptor.getter.tag() == .none) {
                            _ = self.nativeAttributeError(line, column, "unreadable attribute");
                            return null;
                        }
                        return self.invokeValueSync(descriptor.getter, &.{super_value.instance}, line, column);
                    }
                    if (descriptor.kind == .classmethod) return switch (class_module.createBoundMethod(&self.heap, descriptor.callable, Value.object(&super_value.owner_class.header))) {
                        .value => |method| Value.object(&method.header),
                        .python_exception => |exception| blk: {
                            self.setException(exception, line, column, null);
                            break :blk null;
                        },
                        .engine_error => blk: {
                            _ = self.engineFault();
                            break :blk null;
                        },
                    };
                    if (descriptor.kind == .staticmethod) return descriptor.callable;
                }
                if (functions.functionFromHeader(attribute_header) != null) return switch (class_module.createBoundMethod(&self.heap, attribute, super_value.instance)) {
                    .value => |method| Value.object(&method.header),
                    .python_exception => |exception| blk: {
                        self.setException(exception, line, column, null);
                        break :blk null;
                    },
                    .engine_error => blk: {
                        _ = self.engineFault();
                        break :blk null;
                    },
                };
            }
            return attribute;
        }
        if (class_module.instanceFromHeader(header)) |instance| {
            if (std.mem.eql(u8, name, "__class__")) return Value.object(&instance.class.header);
            if (class_module.classAttribute(instance.class, name)) |attribute| if (attribute.asObject()) |attribute_header| if (class_module.descriptorFromHeader(attribute_header)) |descriptor| {
                if (descriptor.kind == .property) {
                    if (descriptor.getter.tag() == .none) {
                        _ = self.nativeAttributeError(line, column, "unreadable attribute");
                        return null;
                    }
                    return self.invokeValueSync(descriptor.getter, &.{receiver}, line, column);
                }
            };
            if (class_module.instanceAttribute(instance, name)) |value| return value;
            if (class_module.classAttribute(instance.class, name)) |attribute| {
                if (attribute.asObject()) |attribute_header| {
                    if (class_module.descriptorFromHeader(attribute_header)) |descriptor| switch (descriptor.kind) {
                        .property => {
                            if (descriptor.getter.tag() == .none) {
                                _ = self.nativeAttributeError(line, column, "unreadable attribute");
                                return null;
                            }
                            return self.invokeValueSync(descriptor.getter, &.{receiver}, line, column);
                        },
                        .staticmethod => return descriptor.callable,
                        .classmethod => return switch (class_module.createBoundMethod(&self.heap, descriptor.callable, Value.object(&instance.class.header))) {
                            .value => |method| Value.object(&method.header),
                            .python_exception => |exception| blk: {
                                self.setException(exception, line, column, null);
                                break :blk null;
                            },
                            .engine_error => blk: {
                                _ = self.engineFault();
                                break :blk null;
                            },
                        },
                    };
                    if (class_module.classFromHeader(attribute_header) != null) return attribute;
                    if (functions.functionFromHeader(attribute_header) != null) return switch (class_module.createBoundMethod(&self.heap, attribute, receiver)) {
                        .value => |method| Value.object(&method.header),
                        .python_exception => |exception| blk: {
                            self.setException(exception, line, column, null);
                            break :blk null;
                        },
                        .engine_error => blk: {
                            _ = self.engineFault();
                            break :blk null;
                        },
                    };
                }
                return attribute;
            }
            return null;
        }
        if (class_module.classFromHeader(header)) |class| {
            if (std.mem.eql(u8, name, "__name__")) return switch (string.create(&self.heap, class.name)) {
                .value => |text| Value.object(&text.header),
                .python_exception => |exception| blk: {
                    self.setException(exception, line, column, null);
                    break :blk null;
                },
                .engine_error => blk: {
                    _ = self.engineFault();
                    break :blk null;
                },
            };
            if (class_module.classAttribute(class, name)) |attribute| {
                if (attribute.asObject()) |attribute_header| if (class_module.descriptorFromHeader(attribute_header)) |descriptor| {
                    if (descriptor.kind == .classmethod) return switch (class_module.createBoundMethod(&self.heap, descriptor.callable, receiver)) {
                        .value => |method| Value.object(&method.header),
                        .python_exception => |exception| blk: {
                            self.setException(exception, line, column, null);
                            break :blk null;
                        },
                        .engine_error => blk: {
                            _ = self.engineFault();
                            break :blk null;
                        },
                    };
                    if (descriptor.kind == .staticmethod) return descriptor.callable;
                };
                return attribute;
            }
            return null;
        }
        if (class_module.descriptorFromHeader(header)) |descriptor| if (descriptor.kind == .property) {
            const native: ?functions.Native = if (std.mem.eql(u8, name, "setter")) .descriptor_setter else if (std.mem.eql(u8, name, "deleter")) .descriptor_deleter else null;
            if (native) |kind| return switch (functions.createBoundNative(&self.heap, kind, receiver)) {
                .value => |function| Value.object(&function.header),
                .python_exception => |exception| blk: {
                    self.setException(exception, line, column, null);
                    break :blk null;
                },
            };
        };
        if (attributeNative(receiver, name)) |native| return switch (functions.createBoundNative(&self.heap, native, receiver)) {
            .value => |function| Value.object(&function.header),
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk null;
            },
        };
        return null;
    }

    fn setUserAttribute(self: *Runtime, receiver: Value, name: []const u8, value: Value, line: u32, column: u32) bool {
        const header = receiver.asObject() orelse return self.nativeAttributeError(line, column, "attribute assignment requires an object");
        if (class_module.instanceFromHeader(header)) |instance| {
            if (class_module.classAttribute(instance.class, name)) |class_value| if (class_value.asObject()) |class_header| if (class_module.descriptorFromHeader(class_header)) |descriptor| {
                if (descriptor.kind == .property) {
                    if (descriptor.setter.tag() == .none) return self.nativeAttributeError(line, column, "property has no setter");
                    _ = self.invokeValueSync(descriptor.setter, &.{ receiver, value }, line, column) orelse return false;
                    return true;
                }
            };
            class_module.setInstanceAttribute(&self.heap, instance, name, value) catch {
                self.setException(exceptions.memoryError(), line, column, null);
                return false;
            };
            return true;
        }
        if (class_module.classFromHeader(header)) |class| {
            class_module.setClassAttribute(&self.heap, class, name, value) catch {
                self.setException(exceptions.memoryError(), line, column, null);
                return false;
            };
            return true;
        }
        return self.nativeAttributeError(line, column, "object has no writable attributes");
    }

    fn deleteUserAttribute(self: *Runtime, receiver: Value, name: []const u8, line: u32, column: u32) bool {
        const header = receiver.asObject() orelse return self.nativeAttributeError(line, column, "attribute deletion requires an object");
        if (class_module.instanceFromHeader(header)) |instance| {
            if (class_module.classAttribute(instance.class, name)) |class_value| if (class_value.asObject()) |class_header| if (class_module.descriptorFromHeader(class_header)) |descriptor| {
                if (descriptor.kind == .property) {
                    if (descriptor.deleter.tag() == .none) return self.nativeAttributeError(line, column, "property has no deleter");
                    _ = self.invokeValueSync(descriptor.deleter, &.{receiver}, line, column) orelse return false;
                    return true;
                }
            };
            if (class_module.deleteInstanceAttribute(&self.heap, instance, name)) return true;
            return self.nativeAttributeError(line, column, "object has no such attribute");
        }
        if (class_module.classFromHeader(header)) |class| {
            if (class_module.deleteClassAttribute(&self.heap, class, name)) return true;
            return self.nativeAttributeError(line, column, "type has no such attribute");
        }
        return self.nativeAttributeError(line, column, "object has no deletable attributes");
    }

    fn executeGetAttribute(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
        if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b())) return self.engineFault();
        const name = self.codeName(instruction.c()) orelse return self.engineFault();
        const receiver = self.registers[instruction.b()];
        if (receiver.asObject()) |header| if (functions.functionFromHeader(header)) |function| {
            if (std.mem.eql(u8, name, "__annotations__")) {
                self.setRegister(instruction.a(), function.annotations_dict);
                return true;
            }
        };
        if (receiver.asObject()) |header| if (exceptions.instanceFromHeader(header)) |instance| {
            if (instance.kind == .stop_iteration and std.mem.eql(u8, name, "value")) {
                self.setRegister(instruction.a(), instance.value);
                return true;
            }
        };
        if (receiver.asObject()) |header| if (file_module.fromHeader(header)) |file| {
            if (std.mem.eql(u8, name, "closed")) {
                self.setRegister(instruction.a(), if (file.closed) Value.trueValue() else Value.falseValue());
                return true;
            }
            if (std.mem.eql(u8, name, "name")) return self.storeStringResult(instruction.a(), string.create(&self.heap, file.path), line, column);
            if (std.mem.eql(u8, name, "mode")) return self.storeStringResult(instruction.a(), string.create(&self.heap, file.mode_text), line, column);
            if (std.mem.eql(u8, name, "encoding")) {
                if (file.mode.binary) {
                    self.setRegister(instruction.a(), Value.noneValue());
                    return true;
                }
                return self.storeStringResult(instruction.a(), string.create(&self.heap, "UTF-8"), line, column);
            }
        };
        if (receiver.asObject()) |user_header| {
            if (class_module.superFromHeader(user_header)) |super_value| {
                const attribute = class_module.superClassAttribute(super_value.owner_class, super_value.start_class, name) orelse {
                    return self.nativeAttributeError(line, column, "super object has no such attribute");
                };
                if (attribute.asObject()) |attribute_header| {
                    if (class_module.descriptorFromHeader(attribute_header)) |descriptor| {
                        if (descriptor.kind == .property) {
                            if (descriptor.getter.tag() == .none) return self.nativeAttributeError(line, column, "unreadable attribute");
                            const result = self.invokeValueSync(descriptor.getter, &.{super_value.instance}, line, column) orelse return false;
                            self.setRegister(instruction.a(), result);
                            return true;
                        }
                        if (descriptor.kind == .classmethod) return self.createBoundMethodResult(instruction.a(), descriptor.callable, Value.object(&super_value.owner_class.header), line, column);
                        if (descriptor.kind == .staticmethod) {
                            self.setRegister(instruction.a(), descriptor.callable);
                            return true;
                        }
                    }
                    if (functions.functionFromHeader(attribute_header) != null) return self.createBoundMethodResult(instruction.a(), attribute, super_value.instance, line, column);
                }
                self.setRegister(instruction.a(), attribute);
                return true;
            }
            if (class_module.instanceFromHeader(user_header)) |instance| {
                if (std.mem.eql(u8, name, "__class__")) {
                    self.setRegister(instruction.a(), Value.object(&instance.class.header));
                    return true;
                }
                if (class_module.classAttribute(instance.class, name)) |attribute| if (attribute.asObject()) |attribute_header| if (class_module.descriptorFromHeader(attribute_header)) |descriptor| {
                    if (descriptor.kind == .property) {
                        if (descriptor.getter.tag() == .none) return self.nativeAttributeError(line, column, "unreadable attribute");
                        const arguments = [_]Value{receiver};
                        const result = self.invokeValueSync(descriptor.getter, &arguments, line, column) orelse return false;
                        self.setRegister(instruction.a(), result);
                        return true;
                    }
                };
                if (class_module.instanceAttribute(instance, name)) |own| {
                    self.setRegister(instruction.a(), own);
                    return true;
                }
                if (class_module.classAttribute(instance.class, name)) |attribute| {
                    if (attribute.asObject()) |attribute_header| {
                        if (class_module.descriptorFromHeader(attribute_header)) |descriptor| {
                            switch (descriptor.kind) {
                                .property => {
                                    if (descriptor.getter.tag() == .none) return self.nativeAttributeError(line, column, "unreadable attribute");
                                    const arguments = [_]Value{receiver};
                                    const result = self.invokeValueSync(descriptor.getter, &arguments, line, column) orelse return false;
                                    self.setRegister(instruction.a(), result);
                                    return true;
                                },
                                .staticmethod => {
                                    self.setRegister(instruction.a(), descriptor.callable);
                                    return true;
                                },
                                .classmethod => return self.createBoundMethodResult(instruction.a(), descriptor.callable, Value.object(&instance.class.header), line, column),
                            }
                        }
                        if (class_module.classFromHeader(attribute_header) != null) {
                            self.setRegister(instruction.a(), attribute);
                            return true;
                        }
                        if (functions.functionFromHeader(attribute_header) != null) return self.createBoundMethodResult(instruction.a(), attribute, receiver, line, column);
                    }
                    self.setRegister(instruction.a(), attribute);
                    return true;
                }
            } else if (class_module.classFromHeader(user_header)) |class| {
                if (std.mem.eql(u8, name, "__name__")) return self.storeStringResult(instruction.a(), string.create(&self.heap, class.name), line, column);
                if (class_module.classAttribute(class, name)) |attribute| {
                    if (attribute.asObject()) |attribute_header| if (class_module.descriptorFromHeader(attribute_header)) |descriptor| {
                        if (descriptor.kind == .classmethod) return self.createBoundMethodResult(instruction.a(), descriptor.callable, receiver, line, column);
                        if (descriptor.kind == .staticmethod) {
                            self.setRegister(instruction.a(), descriptor.callable);
                            return true;
                        }
                    };
                    self.setRegister(instruction.a(), attribute);
                    return true;
                }
            }
        }
        const native = attributeNative(receiver, name) orelse {
            self.setException(.{ .kind = .attribute_error, .message = "object has no such attribute" }, line, column, null);
            return false;
        };
        switch (functions.createBoundNative(&self.heap, native, receiver)) {
            .value => |function| self.setRegister(instruction.a(), Value.object(&function.header)),
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
        }
        return true;
    }

    fn createBoundMethodResult(self: *Runtime, destination: u16, callable: Value, receiver: Value, line: u32, column: u32) bool {
        return switch (class_module.createBoundMethod(&self.heap, callable, receiver)) {
            .value => |method| blk: {
                self.setRegister(destination, Value.object(&method.header));
                break :blk true;
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => self.engineFault(),
        };
    }

    fn executeSetAttribute(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
        if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b())) return self.engineFault();
        const name = self.codeName(instruction.c()) orelse return self.engineFault();
        const receiver = self.registers[instruction.a()];
        const value = self.registers[instruction.b()];
        const header = receiver.asObject() orelse return self.nativeAttributeError(line, column, "attribute assignment requires an object");
        if (class_module.instanceFromHeader(header)) |instance| {
            if (class_module.classAttribute(instance.class, name)) |class_value| if (class_value.asObject()) |class_header| if (class_module.descriptorFromHeader(class_header)) |descriptor| {
                if (descriptor.kind == .property) {
                    if (descriptor.setter.tag() == .none) return self.nativeAttributeError(line, column, "property has no setter");
                    const arguments = [_]Value{ receiver, value };
                    _ = self.invokeValueSync(descriptor.setter, &arguments, line, column) orelse return false;
                    return true;
                }
            };
            class_module.setInstanceAttribute(&self.heap, instance, name, value) catch {
                self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
                return false;
            };
            return true;
        }
        if (class_module.classFromHeader(header)) |class| {
            class_module.setClassAttribute(&self.heap, class, name, value) catch {
                self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
                return false;
            };
            return true;
        }
        return self.nativeAttributeError(line, column, "object does not allow attribute assignment");
    }

    fn executeDeleteAttribute(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
        if (!self.validRegister(instruction.a())) return self.engineFault();
        const name = self.codeName(instruction.c()) orelse return self.engineFault();
        const receiver = self.registers[instruction.a()];
        const header = receiver.asObject() orelse return self.nativeAttributeError(line, column, "attribute deletion requires an object");
        if (class_module.instanceFromHeader(header)) |instance| {
            if (class_module.classAttribute(instance.class, name)) |class_value| if (class_value.asObject()) |class_header| if (class_module.descriptorFromHeader(class_header)) |descriptor| {
                if (descriptor.kind == .property) {
                    if (descriptor.deleter.tag() == .none) return self.nativeAttributeError(line, column, "property has no deleter");
                    const arguments = [_]Value{receiver};
                    _ = self.invokeValueSync(descriptor.deleter, &arguments, line, column) orelse return false;
                    return true;
                }
            };
        }
        const deleted = if (class_module.instanceFromHeader(header)) |instance|
            class_module.deleteInstanceAttribute(&self.heap, instance, name)
        else if (class_module.classFromHeader(header)) |class|
            class_module.deleteClassAttribute(&self.heap, class, name)
        else
            return self.nativeAttributeError(line, column, "object does not allow attribute deletion");
        if (!deleted) return self.nativeAttributeError(line, column, "attribute does not exist");
        return true;
    }

    fn executeGetItem(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
        if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b()) or !self.validRegister(instruction.c())) return self.engineFault();
        const container = self.registers[instruction.b()];
        const index_value = self.registers[instruction.c()];
        const header = container.asObject() orelse {
            self.setException(.{ .kind = .type_error, .message = "object is not subscriptable" }, line, column, null);
            return false;
        };
        if (index_value.asObject()) |index_header| {
            if (slice.fromHeader(index_header) != null) return self.executeSliceItem(instruction.a(), container, index_value, line, column);
        }
        if (iterator.rangeFromHeader(header)) |range| {
            const result = iterator.rangeIndex(&self.heap, range, index_value);
            return self.storeValueResult(instruction.a(), result, line, column);
        }
        if (sequence.listFromHeader(header)) |list| return self.executeIndexedSequence(instruction.a(), container, list.items.items.len, index_value, line, column);
        if (sequence.tupleFromHeader(header)) |tuple| return self.executeIndexedSequence(instruction.a(), container, tuple.items.len, index_value, line, column);
        if (string.fromHeader(header)) |text| {
            const index = sequence.getIndex(string.length(text), index_value);
            return switch (index) {
                .value => |position| self.storeStringIndex(instruction.a(), text, position, line, column),
                .python_exception => |exception| blk: {
                    self.setException(exception, line, column, null);
                    break :blk false;
                },
                .engine_error => self.engineFault(),
            };
        }
        if (byte_module.fromHeader(header)) |data| {
            const index = sequence.getIndex(byte_module.length(data), index_value);
            return switch (index) {
                .value => |position| blk: {
                    self.setRegister(instruction.a(), Value.fromSmallInt(data.data[position]).?);
                    break :blk true;
                },
                .python_exception => |exception| blk: {
                    self.setException(exception, line, column, null);
                    break :blk false;
                },
                .engine_error => self.engineFault(),
            };
        }
        if (dict_module.dictFromHeader(header)) |mapping| {
            if (mapping.is_set) return self.nativeTypeError(line, column, "'set' object is not subscriptable");
            const key_hash = self.pythonHash(index_value, line, column) orelse return false;
            var context = DictEqualityContext{ .runtime = self, .line = line, .column = column };
            return switch (dict_module.get(mapping, index_value, key_hash, &context, dictKeysEqual)) {
                .value => |value| blk: {
                    self.setRegister(instruction.a(), value);
                    break :blk true;
                },
                .missing => blk: {
                    self.setException(.{ .kind = .key_error, .message = "mapping key not found" }, line, column, null);
                    break :blk false;
                },
                .failed => self.last_exception == null and self.engineFault(),
            };
        }
        if (class_module.instanceFromHeader(header) != null) {
            const arguments = [_]Value{index_value};
            const result = self.invokeSpecialSync(container, "__getitem__", &arguments, line, column) orelse {
                if (self.last_exception == null) return self.nativeTypeError(line, column, "object is not subscriptable");
                return false;
            };
            self.setRegister(instruction.a(), result);
            return true;
        }
        self.setException(.{ .kind = .type_error, .message = "object is not subscriptable" }, line, column, null);
        return false;
    }

    fn executeIndexedSequence(self: *Runtime, destination: u16, container: Value, length_value: usize, index_value: Value, line: u32, column: u32) bool {
        const index = sequence.getIndex(length_value, index_value);
        return switch (index) {
            .value => |position| blk: {
                const value = sequence.itemAt(container, position) orelse return self.engineFault();
                self.setRegister(destination, value);
                break :blk true;
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => self.engineFault(),
        };
    }

    fn storeStringIndex(self: *Runtime, destination: u16, text: *string.Str, index: usize, line: u32, column: u32) bool {
        const bounded = std.math.cast(i64, index) orelse {
            self.setException(.{ .kind = .overflow_error, .message = "string is too large to index" }, line, column, null);
            return false;
        };
        return switch (string.index(&self.heap, text, bounded)) {
            .value => |character| blk: {
                self.setRegister(destination, Value.object(&character.header));
                break :blk true;
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => self.engineFault(),
        };
    }

    fn executeSliceItem(self: *Runtime, destination: u16, container: Value, slice_value: Value, line: u32, column: u32) bool {
        const header = container.asObject() orelse return self.engineFault();
        const slice_header = slice_value.asObject() orelse return self.engineFault();
        const slice_object = slice.fromHeader(slice_header) orelse return self.engineFault();
        if (iterator.rangeFromHeader(header)) |range| {
            const result = iterator.rangeSlice(&self.heap, range, slice_object);
            return switch (result) {
                .value => |value| blk: {
                    self.setRegister(destination, Value.object(&value.header));
                    break :blk true;
                },
                .python_exception => |exception| blk: {
                    self.setException(exception, line, column, null);
                    break :blk false;
                },
                .engine_error => self.engineFault(),
            };
        }
        if (sequence.listFromHeader(header)) |list| return self.sliceSequence(destination, container, list.items.items, slice_object, false, line, column);
        if (sequence.tupleFromHeader(header)) |tuple| return self.sliceSequence(destination, container, tuple.items, slice_object, true, line, column);
        if (string.fromHeader(header)) |text| {
            const normalized = slice.normalize(string.length(text), slice_object.start, slice_object.stop, slice_object.step);
            return switch (normalized) {
                .value => |indices| blk: {
                    const result = string.sliceNormalized(&self.heap, text, indices);
                    break :blk self.storeStringResult(destination, result, line, column);
                },
                .python_exception => |exception| blk: {
                    self.setException(exception, line, column, null);
                    break :blk false;
                },
                .engine_error => self.engineFault(),
            };
        }
        if (byte_module.fromHeader(header)) |data| {
            const normalized = slice.normalize(data.data.len, slice_object.start, slice_object.stop, slice_object.step);
            return switch (normalized) {
                .value => |indices| blk: {
                    const result = byte_module.sliceNormalized(&self.heap, data, indices);
                    break :blk self.storeBytesResult(destination, result, line, column);
                },
                .python_exception => |exception| blk: {
                    self.setException(exception, line, column, null);
                    break :blk false;
                },
                .engine_error => self.engineFault(),
            };
        }
        self.setException(.{ .kind = .type_error, .message = "object cannot be sliced" }, line, column, null);
        return false;
    }

    fn sliceSequence(self: *Runtime, destination: u16, container: Value, values: []const Value, slice_object: *slice.Slice, is_tuple: bool, line: u32, column: u32) bool {
        const normalized = slice.normalize(values.len, slice_object.start, slice_object.stop, slice_object.step);
        const indices = switch (normalized) {
            .value => |result| result,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        var output: std.ArrayList(Value) = .empty;
        defer output.deinit(self.heap.allocator);
        var index_value = indices.start;
        while (if (indices.step > 0) index_value < indices.stop else index_value > indices.stop) {
            output.append(self.heap.allocator, values[@intCast(index_value)]) catch {
                self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
                return false;
            };
            index_value = std.math.add(i128, index_value, indices.step) catch break;
        }
        _ = container;
        if (is_tuple) return switch (sequence.createTuple(&self.heap, output.items)) {
            .value => |tuple| blk: {
                self.setRegister(destination, Value.object(&tuple.header));
                break :blk true;
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => self.engineFault(),
        };
        return switch (sequence.createList(&self.heap, output.items)) {
            .value => |list| blk: {
                self.setRegister(destination, Value.object(&list.header));
                break :blk true;
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => self.engineFault(),
        };
    }

    fn storeStringResult(self: *Runtime, destination: u16, result: string.StringResult, line: u32, column: u32) bool {
        return switch (result) {
            .value => |text| blk: {
                self.setRegister(destination, Value.object(&text.header));
                break :blk true;
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => self.engineFault(),
        };
    }

    fn stringValueResult(self: *Runtime, result: string.StringResult, line: u32, column: u32) ?Value {
        return switch (result) {
            .value => |text| Value.object(&text.header),
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk null;
            },
            .engine_error => blk: {
                _ = self.engineFault();
                break :blk null;
            },
        };
    }

    fn storeBytesResult(self: *Runtime, destination: u16, result: byte_module.BytesResult, line: u32, column: u32) bool {
        return switch (result) {
            .value => |data| blk: {
                self.setRegister(destination, Value.object(&data.header));
                break :blk true;
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => self.engineFault(),
        };
    }

    fn executeSetItem(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
        if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b()) or !self.validRegister(instruction.c())) return self.engineFault();
        const container = self.registers[instruction.b()].asObject() orelse {
            self.setException(.{ .kind = .type_error, .message = "object does not support item assignment" }, line, column, null);
            return false;
        };
        if (dict_module.dictFromHeader(container)) |mapping| {
            if (mapping.is_set) return self.nativeTypeError(line, column, "'set' object does not support item assignment");
            return self.setMappingValue(mapping, self.registers[instruction.c()], self.registers[instruction.a()], line, column);
        }
        if (class_module.instanceFromHeader(container) != null) {
            const arguments = [_]Value{ self.registers[instruction.c()], self.registers[instruction.a()] };
            if (self.invokeSpecialSync(self.registers[instruction.b()], "__setitem__", &arguments, line, column)) |_| return true;
            if (self.last_exception == null) return self.nativeTypeError(line, column, "object does not support item assignment");
            return false;
        }
        const list = sequence.listFromHeader(container) orelse {
            self.setException(.{ .kind = .type_error, .message = "object does not support item assignment" }, line, column, null);
            return false;
        };
        const index = sequence.getIndex(list.items.items.len, self.registers[instruction.c()]);
        const position = switch (index) {
            .value => |value| value,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        list.items.items[position] = self.registers[instruction.a()];
        list.version +%= 1;
        return true;
    }

    fn executeDeleteItem(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
        if (!self.validRegister(instruction.b()) or !self.validRegister(instruction.c())) return self.engineFault();
        const container = self.registers[instruction.b()].asObject() orelse {
            self.setException(.{ .kind = .type_error, .message = "object does not support item deletion" }, line, column, null);
            return false;
        };
        if (dict_module.dictFromHeader(container)) |mapping| {
            if (mapping.is_set) return self.nativeTypeError(line, column, "'set' object does not support item deletion");
            const key = self.registers[instruction.c()];
            const key_hash = self.pythonHash(key, line, column) orelse return false;
            var context = DictEqualityContext{ .runtime = self, .line = line, .column = column };
            return switch (dict_module.delete(mapping, key, key_hash, &context, dictKeysEqual)) {
                .found => true,
                .missing => blk: {
                    self.setException(.{ .kind = .key_error, .message = "mapping key not found" }, line, column, null);
                    break :blk false;
                },
                .failed => self.last_exception == null and self.engineFault(),
            };
        }
        if (class_module.instanceFromHeader(container) != null) {
            const arguments = [_]Value{self.registers[instruction.c()]};
            if (self.invokeSpecialSync(self.registers[instruction.b()], "__delitem__", &arguments, line, column)) |_| return true;
            if (self.last_exception == null) return self.nativeTypeError(line, column, "object does not support item deletion");
            return false;
        }
        const list = sequence.listFromHeader(container) orelse {
            self.setException(.{ .kind = .type_error, .message = "object does not support item deletion" }, line, column, null);
            return false;
        };
        const index = sequence.getIndex(list.items.items.len, self.registers[instruction.c()]);
        const position = switch (index) {
            .value => |value| value,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        _ = list.items.orderedRemove(position);
        list.version +%= 1;
        return true;
    }

    fn executeDeleteLocal(self: *Runtime, name: []const u8, binding: u8, line: u32, column: u32) bool {
        const frame = self.top_frame orelse return self.engineFault();
        if (frame.class_namespace) |class| {
            const index = indexOfName(frame.code.local_names, name) orelse return self.engineFault();
            if (!class_module.deleteClassAttribute(&self.heap, class, name)) {
                self.setException(.{ .kind = .name_error, .message = "name is not defined" }, line, column, name);
                return false;
            }
            frame.locals[index] = Value.deletedValue();
            frame.roots[frame.localRootStart() + index].object = null;
            return true;
        }
        const kind: bytecode.LocalBinding = switch (binding) {
            0 => .local,
            1 => .cell,
            2 => .free,
            else => return self.engineFault(),
        };
        const target: *Value = switch (kind) {
            .local => blk: {
                const index = indexOfName(frame.code.local_names, name) orelse return self.engineFault();
                frame.roots[frame.localRootStart() + index].object = null;
                break :blk &frame.locals[index];
            },
            .cell => blk: {
                const index = indexOfName(frame.code.cell_names, name) orelse return self.engineFault();
                const cell = frame.local_cells[index] orelse return self.engineFault();
                break :blk &cell.value;
            },
            .free => blk: {
                const index = indexOfName(frame.code.free_names, name) orelse return self.engineFault();
                const cell = frame.free_cells[index] orelse return self.engineFault();
                break :blk &cell.value;
            },
        };
        if (target.tag() == .unbound or target.tag() == .deleted) {
            self.setException(.{ .kind = if (kind == .free) .name_error else .unbound_local_error, .message = "cannot delete unbound local" }, line, column, null);
            return false;
        }
        target.* = Value.deletedValue();
        return true;
    }

    fn executeDeleteGlobal(self: *Runtime, name: []const u8, line: u32, column: u32) bool {
        for (self.environment.entries.items, 0..) |entry, index| {
            if (!std.mem.eql(u8, entry.name, name)) continue;
            self.heap.allocator.free(entry.name);
            _ = self.environment.entries.orderedRemove(index);
            return true;
        }
        self.setException(.{ .kind = .name_error, .message = "name is not defined" }, line, column, name);
        return false;
    }

    fn executeUnpack(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
        const code = self.activeCode() orelse return self.engineFault();
        const site_index: usize = instruction.index32();
        if (!self.validRegister(instruction.a()) or site_index >= code.unpack_sites.len) return self.engineFault();
        const site = code.unpack_sites[site_index];
        const destination_start: usize = site.destination_start;
        const destination_count: usize = site.destination_count;
        if (destination_start > code.argument_registers.len or destination_count > code.argument_registers.len - destination_start) return self.engineFault();
        for (code.argument_registers[destination_start..][0..destination_count]) |destination| if (!self.validRegister(destination)) return self.engineFault();

        const source = self.registers[instruction.a()];
        const has_star = site.star_index != std.math.maxInt(u16);
        const minimum = if (has_star) destination_count -| 1 else destination_count;
        var known_length: ?usize = null;
        if (has_star) {
            known_length = sequence.length(source);
            if (source.asObject()) |header| {
                if (string.fromHeader(header)) |text| known_length = string.length(text);
                if (byte_module.fromHeader(header)) |data| known_length = data.data.len;
                if (iterator.rangeFromHeader(header)) |range| {
                    const length_result = iterator.rangeLength(&self.heap, range);
                    const length = switch (length_result) {
                        .value => |value| value,
                        .python_exception => |exception| {
                            self.setException(exception, line, column, null);
                            return false;
                        },
                        .engine_error => return self.engineFault(),
                    };
                    known_length = number.toInt(usize, length) orelse {
                        self.setException(.{ .kind = .memory_error, .message = "unpacked iterable exceeds available memory" }, line, column, null);
                        return false;
                    };
                }
            }
        }
        // Exact-size sources get exact temporary storage for starred unpacking.
        // Unknown iterators retain a temporary 65,536-item bound pending the
        // dynamically growing, session-accounted buffer work in Commit 23.
        const capacity: usize = if (!has_star)
            destination_count + 1
        else
            known_length orelse 65_536;
        const root_count = std.math.add(usize, capacity, 1) catch {
            self.setException(.{ .kind = .memory_error, .message = "unpacked iterable exceeds available memory" }, line, column, null);
            return false;
        };
        const values = self.heap.allocator.alloc(Value, capacity) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer self.heap.allocator.free(values);
        const roots = self.heap.allocator.alloc(gc.Root, root_count) catch {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        };
        defer self.heap.allocator.free(roots);
        @memset(roots, .{ .object = null });
        var root_frame = gc.RootFrame{};
        root_frame.push(&self.heap.roots);
        for (roots) |*root| root_frame.add(root);
        defer root_frame.pop();

        const created_iterator = iterator.createIterator(&self.heap, source);
        const loop_iterator = switch (created_iterator) {
            .value => |result| result,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        roots[0].object = &loop_iterator.header;
        var count: usize = 0;
        while (true) {
            switch (iterator.next(&self.heap, loop_iterator)) {
                .item => |value| {
                    if (!has_star and count >= destination_count) {
                        self.setException(.{ .kind = .value_error, .message = "too many values to unpack" }, line, column, null);
                        return false;
                    }
                    if (count == capacity) {
                        const message = if (has_star and known_length == null)
                            "unpacked iterator exceeds the temporary 65536-item limit"
                        else
                            "unpacked iterable exceeds its known length";
                        self.setException(.{ .kind = .memory_error, .message = message }, line, column, null);
                        return false;
                    }
                    values[count] = value;
                    roots[count + 1].object = value.asObject();
                    count += 1;
                },
                .done => break,
                .suspended => return self.engineFault(),
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            }
        }

        if (has_star) {
            if (count < minimum) {
                self.setException(.{ .kind = .value_error, .message = "not enough values to unpack" }, line, column, null);
                return false;
            }
            const star: usize = site.star_index;
            const tail_count = destination_count - star - 1;
            const middle_start = star;
            const middle_end = count - tail_count;
            const rest = sequence.createList(&self.heap, values[middle_start..middle_end]);
            const rest_value = switch (rest) {
                .value => |list| Value.object(&list.header),
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            };
            for (0..star) |index| self.setRegister(code.argument_registers[destination_start + index], values[index]);
            self.setRegister(code.argument_registers[destination_start + star], rest_value);
            for (star + 1..destination_count) |index| {
                const source_index = count - (destination_count - index);
                self.setRegister(code.argument_registers[destination_start + index], values[source_index]);
            }
            return true;
        }
        if (count != destination_count) {
            self.setException(.{ .kind = .value_error, .message = if (count < destination_count) "not enough values to unpack" else "too many values to unpack" }, line, column, null);
            return false;
        }
        for (0..count) |index| self.setRegister(code.argument_registers[destination_start + index], values[index]);
        return true;
    }

    fn rightReflectedHasPriority(self: *Runtime, left: Value, right: Value, reflected_name: []const u8) bool {
        _ = self;
        const left_header = left.asObject() orelse return false;
        const right_header = right.asObject() orelse return false;
        const left_instance = class_module.instanceFromHeader(left_header) orelse return false;
        const right_instance = class_module.instanceFromHeader(right_header) orelse return false;
        if (left_instance.class == right_instance.class or !mroContains(right_instance.class, left_instance.class)) return false;
        const right_reflected = class_module.classAttribute(right_instance.class, reflected_name) orelse return false;
        const left_reflected = class_module.classAttribute(left_instance.class, reflected_name) orelse return true;
        return !left_reflected.identical(right_reflected);
    }

    fn executeBinary(self: *Runtime, destination: u16, left: Value, right: Value, operation: u8, line: u32, column: u32) bool {
        const left_method: ?[]const u8 = switch (operation) {
            0 => "__add__",
            1 => "__sub__",
            2 => "__mul__",
            3 => "__truediv__",
            4 => "__floordiv__",
            5 => "__mod__",
            6 => "__pow__",
            7 => "__and__",
            8 => "__or__",
            9 => "__xor__",
            10 => "__lshift__",
            11 => "__rshift__",
            else => null,
        };
        const right_method: ?[]const u8 = switch (operation) {
            0 => "__radd__",
            1 => "__rsub__",
            2 => "__rmul__",
            3 => "__rtruediv__",
            4 => "__rfloordiv__",
            5 => "__rmod__",
            6 => "__rpow__",
            7 => "__rand__",
            8 => "__ror__",
            9 => "__rxor__",
            10 => "__rlshift__",
            11 => "__rrshift__",
            else => null,
        };
        var right_reflected_tried = false;
        if (right_method) |method| {
            if (self.rightReflectedHasPriority(left, right, method)) {
                right_reflected_tried = true;
                if (self.invokeSpecialSync(right, method, &.{left}, line, column)) |result| {
                    if (result.asExceptionClass() == null or result.asExceptionClass().? != std.math.maxInt(u8)) {
                        self.setRegister(destination, result);
                        return true;
                    }
                } else if (self.last_exception != null) return false;
            }
        }
        if (left_method) |method| {
            if (self.invokeSpecialSync(left, method, &.{right}, line, column)) |result| {
                if (result.asExceptionClass() == null or result.asExceptionClass().? != std.math.maxInt(u8)) {
                    self.setRegister(destination, result);
                    return true;
                }
            } else if (self.last_exception != null) return false;
        }
        if (right_method) |method| {
            if (!right_reflected_tried) {
                if (self.invokeSpecialSync(right, method, &.{left}, line, column)) |result| {
                    if (result.asExceptionClass() == null or result.asExceptionClass().? != std.math.maxInt(u8)) {
                        self.setRegister(destination, result);
                        return true;
                    }
                } else if (self.last_exception != null) return false;
            }
        }
        if (operation == 5) if (left.asObject()) |header| if (string.fromHeader(header)) |template| return self.executePercentFormat(destination, template, right, line, column);
        if (operation == 1 or operation == 7 or operation == 8) {
            const left_header = left.asObject() orelse null;
            const right_header = right.asObject() orelse null;
            if (left_header) |left_object| if (dict_module.dictFromHeader(left_object)) |left_mapping| {
                if (right_header) |right_object| if (dict_module.dictFromHeader(right_object)) |right_mapping| {
                    if (left_mapping.is_set and right_mapping.is_set) return self.storeSetOperation(destination, left_mapping, right_mapping, operation, line, column);
                };
            };
        }
        if (operation == 0) {
            const left_header = left.asObject() orelse null;
            const right_header = right.asObject() orelse null;
            if (left_header) |left_object| {
                if (right_header) |right_object| {
                    if (string.fromHeader(left_object)) |left_text| {
                        if (string.fromHeader(right_object)) |right_text| {
                            return switch (string.concat(&self.heap, left_text, right_text)) {
                                .value => |joined| blk: {
                                    self.setRegister(destination, Value.object(&joined.header));
                                    break :blk true;
                                },
                                .python_exception => |exception| blk: {
                                    self.setException(exception, line, column, null);
                                    break :blk false;
                                },
                                .engine_error => self.engineFault(),
                            };
                        }
                    }
                    if (byte_module.fromHeader(left_object)) |left_bytes| {
                        if (byte_module.fromHeader(right_object)) |right_bytes| {
                            const total = std.math.add(usize, left_bytes.data.len, right_bytes.data.len) catch {
                                self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
                                return false;
                            };
                            const joined_data = self.heap.allocator.alloc(u8, total) catch {
                                self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
                                return false;
                            };
                            defer self.heap.allocator.free(joined_data);
                            @memcpy(joined_data[0..left_bytes.data.len], left_bytes.data);
                            @memcpy(joined_data[left_bytes.data.len..], right_bytes.data);
                            return switch (byte_module.create(&self.heap, joined_data)) {
                                .value => |joined| blk: {
                                    self.setRegister(destination, Value.object(&joined.header));
                                    break :blk true;
                                },
                                .python_exception => |exception| blk: {
                                    self.setException(exception, line, column, null);
                                    break :blk false;
                                },
                                .engine_error => self.engineFault(),
                            };
                        }
                    }
                }
            }
            if (sequence.length(left) != null and sequence.length(right) != null) {
                return self.storeValueResult(destination, sequence.concatenate(&self.heap, left, right), line, column);
            }
        }
        if (operation == 2) {
            if (sequence.length(left) != null) {
                return self.executeSequenceRepeat(destination, left, right, line, column);
            }
            if (sequence.length(right) != null) {
                return self.executeSequenceRepeat(destination, right, left, line, column);
            }
        }
        const result = switch (operation) {
            0 => number.add(&self.heap, left, right),
            1 => number.subtract(&self.heap, left, right),
            2 => number.multiply(&self.heap, left, right),
            3 => return self.storeFloatResult(destination, number.trueDivide(&self.heap, left, right), line, column),
            4 => number.floorDiv(&self.heap, left, right),
            5 => number.modulo(&self.heap, left, right),
            6 => number.power(&self.heap, left, right),
            7 => number.bitAnd(&self.heap, left, right),
            8 => number.bitOr(&self.heap, left, right),
            9 => number.bitXor(&self.heap, left, right),
            10 => number.shiftLeft(&self.heap, left, right),
            11 => number.shiftRight(&self.heap, left, right),
            else => return self.engineFault(),
        };
        return self.storeNumberResult(destination, result, line, column);
    }

    fn executePercentFormat(self: *Runtime, destination: u16, template: *string.Str, arguments_value: Value, line: u32, column: u32) bool {
        const arguments: []const Value = if (arguments_value.asObject()) |header| if (sequence.tupleFromHeader(header)) |tuple| tuple.items else &.{arguments_value} else &.{arguments_value};
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.heap.allocator);
        const input = string.content(template);
        var index: usize = 0;
        var argument_index: usize = 0;
        while (index < input.len) {
            if (input[index] != '%') {
                output.append(self.heap.allocator, input[index]) catch {
                    _ = self.formatMemoryFailure(line, column);
                    return false;
                };
                index += 1;
                continue;
            }
            index += 1;
            if (index < input.len and input[index] == '%') {
                output.append(self.heap.allocator, '%') catch {
                    _ = self.formatMemoryFailure(line, column);
                    return false;
                };
                index += 1;
                continue;
            }
            const spec_start = index;
            while (index < input.len and std.mem.indexOfScalar(u8, "#0-+ ", input[index]) != null) : (index += 1) {}
            while (index < input.len and std.ascii.isDigit(input[index])) : (index += 1) {}
            if (index < input.len and input[index] == '.') {
                index += 1;
                while (index < input.len and std.ascii.isDigit(input[index])) : (index += 1) {}
            }
            if (index >= input.len) return self.nativeTypeError(line, column, "incomplete format");
            const kind = input[index];
            index += 1;
            if (std.mem.indexOfScalar(u8, "sradiuxXof", kind) == null) {
                _ = self.formatValueError(line, column, "unsupported format character");
                return false;
            }
            if (argument_index >= arguments.len) return self.nativeTypeError(line, column, "not enough arguments for format string");
            const argument = arguments[argument_index];
            argument_index += 1;
            const conversion: u8 = if (kind == 's') 1 else if (kind == 'r') 2 else if (kind == 'a') 3 else 0;
            const fmt_kind = if (conversion != 0) 's' else if (kind == 'i' or kind == 'u') 'd' else kind;
            const fmt_spec = std.fmt.allocPrint(self.heap.allocator, "{s}{c}", .{ input[spec_start .. index - 1], fmt_kind }) catch {
                _ = self.formatMemoryFailure(line, column);
                return false;
            };
            defer self.heap.allocator.free(fmt_spec);
            const formatted = self.makeFormattedText(argument, fmt_spec, conversion, line, column) orelse return false;
            defer self.heap.allocator.free(formatted);
            output.appendSlice(self.heap.allocator, formatted) catch {
                _ = self.formatMemoryFailure(line, column);
                return false;
            };
        }
        if (argument_index < arguments.len) return self.nativeTypeError(line, column, "not all arguments converted during string formatting");
        const owned = output.toOwnedSlice(self.heap.allocator) catch {
            _ = self.formatMemoryFailure(line, column);
            return false;
        };
        defer self.heap.allocator.free(owned);
        return self.storeStringResult(destination, string.create(&self.heap, owned), line, column);
    }

    fn storeNumberResult(self: *Runtime, destination: u16, result: number.ValueResult, line: u32, column: u32) bool {
        return switch (result) {
            .value => |value| blk: {
                self.setRegister(destination, value);
                break :blk true;
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => self.engineFault(),
        };
    }

    fn storeFloatResult(self: *Runtime, destination: u16, result: number.FloatResult, line: u32, column: u32) bool {
        return switch (result) {
            .value => |value| blk: {
                self.setRegister(destination, Value.fromFloat(value));
                break :blk true;
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => self.engineFault(),
        };
    }

    fn executePrint(self: *Runtime, registers: []const u16, line: u32, column: u32) bool {
        for (registers, 0..) |register, index| {
            if (index != 0 and !self.appendOutput(" ")) {
                self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
                return false;
            }
            if (!self.appendValue(self.registers[register], line, column)) {
                if (self.last_exception == null) self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
                return false;
            }
        }
        if (!self.appendOutput("\n")) {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        }
        return true;
    }

    fn executePrintValues(self: *Runtime, values: []const Value, separator: []const u8, ending: []const u8, line: u32, column: u32) bool {
        for (values, 0..) |value, index| {
            if (index != 0 and !self.appendOutput(separator)) {
                self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
                return false;
            }
            if (!self.appendValue(value, line, column)) {
                if (self.last_exception == null) self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
                return false;
            }
        }
        if (!self.appendOutput(ending)) {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        }
        return true;
    }

    fn appendValue(self: *Runtime, value: Value, line: u32, column: u32) bool {
        return self.appendValueMode(value, false, line, column);
    }

    fn appendValueMode(self: *Runtime, value: Value, nested: bool, line: u32, column: u32) bool {
        if (value.tag() == .none) return self.appendOutput("None");
        if (value.asBool()) |boolean| return self.appendOutput(if (boolean) "True" else "False");
        if (value.asExceptionClass()) |class_index| {
            if (class_index == std.math.maxInt(u8)) return self.appendOutput("NotImplemented");
            if (class_index >= exceptions.allKinds.len) return self.engineFault();
            return self.appendFormatted("<class '{s}'>", .{exceptions.exceptionName(exceptions.allKinds[class_index])});
        }
        if (value.asSmallInt()) |integer| return self.appendFormatted("{d}", .{integer});
        if (value.asFloat()) |float_value| {
            if (std.math.isFinite(float_value) and @trunc(float_value) == float_value) {
                return self.appendFormatted("{d}.0", .{float_value});
            }
            return self.appendFormatted("{d}", .{float_value});
        }
        if (number.formatInteger(&self.heap, value)) |formatted| {
            return switch (formatted) {
                .value => |bytes| blk: {
                    defer self.heap.allocator.free(bytes);
                    break :blk self.appendOutput(bytes);
                },
                .python_exception => |exception| blk: {
                    self.setException(exception, line, column, null);
                    break :blk false;
                },
                .engine_error => false,
            };
        }
        if (value.asObject()) |header| {
            if (string.fromHeader(header)) |text| {
                if (!nested) return self.appendOutput(string.content(text));
                return self.appendQuoted(string.content(text), false);
            }
            if (exceptions.instanceFromHeader(header)) |exception_value| {
                if (!nested) return self.appendOutput(exception_value.message);
                if (!self.appendOutput(exceptions.exceptionName(exception_value.kind))) return false;
                if (exception_value.message.len == 0) return true;
                if (!self.appendOutput("(")) return false;
                if (!self.appendQuoted(exception_value.message, false)) return false;
                return self.appendOutput(")");
            }
            if (byte_module.fromHeader(header)) |data| return self.appendQuoted(data.data, true);
            if (sequence.listFromHeader(header)) |list| return self.appendSequence(header, list.items.items, false, line, column);
            if (sequence.tupleFromHeader(header)) |tuple| return self.appendSequence(header, tuple.items, true, line, column);
            if (dict_module.dictFromHeader(header)) |mapping| return self.appendMapping(header, mapping, line, column);
            if (dict_module.viewFromHeader(header)) |view| return self.appendMappingView(header, view, line, column);
            if (iterator.rangeFromHeader(header)) |range| return self.appendRange(range, line, column);
            if (file_module.fromHeader(header)) |file| return self.appendFormatted("<_io.File name={s} mode={s}>", .{ file.path, file.mode_text });
            if (class_module.instanceFromHeader(header)) |instance| {
                const method_name = if (nested or class_module.classAttribute(instance.class, "__str__") == null) "__repr__" else "__str__";
                if (self.invokeSpecialSync(value, method_name, &.{}, line, column)) |representation| {
                    const representation_header = representation.asObject() orelse {
                        self.setException(.{ .kind = .type_error, .message = "__repr__ returned non-string" }, line, column, null);
                        return false;
                    };
                    const text = string.fromHeader(representation_header) orelse {
                        self.setException(.{ .kind = .type_error, .message = "__repr__ returned non-string" }, line, column, null);
                        return false;
                    };
                    return self.appendOutput(string.content(text));
                }
                if (self.last_exception != null) return false;
                return self.appendFormatted("<{s} object at 0x{x}>", .{ instance.class.name, @intFromPtr(header) });
            }
            if (class_module.classFromHeader(header)) |class| return self.appendFormatted("<class '{s}'>", .{class.name});
            self.setException(.{ .kind = .type_error, .message = "object has no printable representation" }, line, column, null);
            return false;
        }
        return false;
    }

    fn appendSequence(self: *Runtime, header: *gc.Header, values: []const Value, is_tuple: bool, line: u32, column: u32) bool {
        for (self.repr_path.items) |ancestor| {
            if (ancestor == header) return self.appendOutput(if (is_tuple) "(...)" else "[...]");
        }
        if (self.repr_path.items.len >= 128) {
            self.setException(.{ .kind = .recursion_error, .message = "maximum recursion depth exceeded while getting the repr of an object" }, line, column, null);
            return false;
        }
        self.repr_path.append(self.heap.allocator, header) catch return false;
        defer _ = self.repr_path.pop();
        if (!self.appendOutput(if (is_tuple) "(" else "[")) return false;
        for (values, 0..) |value, index| {
            if (index != 0 and !self.appendOutput(", ")) return false;
            if (!self.appendValueMode(value, true, line, column)) return false;
        }
        if (is_tuple and values.len == 1 and !self.appendOutput(",")) return false;
        return self.appendOutput(if (is_tuple) ")" else "]");
    }

    fn appendMapping(self: *Runtime, header: *gc.Header, mapping: *dict_module.Dict, line: u32, column: u32) bool {
        for (self.repr_path.items) |ancestor| {
            if (ancestor == header) return self.appendOutput("{...}");
        }
        if (self.repr_path.items.len >= 128) {
            self.setException(.{ .kind = .recursion_error, .message = "maximum recursion depth exceeded while getting the repr of an object" }, line, column, null);
            return false;
        }
        if (mapping.is_set and mapping.size == 0) return self.appendOutput("set()");
        self.repr_path.append(self.heap.allocator, header) catch return false;
        defer _ = self.repr_path.pop();
        if (!self.appendOutput("{")) return false;
        var first = true;
        for (mapping.entries.items) |entry| {
            if (!entry.alive) continue;
            if (!first and !self.appendOutput(", ")) return false;
            first = false;
            if (!self.appendValueMode(entry.key, true, line, column)) return false;
            if (!mapping.is_set) {
                if (!self.appendOutput(": ") or !self.appendValueMode(entry.value, true, line, column)) return false;
            }
        }
        return self.appendOutput("}");
    }

    fn appendMappingView(self: *Runtime, header: *gc.Header, view: *dict_module.View, line: u32, column: u32) bool {
        for (self.repr_path.items) |ancestor| if (ancestor == header) return self.appendOutput("...");
        if (self.repr_path.items.len >= 128) {
            self.setException(.{ .kind = .recursion_error, .message = "maximum recursion depth exceeded while getting the repr of an object" }, line, column, null);
            return false;
        }
        self.repr_path.append(self.heap.allocator, header) catch return false;
        defer _ = self.repr_path.pop();
        const prefix = switch (view.kind) {
            .keys => "dict_keys([",
            .values => "dict_values([",
            .items => "dict_items([",
        };
        if (!self.appendOutput(prefix)) return false;
        var first = true;
        for (view.owner.entries.items) |entry| {
            if (!entry.alive) continue;
            if (!first and !self.appendOutput(", ")) return false;
            first = false;
            switch (view.kind) {
                .keys => if (!self.appendValueMode(entry.key, true, line, column)) return false,
                .values => if (!self.appendValueMode(entry.value, true, line, column)) return false,
                .items => {
                    if (!self.appendOutput("(")) return false;
                    if (!self.appendValueMode(entry.key, true, line, column) or !self.appendOutput(", ") or !self.appendValueMode(entry.value, true, line, column) or !self.appendOutput(")")) return false;
                },
            }
        }
        return self.appendOutput("])");
    }

    fn appendQuoted(self: *Runtime, content: []const u8, is_bytes: bool) bool {
        if (is_bytes and !self.appendOutput("b")) return false;
        const has_single_quote = std.mem.indexOfScalar(u8, content, '\'') != null;
        const has_double_quote = std.mem.indexOfScalar(u8, content, '"') != null;
        const quote: u8 = if (has_single_quote and !has_double_quote) '"' else '\'';
        if (!self.appendOutput(&.{quote})) return false;
        for (content) |character| {
            const escaped = if (character == quote) switch (character) {
                '\'' => "\\'",
                '"' => "\\\"",
                else => unreachable,
            } else switch (character) {
                '\\' => "\\\\",
                '\n' => "\\n",
                '\r' => "\\r",
                '\t' => "\\t",
                else => null,
            };
            if (escaped) |text| {
                if (!self.appendOutput(text)) return false;
            } else if (character < 32 or character == 127 or (is_bytes and character >= 127)) {
                if (!self.appendFormatted("\\x{x:0>2}", .{character})) return false;
            } else if (!self.appendOutput(&.{character})) return false;
        }
        return self.appendOutput(&.{quote});
    }

    fn appendRange(self: *Runtime, range: *const iterator.Range, line: u32, column: u32) bool {
        if (!self.appendOutput("range(")) return false;
        if (!self.appendInteger(range.start, line, column) or !self.appendOutput(", ") or !self.appendInteger(range.stop, line, column)) return false;
        const unit_step = number.equal(range.step, Value.fromSmallInt(1).?);
        const has_unit_step = switch (unit_step) {
            .value => |equal| equal,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        if (!has_unit_step and (!self.appendOutput(", ") or !self.appendInteger(range.step, line, column))) return false;
        return self.appendOutput(")");
    }

    fn appendInteger(self: *Runtime, value: Value, line: u32, column: u32) bool {
        const formatted = number.formatInteger(&self.heap, value) orelse {
            self.setException(.{ .kind = .type_error, .message = "range contains a non-integer" }, line, column, null);
            return false;
        };
        return switch (formatted) {
            .value => |bytes| blk: {
                defer self.heap.allocator.free(bytes);
                break :blk self.appendOutput(bytes);
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk false;
            },
            .engine_error => self.engineFault(),
        };
    }

    fn valueTruthy(self: *Runtime, value: Value, line: u32, column: u32) ?bool {
        if (value.tag() == .none) return false;
        if (value.asBool()) |boolean| return boolean;
        if (value.asSmallInt()) |integer| return integer != 0;
        if (value.asFloat()) |float_value| return float_value != 0;
        if (number.isIntegerValue(value)) return !number.isZeroValue(value);
        if (value.asObject()) |header| {
            if (class_module.instanceFromHeader(header)) |instance| {
                if (class_module.classAttribute(instance.class, "__bool__") != null) {
                    const result = self.invokeSpecialSync(value, "__bool__", &.{}, line, column) orelse return null;
                    if (result.asBool()) |boolean| return boolean;
                    self.setException(.{ .kind = .type_error, .message = "__bool__ should return bool" }, line, column, null);
                    return null;
                }
                if (class_module.classAttribute(instance.class, "__len__") != null) {
                    const result = self.invokeSpecialSync(value, "__len__", &.{}, line, column) orelse return null;
                    if (!number.isIntegerValue(result)) {
                        self.setException(.{ .kind = .type_error, .message = "'__len__' should return an integer" }, line, column, null);
                        return null;
                    }
                    return switch (number.compare(result, Value.fromSmallInt(0).?)) {
                        .value => |order| if (order == .less) blk: {
                            self.setException(.{ .kind = .value_error, .message = "__len__() should return >= 0" }, line, column, null);
                            break :blk null;
                        } else !number.isZeroValue(result),
                        .python_exception => |exception| blk: {
                            self.setException(exception, line, column, null);
                            break :blk null;
                        },
                        .engine_error => blk: {
                            _ = self.engineFault();
                            break :blk null;
                        },
                    };
                }
                return true;
            }
            if (sequence.length(value)) |count| return count != 0;
            if (string.fromHeader(header)) |text| return text.data.len != 0;
            if (byte_module.fromHeader(header)) |data| return data.data.len != 0;
            if (dict_module.sizeOf(value)) |count| return count != 0;
            if (iterator.rangeFromHeader(header)) |range| switch (iterator.truthyRange(range)) {
                .value => |truth| return truth,
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return null;
                },
                .engine_error => {
                    _ = self.engineFault();
                    return null;
                },
            };
            return true;
        }
        return false;
    }

    fn normalizeSearchBound(self: *Runtime, value: Value, length: usize, line: u32, column: u32) ?usize {
        if (!number.isIntegerValue(value)) {
            self.setException(.{ .kind = .type_error, .message = "slice indices must be integers" }, line, column, null);
            return null;
        }
        const len = std.math.cast(i64, length) orelse std.math.maxInt(i64);
        const converted = number.toInt(i64, value) orelse {
            const order = number.compare(value, Value.fromSmallInt(0).?);
            return switch (order) {
                .value => |comparison| if (comparison == .less) 0 else length,
                .python_exception => |exception| blk: {
                    self.setException(exception, line, column, null);
                    break :blk null;
                },
                .engine_error => blk: {
                    _ = self.engineFault();
                    break :blk null;
                },
            };
        };
        const adjusted = if (converted < 0) converted + len else converted;
        return @intCast(@max(0, @min(len, adjusted)));
    }

    fn compareValues(self: *Runtime, left: Value, right: Value, operation: u8, line: u32, column: u32) ?bool {
        if (operation == 6) return left.identical(right);
        if (operation == 7) return !left.identical(right);
        if (operation == 8 or operation == 9) {
            const contained = self.containsValue(left, right, line, column) orelse return null;
            return if (operation == 8) contained else !contained;
        }

        const left_is_user = if (left.asObject()) |header| class_module.instanceFromHeader(header) != null else false;
        const right_is_user = if (right.asObject()) |header| class_module.instanceFromHeader(header) != null else false;
        if (operation <= 5 and (left_is_user or right_is_user)) {
            const left_name: []const u8 = switch (operation) {
                0 => "__eq__",
                1 => "__ne__",
                2 => "__lt__",
                3 => "__le__",
                4 => "__gt__",
                5 => "__ge__",
                else => unreachable,
            };
            const right_name: []const u8 = switch (operation) {
                2 => "__gt__",
                3 => "__ge__",
                4 => "__lt__",
                5 => "__le__",
                else => left_name,
            };
            const args = [_]Value{right};
            if (self.invokeSpecialSync(left, left_name, &args, line, column)) |result| {
                if (result.asExceptionClass() == null or result.asExceptionClass().? != std.math.maxInt(u8)) return self.valueTruthy(result, line, column);
            } else if (self.last_exception != null) return null;
            if (self.invokeSpecialSync(right, right_name, &.{left}, line, column)) |result| {
                if (result.asExceptionClass() == null or result.asExceptionClass().? != std.math.maxInt(u8)) return self.valueTruthy(result, line, column);
            } else if (self.last_exception != null) return null;
            if (operation == 0 or operation == 1) return if (operation == 0) left.identical(right) else !left.identical(right);
        }

        if (operation == 0 or operation == 1) {
            if (left.asObject()) |left_header| {
                if (right.asObject()) |right_header| {
                    if (string.fromHeader(left_header)) |left_text| {
                        if (string.fromHeader(right_header)) |right_text| {
                            const equal = string.equal(left_text, right_text);
                            return if (operation == 0) equal else !equal;
                        }
                    }
                    if (sequence.listFromHeader(left_header)) |left_list| if (sequence.listFromHeader(right_header)) |right_list| {
                        const equal = self.valuesEqual(Value.object(&left_list.header), Value.object(&right_list.header), line, column) orelse return null;
                        return if (operation == 0) equal else !equal;
                    };
                    if (sequence.tupleFromHeader(left_header)) |left_tuple| if (sequence.tupleFromHeader(right_header)) |right_tuple| {
                        const equal = self.valuesEqual(Value.object(&left_tuple.header), Value.object(&right_tuple.header), line, column) orelse return null;
                        return if (operation == 0) equal else !equal;
                    };
                    if (byte_module.fromHeader(left_header)) |left_bytes| if (byte_module.fromHeader(right_header)) |right_bytes| {
                        const equal = byte_module.equal(left_bytes, right_bytes);
                        return if (operation == 0) equal else !equal;
                    };
                    if (dict_module.dictFromHeader(left_header)) |_| if (dict_module.dictFromHeader(right_header)) |_| {
                        const equal = self.valuesEqual(left, right, line, column) orelse return null;
                        return if (operation == 0) equal else !equal;
                    };
                }
            }
            return switch (number.equal(left, right)) {
                .value => |equal| if (operation == 0) equal else !equal,
                .python_exception => |exception| blk: {
                    self.setException(exception, line, column, null);
                    break :blk null;
                },
                .engine_error => blk: {
                    _ = self.engineFault();
                    break :blk null;
                },
            };
        }

        if (left.asObject()) |left_header| {
            if (right.asObject()) |right_header| {
                if (string.fromHeader(left_header)) |left_text| {
                    if (string.fromHeader(right_header)) |right_text| {
                        const order = std.mem.order(u8, string.content(left_text), string.content(right_text));
                        return compareOrder(order, operation);
                    }
                }
            }
        }
        return switch (number.compare(left, right)) {
            .value => |order| compareNumericOrder(order, operation),
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk null;
            },
            .engine_error => blk: {
                _ = self.engineFault();
                break :blk null;
            },
        };
    }

    fn containsValue(self: *Runtime, item: Value, container: Value, line: u32, column: u32) ?bool {
        const header = container.asObject() orelse {
            self.setException(.{ .kind = .type_error, .message = "argument of type is not iterable" }, line, column, null);
            return null;
        };
        if (class_module.instanceFromHeader(header) != null) {
            const args = [_]Value{item};
            if (self.invokeSpecialSync(container, "__contains__", &args, line, column)) |result| return self.valueTruthy(result, line, column);
            if (self.last_exception != null) return null;
        }
        if (dict_module.dictFromHeader(header)) |mapping| return self.mappingContains(mapping, item, line, column);
        if (dict_module.viewFromHeader(header)) |view| {
            const mapping_iterator = switch (dict_module.createIterator(&self.heap, view.owner, view.kind)) {
                .value => |selected| selected,
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return null;
                },
                .engine_error => {
                    _ = self.engineFault();
                    return null;
                },
            };
            var root = gc.Root{ .object = &mapping_iterator.header };
            var roots = gc.RootFrame{};
            roots.push(&self.heap.roots);
            roots.add(&root);
            defer roots.pop();
            while (true) switch (dict_module.next(&self.heap, mapping_iterator)) {
                .item => |candidate| {
                    const equal = self.valuesEqual(candidate, item, line, column) orelse return null;
                    if (equal) return true;
                },
                .done => return false,
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return null;
                },
            };
        }
        if (iterator.rangeFromHeader(header)) |range| return switch (iterator.rangeContains(&self.heap, range, item)) {
            .value => |contains| contains,
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk null;
            },
            .engine_error => blk: {
                _ = self.engineFault();
                break :blk null;
            },
        };
        if (string.fromHeader(header)) |text| {
            const needle_header = item.asObject() orelse {
                self.setException(.{ .kind = .type_error, .message = "substring membership requires a string" }, line, column, null);
                return null;
            };
            const needle = string.fromHeader(needle_header) orelse {
                self.setException(.{ .kind = .type_error, .message = "substring membership requires a string" }, line, column, null);
                return null;
            };
            return std.mem.indexOf(u8, string.content(text), string.content(needle)) != null;
        }
        if (sequence.listFromHeader(header)) |list| {
            for (list.items.items) |candidate| {
                const equal = self.valuesEqual(candidate, item, line, column) orelse return null;
                if (equal) return true;
            }
            return false;
        }
        if (sequence.tupleFromHeader(header)) |tuple| {
            for (tuple.items) |candidate| {
                const equal = self.valuesEqual(candidate, item, line, column) orelse return null;
                if (equal) return true;
            }
            return false;
        }
        if (byte_module.fromHeader(header)) |data| {
            if (item.asObject()) |item_header| {
                if (byte_module.fromHeader(item_header)) |needle| return std.mem.indexOf(u8, data.data, needle.data) != null;
            }
            const needle: i128 = if (item.asBool()) |boolean|
                @intFromBool(boolean)
            else blk: {
                if (!number.isIntegerValue(item)) {
                    self.setException(.{ .kind = .type_error, .message = "a bytes-like object or integer is required" }, line, column, null);
                    return null;
                }
                break :blk number.toInt(i128, item) orelse {
                    self.setException(.{ .kind = .value_error, .message = "byte must be in range(0, 256)" }, line, column, null);
                    return null;
                };
            };
            if (needle < 0 or needle > 255) {
                self.setException(.{ .kind = .value_error, .message = "byte must be in range(0, 256)" }, line, column, null);
                return null;
            }
            return std.mem.indexOfScalar(u8, data.data, @intCast(needle)) != null;
        }
        if (class_module.instanceFromHeader(header) != null) return self.containsUserIterable(item, container, line, column);
        self.setException(.{ .kind = .type_error, .message = "object is not a supported container" }, line, column, null);
        return null;
    }

    fn containsUserIterable(self: *Runtime, item: Value, container: Value, line: u32, column: u32) ?bool {
        const selected = switch (self.createVmIterator(container, line, column)) {
            .value => |iterator_value| iterator_value,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return null;
            },
            .engine_error => {
                _ = self.engineFault();
                return null;
            },
        };
        var root = gc.Root{ .object = &selected.header };
        var needle_root = gc.Root{ .object = item.asObject() };
        var candidate_root = gc.Root{ .object = null };
        var roots = gc.RootFrame{};
        roots.push(&self.heap.roots);
        roots.add(&root);
        roots.add(&needle_root);
        roots.add(&candidate_root);
        defer roots.pop();
        const caller = self.top_frame orelse {
            _ = self.engineFault();
            return null;
        };
        if (caller.code.register_count == 0) {
            _ = self.engineFault();
            return null;
        }
        const scratch: u16 = @intCast(caller.code.register_count - 1);
        const owns_work_budget = self.beginSynchronousWork();
        defer self.endSynchronousWork(owns_work_budget);
        while (true) {
            if (!self.chargeSynchronousWork(line, column)) return null;
            switch (self.nextIteratorValue(selected, scratch, line, column)) {
                .item => |candidate| {
                    candidate_root.object = candidate.asObject();
                    const equal = self.valuesEqual(candidate, item, line, column) orelse return null;
                    if (equal) return true;
                },
                .done => return false,
                .suspended => {
                    self.setException(.{ .kind = .runtime_error, .message = "iterator suspended during membership test" }, line, column, null);
                    return null;
                },
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return null;
                },
                .engine_error => {
                    _ = self.engineFault();
                    return null;
                },
            }
        }
    }

    fn appendFormatted(self: *Runtime, comptime format: []const u8, arguments: anytype) bool {
        const text = std.fmt.allocPrint(self.heap.allocator, format, arguments) catch return false;
        defer self.heap.allocator.free(text);
        return self.appendOutput(text);
    }

    fn appendOutput(self: *Runtime, output: []const u8) bool {
        self.stdout_bytes.appendSlice(self.heap.allocator, output) catch return false;
        return true;
    }

    fn setRegister(self: *Runtime, index: u16, value: Value) void {
        const position: usize = index;
        if (position >= self.registers.len) unreachable;
        self.registers[position] = value;
        self.register_roots[position].object = value.asObject();
    }

    fn validRegister(self: *const Runtime, index: u16) bool {
        return @as(usize, index) < self.registers.len;
    }

    fn validJump(self: *const Runtime, target: u32) bool {
        const code = self.activeCode() orelse return false;
        return @as(usize, target) <= code.instructions.len;
    }

    fn codeName(self: *const Runtime, index: u32) ?[]const u8 {
        const code = self.activeCode() orelse return null;
        const position: usize = @intCast(index);
        if (position >= code.names.len) return null;
        return code.names[position];
    }

    fn globalValue(self: *const Runtime, name: []const u8) ?Value {
        for (self.environment.entries.items) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.value;
        return null;
    }

    fn builtinValue(self: *const Runtime, name: []const u8) ?Value {
        if (std.mem.eql(u8, name, "print")) return if (self.print_builtin_root.object) |header| Value.object(header) else null;
        if (std.mem.eql(u8, name, "input")) return if (self.input_builtin_root.object) |header| Value.object(header) else null;
        if (std.mem.eql(u8, name, "range")) return if (self.range_builtin_root.object) |header| Value.object(header) else null;
        if (std.mem.eql(u8, name, "object")) return if (self.object_class_root.object) |header| Value.object(header) else null;
        if (std.mem.eql(u8, name, "type")) return if (self.type_class_root.object) |header| Value.object(header) else null;
        if (std.mem.eql(u8, name, "NotImplemented")) return Value.exceptionClass(std.math.maxInt(u8));
        return null;
    }

    fn ensureBuiltinClasses(self: *Runtime, line: u32, column: u32) bool {
        if (self.object_class_root.object == null) {
            switch (class_module.createRootClass(&self.heap)) {
                .value => |object_class| self.object_class_root.object = &object_class.header,
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            }
        }
        if (self.type_class_root.object == null) {
            const object_header = self.object_class_root.object orelse return self.engineFault();
            const object_class = class_module.classFromHeader(object_header) orelse return self.engineFault();
            switch (class_module.createClass(&self.heap, "type", &.{object_class}, object_class)) {
                .value => |type_class| self.type_class_root.object = &type_class.header,
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            }
        }
        return true;
    }

    fn typeClass(self: *const Runtime) ?*class_module.Class {
        const header = self.type_class_root.object orelse return null;
        return class_module.classFromHeader(header);
    }

    fn activeCode(self: *const Runtime) ?*Code {
        const frame = self.top_frame orelse return null;
        return frame.code;
    }

    fn storeGlobal(self: *Runtime, name: []const u8, value: Value) bool {
        for (self.environment.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                entry.value = value;
                return true;
            }
        }
        const owned_name = self.heap.allocator.dupe(u8, name) catch return false;
        self.environment.entries.append(self.heap.allocator, .{ .name = owned_name, .value = value }) catch {
            self.heap.allocator.free(owned_name);
            return false;
        };
        return true;
    }

    fn setException(self: *Runtime, exception: PythonException, line: u32, column: u32, name: ?[]const u8) void {
        var selected = exception;
        const previous_exception = self.active_exception;
        switch (exceptions.createInstance(&self.heap, exception.kind, exception.message)) {
            .value => |instance| {
                if (previous_exception) |context| if (context != instance) {
                    instance.context = context;
                };
                self.active_exception = instance;
                self.exception_root.object = &instance.header;
                if (self.top_frame) |frame| {
                    const trace_frame = exceptions.TracebackFrame{
                        .filename = frame.code.filename,
                        .function_name = frame.code.display_name,
                        .line = line,
                        .column = column,
                        .source_line = sourceLine(frame.code.source, line),
                    };
                    instance.frames.append(self.heap.allocator, trace_frame) catch {};
                }
                selected.message = instance.message;
            },
            .python_exception, .engine_error => {
                selected = exceptions.memoryError();
                const emergency_header = self.emergency_exception_root.object orelse {
                    self.active_exception = null;
                    self.exception_root.object = null;
                    self.last_exception = selected;
                    self.clearErrorText();
                    self.error_text_static = "MemoryError: session memory limit exceeded";
                    return;
                };
                const emergency = exceptions.instanceFromHeader(emergency_header) orelse {
                    _ = self.engineFault();
                    return;
                };
                emergency.kind = .memory_error;
                emergency.context = if (previous_exception == emergency) null else previous_exception;
                emergency.cause = null;
                emergency.suppress_context = false;
                emergency.frames.clearRetainingCapacity();
                self.active_exception = emergency;
                self.exception_root.object = emergency_header;
                if (self.top_frame) |frame| {
                    emergency.frames.append(self.heap.allocator, .{
                        .filename = frame.code.filename,
                        .function_name = frame.code.display_name,
                        .line = line,
                        .column = column,
                        .source_line = sourceLine(frame.code.source, line),
                    }) catch {};
                }
            },
        }
        self.last_exception = selected;
        self.clearErrorText();
        const message = if (name) |missing| blk: {
            break :blk std.fmt.allocPrint(
                self.heap.allocator,
                "{s}: name '{s}' is not defined ({s}:{d}:{d})",
                .{ exceptionName(selected.kind), missing, self.currentFilename(), line, column },
            ) catch null;
        } else std.fmt.allocPrint(
            self.heap.allocator,
            "{s}: {s} ({s}:{d}:{d})",
            .{ exceptionName(selected.kind), selected.message, self.currentFilename(), line, column },
        ) catch null;
        if (message) |owned| {
            self.error_text_owned = owned;
        } else {
            self.error_text_static = "MemoryError: unable to format the Python exception";
        }
    }

    fn currentFilename(self: *const Runtime) []const u8 {
        if (self.activeCode()) |code| return code.filename;
        return "<module>";
    }

    fn prepareExceptionDiagnostics(self: *Runtime) void {
        if (self.traceback_json_owned != null) return;
        const instance = self.active_exception orelse return;
        const allocator = self.heap.allocator;

        var json: std.ArrayList(u8) = .empty;
        defer json.deinit(allocator);
        json.append(allocator, '[') catch return;
        var frame_index = instance.frames.items.len;
        var index: usize = 0;
        while (frame_index > 0) {
            frame_index -= 1;
            const frame = instance.frames.items[frame_index];
            if (index != 0) json.append(allocator, ',') catch return;
            json.appendSlice(allocator, "{\"filename\":") catch return;
            appendJsonString(allocator, &json, frame.filename) catch return;
            json.appendSlice(allocator, ",\"name\":") catch return;
            appendJsonString(allocator, &json, frame.function_name) catch return;
            json.appendSlice(allocator, ",\"line\":") catch return;
            appendJsonNumber(allocator, &json, frame.line) catch return;
            json.appendSlice(allocator, ",\"column\":") catch return;
            appendJsonNumber(allocator, &json, frame.column) catch return;
            json.appendSlice(allocator, ",\"source_line\":") catch return;
            appendJsonString(allocator, &json, frame.source_line) catch return;
            json.append(allocator, '}') catch return;
            index += 1;
        }
        json.append(allocator, ']') catch return;
        self.traceback_json_owned = json.toOwnedSlice(allocator) catch return;

        var rendered: std.ArrayList(u8) = .empty;
        defer rendered.deinit(allocator);
        appendExceptionText(allocator, &rendered, instance, 0) catch {
            self.error_text_static = "Python exception";
            return;
        };
        const text = rendered.toOwnedSlice(allocator) catch {
            self.error_text_static = "Python exception";
            return;
        };
        self.clearErrorText();
        self.error_text_owned = text;
    }

    fn setStaticError(self: *Runtime, text: []const u8) void {
        self.last_exception = null;
        self.clearErrorText();
        self.error_text_static = text;
    }

    fn clearErrorText(self: *Runtime) void {
        if (self.error_text_owned) |owned| self.heap.allocator.free(owned);
        self.error_text_owned = null;
        self.error_text_static = "";
    }

    fn engineFault(self: *Runtime) bool {
        self.engine_failed = true;
        return false;
    }
};

const DictEqualityContext = struct {
    runtime: *Runtime,
    line: u32,
    column: u32,
};

fn appendJsonString(allocator: std.mem.Allocator, output: *std.ArrayList(u8), text: []const u8) std.mem.Allocator.Error!void {
    try output.append(allocator, '"');
    for (text) |character| {
        const escaped: ?[]const u8 = switch (character) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => null,
        };
        if (escaped) |escape_text| {
            try output.appendSlice(allocator, escape_text);
        } else if (character < 0x20) {
            const encoded = try std.fmt.allocPrint(allocator, "\\u{x:0>4}", .{character});
            defer allocator.free(encoded);
            try output.appendSlice(allocator, encoded);
        } else {
            try output.append(allocator, character);
        }
    }
    try output.append(allocator, '"');
}

fn appendJsonNumber(allocator: std.mem.Allocator, output: *std.ArrayList(u8), value: u32) std.mem.Allocator.Error!void {
    const text = try std.fmt.allocPrint(allocator, "{d}", .{value});
    defer allocator.free(text);
    try output.appendSlice(allocator, text);
}

fn appendExceptionText(allocator: std.mem.Allocator, output: *std.ArrayList(u8), instance: *exceptions.ExceptionInstance, depth: usize) std.mem.Allocator.Error!void {
    if (depth >= 64) return;
    if (instance.cause) |cause| {
        try appendExceptionText(allocator, output, cause, depth + 1);
        try output.appendSlice(allocator, "\nThe above exception was the direct cause of the following exception:\n\n");
    } else if (instance.context) |context| {
        if (!instance.suppress_context) {
            try appendExceptionText(allocator, output, context, depth + 1);
            try output.appendSlice(allocator, "\nDuring handling of the above exception, another exception occurred:\n\n");
        }
    }
    if (instance.frames.items.len != 0) try output.appendSlice(allocator, "Traceback (most recent call last):\n");
    var frame_index = instance.frames.items.len;
    while (frame_index > 0) {
        frame_index -= 1;
        const frame = instance.frames.items[frame_index];
        const heading = try std.fmt.allocPrint(allocator, "  File \"{s}\", line {d}, in {s}\n", .{ frame.filename, frame.line, frame.function_name });
        defer allocator.free(heading);
        try output.appendSlice(allocator, heading);
        if (frame.source_line.len != 0) {
            try output.appendSlice(allocator, "    ");
            try output.appendSlice(allocator, frame.source_line);
            try output.append(allocator, '\n');
        }
    }
    try output.appendSlice(allocator, exceptionName(instance.kind));
    if (instance.message.len != 0) {
        try output.appendSlice(allocator, ": ");
        try output.appendSlice(allocator, instance.message);
    }
    try output.append(allocator, '\n');
}

fn dictKeysEqual(raw_context: *anyopaque, left: Value, right: Value) ?bool {
    const context: *DictEqualityContext = @ptrCast(@alignCast(raw_context));
    return context.runtime.valuesEqual(left, right, context.line, context.column);
}

fn exceptionName(kind: PythonExceptionKind) []const u8 {
    return exceptions.exceptionName(kind);
}

fn sourceLine(source: []const u8, requested_line: u32) []const u8 {
    if (requested_line == 0) return "";
    var line: u32 = 1;
    var start: usize = 0;
    for (source, 0..) |character, index| {
        if (character != '\n') continue;
        if (line == requested_line) return std.mem.trimEnd(u8, source[start..index], "\r");
        line += 1;
        start = index + 1;
    }
    if (line == requested_line and start <= source.len) return std.mem.trimEnd(u8, source[start..], "\r");
    return "";
}

fn indexOfName(names: []const []const u8, name: []const u8) ?usize {
    for (names, 0..) |candidate, index| if (std.mem.eql(u8, candidate, name)) return index;
    return null;
}

fn truncateUtf8(input: []const u8, codepoints: usize) []const u8 {
    var byte_index: usize = 0;
    var seen: usize = 0;
    while (byte_index < input.len and seen < codepoints) : (seen += 1) {
        const width = std.unicode.utf8ByteSequenceLength(input[byte_index]) catch 1;
        byte_index = @min(input.len, byte_index + width);
    }
    return input[0..byte_index];
}

fn trimInputEnding(input: []const u8) []const u8 {
    if (std.mem.endsWith(u8, input, "\r\n")) return input[0 .. input.len - 2];
    if (std.mem.endsWith(u8, input, "\n") or std.mem.endsWith(u8, input, "\r")) return input[0 .. input.len - 1];
    return input;
}

fn trimFloatZeros(input: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, input, '.') orelse return input;
    var end = input.len;
    while (end > dot + 1 and input[end - 1] == '0') end -= 1;
    if (end == dot + 1) end = dot;
    return input[0..end];
}

fn roundDecimalTieEven(value: f64, precision: usize) f64 {
    if (!std.math.isFinite(value) or precision > 15) return value;
    const scale = std.math.pow(f64, 10, @floatFromInt(precision));
    const magnitude = @abs(value) * scale;
    if (!std.math.isFinite(magnitude)) return value;
    const whole = @floor(magnitude);
    if (magnitude - whole != 0.5 or @rem(whole, 2.0) != 0) return value;
    const bits: u64 = @bitCast(value);
    return @bitCast(if (value < 0) bits + 1 else bits - 1);
}

fn mroContains(class: *class_module.Class, target: *class_module.Class) bool {
    for (class.mro) |base| if (base == target) return true;
    return false;
}

fn frameNameValue(frame: *Frame, name: []const u8) ?Value {
    if (indexOfName(frame.code.local_names, name)) |index| return frame.locals[index];
    if (indexOfName(frame.code.cell_names, name)) |index| return if (frame.local_cells[index]) |cell| cell.value else null;
    if (indexOfName(frame.code.free_names, name)) |index| return if (frame.free_cells[index]) |cell| cell.value else null;
    return null;
}

fn compareOrder(order: std.math.Order, operation: u8) bool {
    return switch (operation) {
        2 => order == .lt,
        3 => order != .gt,
        4 => order == .gt,
        5 => order != .lt,
        else => false,
    };
}

fn compareNumericOrder(order: number.Comparison, operation: u8) bool {
    return switch (operation) {
        2 => order == .less,
        3 => order == .less or order == .equal,
        4 => order == .greater,
        5 => order == .greater or order == .equal,
        else => false,
    };
}

fn isAlign(character: u8) bool {
    return character == '<' or character == '>' or character == '^';
}

fn builtinNative(name: []const u8) ?functions.Native {
    if (std.mem.eql(u8, name, "bool")) return .bool_constructor;
    if (std.mem.eql(u8, name, "open")) return .open;
    if (std.mem.eql(u8, name, "str")) return .str_constructor;
    if (std.mem.eql(u8, name, "format")) return .format_builtin;
    if (std.mem.eql(u8, name, "sorted")) return .sorted;
    if (std.mem.eql(u8, name, "map")) return .map;
    if (std.mem.eql(u8, name, "filter")) return .filter;
    if (std.mem.eql(u8, name, "dict")) return .dict;
    if (std.mem.eql(u8, name, "set")) return .set;
    if (std.mem.eql(u8, name, "hash")) return .hash;
    if (std.mem.eql(u8, name, "len")) return .len;
    if (std.mem.eql(u8, name, "list")) return .list;
    if (std.mem.eql(u8, name, "tuple")) return .tuple;
    if (std.mem.eql(u8, name, "iter")) return .iter;
    if (std.mem.eql(u8, name, "next")) return .next;
    if (std.mem.eql(u8, name, "slice")) return .slice;
    if (std.mem.eql(u8, name, "enumerate")) return .enumerate;
    if (std.mem.eql(u8, name, "zip")) return .zip;
    if (std.mem.eql(u8, name, "reversed")) return .reversed;
    if (std.mem.eql(u8, name, "isinstance")) return .isinstance_builtin;
    if (std.mem.eql(u8, name, "issubclass")) return .issubclass_builtin;
    if (std.mem.eql(u8, name, "callable")) return .callable_builtin;
    if (std.mem.eql(u8, name, "repr")) return .repr_builtin;
    if (std.mem.eql(u8, name, "getattr")) return .getattr_builtin;
    if (std.mem.eql(u8, name, "setattr")) return .setattr_builtin;
    if (std.mem.eql(u8, name, "delattr")) return .delattr_builtin;
    if (std.mem.eql(u8, name, "hasattr")) return .hasattr_builtin;
    if (std.mem.eql(u8, name, "property")) return .property_builtin;
    if (std.mem.eql(u8, name, "staticmethod")) return .staticmethod_builtin;
    if (std.mem.eql(u8, name, "classmethod")) return .classmethod_builtin;
    if (std.mem.eql(u8, name, "super")) return .super_builtin;
    return null;
}

fn attributeNative(receiver: Value, name: []const u8) ?functions.Native {
    const header = receiver.asObject() orelse return null;
    if (iterator.iteratorFromHeader(header)) |selected| {
        if (selected.mode == .generator) {
            if (std.mem.eql(u8, name, "send")) return .generator_send;
            if (std.mem.eql(u8, name, "close")) return .generator_close;
        }
    }
    if (class_module.descriptorFromHeader(header)) |descriptor| if (descriptor.kind == .property) {
        if (std.mem.eql(u8, name, "setter")) return .descriptor_setter;
        if (std.mem.eql(u8, name, "deleter")) return .descriptor_deleter;
        if (std.mem.eql(u8, name, "getter")) return null;
    };
    if (file_module.fromHeader(header) != null) {
        if (std.mem.eql(u8, name, "read")) return .file_read;
        if (std.mem.eql(u8, name, "readline")) return .file_readline;
        if (std.mem.eql(u8, name, "readlines")) return .file_readlines;
        if (std.mem.eql(u8, name, "write")) return .file_write;
        if (std.mem.eql(u8, name, "writelines")) return .file_writelines;
        if (std.mem.eql(u8, name, "seek")) return .file_seek;
        if (std.mem.eql(u8, name, "tell")) return .file_tell;
        if (std.mem.eql(u8, name, "truncate")) return .file_truncate;
        if (std.mem.eql(u8, name, "flush")) return .file_flush;
        if (std.mem.eql(u8, name, "close")) return .file_close;
    }
    if (dict_module.dictFromHeader(header)) |mapping| {
        if (mapping.is_set) {
            if (std.mem.eql(u8, name, "add")) return .set_add;
            if (std.mem.eql(u8, name, "remove")) return .set_remove;
            if (std.mem.eql(u8, name, "discard")) return .set_discard;
            if (std.mem.eql(u8, name, "pop")) return .set_pop;
            if (std.mem.eql(u8, name, "update")) return .set_update;
            if (std.mem.eql(u8, name, "clear")) return .set_clear;
            if (std.mem.eql(u8, name, "copy")) return .set_copy;
        } else {
            if (std.mem.eql(u8, name, "get")) return .dict_get;
            if (std.mem.eql(u8, name, "keys")) return .dict_keys;
            if (std.mem.eql(u8, name, "values")) return .dict_values;
            if (std.mem.eql(u8, name, "items")) return .dict_items;
            if (std.mem.eql(u8, name, "pop")) return .dict_pop;
            if (std.mem.eql(u8, name, "setdefault")) return .dict_setdefault;
            if (std.mem.eql(u8, name, "update")) return .dict_update;
            if (std.mem.eql(u8, name, "clear")) return .dict_clear;
            if (std.mem.eql(u8, name, "copy")) return .dict_copy;
        }
    }
    if (sequence.listFromHeader(header) != null) {
        if (std.mem.eql(u8, name, "append")) return .list_append;
        if (std.mem.eql(u8, name, "extend")) return .list_extend;
        if (std.mem.eql(u8, name, "insert")) return .list_insert;
        if (std.mem.eql(u8, name, "pop")) return .list_pop;
        if (std.mem.eql(u8, name, "remove")) return .list_remove;
        if (std.mem.eql(u8, name, "clear")) return .list_clear;
        if (std.mem.eql(u8, name, "index")) return .list_index;
        if (std.mem.eql(u8, name, "count")) return .list_count;
        if (std.mem.eql(u8, name, "reverse")) return .list_reverse;
        if (std.mem.eql(u8, name, "copy")) return .list_copy;
        if (std.mem.eql(u8, name, "sort")) return .list_sort;
    }
    if (string.fromHeader(header) != null) {
        if (std.mem.eql(u8, name, "format")) return .str_format;
        if (std.mem.eql(u8, name, "find")) return .str_find;
        if (std.mem.eql(u8, name, "index")) return .str_index;
        if (std.mem.eql(u8, name, "split")) return .str_split;
        if (std.mem.eql(u8, name, "join")) return .str_join;
        if (std.mem.eql(u8, name, "strip")) return .str_strip;
        if (std.mem.eql(u8, name, "upper")) return .str_upper;
        if (std.mem.eql(u8, name, "lower")) return .str_lower;
        if (std.mem.eql(u8, name, "replace")) return .str_replace;
        if (std.mem.eql(u8, name, "count")) return .str_count;
        if (std.mem.eql(u8, name, "startswith")) return .str_startswith;
        if (std.mem.eql(u8, name, "endswith")) return .str_endswith;
        if (std.mem.eql(u8, name, "encode")) return .str_encode;
    }
    if (byte_module.fromHeader(header) != null) {
        if (std.mem.eql(u8, name, "split")) return .bytes_split;
        if (std.mem.eql(u8, name, "find")) return .bytes_find;
        if (std.mem.eql(u8, name, "decode")) return .bytes_decode;
    }
    return null;
}
