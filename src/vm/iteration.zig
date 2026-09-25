const std = @import("std");
const builtin = @import("builtin");
const bytecode = @import("frontend_bytecode");
const gc = @import("runtime_gc");
const value_module = @import("runtime_value");
const number = @import("runtime_number");
const sequence = @import("runtime_sequence");
const exceptions = @import("runtime_exception");
const iterator = @import("runtime_iterator");
const functions = @import("runtime_function");
const binder = @import("runtime_binder");
const class_module = @import("runtime_class");
const native_types = @import("../stdlib/types.zig");

const Runtime = @import("runtime.zig").Runtime;
const state = @import("state.zig");
const GlobalEntry = state.GlobalEntry;
const TryPhase = state.TryPhase;
const PendingTransfer = state.PendingTransfer;
const TryBlock = state.TryBlock;
const Environment = state.Environment;
const TestContextManager = state.TestContextManager;
const Frame = state.Frame;
const PendingInput = state.PendingInput;
const SyncTaskOperation = state.SyncTaskOperation;
const SyncTaskPhase = state.SyncTaskPhase;
const SyncCallbackResult = state.SyncCallbackResult;
const SyncTask = state.SyncTask;
const destroyGeneratorFrameOpaque = state.destroyGeneratorFrameOpaque;
const Value = value_module.Value;
const Code = bytecode.Code;
const PythonException = exceptions.PythonException;
const PythonExceptionKind = exceptions.PythonExceptionKind;
const setFrameEnvironment = @import("runtime.zig").Runtime.setFrameEnvironment;
const frameHasExceptionContinuation = @import("runtime.zig").Runtime.frameHasExceptionContinuation;
const sourceLine = @import("control.zig").sourceLine;
const indexOfName = @import("runtime.zig").indexOfName;
const frameNameValue = @import("calls.zig").frameNameValue;
const compareOrder = @import("operations.zig").compareOrder;
const compareNumericOrder = @import("operations.zig").compareNumericOrder;
const isAlign = @import("text.zig").isAlign;
const builtinNative = @import("builtins.zig").builtinNative;
const attributeNative = @import("objects.zig").attributeNative;
const exceptionName = @import("control.zig").exceptionName;
const appendExceptionText = @import("control.zig").appendExceptionText;
const dictKeysEqual = @import("operations.zig").dictKeysEqual;
const DictEqualityContext = @import("operations.zig").DictEqualityContext;
const mroContains = @import("objects.zig").mroContains;
const truncateUtf8 = @import("text.zig").truncateUtf8;
const trimInputEnding = @import("runtime.zig").trimInputEnding;
const trimFloatZeros = @import("text.zig").trimFloatZeros;
const roundDecimalTieEven = @import("text.zig").roundDecimalTieEven;

pub fn createIteratorResult(self: *Runtime, destination: u16, value: Value, line: u32, column: u32) bool {
    return self.storeIteratorOutcome(destination, self.createVmIterator(value, line, column), line, column);
}

