const std = @import("std");
const lexer = @import("frontend_lexer");
const tokens = @import("frontend_token");

const Token = tokens.Token;
const Kind = tokens.Kind;

pub fn testTokenSpans() !void {
    const source = "if x:\n    print(1)\n";
    const result = try expectTokens(std.testing.allocator, source);
    defer std.testing.allocator.free(result);

    const expected = [_]Kind{
        .identifier, .identifier, .delimiter, .newline, .indent,
        .identifier, .delimiter, .integer, .delimiter, .newline,
        .dedent, .endmarker,
    };
    try std.testing.expectEqual(expected.len, result.len);
    for (expected, result) |kind, token| try std.testing.expectEqual(kind, token.kind);
    try expectToken(source, result[0], .identifier, "if", 0, 2, 1, 1);
    try expectToken(source, result[1], .identifier, "x", 3, 4, 1, 4);
    try expectToken(source, result[2], .delimiter, ":", 4, 5, 1, 5);
    try expectToken(source, result[4], .indent, "    ", 6, 10, 2, 1);
    try expectToken(source, result[5], .identifier, "print", 10, 15, 2, 5);
    try expectToken(source, result[7], .integer, "1", 16, 17, 2, 11);
    try std.testing.expectEqual(source.len, result[result.len - 1].start);
    try std.testing.expectEqual(@as(usize, 3), result[result.len - 1].line);
}

pub fn testNewlineForms() !void {
    const sources = [_][]const u8{
        "x=1\ny=2\n",
        "x=1\r\ny=2\r\n",
        "x=1\ry=2\r",
    };
    for (sources) |source| {
        const result = try expectTokens(std.testing.allocator, source);
        defer std.testing.allocator.free(result);
        var newline_count: usize = 0;
        var y_token: ?Token = null;
        for (result) |token| {
            if (token.kind == .newline) newline_count += 1;
            if (std.mem.eql(u8, source[token.start..token.end], "y")) y_token = token;
        }
        try std.testing.expectEqual(@as(usize, 2), newline_count);
        try std.testing.expect(y_token != null);
        try std.testing.expectEqual(@as(usize, 2), y_token.?.line);
        try std.testing.expectEqual(@as(usize, 1), y_token.?.column);
    }
}

pub fn testCommentsAndSemicolons() !void {
    const source = "# heading\n\n  # blank comment\nx=1; y=2 # tail\n";
    const result = try expectTokens(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 1), countKind(result, .newline));
    try std.testing.expectEqual(@as(usize, 1), countLexeme(source, result, ";"));
    try std.testing.expectEqual(@as(usize, 0), countKind(result, .indent));
    try std.testing.expectEqual(@as(usize, 0), countLexeme(source, result, "#"));
}

pub fn testIndentationAndTabError() !void {
    const source = "if x:\n\tpass\n";
    const result = try expectTokens(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    const indent = findKind(result, .indent).?;
    const pass = findLexeme(source, result, "pass").?;
    try std.testing.expectEqual(@as(usize, 2), indent.line);
    try std.testing.expectEqual(@as(usize, 2), pass.line);
    try std.testing.expectEqual(@as(usize, 9), pass.column);

    const mixed = "if x:\n \tpass\n        pass\n";
    const error_result = try lexer.tokenize(std.testing.allocator, mixed);
    try std.testing.expect(error_result == .failure);
    const diagnostic = error_result.failure;
    try std.testing.expectEqual(lexer.DiagnosticKind.tab_error, diagnostic.kind);
    try std.testing.expectEqual(@as(usize, 3), diagnostic.line);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "tab") != null);
}

pub fn testUnmatchedDedent() !void {
    const source = "if x:\n    pass\n  pass\n";
    const result = try lexer.tokenize(std.testing.allocator, source);
    try std.testing.expect(result == .failure);
    try std.testing.expectEqual(lexer.DiagnosticKind.indentation_error, result.failure.kind);
    try std.testing.expectEqual(@as(usize, 3), result.failure.line);
    try std.testing.expect(std.mem.indexOf(u8, result.failure.message, "unindent") != null);
}

