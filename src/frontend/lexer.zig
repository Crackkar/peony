const std = @import("std");
const token_module = @import("frontend_token");

pub const Token = token_module.Token;
pub const TokenKind = token_module.Kind;

pub const DiagnosticKind = enum {
    syntax_error,
    indentation_error,
    tab_error,
};

pub const Diagnostic = struct {
    kind: DiagnosticKind,
    message: []const u8,
    start: usize,
    end: usize,
    line: usize,
    column: usize,
};

pub const TokenizeResult = union(enum) {
    tokens: []Token,
    failure: Diagnostic,
};

const Indentation = struct { width: usize, alternate: usize };
const Bracket = struct { opening: u8, start: usize, line: usize, column: usize };
const LineStartResult = union(enum) { scanned, skipped, failure: Diagnostic };

pub fn tokenize(allocator: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error!TokenizeResult {
    if (encodingDiagnostic(source)) |diagnostic| return .{ .failure = diagnostic };

    const bom_len: usize = if (std.mem.startsWith(u8, source, "\xef\xbb\xbf")) 3 else 0;
    if (!std.unicode.utf8ValidateSlice(source[bom_len..])) {
        const bad = firstInvalidUtf8(source[bom_len..]) + bom_len;
        const pos = sourcePosition(source, bad);
        return .{ .failure = .{
            .kind = .syntax_error,
            .message = "source must be valid UTF-8",
            .start = bad,
            .end = @min(source.len, bad + 1),
            .line = pos.line,
            .column = pos.column,
        } };
    }

    var lexer = Lexer.init(allocator, source, bom_len);
    return lexer.run();
}

const Lexer = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: std.ArrayList(Token) = .empty,
    indentation: std.ArrayList(Indentation) = .empty,
    brackets: std.ArrayList(Bracket) = .empty,
    pos: usize,
    line: usize = 1,
    column: usize = 1,
    at_line_start: bool = true,
    joined_line: bool = false,
    logical_has_code: bool = false,

    fn init(allocator: std.mem.Allocator, source: []const u8, initial_pos: usize) Lexer {
        return .{
            .allocator = allocator,
            .source = source,
            .pos = initial_pos,
            .indentation = .empty,
            .brackets = .empty,
        };
    }

    fn run(self: *Lexer) std.mem.Allocator.Error!TokenizeResult {
        defer self.tokens.deinit(self.allocator);
        defer self.indentation.deinit(self.allocator);
        defer self.brackets.deinit(self.allocator);
        try self.indentation.append(self.allocator, .{ .width = 0, .alternate = 0 });

        while (self.pos < self.source.len) {
            if (self.at_line_start) {
                switch (try self.startPhysicalLine()) {
                    .scanned => {},
                    .skipped => continue,
                    .failure => |diagnostic| return .{ .failure = diagnostic },
                }
            }
            if (self.pos >= self.source.len) break;

            const c = self.source[self.pos];
            if (c == '\n' or c == '\r') {
                try self.consumeNewline(false);
                continue;
            }
            if (c == ' ' or c == '\t' or c == '\x0c') {
                self.advanceWhitespace(c);
                continue;
            }
            if (c == '#') {
                while (self.pos < self.source.len and self.source[self.pos] != '\n' and self.source[self.pos] != '\r') self.advanceCodepoint();
                continue;
            }
            if (c == '\\') {
                const next = self.pos + 1;
                if (next < self.source.len and (self.source[next] == '\n' or self.source[next] == '\r')) {
                    self.advanceAscii();
                    try self.consumeNewline(true);
                    continue;
                }
                return self.failure(.syntax_error, "unexpected character after line continuation character", self.pos, self.pos + 1, self.line, self.column);
            }
            if (c == '\'' or c == '"') {
                if (try self.scanString(0)) |diagnostic| return .{ .failure = diagnostic };
                continue;
            }
            if (isDigit(c)) {
                if (try self.scanNumber(false)) |diagnostic| return .{ .failure = diagnostic };
                continue;
            }
            if (c == '.' and self.pos + 1 < self.source.len and isDigit(self.source[self.pos + 1])) {
                if (try self.scanNumber(true)) |diagnostic| return .{ .failure = diagnostic };
                continue;
            }
            if (isIdentifierStart(c)) {
                if (try self.scanIdentifierOrString()) |diagnostic| return .{ .failure = diagnostic };
                continue;
            }
            if (c >= 0x80) {
                return self.failure(.syntax_error, "non-ASCII identifier characters are not supported", self.pos, self.pos + utf8Len(c), self.line, self.column);
            }
            if ((c == ':' and std.mem.startsWith(u8, self.source[self.pos..], ":=")) or
                (c == '!' and std.mem.startsWith(u8, self.source[self.pos..], "!=")))
            {
                const start = self.pos;
                const line = self.line;
                const column = self.column;
                self.advanceAsciiN(2);
                try self.addToken(.operator, start, self.pos, line, column);
                self.logical_has_code = true;
                continue;
            }
            if (isOpening(c)) {
                const start = self.pos;
                const line = self.line;
                const column = self.column;
                try self.brackets.append(self.allocator, .{ .opening = c, .start = start, .line = line, .column = column });
                self.advanceAscii();
                try self.addToken(.delimiter, start, self.pos, line, column);
                self.logical_has_code = true;
                continue;
            }
            if (isClosing(c)) {
                const start = self.pos;
                const line = self.line;
                const column = self.column;
                if (self.brackets.items.len == 0) return self.failure(.syntax_error, "unmatched closing delimiter", start, start + 1, line, column);
                const opening = self.brackets.items[self.brackets.items.len - 1];
                if (!bracketsMatch(opening.opening, c)) return self.failure(.syntax_error, "closing delimiter does not match opening delimiter", start, start + 1, line, column);
                _ = self.brackets.pop();
                self.advanceAscii();
                try self.addToken(.delimiter, start, self.pos, line, column);
                self.logical_has_code = true;
                continue;
            }
            if (isDelimiter(c)) {
                const start = self.pos;
                const line = self.line;
                const column = self.column;
                if (c == '.' and std.mem.startsWith(u8, self.source[self.pos..], "...")) {
                    self.advanceAsciiN(3);
                    try self.addToken(.operator, start, self.pos, line, column);
                    self.logical_has_code = true;
                    continue;
                }
                self.advanceAscii();
                try self.addToken(.delimiter, start, self.pos, line, column);
                self.logical_has_code = true;
                continue;
            }
            if (isOperatorStart(c)) {
                const start = self.pos;
                const line = self.line;
                const column = self.column;
                const length = operatorLength(self.source[self.pos..]);
                self.advanceAsciiN(length);
                try self.addToken(.operator, start, self.pos, line, column);
                self.logical_has_code = true;
                continue;
            }
            return self.failure(.syntax_error, "invalid character in source", self.pos, self.pos + 1, self.line, self.column);
        }

        if (self.brackets.items.len != 0) {
            const opener = self.brackets.items[self.brackets.items.len - 1];
            return self.failure(.syntax_error, "opening delimiter was never closed", opener.start, opener.start + 1, opener.line, opener.column);
        }
        if (self.logical_has_code) try self.addToken(.newline, self.pos, self.pos, self.line, self.column);
        while (self.indentation.items.len > 1) {
            _ = self.indentation.pop();
            try self.addToken(.dedent, self.pos, self.pos, self.line, self.column);
        }
        try self.addToken(.endmarker, self.pos, self.pos, self.line, self.column);
        return .{ .tokens = try self.tokens.toOwnedSlice(self.allocator) };
    }

    fn startPhysicalLine(self: *Lexer) std.mem.Allocator.Error!LineStartResult {
        const indentation_start = self.pos;
        const indentation_column = self.column;
        var width: usize = 0;
        var alternate: usize = 0;
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == ' ') {
                width += 1;
                alternate += 1;
                self.advanceWhitespace(c);
            } else if (c == '\t') {
                width += 8 - (width % 8);
                alternate += 1;
                self.advanceWhitespace(c);
            } else if (c == '\x0c') {
                width = 0;
                alternate = 0;
                self.advanceWhitespace(c);
            } else break;
        }

        if (self.pos == self.source.len or self.source[self.pos] == '\n' or self.source[self.pos] == '\r' or self.source[self.pos] == '#') {
            if (self.pos < self.source.len and self.source[self.pos] == '#') {
                while (self.pos < self.source.len and self.source[self.pos] != '\n' and self.source[self.pos] != '\r') self.advanceCodepoint();
            }
            if (self.pos < self.source.len) try self.consumeNewline(false);
            self.at_line_start = true;
            return .skipped;
        }

        const ignore_indent = self.brackets.items.len != 0 or self.joined_line;
        self.joined_line = false;
        self.at_line_start = false;
        if (ignore_indent) return .scanned;

        const top = self.indentation.items[self.indentation.items.len - 1];
        if (width > top.width) {
            if (alternate <= top.alternate) return .{ .failure = .{ .kind = .tab_error, .message = "inconsistent use of tabs and spaces in indentation", .start = indentation_start, .end = self.pos, .line = self.line, .column = indentation_column } };
            try self.indentation.append(self.allocator, .{ .width = width, .alternate = alternate });
            try self.addToken(.indent, indentation_start, self.pos, self.line, indentation_column);
        } else if (width == top.width) {
            if (alternate != top.alternate) return .{ .failure = .{ .kind = .tab_error, .message = "inconsistent use of tabs and spaces in indentation", .start = indentation_start, .end = self.pos, .line = self.line, .column = indentation_column } };
        } else {
            var matching: ?usize = null;
            for (self.indentation.items, 0..) |level, index| {
                if (level.width == width) matching = index;
            }
            if (matching == null) return .{ .failure = .{ .kind = .indentation_error, .message = "unindent does not match any outer indentation level", .start = indentation_start, .end = self.pos, .line = self.line, .column = indentation_column } };
            const match_index = matching.?;
            if (self.indentation.items[match_index].alternate != alternate) return .{ .failure = .{ .kind = .tab_error, .message = "inconsistent use of tabs and spaces in indentation", .start = indentation_start, .end = self.pos, .line = self.line, .column = indentation_column } };
            while (self.indentation.items.len - 1 > match_index) {
                _ = self.indentation.pop();
                try self.addToken(.dedent, self.pos, self.pos, self.line, self.column);
            }
        }
        return .scanned;
    }

    fn scanIdentifierOrString(self: *Lexer) std.mem.Allocator.Error!?Diagnostic {
        const start = self.pos;
        const start_line = self.line;
        const start_column = self.column;
        var end = self.pos;
        while (end < self.source.len and isIdentifierContinue(self.source[end])) : (end += 1) {}
        const length = end - start;
        if (length <= 2 and end < self.source.len and (self.source[end] == '\'' or self.source[end] == '"')) {
            const prefix = self.source[start..end];
            const category = stringPrefixCategory(prefix) orelse return self.makeDiagnostic(.syntax_error, "invalid string prefix", start, end + 1, start_line, start_column);
            if (try self.scanString(end - start)) |diagnostic| return diagnostic;
            _ = category;
            return null;
        }
        if (end < self.source.len and self.source[end] >= 0x80) return self.makeDiagnostic(.syntax_error, "non-ASCII identifier characters are not supported", end, end + utf8Len(self.source[end]), start_line, start_column + length);
        while (self.pos < end) self.advanceAscii();
        try self.addToken(.identifier, start, self.pos, start_line, start_column);
        self.logical_has_code = true;
        return null;
    }

    fn scanString(self: *Lexer, prefix_len: usize) std.mem.Allocator.Error!?Diagnostic {
        const start = self.pos;
        const start_line = self.line;
        const start_column = self.column;
        const quote_pos = start + prefix_len;
        const quote = self.source[quote_pos];
        const prefix = self.source[start..quote_pos];
        const category = stringPrefixCategory(prefix) orelse return self.makeDiagnostic(.syntax_error, "invalid string prefix", start, quote_pos + 1, start_line, start_column);
        const triple = quote_pos + 2 < self.source.len and self.source[quote_pos + 1] == quote and self.source[quote_pos + 2] == quote;
        while (self.pos < quote_pos) self.advanceAscii();
        const delim_len: usize = if (triple) 3 else 1;
        self.advanceAsciiN(delim_len);
        var escaped = false;
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '\n' or c == '\r') {
                if (!triple and !escaped) return self.makeDiagnostic(.syntax_error, "unterminated string literal", start, self.pos, start_line, start_column);
                if (triple and !escaped) {
                    self.advanceStringNewline();
                    escaped = false;
                    continue;
                }
                self.advanceStringNewline();
                escaped = false;
                continue;
            }
            if (category == .bytes and c >= 0x80) return self.makeDiagnostic(.syntax_error, "bytes literals may contain only ASCII source characters", self.pos, self.pos + utf8Len(c), self.line, self.column);
            if (escaped) {
                escaped = false;
                self.advanceCodepoint();
                continue;
            }
            if (c == '\\') {
                escaped = true;
                self.advanceAscii();
                continue;
            }
            if (c == quote) {
                if (!triple) {
                    self.advanceAscii();
                    try self.addToken(category, start, self.pos, start_line, start_column);
                    self.logical_has_code = true;
                    return null;
                }
                if (self.pos + 2 < self.source.len and self.source[self.pos + 1] == quote and self.source[self.pos + 2] == quote) {
                    self.advanceAsciiN(3);
                    try self.addToken(category, start, self.pos, start_line, start_column);
                    self.logical_has_code = true;
                    return null;
                }
            }
            self.advanceCodepoint();
        }
        return self.makeDiagnostic(.syntax_error, "unterminated string literal", start, self.pos, start_line, start_column);
    }

    fn scanNumber(self: *Lexer, leading_dot: bool) std.mem.Allocator.Error!?Diagnostic {
        const start = self.pos;
        const start_line = self.line;
        const start_column = self.column;
        var is_float = leading_dot;
        var decimal_leading_zero = false;
        if (leading_dot) {
            self.advanceAscii();
            if (!self.scanDigitSequence(10, false)) return self.makeDiagnostic(.syntax_error, "invalid numeric literal", start, self.pos, start_line, start_column);
        } else if (self.pos + 1 < self.source.len and self.source[self.pos] == '0' and isBasePrefix(self.source[self.pos + 1])) {
            const base = baseForPrefix(self.source[self.pos + 1]);
            self.advanceAsciiN(2);
            if (!self.scanDigitSequence(base, true)) return self.makeDiagnostic(.syntax_error, "invalid numeric literal", start, self.pos, start_line, start_column);
            if (self.pos < self.source.len and (self.source[self.pos] == 'j' or self.source[self.pos] == 'J')) return self.makeDiagnostic(.syntax_error, "complex literals are not supported", start, self.pos + 1, start_line, start_column);
            if (self.pos < self.source.len and (isIdentifierContinue(self.source[self.pos]) or self.source[self.pos] == '_')) return self.makeDiagnostic(.syntax_error, "invalid numeric literal", start, self.pos + 1, start_line, start_column);
            try self.addToken(.integer, start, self.pos, start_line, start_column);
            self.logical_has_code = true;
            return null;
        } else {
            const first_digit = self.source[self.pos];
            decimal_leading_zero = first_digit == '0';
            if (!self.scanDigitSequence(10, false)) return self.makeDiagnostic(.syntax_error, "invalid numeric literal", start, self.pos, start_line, start_column);
            if (self.pos < self.source.len and self.source[self.pos] == '.' and !(self.pos + 1 < self.source.len and self.source[self.pos + 1] == '.')) {
                is_float = true;
                self.advanceAscii();
                if (self.pos < self.source.len and self.source[self.pos] == '_') return self.makeDiagnostic(.syntax_error, "invalid numeric literal", start, self.pos + 1, start_line, start_column);
                if (self.pos < self.source.len and isDigit(self.source[self.pos])) {
                    if (!self.scanDigitSequence(10, false)) return self.makeDiagnostic(.syntax_error, "invalid numeric literal", start, self.pos, start_line, start_column);
                }
            }
            if (self.pos < self.source.len and (self.source[self.pos] == 'e' or self.source[self.pos] == 'E')) {
                is_float = true;
                self.advanceAscii();
                if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) self.advanceAscii();
                if (!self.scanDigitSequence(10, false)) return self.makeDiagnostic(.syntax_error, "invalid numeric literal", start, self.pos, start_line, start_column);
            }
        }
        if (decimal_leading_zero and !is_float) {
            for (self.source[start..self.pos]) |digit| {
                if (isDigit(digit) and digit != '0') return self.makeDiagnostic(.syntax_error, "leading zeros in decimal integer literals are not permitted", start, self.pos, start_line, start_column);
            }
        }
        if (self.pos < self.source.len and (self.source[self.pos] == 'j' or self.source[self.pos] == 'J')) return self.makeDiagnostic(.syntax_error, "complex literals are not supported", start, self.pos + 1, start_line, start_column);
        if (self.pos < self.source.len and self.source[self.pos] == '_') return self.makeDiagnostic(.syntax_error, "invalid numeric literal", start, self.pos + 1, start_line, start_column);
        try self.addToken(if (is_float) .float else .integer, start, self.pos, start_line, start_column);
        self.logical_has_code = true;
        return null;
    }

    fn scanDigitSequence(self: *Lexer, base: u8, allow_leading_underscore: bool) bool {
        var saw_digit = false;
        var previous_digit = false;
        if (allow_leading_underscore and self.pos < self.source.len and self.source[self.pos] == '_') {
            if (self.pos + 1 >= self.source.len) return false;
            const first = digitValue(self.source[self.pos + 1]) orelse return false;
            if (first >= base) return false;
            self.advanceAscii();
        }
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (digitValue(c)) |digit| {
                if (digit >= base) break;
                saw_digit = true;
                previous_digit = true;
                self.advanceAscii();
            } else if (c == '_') {
                if (!previous_digit or self.pos + 1 >= self.source.len) return false;
                const next = digitValue(self.source[self.pos + 1]) orelse return false;
                if (next >= base) return false;
                previous_digit = false;
                self.advanceAscii();
            } else break;
        }
        return saw_digit and previous_digit;
    }

    fn consumeNewline(self: *Lexer, explicit_join: bool) std.mem.Allocator.Error!void {
        const start = self.pos;
        const line = self.line;
        const column = self.column;
        const width: usize = if (self.source[self.pos] == '\r' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '\n') 2 else 1;
        const should_emit = !explicit_join and self.brackets.items.len == 0 and self.logical_has_code;
        self.pos += width;
        self.line += 1;
        self.column = 1;
        self.at_line_start = true;
        self.joined_line = explicit_join;
        if (should_emit) {
            try self.addToken(.newline, start, self.pos, line, column);
            self.logical_has_code = false;
        }
    }

    fn advanceStringNewline(self: *Lexer) void {
        if (self.source[self.pos] == '\r' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '\n') {
            self.pos += 2;
        } else self.pos += 1;
        self.line += 1;
        self.column = 1;
        self.at_line_start = false;
    }

    fn advanceWhitespace(self: *Lexer, c: u8) void {
        if (c == '\t') {
            self.column = ((self.column - 1) / 8 + 1) * 8 + 1;
        } else if (c == '\x0c') {
            self.column = 1;
        } else self.column += 1;
        self.pos += 1;
    }

    fn advanceAscii(self: *Lexer) void {
        self.pos += 1;
        self.column += 1;
    }

    fn advanceAsciiN(self: *Lexer, count: usize) void {
        self.pos += count;
        self.column += count;
    }

    fn advanceCodepoint(self: *Lexer) void {
        const length = utf8Len(self.source[self.pos]);
        self.pos += length;
        self.column += 1;
    }

    fn addToken(self: *Lexer, kind: TokenKind, start: usize, end: usize, line: usize, column: usize) std.mem.Allocator.Error!void {
        try self.tokens.append(self.allocator, .{ .kind = kind, .start = start, .end = end, .line = line, .column = column });
    }

    fn failure(self: *Lexer, kind: DiagnosticKind, message: []const u8, start: usize, end: usize, line: usize, column: usize) TokenizeResult {
        return .{ .failure = self.makeDiagnostic(kind, message, start, end, line, column) };
    }

    fn makeDiagnostic(self: *Lexer, kind: DiagnosticKind, message: []const u8, start: usize, end: usize, line: usize, column: usize) Diagnostic {
        _ = self;
        return .{ .kind = kind, .message = message, .start = start, .end = end, .line = line, .column = column };
    }

};

