const std = @import("std");

pub const flag_ignore_case: u32 = 1 << 1;
pub const flag_multiline: u32 = 1 << 3;
pub const flag_dot_all: u32 = 1 << 4;
pub const flag_unicode: u32 = 1 << 5;
pub const flag_ascii: u32 = 1 << 8;
pub const supported_flags = flag_ignore_case | flag_multiline | flag_dot_all | flag_unicode | flag_ascii;

pub const Mode = enum { unicode, bytes };

pub const Limits = struct {
    max_instructions: usize = 8192,
    max_repeat: u32 = 1000,
    max_groups: u16 = 64,
    max_classes: usize = 1024,
    max_class_ranges: usize = 4096,
};

pub const Diagnostic = struct {
    message: []const u8 = "invalid regular expression",
    position: usize = 0,
};

pub const CompileError = error{ OutOfMemory, InvalidPattern };

pub const Assertion = enum(u8) {
    line_start,
    line_end,
    word_boundary,
    not_word_boundary,
};

pub const Category = enum(u8) {
    digit,
    not_digit,
    word,
    not_word,
    space,
    not_space,
};

pub const Range = struct {
    first: u21,
    last: u21,
};

pub const CharacterClass = struct {
    negated: bool,
    categories: u8,
    ranges: []Range,

    pub fn hasCategory(self: CharacterClass, category: Category) bool {
        return self.categories & categoryMask(category) != 0;
    }
};

pub const GroupName = struct {
    name: []u8,
    index: u16,
};

pub const Op = enum(u8) {
    literal,
    any,
    character_class,
    assertion,
    save,
    split,
    jump,
    match,
};

pub const Instruction = struct {
    op: Op,
    a: u32 = 0,
    b: u32 = 0,
};

pub const Program = struct {
    allocator: std.mem.Allocator,
    instructions: []Instruction,
    classes: []CharacterClass,
    group_names: []GroupName,
    group_count: u16,
    flags: u32,
    mode: Mode,

    pub fn deinit(self: *Program) void {
        for (self.classes) |class| self.allocator.free(class.ranges);
        for (self.group_names) |entry| self.allocator.free(entry.name);
        self.allocator.free(self.instructions);
        self.allocator.free(self.classes);
        self.allocator.free(self.group_names);
        self.* = undefined;
    }

    pub fn captureSlotCount(self: *const Program) usize {
        return (@as(usize, self.group_count) + 1) * 2;
    }

    pub fn groupIndex(self: *const Program, name: []const u8) ?u16 {
        for (self.group_names) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.index;
        }
        return null;
    }
};

const NodeId = u32;
const Node = union(enum) {
    empty,
    literal: u21,
    any,
    character_class: u32,
    assertion: Assertion,
    concat: Pair,
    alternate: Pair,
    repeat: Repeat,
    capture: Capture,
};

const Pair = struct { left: NodeId, right: NodeId };
const Repeat = struct { child: NodeId, min: u32, max: u32, greedy: bool };
const Capture = struct { child: NodeId, group: u16 };
const unbounded_repeat = std.math.maxInt(u32);

const ParsedClassAtom = union(enum) {
    literal: u21,
    category: Category,
};