pub fn testContinuations() !void {
    const source = "x = (1 +\n  2)\ny = 3 \\\n + 4\n";
    const result = try expectTokens(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 2), countKind(result, .newline));
    const plus_tokens = countLexeme(source, result, "+");
    try std.testing.expectEqual(@as(usize, 2), plus_tokens);
    try std.testing.expect(findLexeme(source, result, "2").?.line == 2);
    try std.testing.expect(findLexeme(source, result, "4").?.line == 4);
}

pub fn testNumbers() !void {
    const source = "a=0xff+0o17+0b10\nb=1_000.5e-2\n";
    const result = try expectTokens(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 3), countKind(result, .integer));
    try std.testing.expectEqual(@as(usize, 1), countKind(result, .float));
    try std.testing.expect(findLexeme(source, result, "0xff") != null);
    try std.testing.expect(findLexeme(source, result, "1_000.5e-2") != null);

    const underscore_edges = try expectTokens(std.testing.allocator, "a=0x_FF; b=0b_101; c=00; d=0_0; e=00.5\n");
    defer std.testing.allocator.free(underscore_edges);
    try std.testing.expectEqual(@as(usize, 4), countKind(underscore_edges, .integer));
    try std.testing.expectEqual(@as(usize, 1), countKind(underscore_edges, .float));
    const edge_numbers = try expectTokens(std.testing.allocator, "x=.5; y=1.; z=1e2\n");
    defer std.testing.allocator.free(edge_numbers);
    try std.testing.expectEqual(@as(usize, 3), countKind(edge_numbers, .float));
    const ellipsis_tokens = try expectTokens(std.testing.allocator, "x=...\n");
    defer std.testing.allocator.free(ellipsis_tokens);
    try std.testing.expect(findLexeme("x=...\n", ellipsis_tokens, "...") != null);

    try expectDiagnostic("x=0x\n", .syntax_error, "numeric");
    try expectDiagnostic("x=1__2\n", .syntax_error, "numeric");
    try expectDiagnostic("x=012\n", .syntax_error, "leading zeros");
    try expectDiagnostic("x=0_1\n", .syntax_error, "leading zeros");
    try expectDiagnostic("x=2j\n", .syntax_error, "complex");
}

pub fn testOperators() !void {
    const source = "x := 1; y != 2\n";
    const result = try expectTokens(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    const walrus = findLexeme(source, result, ":=").?;
    const inequality = findLexeme(source, result, "!=").?;
    try std.testing.expectEqual(Kind.operator, walrus.kind);
    try std.testing.expectEqual(Kind.operator, inequality.kind);
}

pub fn testStringLiterals() !void {
    const source = "a=r'raw\\n'; b=br\"\\x41\"; c=F\"\"\"say {name}\"\"\"; d='''multi\nline'''\n";
    const result = try expectTokens(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 2), countKind(result, .string));
    try std.testing.expectEqual(@as(usize, 1), countKind(result, .bytes));
    try std.testing.expectEqual(@as(usize, 1), countKind(result, .formatted_string));
    try std.testing.expect(findLexeme(source, result, "r'raw\\n'") != null);
    try std.testing.expect(findLexeme(source, result, "br\"\\x41\"") != null);
    try std.testing.expectEqual(@as(usize, 1), findLexeme(source, result, "d").?.line);

    try expectDiagnostic("x='unfinished\n", .syntax_error, "unterminated string");
    try expectDiagnostic("x=bf'nope'\n", .syntax_error, "prefix");
    try expectDiagnostic("x=b'\u{00e9}'\n", .syntax_error, "ASCII");
}

pub fn testEncodingCookies() !void {
    const bom_cookie = "\xef\xbb\xbf# coding: utf-8\r\nx=1\r\n";
    const bom_tokens = try expectTokens(std.testing.allocator, bom_cookie);
    defer std.testing.allocator.free(bom_tokens);
    try std.testing.expectEqual(@as(usize, 2), findLexeme(bom_cookie, bom_tokens, "x").?.line);

    const sig = "# -*- coding: utf_8_sig -*-\nx=1\n";
    const sig_tokens = try expectTokens(std.testing.allocator, sig);
    defer std.testing.allocator.free(sig_tokens);

    try expectDiagnostic("# coding: latin-1\nx=1\n", .syntax_error, "encoding");
    const late_cookie = "x=1\n# coding: latin-1\ny=2\n";
    const late_cookie_tokens = try expectTokens(std.testing.allocator, late_cookie);
    defer std.testing.allocator.free(late_cookie_tokens);
    const invalid_utf8 = "# coding: utf-8\nx='\xff'\n";
    try expectDiagnostic(invalid_utf8, .syntax_error, "UTF-8");
}