fn stringPrefixCategory(prefix: []const u8) ?TokenKind {
    var lower: [2]u8 = undefined;
    if (prefix.len > lower.len) return null;
    for (prefix, 0..) |c, index| lower[index] = std.ascii.toLower(c);
    const normalized = lower[0..prefix.len];
    if (normalized.len == 0 or std.mem.eql(u8, normalized, "r") or std.mem.eql(u8, normalized, "u")) return .string;
    if (std.mem.eql(u8, normalized, "b") or std.mem.eql(u8, normalized, "br") or std.mem.eql(u8, normalized, "rb")) return .bytes;
    if (std.mem.eql(u8, normalized, "f") or std.mem.eql(u8, normalized, "fr") or std.mem.eql(u8, normalized, "rf")) return .formatted_string;
    return null;
}

fn encodingDiagnostic(source: []const u8) ?Diagnostic {
    var pos: usize = if (std.mem.startsWith(u8, source, "\xef\xbb\xbf")) 3 else 0;
    var line: usize = 1;
    var second_line_allowed = true;
    while (line <= 2 and pos <= source.len) : (line += 1) {
        const start = pos;
        while (pos < source.len and source[pos] != '\n' and source[pos] != '\r') pos += 1;
        const content = source[start..pos];
        const trimmed = std.mem.trimStart(u8, content, " \t\x0c");
        const is_comment_or_blank = trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#");
        if (line == 2 and !second_line_allowed) break;
        if (std.mem.startsWith(u8, trimmed, "#")) {
            if (std.mem.indexOf(u8, trimmed, "coding")) |coding_at| {
                var cursor = coding_at + "coding".len;
                while (cursor < trimmed.len and (trimmed[cursor] == ' ' or trimmed[cursor] == '\t')) cursor += 1;
                if (cursor < trimmed.len and (trimmed[cursor] == ':' or trimmed[cursor] == '=')) {
                    cursor += 1;
                    while (cursor < trimmed.len and (trimmed[cursor] == ' ' or trimmed[cursor] == '\t')) cursor += 1;
                    const name_start = cursor;
                    while (cursor < trimmed.len and isEncodingNameChar(trimmed[cursor])) cursor += 1;
                    if (name_start == cursor or !isUtf8Cookie(trimmed[name_start..cursor])) {
                        return .{ .kind = .syntax_error, .message = "only UTF-8 source encodings are supported", .start = start, .end = pos, .line = line, .column = 1 };
                    }
                }
            }
        }
        if (line == 1) second_line_allowed = is_comment_or_blank;
        if (pos < source.len and source[pos] == '\r' and pos + 1 < source.len and source[pos + 1] == '\n') pos += 2 else if (pos < source.len) pos += 1;
    }
    return null;
}

