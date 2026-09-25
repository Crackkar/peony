const std = @import("std");
const parser = @import("parser.zig");
const regex_vm = @import("vm.zig");

pub const Pattern = struct {
    allocator: std.mem.Allocator,
    source: []u8,
    program: parser.Program,

    pub fn compile(
        allocator: std.mem.Allocator,
        source: []const u8,
        mode: parser.Mode,
        flags: u32,
        limits: parser.Limits,
        diagnostic: *parser.Diagnostic,
    ) parser.CompileError!Pattern {
        const owned = allocator.dupe(u8, source) catch return error.OutOfMemory;
        errdefer allocator.free(owned);
        const program = try parser.compile(allocator, owned, mode, flags, limits, diagnostic);
        return .{ .allocator = allocator, .source = owned, .program = program };
    }

    pub fn deinit(self: *Pattern) void {
        self.program.deinit();
        self.allocator.free(self.source);
        self.* = undefined;
    }
};

pub const Scan = struct {
    next_position: usize,
    end_position: usize,
    suppress_empty_at: ?usize = null,
    done: bool = false,

    pub fn init(start: usize, end: usize) Scan {
        return .{ .next_position = @min(start, end), .end_position = end };
    }

    pub fn next(
        self: *Scan,
        allocator: std.mem.Allocator,
        pattern: *const Pattern,
        subject: []const u8,
        semantics: regex_vm.CharacterSemantics,
        budget: *regex_vm.WorkBudget,
    ) regex_vm.Error!?regex_vm.Match {
        if (self.done) return null;
        const found = try regex_vm.execute(allocator, &pattern.program, subject, .{
            .start = self.next_position,
            .end = self.end_position,
            .anchor = .search,
            .suppress_empty_at = self.suppress_empty_at,
        }, semantics, budget);
        if (found == null) {
            self.done = true;
            return null;
        }
        const span = found.?.span(0).?;
        if (span.start == span.end) {
            self.next_position = span.start;
            self.suppress_empty_at = span.start;
        } else {
            self.next_position = span.end;
            self.suppress_empty_at = null;
        }
        return found;
    }
};

pub const TemplateDiagnostic = struct {
    message: []const u8 = "invalid replacement template",
    position: usize = 0,
};

pub const TemplateError = error{ OutOfMemory, InvalidTemplate };

const LiteralPiece = struct { start: u32, length: u32 };
pub const Piece = union(enum) {
    literal: LiteralPiece,
    group: u16,
};

