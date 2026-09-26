const std = @import("std");
const parser = @import("parser.zig");

pub const Property = enum { decimal, alnum, whitespace };

pub const CharacterSemantics = struct {
    context: ?*const anyopaque = null,
    has_property: *const fn (?*const anyopaque, u21, Property) bool = asciiHasProperty,
    case_variants: *const fn (?*const anyopaque, u21, *[12]u21) usize = asciiCaseVariants,

    pub fn has(self: CharacterSemantics, codepoint: u21, property: Property) bool {
        return self.has_property(self.context, codepoint, property);
    }

    pub fn variants(self: CharacterSemantics, codepoint: u21, output: *[12]u21) []const u21 {
        const length = self.case_variants(self.context, codepoint, output);
        return output[0..length];
    }
};

pub const WorkBudget = struct {
    remaining: u64 = std.math.maxInt(u64),
    used: u64 = 0,

    pub fn charge(self: *WorkBudget, amount: u64) Error!void {
        if (amount > self.remaining) return error.WorkLimit;
        self.remaining -= amount;
        self.used +|= amount;
    }
};

pub const Error = error{ OutOfMemory, InvalidUtf8, WorkLimit };

pub const Anchor = enum { search, match, fullmatch };

pub const Options = struct {
    start: usize = 0,
    end: ?usize = null,
    anchor: Anchor = .search,
    suppress_empty_at: ?usize = null,
};

pub const Match = struct {
    allocator: std.mem.Allocator,
    captures: []i64,

    pub fn deinit(self: *Match) void {
        self.allocator.free(self.captures);
        self.* = undefined;
    }

    pub fn span(self: *const Match, group: usize) ?struct { start: usize, end: usize } {
        const slot = std.math.mul(usize, group, 2) catch return null;
        if (slot + 1 >= self.captures.len) return null;
        const start = self.captures[slot];
        const end = self.captures[slot + 1];
        if (start < 0 or end < 0) return null;
        return .{ .start = @intCast(start), .end = @intCast(end) };
    }
};

pub const StepResult = union(enum) {
    yielded,
    no_match,
    matched: Match,
};

pub const DecodedSubject = struct {
    allocator: std.mem.Allocator,
    codepoints: []u21,
    byte_offsets: ?[]usize = null,
    mode: parser.Mode,

    pub fn deinit(self: *DecodedSubject) void {
        self.allocator.free(self.codepoints);
        if (self.byte_offsets) |offsets| self.allocator.free(offsets);
        self.* = undefined;
    }

    pub fn length(self: *const DecodedSubject) usize {
        return self.codepoints.len;
    }

    pub fn byteOffset(self: *const DecodedSubject, position: usize) ?usize {
        if (position > self.codepoints.len) return null;
        if (self.mode == .bytes) return position;
        const offsets = self.byte_offsets orelse return null;
        return offsets[position];
    }
};

const Thread = struct {
    pc: u32,
    captures: u32,
};

const WorkItem = struct {
    pc: u32,
    captures: u32,
};