fn isEncodingNameChar(c: u8) bool {
    return isIdentifierContinue(c) or c == '-' or c == '.';
}

fn isUtf8Cookie(name: []const u8) bool {
    var normalized: [32]u8 = undefined;
    var length: usize = 0;
    for (name) |c| {
        if (c == '-' or c == '_' or c == '.') continue;
        if (length == normalized.len) return false;
        normalized[length] = std.ascii.toLower(c);
        length += 1;
    }
    const value = normalized[0..length];
    return std.mem.eql(u8, value, "utf8") or std.mem.eql(u8, value, "utf8sig");
}

fn sourcePosition(source: []const u8, end: usize) struct { line: usize, column: usize } {
    var line: usize = 1;
    var column: usize = 1;
    var i: usize = if (std.mem.startsWith(u8, source, "\xef\xbb\xbf")) 3 else 0;
    while (i < end and i < source.len) {
        const c = source[i];
        if (c == '\r') {
            if (i + 1 < end and source[i + 1] == '\n') i += 1;
            line += 1;
            column = 1;
            i += 1;
        } else if (c == '\n') {
            line += 1;
            column = 1;
            i += 1;
        } else if (c == '\t') {
            column = ((column - 1) / 8 + 1) * 8 + 1;
            i += 1;
        } else {
            const len = utf8Len(c);
            i += @min(len, source.len - i);
            column += 1;
        }
    }
    return .{ .line = line, .column = column };
}

