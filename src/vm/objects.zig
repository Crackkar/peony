const std = @import("std");
const builtin = @import("builtin");
const bytecode = @import("frontend_bytecode");
const gc = @import("runtime_gc");
const value_module = @import("runtime_value");
const number = @import("runtime_number");
const string = @import("runtime_string");
const byte_module = @import("runtime_bytes");
const sequence = @import("runtime_sequence");
const dict_module = @import("runtime_dict");
const slice = @import("runtime_slice");
const exceptions = @import("runtime_exception");
const iterator = @import("runtime_iterator");
const functions = @import("runtime_function");
const file_module = @import("runtime_file");
const class_module = @import("runtime_class");
const module_module = @import("runtime_module");
const native_types = @import("../stdlib/types.zig");
const native_library = @import("../stdlib/native.zig");

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
const environmentLookup = @import("runtime.zig").Runtime.environmentLookup;
const Code = bytecode.Code;
const PythonException = exceptions.PythonException;
const PythonExceptionKind = exceptions.PythonExceptionKind;
const sourceLine = @import("control.zig").sourceLine;
const indexOfName = @import("runtime.zig").indexOfName;
const frameNameValue = @import("calls.zig").frameNameValue;
const compareOrder = @import("operations.zig").compareOrder;
const compareNumericOrder = @import("operations.zig").compareNumericOrder;
const isAlign = @import("text.zig").isAlign;
const builtinNative = @import("builtins.zig").builtinNative;
const exceptionName = @import("control.zig").exceptionName;
const appendExceptionText = @import("control.zig").appendExceptionText;
const dictKeysEqual = @import("operations.zig").dictKeysEqual;
const DictEqualityContext = @import("operations.zig").DictEqualityContext;
const truncateUtf8 = @import("text.zig").truncateUtf8;
const trimInputEnding = @import("runtime.zig").trimInputEnding;
const trimFloatZeros = @import("text.zig").trimFloatZeros;
const roundDecimalTieEven = @import("text.zig").roundDecimalTieEven;