pub fn createVmIterator(self: *Runtime, value: Value, line: u32, column: u32) exceptions.Result(*iterator.Iterator) {
    if (value.asObject()) |header| if (native_types.fromHeader(header)) |native_object| {
        const ops = native_object.ops orelse return .{ .python_exception = .{ .kind = .type_error, .message = "object is not iterable" } };
        const iterate = ops.iter orelse return .{ .python_exception = .{ .kind = .type_error, .message = "object is not iterable" } };
        const iterated = iterate(self, native_object, line, column) orelse return .{ .python_exception = self.last_exception orelse .{ .kind = .type_error, .message = "native iteration failed" } };
        const iterated_header = iterated.asObject() orelse return .{ .python_exception = .{ .kind = .type_error, .message = "iter() returned a non-iterator" } };
        if (iterator.iteratorFromHeader(iterated_header)) |selected| return .{ .value = selected };
        if (native_types.fromHeader(iterated_header)) |selected| if (selected.ops) |selected_ops| if (selected_ops.next != null) return iterator.createUserIterator(&self.heap, iterated);
        return .{ .python_exception = .{ .kind = .type_error, .message = "iter() returned a non-iterator" } };
    };
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

pub fn storeIteratorOutcome(self: *Runtime, destination: u16, outcome: exceptions.Result(*iterator.Iterator), line: u32, column: u32) bool {
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

pub fn nextIteratorValue(self: *Runtime, selected: *iterator.Iterator, destination: u16, line: u32, column: u32) iterator.NextResult {
    if (selected.user_object) |user| {
        if (user.asObject()) |user_header| if (native_types.fromHeader(user_header)) |native_object| {
            if (selected.native_pending_value) |pending| {
                selected.native_pending_value = null;
                return .{ .item = pending };
            }
            if (selected.native_pending_done) {
                selected.native_pending_done = false;
                selected.finished = true;
                return .done;
            }
            if (selected.finished) return .done;
            const ops = native_object.ops orelse return .{ .python_exception = .{ .kind = .type_error, .message = "object is not an iterator" } };
            const next = ops.next orelse return .{ .python_exception = .{ .kind = .type_error, .message = "object is not an iterator" } };
            const result = next(self, native_object, destination, line, column);
            if (result == .suspended and self.sync_task != null) {
                const task = self.currentNativeTask() orelse return .{ .engine_error = .internal_invariant };
                if (task.parent == null) {
                    task.sync_next_delivery = true;
                    task.sync_delivery_iterator = Value.object(&selected.header);
                }
            }
            return result;
        };
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

pub fn nextEnumerateIteratorValue(self: *Runtime, selected: *iterator.Iterator, destination: u16, line: u32, column: u32) iterator.NextResult {
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

pub fn nextZipIteratorValue(self: *Runtime, selected: *iterator.Iterator, destination: u16, line: u32, column: u32) iterator.NextResult {
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

pub fn resumeGenerator(self: *Runtime, selected: *iterator.Iterator, line: u32, column: u32) iterator.NextResult {
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

pub fn setIteratorStopIteration(self: *Runtime, selected: *iterator.Iterator, line: u32, column: u32) bool {
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

pub fn createGeneratorFrame(self: *Runtime, selected: *iterator.Iterator, line: u32, column: u32) ?*Frame {
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
    setFrameEnvironment(frame, function.globals orelse frame.environment);
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

pub fn beginSyncTaskRoots(self: *Runtime) void {
    self.sync_roots = @splat(.{ .object = null });
    self.sync_root_frame.push(&self.heap.roots);
    for (&self.sync_roots) |*root| self.sync_root_frame.add(root);
}

pub fn releaseSyncCallbackDepth(self: *Runtime, task: *SyncTask) void {
    if (!task.callback_depth_held) return;
    task.callback_depth_held = false;
    self.sync_callback_depth -|= 1;
}

pub fn takeCompletedSyncCallback(self: *Runtime) ?Value {
    const task = if (self.sync_task) |*active| active else return null;
    if (!task.callback_completed) return null;
    const result = task.callback_result;
    task.callback_result = Value.noneValue();
    task.callback_completed = false;
    self.sync_roots[6].object = null;
    return result;
}

pub fn invokeSyncTaskCallback(self: *Runtime, callable: Value, args: []const Value, destination: u16, line: u32, column: u32) SyncCallbackResult {
    if (self.takeCompletedSyncCallback()) |result| return .{ .value = result };
    if (self.sync_task) |task| if (task.callback_in_progress) return .suspended;
    if (self.invokeCallableSync(callable, args, destination, line, column)) |result| return .{ .value = result };
    if (self.sync_task) |task| if (task.callback_in_progress) return .suspended;
    return .failed;
}

pub fn clearSyncTask(self: *Runtime) void {
    if (self.sync_task) |*task| self.releaseSyncCallbackDepth(task);
    if (self.sync_root_frame.stack != null) self.sync_root_frame.pop();
    if (self.sync_task) |task| if (task.order.len != 0) self.heap.allocator.free(task.order);
    self.sync_roots = @splat(.{ .object = null });
    self.sync_task = null;
    self.suspended_exception_frame = null;
    self.sync_yield_requested = false;
}

pub fn pauseSyncTask(self: *Runtime, task: *SyncTask) bool {
    task.frame.ip = task.call_ip;
    self.instruction_pointer = task.call_ip;
    self.sync_yield_requested = true;
    return true;
}

pub fn continueSyncTaskAfterCallback(self: *Runtime, task: *SyncTask) bool {
    task.frame.ip = task.call_ip;
    self.instruction_pointer = task.call_ip;
    return true;
}

pub fn iteratorHasPendingCallback(selected: *iterator.Iterator) bool {
    if (selected.callback_pending) return true;
    if (selected.inner) |inner| if (iteratorHasPendingCallback(inner)) return true;
    for (selected.children) |maybe_child| if (maybe_child) |child| {
        if (iteratorHasPendingCallback(child)) return true;
    };
    return false;
}

pub fn startSortedTask(self: *Runtime, destination: u16, source: Value, callback: ?Value, reverse: bool, line: u32, column: u32) bool {
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

pub fn startListSortTask(self: *Runtime, destination: u16, list: *sequence.List, callback: ?Value, reverse: bool, line: u32, column: u32) bool {
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

pub fn startNextTask(self: *Runtime, destination: u16, selected: *iterator.Iterator, line: u32, column: u32) bool {
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

pub fn prepareSyncSort(self: *Runtime, task: *SyncTask) bool {
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

pub fn completeSyncTask(self: *Runtime, task: *SyncTask) bool {
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

pub fn finishSyncSort(self: *Runtime, task: *SyncTask) bool {
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

pub fn advanceSyncTask(self: *Runtime) bool {
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

pub fn materializeSequence(self: *Runtime, destination: u16, source: Value, want_tuple: bool, line: u32, column: u32) bool {
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

pub fn materializeSequenceImmediate(self: *Runtime, destination: u16, source: Value, want_tuple: bool, line: u32, column: u32) bool {
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

pub fn sortList(self: *Runtime, list: *sequence.List, reverse: bool, line: u32, column: u32) bool {
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

pub fn sortListWithKey(self: *Runtime, list: *sequence.List, key: ?Value, reverse: bool, destination: u16, line: u32, column: u32) bool {
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
