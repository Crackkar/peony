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
const hash_module = @import("runtime_hash");
const slice = @import("runtime_slice");
const exceptions = @import("runtime_exception");
const iterator = @import("runtime_iterator");
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
const Value = value_module.Value;
const Code = bytecode.Code;
const PythonException = exceptions.PythonException;
const PythonExceptionKind = exceptions.PythonExceptionKind;
const sourceLine = @import("control.zig").sourceLine;
const indexOfName = @import("runtime.zig").indexOfName;
const frameNameValue = @import("calls.zig").frameNameValue;
const isAlign = @import("text.zig").isAlign;
const builtinNative = @import("builtins.zig").builtinNative;
const attributeNative = @import("objects.zig").attributeNative;
const exceptionName = @import("control.zig").exceptionName;
const appendExceptionText = @import("control.zig").appendExceptionText;
const mroContains = @import("objects.zig").mroContains;
const truncateUtf8 = @import("text.zig").truncateUtf8;
const trimInputEnding = @import("runtime.zig").trimInputEnding;
const trimFloatZeros = @import("text.zig").trimFloatZeros;
const roundDecimalTieEven = @import("text.zig").roundDecimalTieEven;

pub fn executeBinary(self: *Runtime, destination: u16, left: Value, right: Value, operation: u8, line: u32, column: u32) bool {
    if (left.asObject()) |header| if (native_types.fromHeader(header)) |object| if (object.ops) |ops| if (ops.binary) |binary| {
        if (binary(self, object, right, operation, false, line, column)) |result| {
            self.setRegister(destination, result);
            return true;
        }
        if (self.last_exception != null) return false;
    };
    if (right.asObject()) |header| if (native_types.fromHeader(header)) |object| if (object.ops) |ops| if (ops.binary) |binary| {
        if (binary(self, object, left, operation, true, line, column)) |result| {
            self.setRegister(destination, result);
            return true;
        }
        if (self.last_exception != null) return false;
    };
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
        if (number.isIntegerValue(left) or number.isIntegerValue(right)) {
            const multiplier = if (number.isIntegerValue(right)) right else left;
            const source = if (number.isIntegerValue(right)) left else right;
            if (source.asObject()) |header| {
                const text = string.fromHeader(header);
                const data = byte_module.fromHeader(header);
                if (text != null or data != null) {
                    const signed = number.toInt(i64, multiplier) orelse {
                        self.setException(exceptions.memoryError(), line, column, null);
                        return false;
                    };
                    const count: usize = if (signed <= 0) 0 else std.math.cast(usize, signed) orelse {
                        self.setException(exceptions.memoryError(), line, column, null);
                        return false;
                    };
                    const length = if (text) |selected| selected.data.len else data.?.data.len;
                    const total = std.math.mul(usize, length, count) catch {
                        self.setException(exceptions.memoryError(), line, column, null);
                        return false;
                    };
                    if (!self.repeatResultFitsSessionHeap(total)) {
                        self.setException(exceptions.memoryError(), line, column, null);
                        return false;
                    }
                    if (!self.chargeBulkWork(@intCast(@max(total, 1)))) return false;
                    if (text) |selected| return self.storeStringResult(destination, string.repeat(&self.heap, selected, count), line, column);
                    return self.storeBytesResult(destination, byte_module.repeat(&self.heap, data.?, count), line, column);
                }
            }
        }
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

pub fn storeNumberResult(self: *Runtime, destination: u16, result: number.ValueResult, line: u32, column: u32) bool {
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

pub fn storeFloatResult(self: *Runtime, destination: u16, result: number.FloatResult, line: u32, column: u32) bool {
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

pub fn valueTruthy(self: *Runtime, value: Value, line: u32, column: u32) ?bool {
    if (value.tag() == .none) return false;
    if (value.asBool()) |boolean| return boolean;
    if (value.asSmallInt()) |integer| return integer != 0;
    if (value.asFloat()) |float_value| return float_value != 0;
    if (number.isIntegerValue(value)) return !number.isZeroValue(value);
    if (value.asObject()) |header| {
        if (native_types.fromHeader(header)) |object| if (object.ops) |ops| if (ops.truth) |truth| return truth(self, object, line, column);
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

pub fn normalizeSearchBound(self: *Runtime, value: Value, length: usize, line: u32, column: u32) ?usize {
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

pub fn compareValues(self: *Runtime, left: Value, right: Value, operation: u8, line: u32, column: u32) ?bool {
    if (operation == 6) return left.identical(right);
    if (operation == 7) return !left.identical(right);
    if (operation == 8 or operation == 9) {
        const contained = self.containsValue(left, right, line, column) orelse return null;
        return if (operation == 8) contained else !contained;
    }
    if (left.asObject()) |header| if (native_types.fromHeader(header)) |object| if (object.ops) |ops| if (ops.compare) |compare| return compare(self, object, right, operation, line, column);
    if (right.asObject()) |header| if (native_types.fromHeader(header)) |object| if (object.ops) |ops| if (ops.compare) |compare| {
        const reversed: u8 = switch (operation) { 2 => 4, 3 => 5, 4 => 2, 5 => 3, else => operation };
        return compare(self, object, left, reversed, line, column);
    };
    if (operation == 0 or operation == 1) {
        const left_native = if (left.asObject()) |header| native_types.fromHeader(header) else null;
        const right_native = if (right.asObject()) |header| native_types.fromHeader(header) else null;
        if (left_native != null or right_native != null) {
            const equal = self.valuesEqual(left, right, line, column) orelse return null;
            return if (operation == 0) equal else !equal;
        }
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

pub fn containsValue(self: *Runtime, item: Value, container: Value, line: u32, column: u32) ?bool {
    const header = container.asObject() orelse {
        self.setException(.{ .kind = .type_error, .message = "argument of type is not iterable" }, line, column, null);
        return null;
    };
    if (native_types.fromHeader(header)) |native_object| {
        if (native_object.ops) |ops| if (ops.contains) |contains| return contains(self, native_object, item, line, column);
    }
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

pub fn containsUserIterable(self: *Runtime, item: Value, container: Value, line: u32, column: u32) ?bool {
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

pub fn findListItem(self: *Runtime, list: *sequence.List, needle: Value, line: u32, column: u32) ?usize {
    for (list.items.items, 0..) |value, index| {
        const equal = self.valuesEqual(value, needle, line, column) orelse return null;
        if (equal) return index;
    }
    return null;
}

pub fn valuesEqual(self: *Runtime, left: Value, right: Value, line: u32, column: u32) ?bool {
    if (left.identical(right)) return true;
    if (left.asObject()) |header| if (native_types.fromHeader(header)) |object| if (object.ops) |ops| if (ops.equals) |equals| return equals(self, object, right, line, column);
    if (right.asObject()) |header| if (native_types.fromHeader(header)) |object| if (object.ops) |ops| if (ops.equals) |equals| return equals(self, object, left, line, column);
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

pub fn compareWithUserEquality(self: *Runtime, instance: Value, other: Value, line: u32, column: u32) ?bool {
    if (self.invokeSpecialSync(instance, "__eq__", &.{other}, line, column)) |result| {
        if (result.asExceptionClass() != null and result.asExceptionClass().? == std.math.maxInt(u8)) return false;
        return self.valueTruthy(result, line, column);
    }
    if (self.last_exception != null) return null;
    return false;
}

pub fn sortOrder(self: *Runtime, left: Value, right: Value, line: u32, column: u32) ?std.math.Order {
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

pub fn beginSynchronousWork(self: *Runtime) bool {
    if (self.synchronous_work_remaining != null) return false;
    self.synchronous_work_remaining = std.math.cast(usize, self.max_instructions -| self.work_executed) orelse std.math.maxInt(usize);
    return true;
}

pub fn endSynchronousWork(self: *Runtime, owns_budget: bool) void {
    if (owns_budget) self.synchronous_work_remaining = null;
}

pub fn chargeSynchronousWork(self: *Runtime, line: u32, column: u32) bool {
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

pub fn chargeBulkWork(self: *Runtime, amount: u64) bool {
    if (amount > self.max_instructions -| self.work_executed) {
        self.limit_reached = true;
        return false;
    }
    if (self.synchronous_work_remaining) |remaining| {
        if (amount > @as(u64, @intCast(remaining))) {
            self.limit_reached = true;
            return false;
        }
        self.synchronous_work_remaining = remaining - @as(usize, @intCast(amount));
    }
    self.work_executed += amount;
    return true;
}

pub fn repeatResultFitsSessionHeap(self: *Runtime, estimated_bytes: usize) bool {
    if (estimated_bytes > self.session_allocator.max_bytes -| self.session_allocator.live_bytes) _ = self.heap.collect();
    return estimated_bytes <= self.session_allocator.max_bytes -| self.session_allocator.live_bytes;
}

pub fn executeSequenceRepeat(self: *Runtime, destination: u16, sequence_value: Value, multiplier: Value, line: u32, column: u32) bool {
    if (sequence.repeatWorkCost(sequence_value, multiplier)) |cost| {
        // Reproduce MemoryError when the result buffers cannot fit the
        // session heap; only charge native work for viable allocations.
        if (sequence.repeatAllocationEstimate(sequence_value, cost)) |estimated_bytes| {
            if (self.repeatResultFitsSessionHeap(estimated_bytes) and !self.chargeBulkWork(cost)) return false;
        }
    }
    return self.storeValueResult(destination, sequence.repeat(&self.heap, sequence_value, multiplier), line, column);
}

pub fn chargeBytecode(self: *Runtime) bool {
    if (self.instructions_executed >= self.max_instructions or self.work_executed >= self.max_instructions) {
        self.limit_reached = true;
        return false;
    }
    self.instructions_executed += 1;
    self.work_executed +%= 1;
    return true;
}

pub fn chargeNestedInstruction(self: *Runtime) bool {
    if (self.instructions_executed >= self.max_instructions) {
        self.limit_reached = true;
        return false;
    }
    self.instructions_executed += 1;
    return true;
}

pub fn rightReflectedHasPriority(self: *Runtime, left: Value, right: Value, reflected_name: []const u8) bool {
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

pub fn pythonHash(self: *Runtime, value: Value, line: u32, column: u32) ?u64 {
    if (value.asObject()) |header| if (native_types.fromHeader(header)) |object| if (object.ops) |ops| {
        if (!ops.hashable) {
            self.setException(.{ .kind = .type_error, .message = "unhashable native object" }, line, column, null);
            return null;
        }
        if (ops.hash) |hash| return hash(self, object, line, column);
    };
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

pub fn setMappingValueWithHash(self: *Runtime, mapping: *dict_module.Dict, key: Value, value: Value, key_hash: u64, line: u32, column: u32) bool {
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

pub fn mappingContains(self: *Runtime, mapping: *dict_module.Dict, key: Value, line: u32, column: u32) ?bool {
    const key_hash = self.pythonHash(key, line, column) orelse return null;
    var context = DictEqualityContext{ .runtime = self, .line = line, .column = column };
    return switch (dict_module.lookup(mapping, key, key_hash, &context, dictKeysEqual)) {
        .found => true,
        .missing => false,
        .failed => null,
    };
}

pub fn storeSetOperation(self: *Runtime, destination: u16, left: *dict_module.Dict, right: *dict_module.Dict, operation: u8, line: u32, column: u32) bool {
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

pub fn valueString(_: *Runtime, value: Value) ?[]const u8 {
    const header = value.asObject() orelse return null;
    const text = string.fromHeader(header) orelse return null;
    return string.content(text);
}

pub fn dictKeysEqual(raw_context: *anyopaque, left: Value, right: Value) ?bool {
    const context: *DictEqualityContext = @ptrCast(@alignCast(raw_context));
    return context.runtime.valuesEqual(left, right, context.line, context.column);
}
pub fn compareOrder(order: std.math.Order, operation: u8) bool {
    return switch (operation) {
        2 => order == .lt,
        3 => order != .gt,
        4 => order == .gt,
        5 => order != .lt,
        else => false,
    };
}
pub fn compareNumericOrder(order: number.Comparison, operation: u8) bool {
    return switch (operation) {
        2 => order == .less,
        3 => order == .less or order == .equal,
        4 => order == .greater,
        5 => order == .greater or order == .equal,
        else => false,
    };
}

pub const DictEqualityContext = struct {
    runtime: *Runtime,
    line: u32,
    column: u32,
};
