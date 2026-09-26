const std = @import("std");
const bytecode = @import("frontend_bytecode");
const gc = @import("runtime_gc");
const value_module = @import("runtime_value");
const functions = @import("runtime_function");
const exceptions = @import("runtime_exception");
const file_module = @import("runtime_file");
const class_module = @import("runtime_class");
const native_types = @import("../stdlib/types.zig");
const sequence = @import("runtime_sequence");
const Runtime = @import("runtime.zig").Runtime;
const state = @import("state.zig");
const Frame = state.Frame;
const TryBlock = state.TryBlock;
const TestContextManager = state.TestContextManager;
const Value = value_module.Value;
const Code = bytecode.Code;
const PythonException = exceptions.PythonException;
const PythonExceptionKind = exceptions.PythonExceptionKind;
const indexOfName = @import("runtime.zig").indexOfName;

pub fn allocateFrame(self: *Runtime, code: *Code, return_destination: ?u16) error{OutOfMemory}!*Frame {
    const allocator = self.heap.allocator;
    const environment = self.currentEnvironment();
    if (takeCachedFrame(self, code)) |frame| {
        frame.environment = environment;
        frame.previous = self.top_frame;
        frame.return_destination = return_destination;
        @memset(frame.registers, Value.unboundValue());
        @memset(frame.locals, Value.unboundValue());
        @memset(frame.local_cells, null);
        @memset(frame.free_cells, null);
        frame.try_blocks.clearRetainingCapacity();
        @memset(frame.pending_values, Value.noneValue());
        @memset(frame.roots, .{ .object = null });
        frame.roots[frame.environmentRootIndex()].object = environment;
        frame.root_frame.push(&self.heap.roots);
        for (frame.roots) |*root| frame.root_frame.add(root);
        self.top_frame = frame;
        self.activateFrame(frame);
        return frame;
    }
    const frame = allocator.create(Frame) catch return error.OutOfMemory;
    frame.* = .{ .code = code, .return_destination = return_destination, .environment = environment };
    errdefer destroyFrameStorage(self, frame);
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
    const with_special_roots = std.math.add(usize, root_prefix, 3) catch return error.OutOfMemory;
    const root_count = std.math.add(usize, with_special_roots, unwind_root_count) catch return error.OutOfMemory;
    frame.roots = try allocator.alloc(gc.Root, root_count);
    @memset(frame.roots, .{ .object = null });
    frame.roots[frame.environmentRootIndex()].object = environment;
    frame.root_frame.push(&self.heap.roots);
    for (frame.roots) |*root| frame.root_frame.add(root);
    frame.previous = self.top_frame;
    self.top_frame = frame;
    self.activateFrame(frame);
    return frame;
}

pub fn freeFrameStorage(self: *Runtime, frame: *Frame) void {
    if (frame.generator_owner == null and self.frame_cache_count < 32 and frameStorageBytes(frame) <= 64 * 1024) {
        frame.module_initializing = null;
        frame.return_destination = null;
        frame.return_override = null;
        frame.return_to_task = null;
        frame.override_requires_none = false;
        frame.ip = 0;
        frame.class_namespace = null;
        @memset(frame.registers, Value.unboundValue());
        @memset(frame.locals, Value.unboundValue());
        @memset(frame.local_cells, null);
        @memset(frame.free_cells, null);
        frame.try_blocks.clearRetainingCapacity();
        @memset(frame.pending_values, Value.noneValue());
        @memset(frame.roots, .{ .object = null });
        frame.root_frame = .{};
        frame.previous = self.frame_cache;
        self.frame_cache = frame;
        self.frame_cache_count += 1;
        return;
    }
    destroyFrameStorage(self, frame);
}

pub fn clearFrameCache(self: *Runtime) void {
    while (self.frame_cache) |frame| {
        self.frame_cache = frame.previous;
        destroyFrameStorage(self, frame);
    }
    self.frame_cache_count = 0;
}

fn takeCachedFrame(self: *Runtime, code: *Code) ?*Frame {
    var link = &self.frame_cache;
    while (link.*) |frame| {
        if (frame.code == code) {
            link.* = frame.previous;
            self.frame_cache_count -= 1;
            frame.previous = null;
            return frame;
        }
        link = &frame.previous;
    }
    return null;
}

fn frameStorageBytes(frame: *const Frame) usize {
    var total: usize = @sizeOf(Frame);
    total +|= frame.registers.len *| @sizeOf(Value);
    total +|= frame.locals.len *| @sizeOf(Value);
    total +|= frame.local_cells.len *| @sizeOf(?*functions.Cell);
    total +|= frame.free_cells.len *| @sizeOf(?*functions.Cell);
    total +|= frame.pending_values.len *| @sizeOf(Value);
    total +|= frame.roots.len *| @sizeOf(gc.Root);
    total +|= frame.try_blocks.capacity *| @sizeOf(TryBlock);
    return total;
}