pub fn executeMakeSequence(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
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

pub fn executeMakeMapping(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
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

pub fn executeMappingSet(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
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

pub fn executeMappingUpdate(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
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

pub fn executeMakeSlice(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
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

pub fn lookupAttributeValue(self: *Runtime, receiver: Value, name: []const u8, line: u32, column: u32) ?Value {
    const header = receiver.asObject() orelse return null;
    if (native_types.fromHeader(header)) |object| return native_library.getAttribute(Runtime, self, object, name, line, column);
    if (module_module.fromHeader(header)) |selected| {
        if (std.mem.eql(u8, name, "__name__")) return self.createStringValue(selected.name, line, column);
        if (std.mem.eql(u8, name, "__package__")) return self.createStringValue(selected.package, line, column);
        if (std.mem.eql(u8, name, "__file__")) return self.createStringValue(selected.filename, line, column);
        return environmentLookup(selected.environment, name);
    }
    if (functions.functionFromHeader(header)) |function| {
        if (std.mem.eql(u8, name, "__annotations__")) return function.annotations_dict;
    }
    if (exceptions.instanceFromHeader(header)) |instance| {
        if (exceptions.getAttribute(instance, name)) |attribute| return attribute;
        if (instance.kind == .stop_iteration and std.mem.eql(u8, name, "value")) return instance.value;
        if (instance.kind == .system_exit and std.mem.eql(u8, name, "code")) return instance.value;
    }
    if (exceptions.classFromHeader(header)) |class| {
        if (std.mem.eql(u8, name, "__name__")) return self.createStringValue(exceptions.className(class), line, column);
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

pub fn setUserAttribute(self: *Runtime, receiver: Value, name: []const u8, value: Value, line: u32, column: u32) bool {
    const header = receiver.asObject() orelse return self.nativeAttributeError(line, column, "attribute assignment requires an object");
    if (native_types.fromHeader(header)) |object| return native_library.setAttribute(Runtime, self, object, name, value, line, column);
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

pub fn deleteUserAttribute(self: *Runtime, receiver: Value, name: []const u8, line: u32, column: u32) bool {
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

pub fn executeGetAttribute(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
    if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b())) return self.engineFault();
    const name = self.codeName(instruction.c()) orelse return self.engineFault();
    const receiver = self.registers[instruction.b()];
    if (receiver.asObject()) |header| if (native_types.fromHeader(header)) |object| {
        const value = native_library.getAttribute(Runtime, self, object, name, line, column) orelse {
            if (self.last_exception != null) return false;
            return self.nativeAttributeError(line, column, "object has no such attribute");
        };
        self.setRegister(instruction.a(), value);
        return true;
    };
    if (receiver.asObject()) |header| if (module_module.fromHeader(header)) |selected| {
        if (std.mem.eql(u8, name, "__name__")) return self.storeStringResult(instruction.a(), string.create(&self.heap, selected.name), line, column);
        if (std.mem.eql(u8, name, "__package__")) return self.storeStringResult(instruction.a(), string.create(&self.heap, selected.package), line, column);
        if (std.mem.eql(u8, name, "__file__")) return self.storeStringResult(instruction.a(), string.create(&self.heap, selected.filename), line, column);
        if (environmentLookup(selected.environment, name)) |value| {
            self.setRegister(instruction.a(), value);
            return true;
        }
        self.setException(.{ .kind = .attribute_error, .message = "module has no such attribute" }, line, column, name);
        return false;
    };
    if (receiver.asObject()) |header| if (functions.functionFromHeader(header)) |function| {
        if (std.mem.eql(u8, name, "__annotations__")) {
            self.setRegister(instruction.a(), function.annotations_dict);
            return true;
        }
    };
    if (receiver.asObject()) |header| if (exceptions.instanceFromHeader(header)) |instance| {
        if (exceptions.getAttribute(instance, name)) |attribute| {
            self.setRegister(instruction.a(), attribute);
            return true;
        }
        if (instance.kind == .stop_iteration and std.mem.eql(u8, name, "value")) {
            self.setRegister(instruction.a(), instance.value);
            return true;
        }
        if (instance.kind == .system_exit and std.mem.eql(u8, name, "code")) {
            self.setRegister(instruction.a(), instance.value);
            return true;
        }
    };
    if (receiver.asObject()) |header| if (exceptions.classFromHeader(header)) |class| {
        if (std.mem.eql(u8, name, "__name__")) return self.storeStringResult(instruction.a(), string.create(&self.heap, exceptions.className(class)), line, column);
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

pub fn createBoundMethodResult(self: *Runtime, destination: u16, callable: Value, receiver: Value, line: u32, column: u32) bool {
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

pub fn executeSetAttribute(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
    if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b())) return self.engineFault();
    const name = self.codeName(instruction.c()) orelse return self.engineFault();
    const receiver = self.registers[instruction.a()];
    const value = self.registers[instruction.b()];
    const header = receiver.asObject() orelse return self.nativeAttributeError(line, column, "attribute assignment requires an object");
    if (native_types.fromHeader(header)) |object| return native_library.setAttribute(Runtime, self, object, name, value, line, column);
    if (module_module.fromHeader(header)) |selected| {
        if (!self.environmentStore(selected.environment, name, value)) {
            self.setException(exceptions.memoryError(), line, column, null);
            return false;
        }
        return true;
    }
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

pub fn executeDeleteAttribute(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
    if (!self.validRegister(instruction.a())) return self.engineFault();
    const name = self.codeName(instruction.c()) orelse return self.engineFault();
    const receiver = self.registers[instruction.a()];
    const header = receiver.asObject() orelse return self.nativeAttributeError(line, column, "attribute deletion requires an object");
    if (module_module.fromHeader(header)) |selected| {
        const environment: *Environment = @ptrCast(@alignCast(selected.environment));
        for (environment.entries.items, 0..) |entry, index| {
            if (!std.mem.eql(u8, entry.name, name)) continue;
            self.heap.allocator.free(entry.name);
            _ = environment.entries.orderedRemove(index);
            environment.shape_version +%= 1;
            return true;
        }
        return self.nativeAttributeError(line, column, "module has no such attribute");
    }
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

pub fn executeGetItem(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
    if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b()) or !self.validRegister(instruction.c())) return self.engineFault();
    const container = self.registers[instruction.b()];
    const index_value = self.registers[instruction.c()];
    const header = container.asObject() orelse {
        self.setException(.{ .kind = .type_error, .message = "object is not subscriptable" }, line, column, null);
        return false;
    };
    if (native_types.fromHeader(header)) |native_object| {
        const ops = native_object.ops orelse return self.nativeTypeError(line, column, "object is not subscriptable");
        const get_item = ops.get_item orelse return self.nativeTypeError(line, column, "object is not subscriptable");
        const previous_task = self.currentNativeTask();
        if (get_item(self, native_object, index_value, instruction.a(), line, column)) |value| {
            self.setRegister(instruction.a(), value);
            return true;
        }
        return self.currentNativeTask() != previous_task and self.last_exception == null;
    }
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

pub fn executeIndexedSequence(self: *Runtime, destination: u16, container: Value, length_value: usize, index_value: Value, line: u32, column: u32) bool {
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

pub fn storeStringIndex(self: *Runtime, destination: u16, text: *string.Str, index: usize, line: u32, column: u32) bool {
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

pub fn executeSliceItem(self: *Runtime, destination: u16, container: Value, slice_value: Value, line: u32, column: u32) bool {
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

pub fn sliceSequence(self: *Runtime, destination: u16, container: Value, values: []const Value, slice_object: *slice.Slice, is_tuple: bool, line: u32, column: u32) bool {
    const normalized = slice.normalize(values.len, slice_object.start, slice_object.stop, slice_object.step);
    const indices = switch (normalized) {
        .value => |result| result,
        .python_exception => |exception| {
            self.setException(exception, line, column, null);
            return false;
        },
        .engine_error => return self.engineFault(),
    };
    const output = self.heap.allocator.alloc(Value, slice.outputLength(indices)) catch {
        self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
        return false;
    };
    var index_value = indices.start;
    var output_index: usize = 0;
    while (if (indices.step > 0) index_value < indices.stop else index_value > indices.stop) {
        output[output_index] = values[@intCast(index_value)];
        output_index += 1;
        index_value = std.math.add(i128, index_value, indices.step) catch break;
    }
    _ = container;
    if (is_tuple) return switch (sequence.createTupleOwned(&self.heap, output)) {
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
    return switch (sequence.createListOwned(&self.heap, output)) {
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

pub fn storeStringResult(self: *Runtime, destination: u16, result: string.StringResult, line: u32, column: u32) bool {
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

pub fn stringValueResult(self: *Runtime, result: string.StringResult, line: u32, column: u32) ?Value {
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

pub fn storeBytesResult(self: *Runtime, destination: u16, result: byte_module.BytesResult, line: u32, column: u32) bool {
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

pub fn executeSetItem(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
    if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b()) or !self.validRegister(instruction.c())) return self.engineFault();
    const container = self.registers[instruction.b()].asObject() orelse {
        self.setException(.{ .kind = .type_error, .message = "object does not support item assignment" }, line, column, null);
        return false;
    };
    if (native_types.fromHeader(container)) |native_object| {
        const ops = native_object.ops orelse return self.nativeTypeError(line, column, "object does not support item assignment");
        const set_item = ops.set_item orelse return self.nativeTypeError(line, column, "object does not support item assignment");
        return set_item(self, native_object, self.registers[instruction.c()], self.registers[instruction.a()], line, column);
    }
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

pub fn executeDeleteItem(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
    if (!self.validRegister(instruction.b()) or !self.validRegister(instruction.c())) return self.engineFault();
    const container = self.registers[instruction.b()].asObject() orelse {
        self.setException(.{ .kind = .type_error, .message = "object does not support item deletion" }, line, column, null);
        return false;
    };
    if (native_types.fromHeader(container)) |native_object| {
        const ops = native_object.ops orelse return self.nativeTypeError(line, column, "object does not support item deletion");
        const delete_item = ops.delete_item orelse return self.nativeTypeError(line, column, "object does not support item deletion");
        return delete_item(self, native_object, self.registers[instruction.c()], line, column);
    }
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

pub fn executeUnpack(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
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
    // Unknown iterators grow session-accounted storage up to the documented
    // 65,536-item bound.
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

pub fn setMappingValue(self: *Runtime, mapping: *dict_module.Dict, key: Value, value: Value, line: u32, column: u32) bool {
    const key_hash = self.pythonHash(key, line, column) orelse return false;
    return self.setMappingValueWithHash(mapping, key, value, key_hash, line, column);
}

pub fn mroContains(class: *class_module.Class, target: *class_module.Class) bool {
    for (class.mro) |base| if (base == target) return true;
    return false;
}
pub fn attributeNative(receiver: Value, name: []const u8) ?functions.Native {
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
        if (std.mem.eql(u8, name, "rfind")) return .str_rfind;
        if (std.mem.eql(u8, name, "index")) return .str_index;
        if (std.mem.eql(u8, name, "rindex")) return .str_rindex;
        if (std.mem.eql(u8, name, "split")) return .str_split;
        if (std.mem.eql(u8, name, "rsplit")) return .str_rsplit;
        if (std.mem.eql(u8, name, "splitlines")) return .str_splitlines;
        if (std.mem.eql(u8, name, "join")) return .str_join;
        if (std.mem.eql(u8, name, "strip")) return .str_strip;
        if (std.mem.eql(u8, name, "lstrip")) return .str_lstrip;
        if (std.mem.eql(u8, name, "rstrip")) return .str_rstrip;
        if (std.mem.eql(u8, name, "upper")) return .str_upper;
        if (std.mem.eql(u8, name, "lower")) return .str_lower;
        if (std.mem.eql(u8, name, "title")) return .str_title;
        if (std.mem.eql(u8, name, "capitalize")) return .str_capitalize;
        if (std.mem.eql(u8, name, "isdigit")) return .str_isdigit;
        if (std.mem.eql(u8, name, "isdecimal")) return .str_isdecimal;
        if (std.mem.eql(u8, name, "isalpha")) return .str_isalpha;
        if (std.mem.eql(u8, name, "isalnum")) return .str_isalnum;
        if (std.mem.eql(u8, name, "isspace")) return .str_isspace;
        if (std.mem.eql(u8, name, "replace")) return .str_replace;
        if (std.mem.eql(u8, name, "removeprefix")) return .str_removeprefix;
        if (std.mem.eql(u8, name, "removesuffix")) return .str_removesuffix;
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