const Parser = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    pattern: []const u8,
    byte_index: usize = 0,
    char_index: usize = 0,
    mode: Mode,
    flags: u32,
    limits: Limits,
    diagnostic: *Diagnostic,
    nodes: std.ArrayList(Node) = .empty,
    classes: std.ArrayList(CharacterClass) = .empty,
    names: std.ArrayList(GroupName) = .empty,
    group_count: u16 = 0,
    total_class_ranges: usize = 0,

    fn init(allocator: std.mem.Allocator, pattern: []const u8, mode: Mode, flags: u32, limits: Limits, diagnostic: *Diagnostic) Parser {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .pattern = pattern,
            .mode = mode,
            .flags = flags,
            .limits = limits,
            .diagnostic = diagnostic,
        };
    }

    fn deinit(self: *Parser, retain_program_storage: bool) void {
        self.nodes.deinit(self.allocator);
        if (!retain_program_storage) {
            for (self.classes.items) |class| self.allocator.free(class.ranges);
            for (self.names.items) |entry| self.allocator.free(entry.name);
        }
        self.classes.deinit(self.allocator);
        self.names.deinit(self.allocator);
        self.arena.deinit();
    }

    fn fail(self: *Parser, message: []const u8, position: usize) CompileError {
        self.diagnostic.* = .{ .message = message, .position = position };
        return error.InvalidPattern;
    }

    fn addNode(self: *Parser, node: Node) CompileError!NodeId {
        if (self.nodes.items.len >= std.math.maxInt(u32)) return self.fail("regular expression is too large", self.char_index);
        self.nodes.append(self.allocator, node) catch return error.OutOfMemory;
        return @intCast(self.nodes.items.len - 1);
    }

    fn peek(self: *Parser) ?u21 {
        if (self.byte_index >= self.pattern.len) return null;
        if (self.mode == .bytes) return self.pattern[self.byte_index];
        const width = std.unicode.utf8ByteSequenceLength(self.pattern[self.byte_index]) catch return null;
        if (self.byte_index + width > self.pattern.len) return null;
        return std.unicode.utf8Decode(self.pattern[self.byte_index..][0..width]) catch null;
    }

    fn take(self: *Parser) CompileError!?u21 {
        if (self.byte_index >= self.pattern.len) return null;
        if (self.mode == .bytes) {
            const value: u21 = self.pattern[self.byte_index];
            self.byte_index += 1;
            self.char_index += 1;
            return value;
        }
        const width = std.unicode.utf8ByteSequenceLength(self.pattern[self.byte_index]) catch return self.fail("invalid UTF-8 in regular expression", self.char_index);
        if (self.byte_index + width > self.pattern.len) return self.fail("invalid UTF-8 in regular expression", self.char_index);
        const value = std.unicode.utf8Decode(self.pattern[self.byte_index..][0..width]) catch return self.fail("invalid UTF-8 in regular expression", self.char_index);
        self.byte_index += width;
        self.char_index += 1;
        return value;
    }

    fn accept(self: *Parser, expected: u21) CompileError!bool {
        if (self.peek() != expected) return false;
        _ = try self.take();
        return true;
    }

    fn parse(self: *Parser) CompileError!NodeId {
        const root = try self.parseAlternation();
        if (self.peek() != null) {
            if (self.peek().? == ')') return self.fail("unbalanced parenthesis", self.char_index);
            return self.fail("unexpected regular expression token", self.char_index);
        }
        return root;
    }

    fn parseAlternation(self: *Parser) CompileError!NodeId {
        var node = try self.parseConcat();
        while (try self.accept('|')) {
            const right = try self.parseConcat();
            node = try self.addNode(.{ .alternate = .{ .left = node, .right = right } });
        }
        return node;
    }

    fn parseConcat(self: *Parser) CompileError!NodeId {
        var result: ?NodeId = null;
        while (self.peek()) |next| {
            if (next == ')' or next == '|') break;
            const atom = try self.parseQuantified();
            result = if (result) |left|
                try self.addNode(.{ .concat = .{ .left = left, .right = atom } })
            else
                atom;
        }
        return result orelse try self.addNode(.empty);
    }

    fn parseQuantified(self: *Parser) CompileError!NodeId {
        const atom_position = self.char_index;
        var node = try self.parseAtom();
        var min: u32 = 0;
        var max: u32 = 0;
        var quantified = true;
        const next = self.peek();
        if (next == '*') {
            _ = try self.take();
            max = unbounded_repeat;
        } else if (next == '+') {
            _ = try self.take();
            min = 1;
            max = unbounded_repeat;
        } else if (next == '?') {
            _ = try self.take();
            max = 1;
        } else if (next == '{') {
            const count = try self.tryParseCount();
            if (count) |repeat| {
                min = repeat.min;
                max = repeat.max;
            } else {
                quantified = false;
            }
        } else {
            quantified = false;
        }
        if (!quantified) return node;
        if (!isRepeatable(self.nodes.items[node])) return self.fail("nothing to repeat", atom_position);
        const greedy = !(try self.accept('?'));
        if (self.peek()) |following| {
            if (following == '*' or following == '+' or following == '?') return self.fail("multiple repeat", self.char_index);
            if (following == '{' and try self.looksLikeCount()) return self.fail("multiple repeat", self.char_index);
        }
        node = try self.addNode(.{ .repeat = .{ .child = node, .min = min, .max = max, .greedy = greedy } });
        return node;
    }

    fn looksLikeCount(self: *Parser) CompileError!bool {
        if (self.peek() != '{') return false;
        const saved_byte = self.byte_index;
        const saved_char = self.char_index;
        _ = try self.take();
        const result = if (self.peek()) |value| value >= '0' and value <= '9' else false;
        self.byte_index = saved_byte;
        self.char_index = saved_char;
        return result;
    }

    fn tryParseCount(self: *Parser) CompileError!?struct { min: u32, max: u32 } {
        const saved_byte = self.byte_index;
        const saved_char = self.char_index;
        _ = try self.take();
        const first = self.peek() orelse {
            self.byte_index = saved_byte;
            self.char_index = saved_char;
            return null;
        };
        if (first < '0' or first > '9') {
            self.byte_index = saved_byte;
            self.char_index = saved_char;
            return null;
        }
        const min = try self.parseDecimal();
        var max = min;
        if (try self.accept(',')) {
            const value = self.peek() orelse return self.fail("unterminated repeat", saved_char);
            if (value < '0' or value > '9') return self.fail("open-ended counted repeats are unsupported in Peony 0.1", self.char_index);
            max = try self.parseDecimal();
        }
        if (!(try self.accept('}'))) return self.fail("unterminated repeat", saved_char);
        if (min > max) return self.fail("min repeat greater than max repeat", saved_char);
        if (max > self.limits.max_repeat) return self.fail("counted repeat exceeds Peony regex limit", saved_char);
        return .{ .min = min, .max = max };
    }

    fn parseDecimal(self: *Parser) CompileError!u32 {
        var value: u32 = 0;
        while (self.peek()) |digit| {
            if (digit < '0' or digit > '9') break;
            _ = try self.take();
            value = std.math.mul(u32, value, 10) catch return self.fail("repeat count is too large", self.char_index - 1);
            value = std.math.add(u32, value, @intCast(digit - '0')) catch return self.fail("repeat count is too large", self.char_index - 1);
        }
        return value;
    }

    fn parseAtom(self: *Parser) CompileError!NodeId {
        const position = self.char_index;
        const value = (try self.take()) orelse return self.fail("unexpected end of regular expression", position);
        return switch (value) {
            '.' => self.addNode(.any),
            '^' => self.addNode(.{ .assertion = .line_start }),
            '$' => self.addNode(.{ .assertion = .line_end }),
            '[' => self.parseClass(position),
            '(' => self.parseGroup(position),
            '\\' => self.parseEscape(false, position),
            '*', '+', '?' => self.fail("nothing to repeat", position),
            '{' => if (self.peek()) |following|
                if (following >= '0' and following <= '9') self.fail("nothing to repeat", position) else self.addNode(.{ .literal = value })
            else
                self.addNode(.{ .literal = value }),
            else => self.addNode(.{ .literal = value }),
        };
    }

    fn parseGroup(self: *Parser, position: usize) CompileError!NodeId {
        var capturing = true;
        var name: ?[]const u8 = null;
        if (try self.accept('?')) {
            if (try self.accept(':')) {
                capturing = false;
            } else if (try self.accept('P')) {
                if (!(try self.accept('<'))) return self.fail("unsupported named-group construct", position);
                name = try self.parseGroupName(position);
            } else {
                return self.fail("unsupported regular expression group construct", position);
            }
        }
        var group: u16 = 0;
        if (capturing) {
            if (self.group_count >= self.limits.max_groups) return self.fail("too many capture groups", position);
            self.group_count += 1;
            group = self.group_count;
            if (name) |group_name| {
                for (self.names.items) |entry| {
                    if (std.mem.eql(u8, entry.name, group_name)) return self.fail("redefinition of group name", position);
                }
                const owned = self.allocator.dupe(u8, group_name) catch return error.OutOfMemory;
                errdefer self.allocator.free(owned);
                self.names.append(self.allocator, .{ .name = owned, .index = group }) catch return error.OutOfMemory;
            }
        }
        const child = try self.parseAlternation();
        if (!(try self.accept(')'))) return self.fail("unterminated subpattern", position);
        if (!capturing) return child;
        return self.addNode(.{ .capture = .{ .child = child, .group = group } });
    }

    fn parseGroupName(self: *Parser, position: usize) CompileError![]const u8 {
        const start = self.byte_index;
        var first = true;
        while (self.peek()) |value| {
            if (value == '>') break;
            if (value > 0x7f or !(value == '_' or value >= 'a' and value <= 'z' or value >= 'A' and value <= 'Z' or (!first and value >= '0' and value <= '9'))) {
                return self.fail("invalid group name", self.char_index);
            }
            _ = try self.take();
            first = false;
        }
        if (first or !(try self.accept('>'))) return self.fail("invalid group name", position);
        return self.pattern[start .. self.byte_index - 1];
    }

    fn parseEscape(self: *Parser, in_class: bool, slash_position: usize) CompileError!NodeId {
        const escaped = (try self.take()) orelse return self.fail("bad escape at end of pattern", slash_position);
        if (categoryForEscape(escaped)) |category| {
            const class_index = try self.addClass(false, categoryMask(category), &.{});
            return self.addNode(.{ .character_class = class_index });
        }
        if (!in_class and (escaped == 'b' or escaped == 'B')) {
            return self.addNode(.{ .assertion = if (escaped == 'b') .word_boundary else .not_word_boundary });
        }
        if (escaped >= '0' and escaped <= '9') return self.fail("pattern backreferences are unsupported in Peony 0.1", slash_position);
        const literal = escapeLiteral(escaped, in_class) orelse blk: {
            if (isAsciiLetter(escaped)) return self.fail("bad escape", slash_position);
            break :blk escaped;
        };
        return self.addNode(.{ .literal = literal });
    }

    fn parseClass(self: *Parser, position: usize) CompileError!NodeId {
        const negated = try self.accept('^');
        var ranges: std.ArrayList(Range) = .empty;
        defer ranges.deinit(self.allocator);
        var categories: u8 = 0;
        var first = true;
        var closed = false;
        while (self.peek()) |next| {
            if (next == ']' and !first) {
                _ = try self.take();
                closed = true;
                break;
            }
            const atom = try self.parseClassAtom(position);
            first = false;
            switch (atom) {
                .category => |category| categories |= categoryMask(category),
                .literal => |literal| {
                    if (self.peek() == '-') {
                        const saved_byte = self.byte_index;
                        const saved_char = self.char_index;
                        _ = try self.take();
                        if (self.peek() != null and self.peek().? != ']') {
                            const endpoint = try self.parseClassAtom(position);
                            switch (endpoint) {
                                .category => return self.fail("bad character range", saved_char),
                                .literal => |last| {
                                    if (literal > last) return self.fail("bad character range", saved_char);
                                    try self.appendRange(&ranges, .{ .first = literal, .last = last });
                                    continue;
                                },
                            }
                        }
                        self.byte_index = saved_byte;
                        self.char_index = saved_char;
                    }
                    try self.appendRange(&ranges, .{ .first = literal, .last = literal });
                },
            }
        }
        if (!closed) return self.fail("unterminated character set", position);
        const class_index = try self.addClass(negated, categories, ranges.items);
        return self.addNode(.{ .character_class = class_index });
    }

    fn parseClassAtom(self: *Parser, position: usize) CompileError!ParsedClassAtom {
        const value = (try self.take()) orelse return self.fail("unterminated character set", position);
        if (value != '\\') return .{ .literal = value };
        const escaped = (try self.take()) orelse return self.fail("bad escape at end of pattern", self.char_index - 1);
        if (categoryForEscape(escaped)) |category| return .{ .category = category };
        if (escaped >= '0' and escaped <= '9') return self.fail("numeric escapes are unsupported in Peony 0.1", self.char_index - 2);
        if (escaped == 'b') return .{ .literal = 0x08 };
        const literal = escapeLiteral(escaped, true) orelse {
            if (isAsciiLetter(escaped)) return self.fail("bad escape", self.char_index - 2);
            return .{ .literal = escaped };
        };
        return .{ .literal = literal };
    }

    fn appendRange(self: *Parser, ranges: *std.ArrayList(Range), range: Range) CompileError!void {
        if (self.total_class_ranges + ranges.items.len >= self.limits.max_class_ranges) return self.fail("regular expression character classes are too large", self.char_index);
        ranges.append(self.allocator, range) catch return error.OutOfMemory;
    }

    fn addClass(self: *Parser, negated: bool, categories: u8, ranges: []const Range) CompileError!u32 {
        if (self.classes.items.len >= self.limits.max_classes) return self.fail("too many character classes", self.char_index);
        const owned = self.allocator.dupe(Range, ranges) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned);
        self.classes.append(self.allocator, .{ .negated = negated, .categories = categories, .ranges = owned }) catch return error.OutOfMemory;
        self.total_class_ranges += ranges.len;
        return @intCast(self.classes.items.len - 1);
    }
};