const Frontier = struct {
    allocator: std.mem.Allocator,
    capture_slots: usize,
    threads: std.ArrayList(Thread) = .empty,
    capture_pool: std.ArrayList(i64) = .empty,
    stack: std.ArrayList(WorkItem) = .empty,
    marks: []u32,
    generation: u32 = 1,

    fn init(allocator: std.mem.Allocator, instruction_count: usize, capture_slots: usize) Error!Frontier {
        const marks = allocator.alloc(u32, instruction_count) catch return error.OutOfMemory;
        @memset(marks, 0);
        return .{ .allocator = allocator, .capture_slots = capture_slots, .marks = marks };
    }

    fn deinit(self: *Frontier) void {
        self.threads.deinit(self.allocator);
        self.capture_pool.deinit(self.allocator);
        self.stack.deinit(self.allocator);
        self.allocator.free(self.marks);
        self.* = undefined;
    }

    fn clear(self: *Frontier) void {
        self.threads.clearRetainingCapacity();
        self.capture_pool.clearRetainingCapacity();
        self.stack.clearRetainingCapacity();
        self.generation +%= 1;
        if (self.generation == 0) {
            @memset(self.marks, 0);
            self.generation = 1;
        }
    }

    fn captureSlice(self: *const Frontier, index: u32) []const i64 {
        const start: usize = @intCast(index);
        return self.capture_pool.items[start..][0..self.capture_slots];
    }

    fn copyCaptures(self: *Frontier, captures: []const i64) Error!u32 {
        const start = self.capture_pool.items.len;
        if (start > std.math.maxInt(u32) or captures.len != self.capture_slots or captures.len > std.math.maxInt(u32) - start) return error.OutOfMemory;
        self.capture_pool.appendSlice(self.allocator, captures) catch return error.OutOfMemory;
        return @intCast(start);
    }

    fn copyCapturesWithSave(self: *Frontier, captures: []const i64, slot: usize, value: i64) Error!u32 {
        const index = try self.copyCaptures(captures);
        self.capture_pool.items[@as(usize, index) + slot] = value;
        return index;
    }

    fn add(
        self: *Frontier,
        program: *const parser.Program,
        input: *const DecodedSubject,
        position: usize,
        end: usize,
        pc: u32,
        captures: []const i64,
        semantics: CharacterSemantics,
        budget: *WorkBudget,
    ) Error!void {
        const capture_index = try self.copyCaptures(captures);
        self.stack.append(self.allocator, .{ .pc = pc, .captures = capture_index }) catch return error.OutOfMemory;
        while (self.stack.pop()) |item| {
            try budget.charge(1);
            const instruction_index: usize = item.pc;
            if (instruction_index >= program.instructions.len) continue;
            if (self.marks[instruction_index] == self.generation) continue;
            self.marks[instruction_index] = self.generation;
            const instruction = program.instructions[instruction_index];
            switch (instruction.op) {
                .jump => self.stack.append(self.allocator, .{ .pc = instruction.a, .captures = item.captures }) catch return error.OutOfMemory,
                .split => {
                    self.stack.append(self.allocator, .{ .pc = instruction.b, .captures = item.captures }) catch return error.OutOfMemory;
                    self.stack.append(self.allocator, .{ .pc = instruction.a, .captures = item.captures }) catch return error.OutOfMemory;
                },
                .save => {
                    if (@as(usize, instruction.a) >= self.capture_slots) continue;
                    const saved = try self.copyCapturesWithSave(self.captureSlice(item.captures), @intCast(instruction.a), @intCast(position));
                    self.stack.append(self.allocator, .{ .pc = item.pc + 1, .captures = saved }) catch return error.OutOfMemory;
                },
                .assertion => {
                    const assertion = std.enums.fromInt(parser.Assertion, instruction.a) orelse continue;
                    if (assertionMatches(program, input, position, end, assertion, semantics)) {
                        self.stack.append(self.allocator, .{ .pc = item.pc + 1, .captures = item.captures }) catch return error.OutOfMemory;
                    }
                },
                .literal, .any, .character_class, .match => {
                    self.threads.append(self.allocator, .{ .pc = item.pc, .captures = item.captures }) catch return error.OutOfMemory;
                },
            }
        }
    }
};