fn firstInvalidUtf8(source: []const u8) usize {
    var i: usize = 0;
    while (i < source.len) {
        const len = utf8Len(source[i]);
        if (len == 0 or i + len > source.len or !std.unicode.utf8ValidateSlice(source[i .. i + len])) return i;
        i += len;
    }
    return 0;
}

fn utf8Len(c: u8) usize {
    if (c <= 0x7f) return 1;
    if (c >= 0xc2 and c <= 0xdf) return 2;
    if (c >= 0xe0 and c <= 0xef) return 3;
    if (c >= 0xf0 and c <= 0xf4) return 4;
    return 1;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn digitValue(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

fn isBasePrefix(c: u8) bool {
    return c == 'x' or c == 'X' or c == 'o' or c == 'O' or c == 'b' or c == 'B';
}

fn baseForPrefix(c: u8) u8 {
    return switch (c) {
        'x', 'X' => 16,
        'o', 'O' => 8,
        else => 2,
    };
}

fn isIdentifierStart(c: u8) bool {
    return c == '_' or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn isIdentifierContinue(c: u8) bool {
    return isIdentifierStart(c) or isDigit(c);
}

fn isOpening(c: u8) bool {
    return c == '(' or c == '[' or c == '{';
}

fn isClosing(c: u8) bool {
    return c == ')' or c == ']' or c == '}';
}

fn bracketsMatch(opening: u8, closing: u8) bool {
    return (opening == '(' and closing == ')') or (opening == '[' and closing == ']') or (opening == '{' and closing == '}');
}

fn isDelimiter(c: u8) bool {
    return c == ',' or c == ':' or c == ';' or c == '.';
}

fn isOperatorStart(c: u8) bool {
    return std.mem.indexOfScalar(u8, "+-*/%@&|^~<>=", c) != null;
}

fn operatorLength(source: []const u8) usize {
    const operators = [_][]const u8{ "**=", "//=", "<<=", ">>=", "...", ":=", "==", "!=", "<=", ">=", "->", "+=", "-=", "*=", "/=", "%=", "@=", "&=", "|=", "^=", "**", "//", "<<", ">>" };
    for (operators) |op| if (std.mem.startsWith(u8, source, op)) return op.len;
    return 1;
}