const Emitter = struct {
    allocator: std.mem.Allocator,
    nodes: []const Node,
    limits: Limits,
    diagnostic: *Diagnostic,
    instructions: std.ArrayList(Instruction) = .empty,

    fn deinit(self: *Emitter) void {
        self.instructions.deinit(self.allocator);
    }

    fn emit(self: *Emitter, instruction: Instruction) CompileError!u32 {
        if (self.instructions.items.len >= self.limits.max_instructions or self.instructions.items.len >= std.math.maxInt(u32)) {
            self.diagnostic.* = .{ .message = "regular expression program is too large", .position = 0 };
            return error.InvalidPattern;
        }
        self.instructions.append(self.allocator, instruction) catch return error.OutOfMemory;
        return @intCast(self.instructions.items.len - 1);
    }

    fn compileNode(self: *Emitter, id: NodeId) CompileError!void {
        switch (self.nodes[id]) {
            .empty => {},
            .literal => |codepoint| _ = try self.emit(.{ .op = .literal, .a = codepoint }),
            .any => _ = try self.emit(.{ .op = .any }),
            .character_class => |class_index| _ = try self.emit(.{ .op = .character_class, .a = class_index }),
            .assertion => |assertion| _ = try self.emit(.{ .op = .assertion, .a = @intFromEnum(assertion) }),
            .concat => |pair| {
                try self.compileNode(pair.left);
                try self.compileNode(pair.right);
            },
            .alternate => |pair| {
                const split = try self.emit(.{ .op = .split });
                const left_start: u32 = @intCast(self.instructions.items.len);
                try self.compileNode(pair.left);
                const jump = try self.emit(.{ .op = .jump });
                const right_start: u32 = @intCast(self.instructions.items.len);
                try self.compileNode(pair.right);
                const after: u32 = @intCast(self.instructions.items.len);
                self.instructions.items[split].a = left_start;
                self.instructions.items[split].b = right_start;
                self.instructions.items[jump].a = after;
            },
            .repeat => |repeat| try self.compileRepeat(repeat),
            .capture => |capture| {
                _ = try self.emit(.{ .op = .save, .a = @as(u32, capture.group) * 2 });
                try self.compileNode(capture.child);
                _ = try self.emit(.{ .op = .save, .a = @as(u32, capture.group) * 2 + 1 });
            },
        }
    }

    fn compileRepeat(self: *Emitter, repeat: Repeat) CompileError!void {
        var index: u32 = 0;
        while (index < repeat.min) : (index += 1) try self.compileNode(repeat.child);
        if (repeat.max == repeat.min) return;
        if (repeat.max == unbounded_repeat) {
            const split: u32 = @intCast(self.instructions.items.len);
            _ = try self.emit(.{ .op = .split });
            const child_start: u32 = @intCast(self.instructions.items.len);
            try self.compileNode(repeat.child);
            _ = try self.emit(.{ .op = .jump, .a = split });
            const after: u32 = @intCast(self.instructions.items.len);
            if (repeat.greedy) {
                self.instructions.items[split].a = child_start;
                self.instructions.items[split].b = after;
            } else {
                self.instructions.items[split].a = after;
                self.instructions.items[split].b = child_start;
            }
            return;
        }
        var optional = repeat.min;
        while (optional < repeat.max) : (optional += 1) {
            const split = try self.emit(.{ .op = .split });
            const child_start: u32 = @intCast(self.instructions.items.len);
            try self.compileNode(repeat.child);
            const after: u32 = @intCast(self.instructions.items.len);
            if (repeat.greedy) {
                self.instructions.items[split].a = child_start;
                self.instructions.items[split].b = after;
            } else {
                self.instructions.items[split].a = after;
                self.instructions.items[split].b = child_start;
            }
        }
    }
};

