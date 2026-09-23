const std = @import("std");

pub const Spec = struct {
    fill: u8 = ' ',
    alignment: u8 = 0,
    sign: u8 = '-',
    sign_specified: bool = false,
    alternate: bool = false,
    width: usize = 0,
    comma: bool = false,
    precision: ?usize = null,
    kind: u8 = 0,
};

pub const ParseError = error{ Invalid, MissingPrecisionDigits, Overflow };

/// Parse the shared alignment, width, grouping, precision and type portions
/// used by f-strings, `str.format`, `format()` and percent formatting.
pub fn parse(spec: []const u8) ParseError!Spec {
    var result: Spec = .{};
    var index: usize = 0;
    if (spec.len >= 2 and isAlignment(spec[1])) {
        result.fill = spec[0];
        result.alignment = spec[1];
        index = 2;
    } else if (spec.len != 0 and isAlignment(spec[0])) {
        result.alignment = spec[0];
        index = 1;
    }
    if (index < spec.len and (spec[index] == '+' or spec[index] == '-' or spec[index] == ' ')) {
        result.sign = spec[index];
        result.sign_specified = true;
        index += 1;
    }
    if (index < spec.len and spec[index] == '#') {
        result.alternate = true;
        index += 1;
    }
    if (index < spec.len and spec[index] == '0' and result.alignment == 0) {
        result.fill = '0';
        result.alignment = '=';
        index += 1;
    }
    while (index < spec.len and std.ascii.isDigit(spec[index])) : (index += 1) {
        result.width = std.math.add(
            usize,
            std.math.mul(usize, result.width, 10) catch return error.Overflow,
            spec[index] - '0',
        ) catch return error.Overflow;
    }
    if (index < spec.len and spec[index] == ',') {
        result.comma = true;
        index += 1;
    }
    if (index < spec.len and spec[index] == '.') {
        index += 1;
        var precision: usize = 0;
        const precision_start = index;
        while (index < spec.len and std.ascii.isDigit(spec[index])) : (index += 1) {
            precision = std.math.add(
                usize,
                std.math.mul(usize, precision, 10) catch return error.Overflow,
                spec[index] - '0',
            ) catch return error.Overflow;
        }
        if (index == precision_start) return error.MissingPrecisionDigits;
        result.precision = precision;
    }
    if (index < spec.len) {
        result.kind = spec[index];
        index += 1;
    }
    if (index != spec.len) return error.Invalid;
    return result;
}

fn isAlignment(character: u8) bool {
    return character == '<' or character == '>' or character == '^' or character == '=';
}
