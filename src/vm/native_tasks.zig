const std = @import("std");
const bytecode = @import("frontend_bytecode");
const gc = @import("runtime_gc");
const Value = @import("runtime_value").Value;
const functions = @import("runtime_function");
const binder = @import("runtime_binder");
const class_module = @import("runtime_class");
const iterator = @import("runtime_iterator");
const native_library = @import("../stdlib/native.zig");
const exceptions = @import("runtime_exception");
const host = @import("runtime_host");
const native_types = @import("../stdlib/types.zig");

const Runtime = @import("runtime.zig").Runtime;
const RunStatus = @import("runtime.zig").RunStatus;
const Frame = @import("state.zig").Frame;

pub fn currentNativeTask(self: *const Runtime) ?*native_types.Task {
    const header = self.native_task_root.object orelse return null;
    return native_types.taskFromHeader(header);
}

pub fn startNativeTask(self: *Runtime, task: *native_types.Task) bool {
    const caller: *Frame = @ptrCast(@alignCast(task.caller_frame));
    if (caller != self.top_frame or task.parent != self.currentNativeTask()) return self.engineFault();
    self.native_task_root.object = &task.header;
    return true;
}

pub fn processNativeTask(self: *Runtime, task: *native_types.Task) ?RunStatus {
    if (task.stage != .ready or self.top_frame != @as(*Frame, @ptrCast(@alignCast(task.caller_frame)))) {
        _ = self.engineFault();
        return .engine_error;
    }
    if (!self.chargeBulkWork(1)) return .limit;
    const action = task.ops.step(self, task);
    switch (action) {
        .done => {
            if (task.sync_next_delivery) {
                const header = task.sync_delivery_iterator.asObject() orelse return .engine_error;
                const selected = iterator.iteratorFromHeader(header) orelse return .engine_error;
                selected.native_pending_value = null;
                selected.native_pending_done = true;
                self.native_task_root.object = if (task.parent) |parent| &parent.header else null;
                return null;
            }
            if (task.parent) |parent| if (parent.stage == .waiting_next and parent.caller_frame == task.caller_frame) {
                parent.child_value = Value.noneValue();
                parent.child_error = null;
                parent.child_done = true;
                parent.child_ready = true;
                parent.stage = .ready;
                self.native_task_root.object = &parent.header;
                return null;
            };
            if (task.item_presence_destination) |has_item_destination| {
                if (!self.validRegister(has_item_destination)) {
                    _ = self.engineFault();
                    return .engine_error;
                }
                self.setRegister(has_item_destination, Value.falseValue());
                self.native_task_root.object = if (task.parent) |parent| &parent.header else null;
                return null;
            }
            self.setException(.{ .kind = .stop_iteration, .message = "" }, task.line, task.column, null);
            self.native_task_root.object = if (task.parent) |parent| &parent.header else null;
            return unwindTaskException(self);
        },
        .complete => |value| {
            if (task.sync_next_delivery) {
                const header = task.sync_delivery_iterator.asObject() orelse return .engine_error;
                const selected = iterator.iteratorFromHeader(header) orelse return .engine_error;
                selected.native_pending_value = value;
                selected.native_pending_done = false;
                self.native_task_root.object = if (task.parent) |parent| &parent.header else null;
                return null;
            }
            if (!self.validRegister(task.destination)) {
                _ = self.engineFault();
                return .engine_error;
            }
            if (task.parent) |parent| {
                if ((parent.stage == .waiting_call or parent.stage == .waiting_next) and parent.caller_frame == task.caller_frame) {
                    parent.child_value = value;
                    parent.child_error = null;
                    parent.child_ready = true;
                    parent.child_done = false;
                    parent.stage = .ready;
                } else {
                    self.setRegister(task.destination, value);
                    if (task.item_presence_destination) |has_item_destination| self.setRegister(has_item_destination, Value.trueValue());
                }
                self.native_task_root.object = &parent.header;
            } else {
                self.setRegister(task.destination, value);
                if (task.item_presence_destination) |has_item_destination| self.setRegister(has_item_destination, Value.trueValue());
                self.native_task_root.object = null;
            }
            return null;
        },
        .raise => |exception| {
            self.setException(exception, task.line, task.column, null);
            self.native_task_root.object = if (task.parent) |parent| &parent.header else null;
            return unwindTaskException(self);
        },
        .propagate => {
            if (task.child_error) |error_instance| {
                self.active_exception = error_instance;
                self.exception_root.object = &error_instance.header;
                self.last_exception = .{ .kind = error_instance.kind, .message = error_instance.message, .native_class = error_instance.native_class };
            } else if (self.last_exception == null or self.active_exception == null) {
                _ = self.engineFault();
                return .engine_error;
            }
            self.native_task_root.object = if (task.parent) |parent| &parent.header else null;
            return unwindTaskException(self);
        },
        .yield => return null,
        .call => |request| {
            task.stage = .waiting_call;
            if (!self.startTaskCall(task, request)) {
                self.native_task_root.object = if (task.parent) |parent| &parent.header else null;
                return unwindTaskException(self);
            }
            return null;
        },
        .next => |iterator_value| {
            task.stage = .waiting_next;
            task.next_iterator = iterator_value;
            task.child_ready = false;
            task.child_done = false;
            task.child_error = null;
            if (!self.startTaskNext(task, iterator_value)) {
                self.native_task_root.object = if (task.parent) |parent| &parent.header else null;
                return unwindTaskException(self);
            }
            return null;
        },
        .host => |request| {
            if (request.kind != .http and request.kind != .clock and request.kind != .sleep) {
                _ = self.engineFault();
                return .engine_error;
            }
            const request_id = self.nextEventId();
            if (!self.createEventPacket(.{
                .kind = request.kind,
                .request_id = request_id,
                .sections = request.sections,
            })) {
                self.setException(exceptions.memoryError(), task.line, task.column, null);
                self.native_task_root.object = if (task.parent) |parent| &parent.header else null;
                return unwindTaskException(self);
            }
            task.request_id = request_id;
            task.request_kind = request.kind;
            task.stage = .waiting_host;
            return .host_request;
        },
    }
}