pub const Engine = struct {
    allocator: std.mem.Allocator,
    program: *const parser.Program,
    input: *const DecodedSubject,
    owned_input: ?*DecodedSubject = null,
    options: Options,
    semantics: CharacterSemantics,
    empty_captures: []i64,
    current: Frontier,
    next_frontier: Frontier,
    candidate: ?[]i64 = null,
    position: usize,
    end: usize,
    added_anchor: bool = false,
    finished: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        program: *const parser.Program,
        subject: []const u8,
        options: Options,
        semantics: CharacterSemantics,
        budget: *WorkBudget,
    ) Error!Engine {
        const input = allocator.create(DecodedSubject) catch return error.OutOfMemory;
        errdefer allocator.destroy(input);
        input.* = try decodeSubject(allocator, subject, program.mode, budget);
        errdefer input.deinit();
        var engine = try initDecoded(allocator, program, input, options, semantics);
        engine.owned_input = input;
        return engine;
    }

    pub fn initDecoded(
        allocator: std.mem.Allocator,
        program: *const parser.Program,
        input: *const DecodedSubject,
        options: Options,
        semantics: CharacterSemantics,
    ) Error!Engine {
        if (input.mode != program.mode) return error.InvalidUtf8;
        const end = @min(options.end orelse input.codepoints.len, input.codepoints.len);
        const start = @min(options.start, input.codepoints.len);
        const capture_slots = program.captureSlotCount();
        const empty_captures = allocator.alloc(i64, capture_slots) catch return error.OutOfMemory;
        errdefer allocator.free(empty_captures);
        @memset(empty_captures, -1);
        var current = try Frontier.init(allocator, program.instructions.len, capture_slots);
        errdefer current.deinit();
        const next_frontier = try Frontier.init(allocator, program.instructions.len, capture_slots);
        return .{
            .allocator = allocator,
            .program = program,
            .input = input,
            .options = options,
            .semantics = semantics,
            .empty_captures = empty_captures,
            .current = current,
            .next_frontier = next_frontier,
            .position = start,
            .end = end,
        };
    }

    pub fn deinit(self: *Engine) void {
        if (self.candidate) |captures| self.allocator.free(captures);
        self.current.deinit();
        self.next_frontier.deinit();
        self.allocator.free(self.empty_captures);
        if (self.owned_input) |input| {
            input.deinit();
            self.allocator.destroy(input);
        }
        self.* = undefined;
    }

    pub fn step(self: *Engine, max_positions: usize, budget: *WorkBudget) Error!StepResult {
        if (self.finished) return .no_match;
        if (max_positions == 0) return .yielded;
        var processed: usize = 0;
        while (processed < max_positions) : (processed += 1) {
            if (self.position > self.end) return self.finish();
            if (self.candidate == null and (!self.added_anchor or self.options.anchor == .search)) {
                try self.current.add(self.program, self.input, self.position, self.end, 0, self.empty_captures, self.semantics, budget);
                self.added_anchor = true;
            }

            var processing_limit = self.current.threads.items.len;
            for (self.current.threads.items, 0..) |thread, index| {
                const instruction = self.program.instructions[thread.pc];
                if (instruction.op != .match) continue;
                const captures = self.current.captureSlice(thread.captures);
                if (!eligibleMatch(captures, self.options, self.end)) continue;
                const owned = self.allocator.dupe(i64, captures) catch return error.OutOfMemory;
                if (self.candidate) |previous| self.allocator.free(previous);
                self.candidate = owned;
                processing_limit = index;
                break;
            }

            if (self.position == self.end) return self.finish();
            self.next_frontier.clear();
            const codepoint = self.input.codepoints[self.position];
            for (self.current.threads.items[0..processing_limit]) |thread| {
                try budget.charge(1);
                const instruction = self.program.instructions[thread.pc];
                if (consumes(self.program, instruction, codepoint, self.semantics)) {
                    try self.next_frontier.add(self.program, self.input, self.position + 1, self.end, thread.pc + 1, self.current.captureSlice(thread.captures), self.semantics, budget);
                }
            }
            if (self.next_frontier.threads.items.len == 0) {
                if (self.candidate != null or self.options.anchor != .search) return self.finish();
                self.current.clear();
                self.position += 1;
                continue;
            }
            std.mem.swap(Frontier, &self.current, &self.next_frontier);
            self.position += 1;
        }
        return .yielded;
    }

    fn finish(self: *Engine) StepResult {
        self.finished = true;
        if (self.candidate) |captures| {
            self.candidate = null;
            return .{ .matched = .{ .allocator = self.allocator, .captures = captures } };
        }
        return .no_match;
    }
};

pub fn execute(
    allocator: std.mem.Allocator,
    program: *const parser.Program,
    subject: []const u8,
    options: Options,
    semantics: CharacterSemantics,
    budget: *WorkBudget,
) Error!?Match {
    var engine = try Engine.init(allocator, program, subject, options, semantics, budget);
    defer engine.deinit();
    while (true) switch (try engine.step(std.math.maxInt(usize), budget)) {
        .yielded => continue,
        .no_match => return null,
        .matched => |match| return match,
    };
}

pub fn decodeSubject(allocator: std.mem.Allocator, subject: []const u8, mode: parser.Mode, budget: *WorkBudget) Error!DecodedSubject {
    if (mode == .bytes) {
        const codepoints = allocator.alloc(u21, subject.len) catch return error.OutOfMemory;
        errdefer allocator.free(codepoints);
        for (subject, 0..) |byte, index| {
            try budget.charge(1);
            codepoints[index] = byte;
        }
        return .{ .allocator = allocator, .codepoints = codepoints, .mode = mode };
    }
    if (!std.unicode.utf8ValidateSlice(subject)) return error.InvalidUtf8;
    var count: usize = 0;
    var byte_index: usize = 0;
    while (byte_index < subject.len) : (count += 1) {
        try budget.charge(1);
        const width = std.unicode.utf8ByteSequenceLength(subject[byte_index]) catch return error.InvalidUtf8;
        byte_index += width;
    }
    const codepoints = allocator.alloc(u21, count) catch return error.OutOfMemory;
    errdefer allocator.free(codepoints);
    const offset_count = std.math.add(usize, count, 1) catch return error.OutOfMemory;
    const byte_offsets = allocator.alloc(usize, offset_count) catch return error.OutOfMemory;
    errdefer allocator.free(byte_offsets);
    byte_index = 0;
    var index: usize = 0;
    while (byte_index < subject.len) : (index += 1) {
        byte_offsets[index] = byte_index;
        const width = std.unicode.utf8ByteSequenceLength(subject[byte_index]) catch return error.InvalidUtf8;
        codepoints[index] = std.unicode.utf8Decode(subject[byte_index..][0..width]) catch return error.InvalidUtf8;
        byte_index += width;
    }
    byte_offsets[count] = subject.len;
    return .{ .allocator = allocator, .codepoints = codepoints, .byte_offsets = byte_offsets, .mode = mode };
}