pub const Template = struct {
    allocator: std.mem.Allocator,
    literals: []u8,
    pieces: []Piece,

    pub fn parse(allocator: std.mem.Allocator, replacement: []const u8, program: *const parser.Program, diagnostic: *TemplateDiagnostic) TemplateError!Template {
        diagnostic.* = .{};
        var literals: std.ArrayList(u8) = .empty;
        defer literals.deinit(allocator);
        var pieces: std.ArrayList(Piece) = .empty;
        defer pieces.deinit(allocator);
        var literal_start: usize = 0;
        var index: usize = 0;
        while (index < replacement.len) {
            if (replacement[index] != '\\') {
                literals.append(allocator, replacement[index]) catch return error.OutOfMemory;
                index += 1;
                continue;
            }
            try flushLiteral(&pieces, allocator, literal_start, literals.items.len);
            literal_start = literals.items.len;
            const slash = index;
            index += 1;
            if (index >= replacement.len) return templateFail(diagnostic, "bad escape at end of replacement", slash);
            const escaped = replacement[index];
            index += 1;
            if (escaped >= '1' and escaped <= '9') {
                var group: u32 = escaped - '0';
                if (index < replacement.len and replacement[index] >= '0' and replacement[index] <= '9') {
                    group = group * 10 + replacement[index] - '0';
                    index += 1;
                }
                if (group > program.group_count) return templateFail(diagnostic, "invalid group reference", slash);
                pieces.append(allocator, .{ .group = @intCast(group) }) catch return error.OutOfMemory;
                continue;
            }
            if (escaped == 'g') {
                if (index >= replacement.len or replacement[index] != '<') return templateFail(diagnostic, "missing < in group reference", slash);
                index += 1;
                const name_start = index;
                while (index < replacement.len and replacement[index] != '>') index += 1;
                if (index >= replacement.len or index == name_start) return templateFail(diagnostic, "unterminated group reference", slash);
                const name = replacement[name_start..index];
                index += 1;
                const group = parseGroupReference(name, program) orelse return templateFail(diagnostic, "unknown group name", name_start);
                pieces.append(allocator, .{ .group = group }) catch return error.OutOfMemory;
                continue;
            }
            const literal: ?u8 = switch (escaped) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                'f' => 0x0c,
                'v' => 0x0b,
                'a' => 0x07,
                '\\' => '\\',
                else => null,
            };
            if (literal) |value| {
                literals.append(allocator, value) catch return error.OutOfMemory;
            } else if (isAsciiLetter(escaped)) {
                return templateFail(diagnostic, "bad escape in replacement", slash);
            } else {
                literals.append(allocator, '\\') catch return error.OutOfMemory;
                literals.append(allocator, escaped) catch return error.OutOfMemory;
            }
        }
        try flushLiteral(&pieces, allocator, literal_start, literals.items.len);
        const owned_literals = literals.toOwnedSlice(allocator) catch return error.OutOfMemory;
        errdefer allocator.free(owned_literals);
        const owned_pieces = pieces.toOwnedSlice(allocator) catch return error.OutOfMemory;
        return .{ .allocator = allocator, .literals = owned_literals, .pieces = owned_pieces };
    }

    pub fn deinit(self: *Template) void {
        self.allocator.free(self.literals);
        self.allocator.free(self.pieces);
        self.* = undefined;
    }

    pub fn expand(
        self: *const Template,
        allocator: std.mem.Allocator,
        output: *std.ArrayList(u8),
        subject: []const u8,
        mode: parser.Mode,
        match: *const regex_vm.Match,
    ) error{OutOfMemory}!void {
        for (self.pieces) |piece| switch (piece) {
            .literal => |literal| output.appendSlice(allocator, self.literals[literal.start..][0..literal.length]) catch return error.OutOfMemory,
            .group => |group| try appendCapture(allocator, output, subject, mode, match, group),
        };
    }

    pub fn expandDecoded(
        self: *const Template,
        allocator: std.mem.Allocator,
        output: *std.ArrayList(u8),
        subject: []const u8,
        decoded: *const regex_vm.DecodedSubject,
        match: *const regex_vm.Match,
    ) error{OutOfMemory}!void {
        for (self.pieces) |piece| switch (piece) {
            .literal => |literal| output.appendSlice(allocator, self.literals[literal.start..][0..literal.length]) catch return error.OutOfMemory,
            .group => |group| try appendCaptureDecoded(allocator, output, subject, decoded, match, group),
        };
    }
};

pub fn appendCapture(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    subject: []const u8,
    mode: parser.Mode,
    match: *const regex_vm.Match,
    group: usize,
) error{OutOfMemory}!void {
    const span = match.span(group) orelse return;
    const start = codepointByteOffset(subject, mode, span.start) orelse return;
    const end = codepointByteOffset(subject, mode, span.end) orelse return;
    output.appendSlice(allocator, subject[start..end]) catch return error.OutOfMemory;
}

pub fn captureSlice(subject: []const u8, mode: parser.Mode, match: *const regex_vm.Match, group: usize) ?[]const u8 {
    const span = match.span(group) orelse return null;
    const start = codepointByteOffset(subject, mode, span.start) orelse return null;
    const end = codepointByteOffset(subject, mode, span.end) orelse return null;
    return subject[start..end];
}

pub fn appendCaptureDecoded(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    subject: []const u8,
    decoded: *const regex_vm.DecodedSubject,
    match: *const regex_vm.Match,
    group: usize,
) error{OutOfMemory}!void {
    const slice = captureSliceDecoded(subject, decoded, match, group) orelse return;
    output.appendSlice(allocator, slice) catch return error.OutOfMemory;
}

pub fn captureSliceDecoded(subject: []const u8, decoded: *const regex_vm.DecodedSubject, match: *const regex_vm.Match, group: usize) ?[]const u8 {
    const span = match.span(group) orelse return null;
    return sliceDecoded(subject, decoded, span.start, span.end);
}

pub fn sliceDecoded(subject: []const u8, decoded: *const regex_vm.DecodedSubject, start: usize, end: usize) ?[]const u8 {
    const byte_start = decoded.byteOffset(start) orelse return null;
    const byte_end = decoded.byteOffset(end) orelse return null;
    if (byte_start > byte_end or byte_end > subject.len) return null;
    return subject[byte_start..byte_end];
}

pub fn codepointLength(subject: []const u8, mode: parser.Mode) ?usize {
    if (mode == .bytes) return subject.len;
    if (!std.unicode.utf8ValidateSlice(subject)) return null;
    var length: usize = 0;
    var index: usize = 0;
    while (index < subject.len) : (length += 1) {
        index += std.unicode.utf8ByteSequenceLength(subject[index]) catch return null;
    }
    return length;
}