fn destroyFrameStorage(self: *Runtime, frame: *Frame) void {
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

pub fn activateFrame(self: *Runtime, frame: *Frame) void {
    self.registers = frame.registers;
    self.register_roots = frame.roots[0..frame.registers.len];
    self.instruction_pointer = frame.ip;
}

pub fn popFrame(self: *Runtime) ?*Frame {
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

pub fn unwindFrames(self: *Runtime) void {
    while (self.popFrame()) |frame| {
        self.forgetGeneratorFrame(frame);
        self.freeFrameStorage(frame);
    }
}

pub fn unwindFramesUntil(self: *Runtime, boundary: *Frame) void {
    while (self.top_frame != boundary) {
        const frame = self.popFrame() orelse break;
        self.forgetGeneratorFrame(frame);
        self.freeFrameStorage(frame);
    }
}

pub fn hasExceptionContinuation(self: *const Runtime) bool {
    if (self.suspended_exception_frame != null) return true;
    var frame = self.top_frame;
    while (frame) |current| : (frame = current.previous) {
        for (current.try_blocks.items) |block| {
            if (block.phase == .handler or (block.phase == .finally_body and block.pending == .exception)) return true;
        }
    }
    return false;
}

pub fn frameHasExceptionContinuation(frame: *const Frame) bool {
    for (frame.try_blocks.items) |block| {
        if (block.phase == .handler or (block.phase == .finally_body and block.pending == .exception)) return true;
    }
    return false;
}

pub fn unwindPythonException(self: *Runtime) bool {
    return self.unwindPythonExceptionUntil(null);
}

pub fn unwindPythonExceptionUntil(self: *Runtime, boundary: ?*Frame) bool {
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

        if (frame.generator_owner) |generator| {
            if (self.currentNativeTask()) |task| {
                if (task.stage == .waiting_next and task.next_iterator.asObject() == &generator.header) {
                    task.child_error = self.active_exception;
                    task.child_ready = true;
                    task.child_done = false;
                    task.stage = .ready;
                    self.last_exception = null;
                    self.active_exception = null;
                    self.exception_root.object = null;
                    self.clearErrorText();
                    self.resuming_generator = null;
                    const popped = self.popFrame() orelse return self.engineFault();
                    self.forgetGeneratorFrame(popped);
                    self.freeFrameStorage(popped);
                    return true;
                }
            }
            if (self.suspended_exception_frame == frame) self.suspended_exception_frame = null;
            return false;
        }
        if (frame.return_to_task) |task| {
            if (task.stage == .waiting_next and self.active_exception != null and self.active_exception.?.kind == .stop_iteration) {
                task.child_error = null;
                task.child_done = true;
            } else {
                task.child_error = self.active_exception;
                task.child_done = false;
            }
            task.child_ready = true;
            task.stage = .ready;
            self.last_exception = null;
            self.active_exception = null;
            self.exception_root.object = null;
            self.clearErrorText();
            const popped = self.popFrame() orelse return self.engineFault();
            self.freeFrameStorage(popped);
            return true;
        }
        const caller = frame.previous;
        if (caller == null) return false;
        self.appendTracebackCaller(caller.?);
        if (frame.module_initializing) |failed_module| self.removeCachedModule(failed_module);
        const popped = self.popFrame() orelse return self.engineFault();
        self.forgetGeneratorFrame(popped);
        self.freeFrameStorage(popped);
    }
    return false;
}

pub fn appendTracebackCaller(self: *Runtime, caller: *Frame) void {
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

pub fn tryRootIndex(frame: *const Frame, slot_index: usize, saved_exception: bool) usize {
    return frame.unwindRootStart() + slot_index * 2 + @as(usize, @intFromBool(saved_exception));
}

pub fn savePendingException(self: *Runtime, frame: *Frame, block: *TryBlock) void {
    block.pending = .exception;
    block.pending_exception = self.last_exception;
    frame.roots[tryRootIndex(frame, block.slot_index, false)].object = if (self.active_exception) |active| &active.header else null;
}

pub fn restorePendingException(self: *Runtime, frame: *Frame, block: TryBlock) void {
    const saved = frame.roots[tryRootIndex(frame, block.slot_index, false)].object;
    self.exception_root.object = saved;
    self.active_exception = if (saved) |header| exceptions.instanceFromHeader(header) else null;
    self.last_exception = block.pending_exception;
    self.clearErrorText();
    self.error_text_static = "Python exception";
}

pub fn setFrameInstruction(self: *Runtime, frame: *Frame, target: u32) bool {
    if (@as(usize, target) > frame.code.instructions.len) return self.engineFault();
    frame.ip = target;
    if (self.top_frame == frame) self.instruction_pointer = target;
    return true;
}

pub fn clearExceptionTarget(self: *Runtime, frame: *Frame, block: TryBlock) void {
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
            const environment = self.currentEnvironmentObject();
            for (environment.entries.items, 0..) |entry, global_index| {
                if (!std.mem.eql(u8, entry.name, name)) continue;
                self.heap.allocator.free(entry.name);
                _ = environment.entries.orderedRemove(global_index);
                environment.shape_version +%= 1;
                return;
            }
        },
        else => self.engine_failed = true,
    }
}

