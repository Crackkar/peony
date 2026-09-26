const std = @import("std");
const value_module = @import("runtime_value");
const gc = @import("runtime_gc");
const sequence = @import("runtime_sequence");

const Value = value_module.Value;

pub const Keyword = struct {
    name: []const u8,
    value: Value,
};

pub const BindError = std.mem.Allocator.Error || error{
    TooManyPositional,
    MissingArgument,
    MultipleValues,
    UnexpectedKeyword,
    PositionalOnlyAsKeyword,
};

pub const BoundArguments = struct {
    values: []Value,
    extra_keywords: []Keyword,
};

pub const PrintArguments = struct {
    values: []const Value,
    separator: ?Value = null,
    ending: ?Value = null,
    file: ?Value = null,
    flush: ?Value = null,
};

pub fn bindFunction(
    heap: *gc.Heap,
    allocator: std.mem.Allocator,
    parameter_names: []const []const u8,
    parameter_flags: []const u32,
    defaults: []const Value,
    positional: []const Value,
    keywords: []const Keyword,
) BindError!BoundArguments {
    std.debug.assert(parameter_names.len == parameter_flags.len and parameter_names.len == defaults.len);
    const bound = try allocator.alloc(Value, parameter_names.len);
    @memset(bound, Value.unboundValue());
    errdefer allocator.free(bound);
    var created_root = gc.Root{ .object = null };
    var root_frame = gc.RootFrame{};
    root_frame.push(&heap.roots);
    root_frame.add(&created_root);
    defer root_frame.pop();
    var extra_keywords: std.ArrayList(Keyword) = .empty;
    defer extra_keywords.deinit(allocator);

    var positional_capacity: usize = 0;
    var var_positional_index: ?usize = null;
    var var_keyword_index: ?usize = null;
    for (parameter_flags, 0..) |flags, index| {
        if (flags & parameter_flags_module.keyword_only != 0) continue;
        if (flags & parameter_flags_module.var_positional != 0) {
            var_positional_index = index;
            continue;
        }
        if (flags & parameter_flags_module.var_keyword != 0) {
            var_keyword_index = index;
            continue;
        }
        positional_capacity += 1;
    }
    if (positional.len > positional_capacity and var_positional_index == null) return error.TooManyPositional;
    const fixed_positional_count = @min(positional.len, positional_capacity);
    for (positional[0..fixed_positional_count], 0..) |value, index| bound[positionalParameter(parameter_flags, index) orelse return error.TooManyPositional] = value;

    if (var_positional_index) |index| {
        const extra = positional[fixed_positional_count..];
        const tuple = switch (sequence.createTuple(heap, extra)) {
            .value => |value| value,
            .python_exception, .engine_error => return error.OutOfMemory,
        };
        bound[index] = Value.object(&tuple.header);
        created_root.object = &tuple.header;
    }

    for (keywords) |keyword| {
        var match: ?usize = null;
        for (parameter_names, 0..) |name, index| {
            if (parameter_flags[index] & (parameter_flags_module.var_positional | parameter_flags_module.var_keyword) != 0) continue;
            if (std.mem.eql(u8, name, keyword.name)) {
                match = index;
                break;
            }
        }
        const index = match orelse {
            if (var_keyword_index == null) return error.UnexpectedKeyword;
            for (extra_keywords.items) |previous| if (std.mem.eql(u8, previous.name, keyword.name)) return error.MultipleValues;
            try extra_keywords.append(allocator, keyword);
            continue;
        };
        if (parameter_flags[index] & parameter_flags_module.positional_only != 0) {
            if (var_keyword_index == null) return error.PositionalOnlyAsKeyword;
            for (extra_keywords.items) |previous| if (std.mem.eql(u8, previous.name, keyword.name)) return error.MultipleValues;
            try extra_keywords.append(allocator, keyword);
            continue;
        }
        if (bound[index].tag() != .unbound) return error.MultipleValues;
        bound[index] = keyword.value;
    }

    for (bound, 0..) |*value, index| {
        if (value.tag() != .unbound) continue;
        if (var_keyword_index != null and index == var_keyword_index.?) continue;
        if (defaults[index].tag() != .unbound) {
            value.* = defaults[index];
        } else return error.MissingArgument;
    }
    return .{ .values = bound, .extra_keywords = try extra_keywords.toOwnedSlice(allocator) };
}

pub fn bindRange(positional: []const Value, keywords: []const Keyword) error{TooManyPositional, MissingArgument, UnexpectedKeyword}! [3]Value {
    if (keywords.len != 0) return error.UnexpectedKeyword;
    if (positional.len > 3) return error.TooManyPositional;
    if (positional.len == 0) return error.MissingArgument;
    const zero = Value.fromSmallInt(0).?;
    const one = Value.fromSmallInt(1).?;
    return switch (positional.len) {
        1 => .{ zero, positional[0], one },
        2 => .{ positional[0], positional[1], one },
        3 => .{ positional[0], positional[1], positional[2] },
        else => unreachable,
    };
}

pub fn bindPrint(positional: []const Value, keywords: []const Keyword) error{UnexpectedKeyword, MultipleValues}!PrintArguments {
    var result = PrintArguments{ .values = positional };
    var saw_separator = false;
    var saw_ending = false;
    var saw_file = false;
    var saw_flush = false;
    for (keywords) |keyword| {
        if (std.mem.eql(u8, keyword.name, "sep")) {
            if (saw_separator) return error.MultipleValues;
            saw_separator = true;
            result.separator = keyword.value;
        } else if (std.mem.eql(u8, keyword.name, "end")) {
            if (saw_ending) return error.MultipleValues;
            saw_ending = true;
            result.ending = keyword.value;
        } else if (std.mem.eql(u8, keyword.name, "file")) {
            if (saw_file) return error.MultipleValues;
            saw_file = true;
            result.file = keyword.value;
        } else if (std.mem.eql(u8, keyword.name, "flush")) {
            if (saw_flush) return error.MultipleValues;
            saw_flush = true;
            result.flush = keyword.value;
        } else return error.UnexpectedKeyword;
    }
    return result;
}

pub const parameter_flags_module = struct {
    pub const positional_only: u32 = 1 << 0;
    pub const keyword_only: u32 = 1 << 1;
    pub const var_positional: u32 = 1 << 2;
    pub const var_keyword: u32 = 1 << 3;
};

fn positionalParameter(flags: []const u32, ordinal: usize) ?usize {
    var seen: usize = 0;
    for (flags, 0..) |parameter_flags, index| {
        if (parameter_flags & parameter_flags_module.keyword_only != 0) continue;
        if (parameter_flags & (parameter_flags_module.var_positional | parameter_flags_module.var_keyword) != 0) continue;
        if (seen == ordinal) return index;
        seen += 1;
    }
    return null;
}