fn eligibleMatch(captures: []const i64, options: Options, end: usize) bool {
    if (captures.len < 2 or captures[0] < 0 or captures[1] < 0) return false;
    const start: usize = @intCast(captures[0]);
    const stop: usize = @intCast(captures[1]);
    if (options.anchor == .fullmatch and stop != end) return false;
    if (options.suppress_empty_at) |suppressed| {
        if (start == suppressed and stop == suppressed) return false;
    }
    return true;
}

fn consumes(program: *const parser.Program, instruction: parser.Instruction, codepoint: u21, semantics: CharacterSemantics) bool {
    return switch (instruction.op) {
        .literal => equalCharacter(program, @intCast(instruction.a), codepoint, semantics),
        .any => program.flags & parser.flag_dot_all != 0 or codepoint != '\n',
        .character_class => instruction.a < program.classes.len and classMatches(program, program.classes[instruction.a], codepoint, semantics),
        else => false,
    };
}

fn assertionMatches(
    program: *const parser.Program,
    input: *const DecodedSubject,
    position: usize,
    end: usize,
    assertion: parser.Assertion,
    semantics: CharacterSemantics,
) bool {
    return switch (assertion) {
        .line_start => position == 0 or (program.flags & parser.flag_multiline != 0 and position > 0 and input.codepoints[position - 1] == '\n'),
        .line_end => position == end or if (program.flags & parser.flag_multiline != 0)
            position < end and input.codepoints[position] == '\n'
        else
            position + 1 == end and input.codepoints[position] == '\n',
        .word_boundary, .not_word_boundary => blk: {
            if (assertion == .not_word_boundary and input.codepoints.len == 0) break :blk false;
            const left = position > 0 and isWord(program, input.codepoints[position - 1], semantics);
            const right = position < end and isWord(program, input.codepoints[position], semantics);
            const boundary = left != right;
            break :blk if (assertion == .word_boundary) boundary else !boundary;
        },
    };
}

fn classMatches(program: *const parser.Program, class: parser.CharacterClass, codepoint: u21, semantics: CharacterSemantics) bool {
    var matched = false;
    if (class.hasCategory(.digit) and isDigit(program, codepoint, semantics)) matched = true;
    if (class.hasCategory(.not_digit) and !isDigit(program, codepoint, semantics)) matched = true;
    if (class.hasCategory(.word) and isWord(program, codepoint, semantics)) matched = true;
    if (class.hasCategory(.not_word) and !isWord(program, codepoint, semantics)) matched = true;
    if (class.hasCategory(.space) and isSpace(program, codepoint, semantics)) matched = true;
    if (class.hasCategory(.not_space) and !isSpace(program, codepoint, semantics)) matched = true;
    if (!matched) {
        var variants_buffer: [12]u21 = undefined;
        const variants = if (program.flags & parser.flag_ignore_case == 0) blk: {
            variants_buffer[0] = codepoint;
            break :blk variants_buffer[0..1];
        } else if (program.flags & parser.flag_ascii != 0 or program.mode == .bytes)
            variants_buffer[0..asciiCaseVariants(null, codepoint, &variants_buffer)]
        else
            semantics.variants(codepoint, &variants_buffer);
        outer: for (variants) |variant| {
            for (class.ranges) |range| {
                if (variant >= range.first and variant <= range.last) {
                    matched = true;
                    break :outer;
                }
                if (program.flags & parser.flag_ignore_case != 0 and asciiFoldedRangeContains(range, variant)) {
                    matched = true;
                    break :outer;
                }
            }
        }
    }
    return if (class.negated) !matched else matched;
}

