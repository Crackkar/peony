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
const binder = @import("runtime_binder");
const file_module = @import("runtime_file");
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
const frameNameValue = @import("calls.zig").frameNameValue;
const compareOrder = @import("operations.zig").compareOrder;
const compareNumericOrder = @import("operations.zig").compareNumericOrder;
const isAlign = @import("text.zig").isAlign;
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

pub fn executeNativeCall(
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

pub fn executeOtherNativeCall(
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

pub fn executeGeneratorSend(
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

pub fn executeGeneratorClose(
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

pub fn executeOpen(self: *Runtime, destination: u16, positional: []const Value, keywords: []const binder.Keyword, line: u32, column: u32) bool {
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

pub fn executeFileNative(
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

pub fn fileInteger(self: *Runtime, value: Value, line: u32, column: u32) ?i64 {
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

pub fn executeMappingConstructor(self: *Runtime, destination: u16, is_set: bool, positional: []const Value, keywords: []const binder.Keyword, line: u32, column: u32) bool {
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

pub fn updateDictFromValue(self: *Runtime, mapping: *dict_module.Dict, source_value: Value, line: u32, column: u32) bool {
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

pub fn updateSetFromIterable(self: *Runtime, target: *dict_module.Dict, source: Value, line: u32, column: u32) bool {
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

pub fn executeMappingMethod(self: *Runtime, destination: u16, native: functions.Native, bound_self: Value, positional: []const Value, keywords: []const binder.Keyword, line: u32, column: u32) bool {
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

pub fn setMappingResult(self: *Runtime, mapping: *dict_module.Dict, key: Value, line: u32, column: u32) exceptions.Result(void) {
    const key_hash = self.pythonHash(key, line, column) orelse return .{ .python_exception = self.last_exception.? };
    var context = DictEqualityContext{ .runtime = self, .line = line, .column = column };
    return dict_module.set(&self.heap, mapping, key, Value.noneValue(), key_hash, &context, dictKeysEqual);
}

pub fn storeDictResult(self: *Runtime, destination: u16, result: exceptions.Result(*dict_module.Dict), line: u32, column: u32) bool {
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

pub fn executeStringNative(self: *Runtime, destination: u16, native: functions.Native, text: *string.Str, positional: []const Value, keywords: []const binder.Keyword, line: u32, column: u32) bool {
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

pub fn executeBytesNative(self: *Runtime, destination: u16, native: functions.Native, data: *byte_module.Bytes, positional: []const Value, keywords: []const binder.Keyword, line: u32, column: u32) bool {
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

pub fn nativeTypeError(self: *Runtime, line: u32, column: u32, message: []const u8) bool {
    self.setException(.{ .kind = .type_error, .message = message }, line, column, null);
    return false;
}

pub fn nativeAttributeError(self: *Runtime, line: u32, column: u32, message: []const u8) bool {
    self.setException(.{ .kind = .attribute_error, .message = message }, line, column, null);
    return false;
}

pub fn suppressAttributeError(self: *Runtime) void {
    const handled = if (self.active_exception) |suppressed| suppressed.context else null;
    self.last_exception = null;
    self.active_exception = handled;
    self.exception_root.object = if (handled) |instance| &instance.header else null;
    self.clearErrorText();
}

pub fn nativeArity(self: *Runtime, line: u32, column: u32) bool {
    return self.nativeTypeError(line, column, "incorrect number of arguments");
}

pub fn storeVoidResult(self: *Runtime, destination: u16, result: exceptions.Result(void), line: u32, column: u32) bool {
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

pub fn storeValueResult(self: *Runtime, destination: u16, result: exceptions.Result(Value), line: u32, column: u32) bool {
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

pub fn storeListResult(self: *Runtime, destination: u16, result: sequence.ListResult, line: u32, column: u32) bool {
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

pub fn storeTupleResult(self: *Runtime, destination: u16, result: sequence.TupleResult, line: u32, column: u32) bool {
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

pub fn setSmallInt(self: *Runtime, destination: u16, input: anytype, line: u32, column: u32) bool {
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

pub fn executeSliceBuiltin(self: *Runtime, destination: u16, positional: []const Value, keywords: []const binder.Keyword, line: u32, column: u32) bool {
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

pub fn valueBytes(_: *Runtime, value: Value) ?[]const u8 {
    const header = value.asObject() orelse return null;
    const data = byte_module.fromHeader(header) orelse return null;
    return data.data;
}

pub fn valueIsUtf8(self: *Runtime, value: Value) bool {
    const text = self.valueString(value) orelse return false;
    return std.mem.eql(u8, text, "utf-8") or std.mem.eql(u8, text, "utf8");
}

pub fn splitStringResult(self: *Runtime, destination: u16, text: *string.Str, separator: []const u8, line: u32, column: u32) bool {
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

pub fn splitStringWhitespaceResult(self: *Runtime, destination: u16, text: *string.Str, line: u32, column: u32) bool {
    return self.splitStringIteratorResult(destination, text, string.splitWhitespace(text), line, column);
}

pub fn splitStringIteratorResult(
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

pub fn splitBytesResult(self: *Runtime, destination: u16, data: *byte_module.Bytes, separator: []const u8, line: u32, column: u32) bool {
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

pub fn joinStringResult(self: *Runtime, destination: u16, separator: *string.Str, iterable: Value, line: u32, column: u32) bool {
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

pub fn builtinNative(name: []const u8) ?functions.Native {
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