pub fn testUnicodeSource() !void {
    const source = "word='\u{03bb}'\n";
    const result = try expectTokens(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expect(findLexeme(source, result, "'\u{03bb}'") != null);
    const span_source = "word='\u{03bb}'; next=1\n";
    const span_tokens = try expectTokens(std.testing.allocator, span_source);
    defer std.testing.allocator.free(span_tokens);
    const unicode_literal = findLexeme(span_source, span_tokens, "'\u{03bb}'").?;
    try std.testing.expectEqual(@as(usize, 5), unicode_literal.start);
    try std.testing.expectEqual(@as(usize, 9), unicode_literal.end);
    try std.testing.expectEqual(@as(usize, 6), unicode_literal.column);
    const next_identifier = findLexeme(span_source, span_tokens, "next").?;
    try std.testing.expectEqual(@as(usize, 11), next_identifier.start);
    try std.testing.expectEqual(@as(usize, 11), next_identifier.column);
    try expectDiagnostic("\u{03bb}=1\n", .syntax_error, "non-ASCII identifier");
}

pub fn testSoftKeywords() !void {
    const source = "match case _ type\n";
    const result = try expectTokens(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 4), countKind(result, .identifier));
    for ([_][]const u8{ "match", "case", "_", "type" }) |word| {
        try std.testing.expect(findLexeme(source, result, word).?.kind == .identifier);
    }
}

fn expectTokens(allocator: std.mem.Allocator, source: []const u8) ![]Token {
    return switch (try lexer.tokenize(allocator, source)) {
        .tokens => |result| result,
        .failure => |diagnostic| {
            std.debug.print("unexpected lexical error at {d}:{d}: {s}\n", .{ diagnostic.line, diagnostic.column, diagnostic.message });
            return error.UnexpectedLexicalError;
        },
    };
}

fn expectDiagnostic(source: []const u8, kind: lexer.DiagnosticKind, fragment: []const u8) !void {
    const result = try lexer.tokenize(std.testing.allocator, source);
    if (result == .tokens) {
        std.testing.allocator.free(result.tokens);
        return error.ExpectedLexicalDiagnostic;
    }
    try std.testing.expect(result == .failure);
    try std.testing.expectEqual(kind, result.failure.kind);
    try std.testing.expect(std.mem.indexOf(u8, result.failure.message, fragment) != null);
    try std.testing.expect(result.failure.line >= 1);
    try std.testing.expect(result.failure.column >= 1);
    try std.testing.expect(result.failure.start <= result.failure.end);
}

fn expectToken(
    source: []const u8,
    token: Token,
    kind: Kind,
    text: []const u8,
    start: usize,
    end: usize,
    line: usize,
    column: usize,
) !void {
    try std.testing.expectEqual(kind, token.kind);
    try std.testing.expectEqual(start, token.start);
    try std.testing.expectEqual(end, token.end);
    try std.testing.expectEqual(line, token.line);
    try std.testing.expectEqual(column, token.column);
    try std.testing.expectEqualStrings(text, source[token.start..token.end]);
}

fn countKind(items: []const Token, kind: Kind) usize {
    var count: usize = 0;
    for (items) |item| if (item.kind == kind) { count += 1; };
    return count;
}

fn countLexeme(source: []const u8, items: []const Token, text: []const u8) usize {
    var count: usize = 0;
    for (items) |item| if (std.mem.eql(u8, source[item.start..item.end], text)) { count += 1; };
    return count;
}

fn findKind(items: []const Token, kind: Kind) ?Token {
    for (items) |item| if (item.kind == kind) return item;
    return null;
}

fn findLexeme(source: []const u8, items: []const Token, text: []const u8) ?Token {
    for (items) |item| if (std.mem.eql(u8, source[item.start..item.end], text)) return item;
    return null;
}
