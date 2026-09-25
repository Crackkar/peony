const std = @import("std");
const builtin = @import("builtin");
const bytecode = @import("frontend_bytecode");
const gc = @import("runtime_gc");
const value_module = @import("runtime_value");
const string = @import("runtime_string");
const sequence = @import("runtime_sequence");
const dict_module = @import("runtime_dict");
const exceptions = @import("runtime_exception");
const iterator = @import("runtime_iterator");
const functions = @import("runtime_function");
const binder = @import("runtime_binder");
const ast_module = @import("frontend_ast");
const class_module = @import("runtime_class");

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
const Value = value_module.Value;
const Code = bytecode.Code;
const PythonException = exceptions.PythonException;
const PythonExceptionKind = exceptions.PythonExceptionKind;
const sourceLine = @import("control.zig").sourceLine;
const indexOfName = @import("runtime.zig").indexOfName;
const setFrameEnvironment = @import("runtime.zig").Runtime.setFrameEnvironment;
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

pub fn executeCall(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
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
    setFrameEnvironment(frame, function.globals orelse frame.environment);
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

pub fn executeExceptionConstructor(self: *Runtime, destination: u16, kind: PythonExceptionKind, positional: []const Value, keywords: []const binder.Keyword, line: u32, column: u32) bool {
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

pub fn appendCallKeyword(self: *Runtime, keywords: []binder.Keyword, count: *usize, name: []const u8, value: Value, line: u32, column: u32) bool {
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

pub fn executeMaterializeStar(self: *Runtime, register: u16, line: u32, column: u32) bool {
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

pub fn extendListFromIterable(self: *Runtime, destination: u16, list: *sequence.List, source: Value, line: u32, column: u32) bool {
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

pub fn invokeCallableSync(self: *Runtime, callable: Value, args: []const Value, destination: u16, line: u32, column: u32) ?Value {
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

pub fn invokeSpecialSync(self: *Runtime, receiver: Value, name: []const u8, arguments: []const Value, line: u32, column: u32) ?Value {
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

pub fn invokeValueSync(self: *Runtime, callable: Value, arguments: []const Value, line: u32, column: u32) ?Value {
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

pub fn restoreFrameRegister(self: *Runtime, frame: *Frame, index: u16, value: Value) void {
    const position: usize = index;
    if (position >= frame.registers.len or position >= frame.roots.len) {
        _ = self.engineFault();
        return;
    }
    frame.registers[position] = value;
    frame.roots[position].object = value.asObject();
    if (self.top_frame == frame) self.activateFrame(frame);
}

pub fn invokePythonSync(self: *Runtime, callable: Value, args: []const Value, destination: u16, line: u32, column: u32) ?Value {
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
    setFrameEnvironment(frame, function.globals orelse frame.environment);
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

pub fn executeMakeFunction(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
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
    switch (functions.createPython(&self.heap, nested_code, self.currentEnvironment(), captured, defaults, annotations, Value.object(&annotation_dict.header))) {
        .value => |function| self.setRegister(instruction.a(), Value.object(&function.header)),
        .python_exception => |exception| {
            self.setException(exception, line, column, null);
            return false;
        },
    }
    return true;
}

pub fn executeMakeClass(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
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

pub fn setBinderException(self: *Runtime, err: anyerror, line: u32, column: u32) void {
    const message: []const u8 = if (err == error.TooManyPositional) "too many positional arguments" else if (err == error.MissingArgument) "missing required argument" else if (err == error.MultipleValues) "multiple values for an argument" else if (err == error.PositionalOnlyAsKeyword) "positional-only argument passed as a keyword" else if (err == error.UnexpectedKeyword) "unexpected keyword argument" else if (err == error.OutOfMemory) "session memory limit exceeded" else "invalid call arguments";
    const kind: PythonExceptionKind = if (err == error.OutOfMemory) .memory_error else .type_error;
    self.setException(.{ .kind = kind, .message = message }, line, column, null);
}

pub fn storeFrameLocal(self: *Runtime, frame: *Frame, name: []const u8, value: Value) bool {
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

pub fn findCell(self: *Runtime, name: []const u8) ?*functions.Cell {
    var frame = self.top_frame;
    while (frame) |active| : (frame = active.previous) {
        if (indexOfName(active.code.cell_names, name)) |index| return active.local_cells[index];
        if (indexOfName(active.code.free_names, name)) |index| return active.free_cells[index];
    }
    return null;
}

pub fn loadLocal(self: *Runtime, destination: u16, name: []const u8, binding: u8, line: u32, column: u32) bool {
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

pub fn storeLocal(self: *Runtime, source: u16, name: []const u8, binding: u8, line: u32, column: u32) bool {
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

pub fn isCallable(self: *const Runtime, value: Value) bool {
    _ = self;
    const header = value.asObject() orelse return false;
    if (class_module.classFromHeader(header) != null or class_module.boundMethodFromHeader(header) != null) return true;
    if (class_module.instanceFromHeader(header)) |instance| return class_module.classAttribute(instance.class, "__call__") != null;
    const function = functions.functionFromHeader(header) orelse return false;
    return function.native != null or function.code != null;
}
pub fn executeMaterializeDstar(self: *Runtime, register: u16, site_index: u32, line: u32, column: u32) bool {
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

pub fn mappingHasStringKey(self: *Runtime, mapping: *dict_module.Dict, name: []const u8) bool {
    _ = self;
    for (mapping.entries.items) |entry| {
        if (!entry.alive) continue;
        const header = entry.key.asObject() orelse continue;
        const text = string.fromHeader(header) orelse continue;
        if (std.mem.eql(u8, string.content(text), name)) return true;
    }
    return false;
}

pub fn duplicateCallKeyword(self: *Runtime, line: u32, column: u32) bool {
    self.setException(.{ .kind = .type_error, .message = "got multiple values for keyword argument" }, line, column, null);
    return false;
}

pub fn executeDeleteLocal(self: *Runtime, name: []const u8, binding: u8, line: u32, column: u32) bool {
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

pub fn frameNameValue(frame: *Frame, name: []const u8) ?Value {
    if (indexOfName(frame.code.local_names, name)) |index| return frame.locals[index];
    if (indexOfName(frame.code.cell_names, name)) |index| return if (frame.local_cells[index]) |cell| cell.value else null;
    if (indexOfName(frame.code.free_names, name)) |index| return if (frame.free_cells[index]) |cell| cell.value else null;
    return null;
}