pub fn startTaskNext(self: *Runtime, task: *native_types.Task, iterator_value: Value) bool {
    const header = iterator_value.asObject() orelse return self.nativeTypeError(task.line, task.column, "object is not an iterator");
    const selected = iterator.iteratorFromHeader(header) orelse return self.nativeTypeError(task.line, task.column, "object is not an iterator");
    if (selected.user_object) |user| {
        const user_header = user.asObject() orelse return self.engineFault();
        if (native_types.fromHeader(user_header)) |native_object| {
            const ops = native_object.ops orelse return self.nativeTypeError(task.line, task.column, "object is not an iterator");
            const next = ops.next orelse return self.nativeTypeError(task.line, task.column, "object is not an iterator");
            return switch (next(self, native_object, task.destination, task.line, task.column)) {
                .item => |item| blk: {
                    task.child_value = item;
                    task.child_done = false;
                    task.child_ready = true;
                    task.stage = .ready;
                    break :blk true;
                },
                .done => blk: {
                    task.child_value = Value.noneValue();
                    task.child_done = true;
                    task.child_ready = true;
                    task.stage = .ready;
                    break :blk true;
                },
                .suspended => blk: {
                    const child = self.currentNativeTask() orelse break :blk self.engineFault();
                    if (child == task or child.parent != task) break :blk self.engineFault();
                    break :blk true;
                },
                .python_exception => |exception| blk: {
                    self.setException(exception, task.line, task.column, null);
                    break :blk false;
                },
                .engine_error => self.engineFault(),
            };
        }
        const instance = class_module.instanceFromHeader(user_header) orelse return self.nativeTypeError(task.line, task.column, "object is not an iterator");
        const method = class_module.classAttribute(instance.class, "__next__") orelse return self.nativeTypeError(task.line, task.column, "object is not an iterator");
        if (!self.startTaskCall(task, .{ .callable = method, .positional = &.{user} })) {
            if (self.last_exception != null and self.last_exception.?.kind == .stop_iteration) {
                self.last_exception = null;
                self.active_exception = null;
                self.exception_root.object = null;
                self.clearErrorText();
                task.child_error = null;
                task.child_done = true;
                task.child_ready = true;
                task.stage = .ready;
                return true;
            }
            return false;
        }
        return true;
    }
    if (selected.mode == .generator) {
        if (selected.generator_done) {
            task.child_done = true;
            task.child_ready = true;
            task.stage = .ready;
            return true;
        }
        if (!selected.started) {
            const frame = self.createGeneratorFrame(selected, task.line, task.column) orelse return false;
            selected.generator_frame = frame;
            selected.generator_roots = frame.roots;
            selected.generator_frame_destroy = @import("state.zig").destroyGeneratorFrameOpaque;
            selected.started = true;
        }
        const frame: *Frame = @ptrCast(@alignCast(selected.generator_frame orelse return self.engineFault()));
        const caller = self.top_frame orelse return self.engineFault();
        selected.generator_yielded = null;
        frame.previous = caller;
        frame.root_frame.push(&self.heap.roots);
        for (frame.roots) |*root| frame.root_frame.add(root);
        self.top_frame = frame;
        self.activateFrame(frame);
        if (selected.generator_yield_register) |register| {
            const slot: usize = register;
            if (slot >= frame.registers.len or slot >= frame.roots.len) return self.engineFault();
            frame.registers[slot] = selected.generator_send_value;
            frame.roots[slot].object = selected.generator_send_value.asObject();
            selected.generator_yield_register = null;
        }
        selected.generator_send_value = Value.noneValue();
        self.resuming_generator = selected;
        return true;
    }
    const result = self.nextIteratorValue(selected, task.destination, task.line, task.column);
    switch (result) {
        .item => |item| {
            task.child_value = item;
            task.child_done = false;
            task.child_ready = true;
            task.stage = .ready;
            return true;
        },
        .done => {
            task.child_value = Value.noneValue();
            task.child_done = true;
            task.child_ready = true;
            task.stage = .ready;
            return true;
        },
        .suspended => {
            const child = self.currentNativeTask() orelse return self.nativeTypeError(task.line, task.column, "nested iterator task suspension is not ready");
            if (child == task or child.parent != task) return self.nativeTypeError(task.line, task.column, "nested iterator task suspension is not ready");
            return true;
        },
        .python_exception => |exception| {
            self.setException(exception, task.line, task.column, null);
            return false;
        },
        .engine_error => return self.engineFault(),
    }
}