pub fn codepointByteOffset(subject: []const u8, mode: parser.Mode, position: usize) ?usize {
    if (mode == .bytes) return if (position <= subject.len) position else null;
    var count: usize = 0;
    var index: usize = 0;
    while (count < position and index < subject.len) : (count += 1) {
        index += std.unicode.utf8ByteSequenceLength(subject[index]) catch return null;
    }
    return if (count == position) index else null;
}

pub fn escape(allocator: std.mem.Allocator, input: []const u8, mode: parser.Mode) error{ OutOfMemory, InvalidUtf8 }![]u8 {
    if (mode == .unicode and !std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    for (input) |byte| {
        if (shouldEscape(byte)) output.append(allocator, '\\') catch return error.OutOfMemory;
        output.append(allocator, byte) catch return error.OutOfMemory;
    }
    return output.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn flushLiteral(pieces: *std.ArrayList(Piece), allocator: std.mem.Allocator, start: usize, end: usize) TemplateError!void {
    if (end == start) return;
    if (start > std.math.maxInt(u32) or end - start > std.math.maxInt(u32)) return error.OutOfMemory;
    pieces.append(allocator, .{ .literal = .{ .start = @intCast(start), .length = @intCast(end - start) } }) catch return error.OutOfMemory;
}

fn parseGroupReference(name: []const u8, program: *const parser.Program) ?u16 {
    var numeric: u32 = 0;
    var digits = name.len != 0;
    for (name) |byte| {
        if (byte < '0' or byte > '9') {
            digits = false;
            break;
        }
        numeric = std.math.mul(u32, numeric, 10) catch return null;
        numeric = std.math.add(u32, numeric, byte - '0') catch return null;
    }
    if (digits) {
        if (numeric > program.group_count) return null;
        return @intCast(numeric);
    }
    return program.groupIndex(name);
}

fn templateFail(diagnostic: *TemplateDiagnostic, message: []const u8, position: usize) TemplateError {
    diagnostic.* = .{ .message = message, .position = position };
    return error.InvalidTemplate;
}

fn isAsciiLetter(value: u8) bool {
    return value >= 'a' and value <= 'z' or value >= 'A' and value <= 'Z';
}

fn shouldEscape(value: u8) bool {
    return switch (value) {
        '(',
        ')',
        '[',
        ']',
        '{',
        '}',
        '?',
        '*',
        '+',
        '-',
        '|',
        '^',
        '$',
        '\\',
        '.',
        '&',
        '~',
        '#',
        ' ',
        '\t',
        '\n',
        '\r',
        0x0b,
        0x0c,
        => true,
        else => false,
    };
}

test "regex scan keeps the nonempty alternative after an empty match" {
    var diagnostic = parser.Diagnostic{};
    var pattern = try Pattern.compile(std.testing.allocator, "|a", .unicode, 0, .{}, &diagnostic);
    defer pattern.deinit();
    var scan = Scan.init(0, 1);
    var budget = regex_vm.WorkBudget{};
    var first = (try scan.next(std.testing.allocator, &pattern, "a", .{}, &budget)).?;
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 0), first.span(0).?.end);
    var second = (try scan.next(std.testing.allocator, &pattern, "a", .{}, &budget)).?;
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 1), second.span(0).?.end);
    var third = (try scan.next(std.testing.allocator, &pattern, "a", .{}, &budget)).?;
    defer third.deinit();
    try std.testing.expectEqual(@as(usize, 1), third.span(0).?.start);
    try std.testing.expect((try scan.next(std.testing.allocator, &pattern, "a", .{}, &budget)) == null);
}

test "replacement templates expand numbered and named captures" {
    var diagnostic = parser.Diagnostic{};
    var pattern = try Pattern.compile(std.testing.allocator, "(?P<x>a)", .unicode, 0, .{}, &diagnostic);
    defer pattern.deinit();
    var budget = regex_vm.WorkBudget{};
    var found = (try regex_vm.execute(std.testing.allocator, &pattern.program, "a", .{}, .{}, &budget)).?;
    defer found.deinit();
    var template_diagnostic = TemplateDiagnostic{};
    var template = try Template.parse(std.testing.allocator, "[\\g<x>]-\\1", &pattern.program, &template_diagnostic);
    defer template.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try template.expand(std.testing.allocator, &output, "a", .unicode, &found);
    try std.testing.expectEqualStrings("[a]-a", output.items);

    const escaped = try escape(std.testing.allocator, "a.b-c_ /", .unicode);
    defer std.testing.allocator.free(escaped);
    try std.testing.expectEqualStrings("a\\.b\\-c_\\ /", escaped);
}