fn equalCharacter(program: *const parser.Program, expected: u21, actual: u21, semantics: CharacterSemantics) bool {
    if (expected == actual) return true;
    if (program.flags & parser.flag_ignore_case == 0) return false;
    if (program.flags & parser.flag_ascii != 0 or program.mode == .bytes) return asciiFold(expected) == asciiFold(actual);
    var expected_buffer: [12]u21 = undefined;
    var actual_buffer: [12]u21 = undefined;
    const expected_variants = semantics.variants(expected, &expected_buffer);
    const actual_variants = semantics.variants(actual, &actual_buffer);
    for (expected_variants) |left| for (actual_variants) |right| if (left == right) return true;
    return false;
}

fn isDigit(program: *const parser.Program, codepoint: u21, semantics: CharacterSemantics) bool {
    if (program.mode == .bytes or program.flags & parser.flag_ascii != 0) return codepoint >= '0' and codepoint <= '9';
    return semantics.has(codepoint, .decimal);
}

fn isWord(program: *const parser.Program, codepoint: u21, semantics: CharacterSemantics) bool {
    if (codepoint == '_') return true;
    if (program.mode == .bytes or program.flags & parser.flag_ascii != 0) return codepoint >= '0' and codepoint <= '9' or codepoint >= 'a' and codepoint <= 'z' or codepoint >= 'A' and codepoint <= 'Z';
    return semantics.has(codepoint, .alnum);
}

fn isSpace(program: *const parser.Program, codepoint: u21, semantics: CharacterSemantics) bool {
    if (program.mode == .bytes or program.flags & parser.flag_ascii != 0) return codepoint == ' ' or codepoint == '\t' or codepoint == '\n' or codepoint == '\r' or codepoint == 0x0b or codepoint == 0x0c;
    return semantics.has(codepoint, .whitespace);
}

fn asciiFold(value: u21) u21 {
    return if (value >= 'A' and value <= 'Z') value + ('a' - 'A') else value;
}

fn asciiFoldedRangeContains(range: parser.Range, value: u21) bool {
    const folded = asciiFold(value);
    if (range.first >= 'A' and range.last <= 'Z') return folded >= asciiFold(range.first) and folded <= asciiFold(range.last);
    if (range.first >= 'a' and range.last <= 'z') return folded >= range.first and folded <= range.last;
    return false;
}

fn asciiHasProperty(_: ?*const anyopaque, codepoint: u21, property: Property) bool {
    return switch (property) {
        .decimal => codepoint >= '0' and codepoint <= '9',
        .alnum => codepoint >= '0' and codepoint <= '9' or codepoint >= 'a' and codepoint <= 'z' or codepoint >= 'A' and codepoint <= 'Z',
        .whitespace => codepoint == ' ' or codepoint == '\t' or codepoint == '\n' or codepoint == '\r' or codepoint == 0x0b or codepoint == 0x0c,
    };
}

fn asciiCaseVariants(_: ?*const anyopaque, codepoint: u21, output: *[12]u21) usize {
    output[0] = codepoint;
    var length: usize = 1;
    const folded = asciiFold(codepoint);
    if (folded != codepoint) {
        output[length] = folded;
        length += 1;
    } else if (codepoint >= 'a' and codepoint <= 'z') {
        output[length] = codepoint - ('a' - 'A');
        length += 1;
    }
    return length;
}

fn expectMatch(pattern_text: []const u8, subject: []const u8, expected_start: usize, expected_end: usize) !void {
    var diagnostic = parser.Diagnostic{};
    var program = try parser.compile(std.testing.allocator, pattern_text, .unicode, 0, .{}, &diagnostic);
    defer program.deinit();
    var budget = WorkBudget{};
    var found = (try execute(std.testing.allocator, &program, subject, .{}, .{}, &budget)) orelse return error.ExpectedRegexMatch;
    defer found.deinit();
    const span = found.span(0).?;
    try std.testing.expectEqual(expected_start, span.start);
    try std.testing.expectEqual(expected_end, span.end);
}

test "ordered Pike VM preserves alternation and greedy priority" {
    try expectMatch("a|ab", "zab", 1, 2);
    try expectMatch("ab|a", "zab", 1, 3);
    try expectMatch("a.*b", "axxbxxb", 0, 7);
    try expectMatch("a.*?b", "axxbxxb", 0, 4);
    try expectMatch("a\\+b", "a+b", 0, 3);
}