fn unwindTaskException(self: *Runtime) ?RunStatus {
    if (self.sync_task) |task| if (!task.callback_in_progress) self.clearSyncTask();
    if (!self.engine_failed and self.last_exception != null and self.unwindPythonException()) return null;
    if (self.engine_failed) return .engine_error;
    self.unwindFrames();
    self.prepareExceptionDiagnostics();
    return .python_exception;
}

pub fn startTaskCall(self: *Runtime, task: *native_types.Task, request: native_types.CallRequest) bool {
    const callable_header = request.callable.asObject() orelse return self.nativeTypeError(task.line, task.column, "object is not callable");
    if (class_module.boundMethodFromHeader(callable_header)) |method| {
        const expanded = self.heap.allocator.alloc(Value, request.positional.len + 1) catch {
            self.setException(exceptions.memoryError(), task.line, task.column, null);
            return false;
        };
        defer self.heap.allocator.free(expanded);
        expanded[0] = method.receiver;
        @memcpy(expanded[1..], request.positional);
        return self.startTaskCall(task, .{ .callable = method.callable, .positional = expanded, .keywords = request.keywords });
    }
    if (class_module.instanceFromHeader(callable_header)) |instance| {
        const method = class_module.classAttribute(instance.class, "__call__") orelse return self.nativeTypeError(task.line, task.column, "object is not callable");
        const expanded = self.heap.allocator.alloc(Value, request.positional.len + 1) catch {
            self.setException(exceptions.memoryError(), task.line, task.column, null);
            return false;
        };
        defer self.heap.allocator.free(expanded);
        expanded[0] = request.callable;
        @memcpy(expanded[1..], request.positional);
        return self.startTaskCall(task, .{ .callable = method, .positional = expanded, .keywords = request.keywords });
    }
    if (class_module.classFromHeader(callable_header)) |class| {
        if (class.primitive) |primitive| {
            const builtin_native: functions.Native = switch (primitive) {
                .bool_type => .bool_constructor,
                .int_type => .int_constructor,
                .str_type => .str_constructor,
                .float_type => .float_constructor,
                .list_type => .list,
                .tuple_type => .tuple,
                .dict_type => .dict,
                .set_type => .set,
                .range_type => .range,
                .slice_type => .slice,
                else => return self.nativeTypeError(task.line, task.column, "type constructor is not supported"),
            };
            if (!self.executeNativeCall(task.destination, builtin_native, Value.noneValue(), request.positional, request.keywords, task.line, task.column)) return false;
            return finishImmediateTaskCall(self, task);
        }
        if (class.native_type_id != 0) {
            const type_id = std.enums.fromInt(native_types.TypeId, class.native_type_id - 1) orelse return self.engineFault();
            if (!native_library.construct(Runtime, self, task.destination, type_id, request.callable, request.positional, request.keywords, task.line, task.column)) return false;
            return finishImmediateTaskCall(self, task);
        }
        const instance = switch (class_module.createInstance(&self.heap, class)) {
            .value => |selected| selected,
            .python_exception => |exception| {
                self.setException(exception, task.line, task.column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        const value = Value.object(&instance.header);
        task.constructor_instance = value;
        const initializer = class_module.classAttribute(class, "__init__") orelse {
            if (request.positional.len != 0 or request.keywords.len != 0) return self.nativeTypeError(task.line, task.column, "object takes no arguments");
            task.child_value = value;
            task.child_error = null;
            task.child_ready = true;
            task.stage = .ready;
            task.constructor_instance = Value.noneValue();
            return true;
        };
        const expanded = self.heap.allocator.alloc(Value, request.positional.len + 1) catch {
            self.setException(exceptions.memoryError(), task.line, task.column, null);
            return false;
        };
        defer self.heap.allocator.free(expanded);
        expanded[0] = value;
        @memcpy(expanded[1..], request.positional);
        return self.startTaskCall(task, .{ .callable = initializer, .positional = expanded, .keywords = request.keywords });
    }
    const function = functions.functionFromHeader(callable_header) orelse return self.nativeTypeError(task.line, task.column, "object is not callable");
    if (function.library_module != 0) {
        if (!native_library.call(Runtime, self, task.destination, function.library_module, function.library_function, function.bound_self, request.positional, request.keywords, task.line, task.column)) return false;
        return finishImmediateTaskCall(self, task);
    }
    if (function.native) |builtin_native| {
        if (!self.executeNativeCall(task.destination, builtin_native, function.bound_self, request.positional, request.keywords, task.line, task.column)) return false;
        return finishImmediateTaskCall(self, task);
    }
    const code = function.code orelse return self.engineFault();
    if (code.flags & bytecode.code_flags.generator != 0) {
        const generated = iterator.createFunctionGenerator(&self.heap, request.callable, request.positional);
        switch (generated) {
            .value => |selected| {
                task.child_value = Value.object(&selected.header);
                task.child_error = null;
                task.child_ready = true;
                task.stage = .ready;
                return true;
            },
            .python_exception => |exception| {
                self.setException(exception, task.line, task.column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        }
    }
    const caller = self.top_frame orelse return self.engineFault();
    const allocator = self.heap.allocator;
    const binding = binder.bindFunction(
        &self.heap,
        allocator,
        code.parameter_names,
        code.parameter_flags,
        function.defaults,
        request.positional,
        request.keywords,
    ) catch |err| {
        self.setBinderException(err, task.line, task.column);
        return false;
    };
    defer allocator.free(binding.values);
    defer if (binding.extra_keywords.len != 0) allocator.free(binding.extra_keywords);
    if (binding.extra_keywords.len != 0) return self.nativeTypeError(task.line, task.column, "callback keyword capture is not ready");
    const roots = allocator.alloc(gc.Root, binding.values.len) catch {
        self.setException(exceptions.memoryError(), task.line, task.column, null);
        return false;
    };
    defer allocator.free(roots);
    for (binding.values, 0..) |value, index| roots[index] = .{ .object = value.asObject() };
    var bound_frame = gc.RootFrame{};
    bound_frame.push(&self.heap.roots);
    for (roots) |*root| bound_frame.add(root);
    var bound_frame_active = true;
    defer if (bound_frame_active) bound_frame.pop();

    const frame = self.allocateFrame(code, task.destination) catch {
        self.setException(exceptions.memoryError(), task.line, task.column, null);
        return false;
    };
    Runtime.setFrameEnvironment(frame, function.globals orelse frame.environment);
    frame.return_to_task = task;
    var frame_active = true;
    defer if (frame_active) {
        bound_frame.pop();
        bound_frame_active = false;
        self.unwindFramesUntil(caller);
    };
    frame.root_frame.pop();
    bound_frame.pop();
    bound_frame_active = false;
    frame.root_frame.push(&self.heap.roots);
    for (frame.roots) |*root| frame.root_frame.add(root);
    bound_frame.push(&self.heap.roots);
    for (roots) |*root| bound_frame.add(root);
    bound_frame_active = true;

    if (function.cells.len != code.free_names.len) return self.engineFault();
    for (function.cells, 0..) |cell, index| {
        frame.free_cells[index] = cell;
        frame.roots[frame.freeRootStart() + index].object = &cell.header;
    }
    for (code.cell_names, 0..) |_, index| {
        const cell = functions.createCell(&self.heap, Value.unboundValue()) catch {
            self.setException(exceptions.memoryError(), task.line, task.column, null);
            return false;
        };
        frame.local_cells[index] = cell;
        frame.roots[frame.cellRootStart() + index].object = &cell.header;
    }
    for (code.parameter_names, 0..) |name, index| {
        if (!self.storeFrameLocal(frame, name, binding.values[index])) return self.engineFault();
    }
    bound_frame.pop();
    bound_frame_active = false;
    frame_active = false;
    return true;
}

fn finishImmediateTaskCall(self: *Runtime, task: *native_types.Task) bool {
    if (self.currentNativeTask() != task or self.pending_input != null or self.sync_task != null) return true;
    if (!self.validRegister(task.destination)) return self.engineFault();
    task.child_value = self.registers[task.destination];
    task.child_error = null;
    task.child_ready = true;
    task.stage = .ready;
    return true;
}

pub fn pendingNativeHost(self: *const Runtime) ?struct { kind: host.Kind, request_id: u32 } {
    const task = self.currentNativeTask() orelse return null;
    if (task.stage != .waiting_host) return null;
    return .{ .kind = task.request_kind orelse return null, .request_id = task.request_id };
}

pub fn resumeNativeHost(self: *Runtime, packet: *const host.DecodedPacket) bool {
    if (!host.validDecodedPacket(packet)) return false;
    const task = self.currentNativeTask() orelse return false;
    if (task.stage != .waiting_host or packet.kind != task.request_kind or packet.request_id != task.request_id or packet.flags != 0) return false;
    switch (packet.status) {
        .ok => switch (packet.kind) {
            .http => {
                if (packet.sections.len != 3 or packet.sections[0].kind != .binary or packet.sections[0].bytes.len != 2 or packet.sections[1].kind != .utf8 or packet.sections[2].kind != .binary) return false;
                const status_code = std.mem.readInt(u16, packet.sections[0].bytes[0..2], .little);
                if (status_code < 100 or status_code > 599) return false;
            },
            .clock => {
                if (packet.sections.len != 1 or packet.sections[0].kind != .binary or packet.sections[0].bytes.len != 8) return false;
                const bits = std.mem.readInt(u64, packet.sections[0].bytes[0..8], .little);
                if (!std.math.isFinite(@as(f64, @bitCast(bits)))) return false;
            },
            .sleep => if (packet.sections.len != 0) return false,
            else => return false,
        },
        .host_error => {
            if (packet.sections.len != 2 or packet.sections[0].kind != .utf8 or packet.sections[1].kind != .utf8) return false;
        },
        .eof => return false,
    }
    const handler = task.ops.host_reply orelse return false;
    if (!handler(self, task, packet)) return false;
    task.stage = .ready;
    task.request_id = 0;
    task.request_kind = null;
    self.invalidateEvent();
    return true;
}
