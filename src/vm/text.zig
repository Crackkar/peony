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
const exceptions = @import("runtime_exception");
const iterator = @import("runtime_iterator");
const binder = @import("runtime_binder");
const format_rules = @import("runtime_format_rules");
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
const builtinNative = @import("builtins.zig").builtinNative;
const attributeNative = @import("objects.zig").attributeNative;
const exceptionName = @import("control.zig").exceptionName;
const appendExceptionText = @import("control.zig").appendExceptionText;
const dictKeysEqual = @import("operations.zig").dictKeysEqual;
const DictEqualityContext = @import("operations.zig").DictEqualityContext;
const mroContains = @import("objects.zig").mroContains;
const trimInputEnding = @import("runtime.zig").trimInputEnding;

pub fn executeFormatValue(self: *Runtime, destination: u16, value: Value, spec: []const u8, conversion: u8, line: u32, column: u32) bool {
    const rendered = self.makeFormattedText(value, spec, conversion, line, column) orelse return false;
    defer self.heap.allocator.free(rendered);
    return self.storeStringResult(destination, string.create(&self.heap, rendered), line, column);
}

pub fn executeStrFormat(self: *Runtime, destination: u16, template: *string.Str, positional: []const Value, keywords: []const binder.Keyword, line: u32, column: u32) bool {
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

pub fn makeFormattedText(self: *Runtime, value: Value, spec: []const u8, conversion: u8, line: u32, column: u32) ?[]u8 {
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

pub fn renderValueOwned(self: *Runtime, value: Value, nested: bool, line: u32, column: u32) ?[]u8 {
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

pub fn asciiEscape(self: *Runtime, input: []const u8) ?[]u8 {
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

pub fn applyFormatSpec(self: *Runtime, value: Value, text: []const u8, spec: []const u8, line: u32, column: u32, force_string: bool) ?[]u8 {
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

pub fn padSignedNumeric(self: *Runtime, text: []const u8, spec: format_rules.Spec, line: u32, column: u32) ?[]u8 {
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

pub fn padFormatted(self: *Runtime, text: []const u8, width: usize, fill: u8, requested_align: u8, head_len: usize, line: u32, column: u32) ?[]u8 {
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

pub fn formatFloat(self: *Runtime, value: f64, precision: usize, kind: u8, alternate: bool, line: u32, column: u32) ?[]u8 {
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

pub fn formatGeneralFloat(self: *Runtime, value: f64, precision: usize, alternate: bool, upper: bool, line: u32, column: u32) ?[]u8 {
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

pub fn normalizedScientific(self: *Runtime, mantissa: []const u8, exponent: i32, upper: bool, line: u32, column: u32) ?[]u8 {
    const marker: u8 = if (upper) 'E' else 'e';
    const sign: u8 = if (exponent < 0) '-' else '+';
    const magnitude: u32 = @intCast(@abs(exponent));
    const result = std.fmt.allocPrint(self.heap.allocator, "{s}{c}{c}{d:0>2}", .{ mantissa, marker, sign, magnitude }) catch return self.formatMemoryFailure(line, column);
    return result;
}

pub fn scientificMantissaToFixed(self: *Runtime, mantissa: []const u8, exponent: i32, line: u32, column: u32) ?[]u8 {
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

pub fn groupThousands(self: *Runtime, input: []const u8) ?[]u8 {
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

pub fn remainingSessionBytes(self: *const Runtime) usize {
    return self.session_allocator.max_bytes -| self.session_allocator.live_bytes;
}

pub fn formatMemoryFailure(self: *Runtime, line: u32, column: u32) ?[]u8 {
    self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
    return null;
}

pub fn formatValueError(self: *Runtime, line: u32, column: u32, message: []const u8) ?[]u8 {
    self.setException(.{ .kind = .value_error, .message = message }, line, column, null);
    return null;
}

pub fn formatTypeError(self: *Runtime, line: u32, column: u32, message: []const u8) ?[]u8 {
    self.setException(.{ .kind = .type_error, .message = message }, line, column, null);
    return null;
}

pub fn executePercentFormat(self: *Runtime, destination: u16, template: *string.Str, arguments_value: Value, line: u32, column: u32) bool {
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

pub fn executePrint(self: *Runtime, registers: []const u16, line: u32, column: u32) bool {
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

pub fn executePrintValues(self: *Runtime, values: []const Value, separator: []const u8, ending: []const u8, line: u32, column: u32) bool {
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

pub fn appendValue(self: *Runtime, value: Value, line: u32, column: u32) bool {
    return self.appendValueMode(value, false, line, column);
}

pub fn appendValueMode(self: *Runtime, value: Value, nested: bool, line: u32, column: u32) bool {
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

pub fn appendSequence(self: *Runtime, header: *gc.Header, values: []const Value, is_tuple: bool, line: u32, column: u32) bool {
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

pub fn appendMapping(self: *Runtime, header: *gc.Header, mapping: *dict_module.Dict, line: u32, column: u32) bool {
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

pub fn appendMappingView(self: *Runtime, header: *gc.Header, view: *dict_module.View, line: u32, column: u32) bool {
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

pub fn appendQuoted(self: *Runtime, content: []const u8, is_bytes: bool) bool {
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

pub fn appendRange(self: *Runtime, range: *const iterator.Range, line: u32, column: u32) bool {
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

pub fn appendInteger(self: *Runtime, value: Value, line: u32, column: u32) bool {
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

pub fn appendFormatted(self: *Runtime, comptime format: []const u8, arguments: anytype) bool {
    const text = std.fmt.allocPrint(self.heap.allocator, format, arguments) catch return false;
    defer self.heap.allocator.free(text);
    return self.appendOutput(text);
}

pub fn appendOutput(self: *Runtime, output: []const u8) bool {
    self.stdout_bytes.appendSlice(self.heap.allocator, output) catch return false;
    return true;
}

pub fn truncateUtf8(input: []const u8, codepoints: usize) []const u8 {
    var byte_index: usize = 0;
    var seen: usize = 0;
    while (byte_index < input.len and seen < codepoints) : (seen += 1) {
        const width = std.unicode.utf8ByteSequenceLength(input[byte_index]) catch 1;
        byte_index = @min(input.len, byte_index + width);
    }
    return input[0..byte_index];
}
pub fn trimFloatZeros(input: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, input, '.') orelse return input;
    var end = input.len;
    while (end > dot + 1 and input[end - 1] == '0') end -= 1;
    if (end == dot + 1) end = dot;
    return input[0..end];
}
pub fn roundDecimalTieEven(value: f64, precision: usize) f64 {
    if (!std.math.isFinite(value) or precision > 15) return value;
    const scale = std.math.pow(f64, 10, @floatFromInt(precision));
    const magnitude = @abs(value) * scale;
    if (!std.math.isFinite(magnitude)) return value;
    const whole = @floor(magnitude);
    if (magnitude - whole != 0.5 or @rem(whole, 2.0) != 0) return value;
    const bits: u64 = @bitCast(value);
    return @bitCast(if (value < 0) bits + 1 else bits - 1);
}
fn isAlign(character: u8) bool {
    return character == '<' or character == '>' or character == '^';
}