pub fn popTryBlock(self: *Runtime, frame: *Frame, restore_exception: bool) ?TryBlock {
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

pub fn beginJumpTransfer(self: *Runtime, frame: *Frame, target: u32) bool {
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

pub fn performReturn(self: *Runtime, result: Value, line: u32, column: u32) bool {
    const returning_frame = self.top_frame orelse return self.engineFault();
    const completing_module = returning_frame.module_initializing;
    var result_value = result;
    if (returning_frame.return_override) |override| {
        if (returning_frame.override_requires_none and result.tag() != .none) {
            self.setException(.{ .kind = .type_error, .message = "__init__() should return None" }, line, column, null);
            return false;
        }
        _ = override;
        result_value = returning_frame.return_override.?;
    }
    if (returning_frame.return_to_task) |task| {
        if (task.constructor_instance.tag() != .none) {
            if (result_value.tag() != .none) {
                self.setException(.{ .kind = .type_error, .message = "__init__() should return None" }, line, column, null);
                task.child_error = self.active_exception;
                self.last_exception = null;
                self.active_exception = null;
                self.exception_root.object = null;
                self.clearErrorText();
            } else {
                task.child_value = task.constructor_instance;
                task.child_error = null;
            }
            task.constructor_instance = Value.noneValue();
        } else {
            task.child_value = result_value;
            task.child_error = null;
        }
        task.child_ready = true;
        task.stage = .ready;
        const frame = self.popFrame() orelse return self.engineFault();
        self.freeFrameStorage(frame);
        return true;
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
    if (completing_module) |selected| {
        selected.initialized = true;
        if (!self.attachImportedChild(selected, line, column)) {
            self.removeCachedModule(selected);
            self.freeFrameStorage(frame);
            return false;
        }
    }
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

pub fn framePreviousIsTask(selected: ?*Frame, task_frame: *Frame) bool {
    const frame = selected orelse return false;
    return frame.previous == task_frame;
}

pub fn beginReturnTransfer(self: *Runtime, frame: *Frame, result: Value, line: u32, column: u32) bool {
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

pub fn enterTry(self: *Runtime, site_index: u32, line: u32, column: u32) bool {
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

pub fn testContextManager(value: Value) ?*TestContextManager {
    const header = value.asObject() orelse return null;
    if (header.kind != &state.test_context_manager_kind) return null;
    return @ptrCast(@alignCast(header));
}

pub fn executeWithEnter(self: *Runtime, destination: u16, manager_value: Value, line: u32, column: u32) bool {
    if (manager_value.asObject()) |header| {
        if (native_types.fromHeader(header)) |native_object| {
            const ops = native_object.ops orelse return self.nativeTypeError(line, column, "object does not support the context manager protocol");
            const enter = ops.enter orelse return self.nativeTypeError(line, column, "object does not support the context manager protocol");
            const entered = enter(self, native_object, line, column) orelse return false;
            self.setRegister(destination, entered);
            return true;
        }
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

pub fn executeWithExit(self: *Runtime, destination: u16, manager_value: Value, line: u32, column: u32) bool {
    const frame = self.top_frame orelse return self.engineFault();
    if (frame.try_blocks.items.len == 0) return self.engineFault();
    const block = &frame.try_blocks.items[frame.try_blocks.items.len - 1];
    if (block.phase != .finally_body) return self.engineFault();
    if (manager_value.asObject()) |header| {
        if (native_types.fromHeader(header)) |native_object| {
            const ops = native_object.ops orelse return self.nativeTypeError(line, column, "object does not support the context manager protocol");
            const exit = ops.exit orelse return self.nativeTypeError(line, column, "object does not support the context manager protocol");
            if (!(exit(self, native_object, line, column) orelse return false)) return false;
            self.setRegister(destination, Value.noneValue());
            return true;
        }
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

pub fn activeExceptionKind(self: *const Runtime) ?PythonExceptionKind {
    if (self.last_exception) |pending| return pending.kind;
    if (self.active_exception) |active| return active.kind;
    return null;
}

pub fn matchesExceptionType(self: *Runtime, candidate: Value, kind: PythonExceptionKind, line: u32, column: u32) ?bool {
    const active = self.active_exception orelse {
        _ = self.engineFault();
        return null;
    };
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
    if (exceptions.classFromHeader(header)) |class| return exceptions.instanceMatchesClass(active, class);
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
            matched = matched or exceptions.instanceMatchesClass(active, class);
        }
        return matched;
    }
    self.setException(.{ .kind = .type_error, .message = "catching classes that do not inherit from BaseException is not allowed" }, line, column, null);
    return null;
}

pub fn storeBoundValue(self: *Runtime, frame: *Frame, name: []const u8, binding: u8, value: Value, line: u32, column: u32) bool {
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

pub fn acceptCurrentException(self: *Runtime, frame: *Frame, site_index: u32) bool {
    if (frame.try_blocks.items.len == 0) return self.engineFault();
    const block = &frame.try_blocks.items[frame.try_blocks.items.len - 1];
    if (block.site_index != site_index or block.phase != .handler or self.last_exception == null) return self.engineFault();
    self.last_exception = null;
    self.clearErrorText();
    return true;
}

pub fn completeTry(self: *Runtime, frame: *Frame, site_index: u32) bool {
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

pub fn completeFinally(self: *Runtime, frame: *Frame, site_index: u32, line: u32, column: u32) bool {
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

pub fn raiseExisting(self: *Runtime, instance: *exceptions.ExceptionInstance, line: u32, column: u32, add_traceback_frame: bool) void {
    const previous = self.active_exception;
    if (previous) |context| {
        if (context != instance and instance.context == null) instance.context = context;
    }
    self.active_exception = instance;
    self.exception_root.object = &instance.header;
    self.last_exception = .{ .kind = instance.kind, .message = instance.message, .native_class = instance.native_class };
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
    const error_text = std.fmt.allocPrint(self.heap.allocator, "{s}: {s} ({s}:{d}:{d})", .{ exceptions.instanceName(instance), instance.message, self.currentFilename(), line, column }) catch null;
    if (error_text) |owned| self.error_text_owned = owned else self.error_text_static = "Python exception";
}

pub fn executeRaise(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
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
            switch (exceptions.createNativeInstance(&self.heap, class, "")) {
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
                switch (exceptions.createNativeInstance(&self.heap, cause_class, "")) {
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
pub fn setException(self: *Runtime, exception: PythonException, line: u32, column: u32, name: ?[]const u8) void {
    var selected = exception;
    const previous_exception = self.active_exception;
    const created = if (exception.native_class) |class|
        exceptions.createNativeInstance(&self.heap, class, exception.message)
    else
        exceptions.createInstance(&self.heap, exception.kind, exception.message);
    switch (created) {
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
            selected.native_class = instance.native_class;
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
            emergency.native_class = null;
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

pub fn currentFilename(self: *const Runtime) []const u8 {
    if (self.activeCode()) |code| return code.filename;
    return "<module>";
}

/// Preserve the compiler's source position before the host releases its input
/// transfer block. The public traceback shape is shared with runtime errors.
pub fn prepareCompileDiagnostic(self: *Runtime, source: []const u8, filename: []const u8, line: usize, column: usize) void {
    const allocator = self.heap.allocator;
    const source_line = sourceLine(source, std.math.cast(u32, line) orelse std.math.maxInt(u32));
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(allocator);
    json.appendSlice(allocator, "[{\"filename\":") catch return;
    appendJsonString(allocator, &json, filename) catch return;
    json.appendSlice(allocator, ",\"name\":\"<module>\",\"line\":") catch return;
    appendJsonNumber(allocator, &json, std.math.cast(u32, line) orelse std.math.maxInt(u32)) catch return;
    json.appendSlice(allocator, ",\"column\":") catch return;
    appendJsonNumber(allocator, &json, std.math.cast(u32, column) orelse std.math.maxInt(u32)) catch return;
    json.appendSlice(allocator, ",\"source_line\":") catch return;
    appendJsonString(allocator, &json, source_line) catch return;
    json.appendSlice(allocator, "}]") catch return;
    self.traceback_json_owned = json.toOwnedSlice(allocator) catch return;
}

pub fn prepareExceptionDiagnostics(self: *Runtime) void {
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
    try output.appendSlice(allocator, exceptions.instanceName(instance));
    if (instance.message.len != 0) {
        try output.appendSlice(allocator, ": ");
        try output.appendSlice(allocator, instance.message);
    }
    try output.append(allocator, '\n');
}
pub fn exceptionName(kind: PythonExceptionKind) []const u8 {
    return exceptions.exceptionName(kind);
}
pub fn sourceLine(source: []const u8, requested_line: u32) []const u8 {
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