pub fn compile(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    mode: Mode,
    requested_flags: u32,
    limits: Limits,
    diagnostic: *Diagnostic,
) CompileError!Program {
    diagnostic.* = .{};
    if (requested_flags & ~supported_flags != 0) {
        diagnostic.* = .{ .message = "unsupported regular expression flag", .position = 0 };
        return error.InvalidPattern;
    }
    var flags = requested_flags;
    if (mode == .unicode) {
        if (flags & flag_ascii == 0) flags |= flag_unicode;
    } else if (flags & flag_unicode != 0) {
        diagnostic.* = .{ .message = "UNICODE flag cannot be used with a bytes pattern", .position = 0 };
        return error.InvalidPattern;
    }
    if (flags & flag_ascii != 0 and flags & flag_unicode != 0) {
        diagnostic.* = .{ .message = "ASCII and UNICODE flags are incompatible", .position = 0 };
        return error.InvalidPattern;
    }
    if (mode == .unicode and !std.unicode.utf8ValidateSlice(pattern)) {
        diagnostic.* = .{ .message = "invalid UTF-8 in regular expression", .position = 0 };
        return error.InvalidPattern;
    }

    var parser = Parser.init(allocator, pattern, mode, flags, limits, diagnostic);
    var retain_program_storage = false;
    defer parser.deinit(retain_program_storage);
    const root = try parser.parse();

    var emitter = Emitter{ .allocator = allocator, .nodes = parser.nodes.items, .limits = limits, .diagnostic = diagnostic };
    defer emitter.deinit();
    _ = try emitter.emit(.{ .op = .save, .a = 0 });
    try emitter.compileNode(root);
    _ = try emitter.emit(.{ .op = .save, .a = 1 });
    _ = try emitter.emit(.{ .op = .match });

    const instructions = emitter.instructions.toOwnedSlice(allocator) catch return error.OutOfMemory;
    errdefer allocator.free(instructions);
    const classes = parser.classes.toOwnedSlice(allocator) catch return error.OutOfMemory;
    errdefer {
        for (classes) |class| allocator.free(class.ranges);
        allocator.free(classes);
    }
    const names = parser.names.toOwnedSlice(allocator) catch return error.OutOfMemory;
    errdefer allocator.free(names);
    retain_program_storage = true;
    return .{
        .allocator = allocator,
        .instructions = instructions,
        .classes = classes,
        .group_names = names,
        .group_count = parser.group_count,
        .flags = flags,
        .mode = mode,
    };
}