test "ordered Pike VM supports captures fullmatch and Python 3.12 empty progression" {
    var diagnostic = parser.Diagnostic{};
    var program = try parser.compile(std.testing.allocator, "(?P<x>a)?b", .unicode, 0, .{}, &diagnostic);
    defer program.deinit();
    var budget = WorkBudget{};
    var found = (try execute(std.testing.allocator, &program, "b", .{ .anchor = .fullmatch }, .{}, &budget)) orelse return error.ExpectedRegexMatch;
    defer found.deinit();
    try std.testing.expect(found.span(1) == null);

    var empty_program = try parser.compile(std.testing.allocator, "|a", .unicode, 0, .{}, &diagnostic);
    defer empty_program.deinit();
    var empty = (try execute(std.testing.allocator, &empty_program, "a", .{}, .{}, &budget)) orelse return error.ExpectedRegexMatch;
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.span(0).?.end);
    var nonempty = (try execute(std.testing.allocator, &empty_program, "a", .{ .suppress_empty_at = 0 }, .{}, &budget)) orelse return error.ExpectedRegexMatch;
    defer nonempty.deinit();
    try std.testing.expectEqual(@as(usize, 1), nonempty.span(0).?.end);

    var boundary_program = try parser.compile(std.testing.allocator, "\\B", .unicode, 0, .{}, &diagnostic);
    defer boundary_program.deinit();
    try std.testing.expect((try execute(std.testing.allocator, &boundary_program, "", .{}, .{}, &budget)) == null);
    try std.testing.expect((try execute(std.testing.allocator, &empty_program, "a", .{ .start = 1, .end = 0 }, .{}, &budget)) == null);
}

test "ordered Pike VM charges bounded work" {
    var diagnostic = parser.Diagnostic{};
    var program = try parser.compile(std.testing.allocator, "(?:a|aa)*b", .unicode, 0, .{}, &diagnostic);
    defer program.deinit();
    var budget = WorkBudget{ .remaining = 8 };
    try std.testing.expectError(error.WorkLimit, execute(std.testing.allocator, &program, "aaaaaaaa", .{}, .{}, &budget));
}

test "decoded subject owns exact Unicode byte offsets within the work cap" {
    var budget = WorkBudget{};
    var decoded = try decodeSubject(std.testing.allocator, "aé中", .unicode, &budget);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(?usize, 0), decoded.byteOffset(0));
    try std.testing.expectEqual(@as(?usize, 1), decoded.byteOffset(1));
    try std.testing.expectEqual(@as(?usize, 3), decoded.byteOffset(2));
    try std.testing.expectEqual(@as(?usize, 6), decoded.byteOffset(3));
    try std.testing.expect(decoded.byteOffset(4) == null);

    var bytes_budget = WorkBudget{};
    var bytes = try decodeSubject(std.testing.allocator, "a\xff", .bytes, &bytes_budget);
    defer bytes.deinit();
    try std.testing.expectEqual(@as(?usize, 1), bytes.byteOffset(1));
    try std.testing.expectEqual(@as(?usize, 2), bytes.byteOffset(2));

    var limited = WorkBudget{ .remaining = 1 };
    try std.testing.expectError(error.WorkLimit, decodeSubject(std.testing.allocator, "éa", .unicode, &limited));
    try std.testing.expectEqual(@as(u64, 1), limited.used);

    var storage: [80]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var memory_budget = WorkBudget{};
    try std.testing.expectError(error.OutOfMemory, decodeSubject(fixed.allocator(), "abcdefgh", .unicode, &memory_budget));
}

test "ordered Pike VM resumes at input-position checkpoints without replay" {
    var diagnostic = parser.Diagnostic{};
    var program = try parser.compile(std.testing.allocator, "z$", .unicode, 0, .{}, &diagnostic);
    defer program.deinit();
    var budget = WorkBudget{};
    var engine = try Engine.init(std.testing.allocator, &program, "aaaaaz", .{}, .{}, &budget);
    defer engine.deinit();
    var yields: usize = 0;
    while (true) switch (try engine.step(1, &budget)) {
        .yielded => yields += 1,
        .no_match => return error.ExpectedRegexMatch,
        .matched => |found_value| {
            var found = found_value;
            defer found.deinit();
            try std.testing.expectEqual(@as(usize, 5), found.span(0).?.start);
            break;
        },
    };
    try std.testing.expect(yields >= 5);
}