fn isRepeatable(node: Node) bool {
    return switch (node) {
        .assertion => false,
        else => true,
    };
}

fn categoryForEscape(value: u21) ?Category {
    return switch (value) {
        'd' => .digit,
        'D' => .not_digit,
        'w' => .word,
        'W' => .not_word,
        's' => .space,
        'S' => .not_space,
        else => null,
    };
}

fn categoryMask(category: Category) u8 {
    return @as(u8, 1) << @as(u3, @intCast(@intFromEnum(category)));
}

fn escapeLiteral(value: u21, in_class: bool) ?u21 {
    return switch (value) {
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        'f' => 0x0c,
        'v' => 0x0b,
        'a' => 0x07,
        'b' => if (in_class) 0x08 else null,
        else => null,
    };
}

fn isAsciiLetter(value: u21) bool {
    return value >= 'a' and value <= 'z' or value >= 'A' and value <= 'Z';
}

test "regex parser compiles ordered syntax and rejects excluded grammar" {
    var diagnostic = Diagnostic{};
    var program = try compile(std.testing.allocator, "(?P<word>a+?)(?:b|c){1,2}", .unicode, flag_ignore_case, .{}, &diagnostic);
    defer program.deinit();
    try std.testing.expectEqual(@as(u16, 1), program.group_count);
    try std.testing.expectEqual(@as(?u16, 1), program.groupIndex("word"));
    try std.testing.expect(program.instructions.len > 8);
    try std.testing.expect(program.flags & flag_unicode != 0);

    try std.testing.expectError(error.InvalidPattern, compile(std.testing.allocator, "(a)\\1", .unicode, 0, .{}, &diagnostic));
    try std.testing.expectEqualStrings("pattern backreferences are unsupported in Peony 0.1", diagnostic.message);
    try std.testing.expectError(error.InvalidPattern, compile(std.testing.allocator, "(?=a)", .unicode, 0, .{}, &diagnostic));
    try std.testing.expectError(error.InvalidPattern, compile(std.testing.allocator, "a{2,}", .unicode, 0, .{}, &diagnostic));
    try std.testing.expectError(error.InvalidPattern, compile(std.testing.allocator, "a", .bytes, flag_unicode, .{}, &diagnostic));
}

test "regex parser bounds counted expansion and preserves class categories" {
    var diagnostic = Diagnostic{};
    try std.testing.expectError(error.InvalidPattern, compile(std.testing.allocator, "a{1001}", .unicode, 0, .{ .max_repeat = 1000 }, &diagnostic));
    var program = try compile(std.testing.allocator, "[^a-c\\d]+", .unicode, 0, .{}, &diagnostic);
    defer program.deinit();
    try std.testing.expectEqual(@as(usize, 1), program.classes.len);
    try std.testing.expect(program.classes[0].negated);
    try std.testing.expect(program.classes[0].hasCategory(.digit));
    try std.testing.expectEqual(@as(usize, 1), program.classes[0].ranges.len);
}
