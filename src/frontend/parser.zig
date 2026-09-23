const std = @import("std");
const ast_module = @import("frontend_ast");
const lexer = @import("frontend_lexer");
const token_module = @import("frontend_token");

const Ast = ast_module.Ast;
const Node = ast_module.Node;
const NodeId = ast_module.NodeId;
const NodeKind = ast_module.Kind;
const Span = ast_module.Span;
const Token = token_module.Token;
const TokenKind = token_module.Kind;
const ParseError = std.mem.Allocator.Error || error{ParseAbort};

pub const DiagnosticKind = enum { syntax_error, unsupported_feature };
pub const SupportStatus = enum { later_commit, excluded };

pub const Diagnostic = struct {
    kind: DiagnosticKind,
    support: ?SupportStatus = null,
    message: []const u8,
    span: Span,
    line: usize,
    column: usize,
};

pub const ParseResult = union(enum) {
    ast: Ast,
    failure: Diagnostic,
};

pub fn parse(backing_allocator: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error!ParseResult {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    const token_result = try lexer.tokenize(allocator, source);
    const tokens = switch (token_result) {
        .tokens => |items| items,
        .failure => |diagnostic| {
            arena.deinit();
            return .{ .failure = .{
                .kind = .syntax_error,
                .message = diagnostic.message,
                .span = .{ .start = diagnostic.start, .end = diagnostic.end },
                .line = diagnostic.line,
                .column = diagnostic.column,
            } };
        },
    };

    var parser = Parser.init(allocator, source, tokens);
    const root = parser.parseModule() catch |err| {
        if (err == error.ParseAbort) {
            const diagnostic = parser.failure.?;
            arena.deinit();
            return .{ .failure = diagnostic };
        }
        return error.OutOfMemory;
    };
    const nodes = try parser.nodes.toOwnedSlice(allocator);
    const children = try parser.edges.toOwnedSlice(allocator);
    return .{ .ast = .{
        .arena = arena,
        .source = source,
        .nodes = nodes,
        .children_data = children,
        .root = root,
    } };
}

const Parser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const Token,
    position: usize = 0,
    nodes: std.ArrayList(Node) = .empty,
    edges: std.ArrayList(NodeId) = .empty,
    failure: ?Diagnostic = null,
    function_depth: usize = 0,
    loop_depth: usize = 0,
    stop_in_keyword: usize = 0,

    fn init(allocator: std.mem.Allocator, source: []const u8, tokens: []const Token) Parser {
        return .{ .allocator = allocator, .source = source, .tokens = tokens };
    }

    fn parseModule(self: *Parser) ParseError!NodeId {
        const root = try self.addNode(.module, .{ .start = 0, .end = self.source.len }, "", 0, &.{});
        var statements: std.ArrayList(NodeId) = .empty;
        while (!self.at(.endmarker)) {
            if (self.at(.newline)) {
                _ = self.advance();
                continue;
            }
            if (self.at(.dedent)) return self.failAtCurrent("unexpected dedent");
            try self.parseStatementInto(&statements);
        }
        try self.setChildren(root, statements.items);
        return root;
    }

    fn parseStatementInto(self: *Parser, statements: *std.ArrayList(NodeId)) ParseError!void {
        if (self.atText("async")) {
            if (self.peekText(1, "def") or self.peekText(1, "for") or self.peekText(1, "with")) {
                return self.failUnsupported(.excluded, "async syntax is permanently excluded");
            }
            return self.failAtCurrent("async is a reserved word");
        }
        if (self.atText("if")) {
            try statements.append(self.allocator, try self.parseIf());
            return;
        }
        if (self.atText("while")) {
            try statements.append(self.allocator, try self.parseWhile());
            return;
        }
        if (self.atText("for")) {
            try statements.append(self.allocator, try self.parseFor());
            return;
        }
        if (self.atText("def")) {
            try statements.append(self.allocator, try self.parseFunction());
            return;
        }
        if (self.atText("try")) {
            if (self.containsExceptStar()) return self.failUnsupported(.excluded, "except* syntax is permanently excluded");
            return self.failUnsupported(.later_commit, "try statements are not parsed in this commit");
        }
        if (self.atText("class")) return self.failUnsupported(.later_commit, "class definitions are not parsed in this commit");
        if (self.atText("with")) return self.failUnsupported(.later_commit, "with statements are not parsed in this commit");
        if (self.atText("import") or self.atText("from")) return self.failUnsupported(.later_commit, "import statements are not parsed in this commit");
        if (self.atText("match") and self.looksLikeMatchStatement()) return self.failUnsupported(.later_commit, "match statements are not parsed in this commit");
        if (self.atText("type") and self.peekKind(1, .identifier) and self.peekText(2, "=")) return self.failUnsupported(.excluded, "type statements and PEP 695 syntax are permanently excluded");
        if (self.atOperator("@")) return self.failUnsupported(.later_commit, "decorators are not parsed in this commit");
        try self.parseSimpleLine(statements);
    }

    fn parseSimpleLine(self: *Parser, statements: *std.ArrayList(NodeId)) ParseError!void {
        while (true) {
            try statements.append(self.allocator, try self.parseSimpleStatement());
            if (self.atText(";")) {
                _ = self.advance();
                if (self.at(.newline)) {
                    _ = self.advance();
                    return;
                }
                if (self.at(.endmarker)) return;
                continue;
            }
            if (self.at(.newline)) {
                _ = self.advance();
                return;
            }
            if (self.at(.endmarker)) return;
            return self.failAtCurrent("expected a semicolon or end of statement");
        }
    }

    fn parseSimpleStatement(self: *Parser) ParseError!NodeId {
        if (self.atText("pass")) return self.simpleLeaf(.pass_statement);
        if (self.atText("break")) {
            if (self.loop_depth == 0) return self.failAtCurrent("break outside loop");
            return self.simpleLeaf(.break_statement);
        }
        if (self.atText("continue")) {
            if (self.loop_depth == 0) return self.failAtCurrent("continue outside loop");
            return self.simpleLeaf(.continue_statement);
        }
        if (self.atText("return")) return self.parseReturn();
        if (self.atText("raise")) return self.parseRaise();
        if (self.atText("assert")) return self.parseAssert();
        if (self.atText("global")) return self.parseNameListStatement(.global_statement);
        if (self.atText("nonlocal")) return self.parseNameListStatement(.nonlocal_statement);
        if (self.atText("del")) return self.parseDelete();

        const left = try self.parseExpressionList();
        if (self.atText(":")) {
            const colon = self.advance();
            try self.validateTarget(left, .annotated);
            if (self.node(left).kind == .tuple_display or self.node(left).kind == .list_display) return self.failSpan("annotated assignment requires a single target", self.node(left).span);
            const annotation = try self.parseExpression(0);
            var children = std.ArrayList(NodeId).empty;
            try children.append(self.allocator, left);
            try children.append(self.allocator, annotation);
            var end = self.node(annotation).span.end;
            if (self.atText("=")) {
                _ = self.advance();
                const value = try self.parseExpressionList();
                try children.append(self.allocator, value);
                end = self.node(value).span.end;
            }
            return self.addNode(.annotated_assignment, .{ .start = self.node(left).span.start, .end = end }, self.tokenText(colon), 0, children.items);
        }

        if (self.atText("=")) {
            var targets: std.ArrayList(NodeId) = .empty;
            try self.validateTarget(left, .assignment);
            try targets.append(self.allocator, left);
            var value: NodeId = undefined;
            while (self.atText("=")) {
                _ = self.advance();
                value = try self.parseExpressionList();
                if (self.atText("=")) {
                    try self.validateTarget(value, .assignment);
                    try targets.append(self.allocator, value);
                } else break;
            }
            try targets.append(self.allocator, value);
            const start_span = self.node(left).span.start;
            const end_span = self.node(value).span.end;
            return self.addNode(.assignment, .{ .start = start_span, .end = end_span }, "=", 0, targets.items);
        }

        if (self.current().kind == .operator and isAugmentedOperator(self.tokenText(self.current()))) {
            const operator = self.advance();
            try self.validateTarget(left, .augmented);
            const right = try self.parseExpression(0);
            return self.addNode(.augmented_assignment, .{ .start = self.node(left).span.start, .end = self.node(right).span.end }, self.tokenText(operator), 0, &.{ left, right });
        }
        const node_span = self.node(left).span;
        return self.addNode(.expression_statement, node_span, "", 0, &.{left});
    }

    fn parseReturn(self: *Parser) ParseError!NodeId {
        const start = self.advance();
        if (self.function_depth == 0) return self.failAtToken(start, "return outside function");
        if (self.at(.newline) or self.at(.endmarker) or self.atText(";")) return self.addNode(.return_statement, .{ .start = start.start, .end = start.end }, "", 0, &.{});
        const value = try self.parseExpressionList();
        return self.addNode(.return_statement, .{ .start = start.start, .end = self.node(value).span.end }, "", 0, &.{value});
    }

    fn parseRaise(self: *Parser) ParseError!NodeId {
        const start = self.advance();
        var children = std.ArrayList(NodeId).empty;
        if (!self.at(.newline) and !self.at(.endmarker) and !self.atText(";")) {
            try children.append(self.allocator, try self.parseExpression(0));
            if (self.atText("from")) {
                _ = self.advance();
                try children.append(self.allocator, try self.parseExpression(0));
            }
        }
        const end = if (children.items.len == 0) start.end else self.node(children.items[children.items.len - 1]).span.end;
        return self.addNode(.raise_statement, .{ .start = start.start, .end = end }, "", 0, children.items);
    }

    fn parseAssert(self: *Parser) ParseError!NodeId {
        const start = self.advance();
        var children = std.ArrayList(NodeId).empty;
        try children.append(self.allocator, try self.parseExpression(0));
        if (self.atText(",")) {
            _ = self.advance();
            try children.append(self.allocator, try self.parseExpression(0));
        }
        return self.addNode(.assert_statement, .{ .start = start.start, .end = self.node(children.items[children.items.len - 1]).span.end }, "", 0, children.items);
    }

    fn parseNameListStatement(self: *Parser, kind: NodeKind) ParseError!NodeId {
        const start = self.advance();
        var children: std.ArrayList(NodeId) = .empty;
        while (true) {
            if (!self.at(.identifier)) return self.failAtCurrent("expected an identifier");
            const token = self.advance();
            try children.append(self.allocator, try self.addNode(.name, tokenSpan(token), self.tokenText(token), 0, &.{}));
            if (!self.atText(",")) break;
            _ = self.advance();
        }
        return self.addNode(kind, .{ .start = start.start, .end = self.node(children.items[children.items.len - 1]).span.end }, "", 0, children.items);
    }

    fn parseDelete(self: *Parser) ParseError!NodeId {
        const start = self.advance();
        const targets = try self.parseExpressionList();
        try self.validateTarget(targets, .delete);
        return self.addNode(.delete_statement, .{ .start = start.start, .end = self.node(targets).span.end }, "", 0, &.{targets});
    }

    fn simpleLeaf(self: *Parser, kind: NodeKind) ParseError!NodeId {
        const token = self.advance();
        return self.addNode(kind, tokenSpan(token), self.tokenText(token), 0, &.{});
    }

    fn parseIf(self: *Parser) ParseError!NodeId {
        const start = self.advance();
        return self.parseIfTail(start);
    }

    fn parseIfTail(self: *Parser, start: Token) ParseError!NodeId {
        const condition = try self.parseExpression(0);
        _ = try self.expectText(":", "expected ':' after if condition");
        const body = try self.parseSuite();
        var children = std.ArrayList(NodeId).empty;
        try children.appendSlice(self.allocator, &.{ condition, body });
        var end = self.node(body).span.end;
        if (self.atText("elif")) {
            const elif_token = self.advance();
            const nested = try self.parseIfTail(elif_token);
            try children.append(self.allocator, nested);
            end = self.node(nested).span.end;
        } else if (self.atText("else")) {
            _ = self.advance();
            _ = try self.expectText(":", "expected ':' after else");
            const alternative = try self.parseSuite();
            try children.append(self.allocator, alternative);
            end = self.node(alternative).span.end;
        }
        return self.addNode(.if_statement, .{ .start = start.start, .end = end }, "", 0, children.items);
    }

    fn parseWhile(self: *Parser) ParseError!NodeId {
        const start = self.advance();
        const condition = try self.parseExpression(0);
        _ = try self.expectText(":", "expected ':' after while condition");
        self.loop_depth += 1;
        const body = self.parseSuite() catch |err| {
            self.loop_depth -= 1;
            return err;
        };
        self.loop_depth -= 1;
        var children = std.ArrayList(NodeId).empty;
        try children.appendSlice(self.allocator, &.{ condition, body });
        var end = self.node(body).span.end;
        if (self.atText("else")) {
            _ = self.advance();
            _ = try self.expectText(":", "expected ':' after loop else");
            const alternative = try self.parseSuite();
            try children.append(self.allocator, alternative);
            end = self.node(alternative).span.end;
        }
        return self.addNode(.while_statement, .{ .start = start.start, .end = end }, "", 0, children.items);
    }

    fn parseFor(self: *Parser) ParseError!NodeId {
        const start = self.advance();
        self.stop_in_keyword += 1;
        const target = self.parseExpressionList() catch |err| {
            self.stop_in_keyword -= 1;
            return err;
        };
        self.stop_in_keyword -= 1;
        try self.validateTarget(target, .assignment);
        if (!self.atText("in")) return self.failAtCurrent("expected 'in' in for statement");
        _ = self.advance();
        const iterable = try self.parseExpressionList();
        _ = try self.expectText(":", "expected ':' after for iterable");
        self.loop_depth += 1;
        const body = self.parseSuite() catch |err| {
            self.loop_depth -= 1;
            return err;
        };
        self.loop_depth -= 1;
        var children = std.ArrayList(NodeId).empty;
        try children.appendSlice(self.allocator, &.{ target, iterable, body });
        var end = self.node(body).span.end;
        if (self.atText("else")) {
            _ = self.advance();
            _ = try self.expectText(":", "expected ':' after loop else");
            const alternative = try self.parseSuite();
            try children.append(self.allocator, alternative);
            end = self.node(alternative).span.end;
        }
        return self.addNode(.for_statement, .{ .start = start.start, .end = end }, "", 0, children.items);
    }

    fn parseFunction(self: *Parser) ParseError!NodeId {
        const start = self.advance();
        if (!self.at(.identifier)) return self.failAtCurrent("expected function name");
        const name = self.advance();
        if (self.atText("[")) return self.failUnsupported(.excluded, "PEP 695 type parameter syntax is permanently excluded");
        _ = try self.expectText("(", "expected '(' after function name");
        const parameters = try self.parseParameters(")", true);
        _ = try self.expectText(")", "expected ')' after parameters");
        var return_annotation: ?NodeId = null;
        if (self.atOperator("->")) {
            _ = self.advance();
            return_annotation = try self.parseExpression(0);
        }
        _ = try self.expectText(":", "expected ':' after function signature");
        var children: std.ArrayList(NodeId) = .empty;
        try children.appendSlice(self.allocator, parameters);
        if (return_annotation) |annotation| try children.append(self.allocator, annotation);
        const enclosing_loop_depth = self.loop_depth;
        self.loop_depth = 0;
        self.function_depth += 1;
        const body = self.parseSuite() catch |err| {
            self.function_depth -= 1;
            self.loop_depth = enclosing_loop_depth;
            return err;
        };
        self.function_depth -= 1;
        self.loop_depth = enclosing_loop_depth;
        try children.append(self.allocator, body);
        const flags = if (return_annotation != null) ast_module.function_flags.has_return_annotation else 0;
        return self.addNode(.function_definition, .{ .start = start.start, .end = self.node(body).span.end }, self.tokenText(name), flags, children.items);
    }

    fn parseSuite(self: *Parser) ParseError!NodeId {
        if (!self.at(.newline)) {
            const start = self.current().start;
            var statements: std.ArrayList(NodeId) = .empty;
            try self.parseSimpleLine(&statements);
            const end = if (statements.items.len == 0) start else self.node(statements.items[statements.items.len - 1]).span.end;
            return self.addNode(.block, .{ .start = start, .end = end }, "", 0, statements.items);
        }
        _ = self.advance();
        while (self.at(.newline)) _ = self.advance();
        if (!self.at(.indent)) return self.failAtCurrent("expected an indented block after ':'");
        const indent = self.advance();
        var statements: std.ArrayList(NodeId) = .empty;
        while (!self.at(.dedent) and !self.at(.endmarker)) {
            if (self.at(.newline)) {
                _ = self.advance();
                continue;
            }
            try self.parseStatementInto(&statements);
        }
        if (!self.at(.dedent)) return self.failAtCurrent("expected end of indented block");
        _ = self.advance();
        const end = if (statements.items.len == 0) indent.end else self.node(statements.items[statements.items.len - 1]).span.end;
        return self.addNode(.block, .{ .start = indent.start, .end = end }, "", 0, statements.items);
    }

    fn parseParameters(self: *Parser, terminator: []const u8, annotations_allowed: bool) ParseError![]const NodeId {
        var parameters: std.ArrayList(NodeId) = .empty;
        var names: std.StringHashMap(void) = .init(self.allocator);
        var keyword_only = false;
        var slash_seen = false;
        var varargs_seen = false;
        var varkw_seen = false;
        var positional_default_seen = false;
        while (!self.atText(terminator) and !self.at(.endmarker)) {
            if (self.atText("/")) {
                const slash = self.advance();
                if (slash_seen or keyword_only or parameters.items.len == 0) return self.failAtToken(slash, "invalid positional-only marker");
                slash_seen = true;
                for (parameters.items) |id| {
                    const param = &self.nodes.items[@intCast(id)];
                    if ((param.flags & (ast_module.parameter_flags.var_positional | ast_module.parameter_flags.var_keyword)) == 0) param.flags |= ast_module.parameter_flags.positional_only;
                }
            } else if (self.atOperator("**")) {
                if (varkw_seen or !self.peekKind(1, .identifier)) return self.failAtCurrent("expected a parameter name after '**'");
                _ = self.advance();
                const parameter = try self.parseOneParameter(ast_module.parameter_flags.var_keyword, annotations_allowed, false);
                try self.appendUniqueParameter(&parameters, &names, parameter);
                varkw_seen = true;
                keyword_only = true;
            } else if (self.atOperator("*")) {
                const star = self.advance();
                if (varargs_seen) return self.failAtToken(star, "multiple variadic positional parameters");
                keyword_only = true;
                if (self.at(.identifier)) {
                    const parameter = try self.parseOneParameter(ast_module.parameter_flags.var_positional, annotations_allowed, false);
                    try self.appendUniqueParameter(&parameters, &names, parameter);
                    varargs_seen = true;
                } else if (self.atText(",")) {
                    varargs_seen = true;
                } else return self.failAtCurrent("expected a parameter name or ',' after '*'");
            } else {
                if (varkw_seen) return self.failAtCurrent("parameter follows '**kwargs'");
                const parameter = try self.parseOneParameter(if (keyword_only) ast_module.parameter_flags.keyword_only else 0, annotations_allowed, true);
                const flags = self.node(parameter).flags;
                if (!keyword_only) {
                    const has_default = flags & ast_module.parameter_flags.has_default != 0;
                    if (positional_default_seen and !has_default) return self.failSpan("non-default argument follows default argument", self.node(parameter).span);
                    positional_default_seen = positional_default_seen or has_default;
                }
                try self.appendUniqueParameter(&parameters, &names, parameter);
            }
            if (self.atText(",")) {
                _ = self.advance();
                if (self.atText(terminator)) break;
            } else if (!self.atText(terminator)) return self.failAtCurrent("expected ',' between parameters");
        }
        if (!self.atText(terminator)) return self.failAtCurrent("unterminated parameter list");
        return parameters.toOwnedSlice(self.allocator);
    }

    fn parseOneParameter(self: *Parser, initial_flags: u32, annotations_allowed: bool, default_allowed: bool) ParseError!NodeId {
        if (!self.at(.identifier) or isHardKeyword(self.tokenText(self.current()))) return self.failAtCurrent("expected parameter name");
        const name = self.advance();
        var flags = initial_flags;
        var children: std.ArrayList(NodeId) = .empty;
        if (annotations_allowed and self.atText(":")) {
            _ = self.advance();
            const annotation = try self.parseExpression(0);
            try children.append(self.allocator, annotation);
            flags |= ast_module.parameter_flags.has_annotation;
        }
        if (self.atText("=")) {
            if (!default_allowed) return self.failAtCurrent("variadic parameter cannot have a default");
            _ = self.advance();
            const default = try self.parseExpression(0);
            try children.append(self.allocator, default);
            flags |= ast_module.parameter_flags.has_default;
        }
        const end = if (children.items.len == 0) name.end else self.node(children.items[children.items.len - 1]).span.end;
        return self.addNode(.parameter, .{ .start = name.start, .end = end }, self.tokenText(name), flags, children.items);
    }

    fn appendUniqueParameter(self: *Parser, parameters: *std.ArrayList(NodeId), names: *std.StringHashMap(void), id: NodeId) ParseError!void {
        const name = self.node(id).text;
        if (names.contains(name)) return self.failSpan("duplicate parameter name", self.node(id).span);
        try names.put(name, {});
        try parameters.append(self.allocator, id);
    }

    fn parseExpressionList(self: *Parser) ParseError!NodeId {
        const first = try self.parseExpression(0);
        if (!self.atText(",")) return first;
        var items: std.ArrayList(NodeId) = .empty;
        try items.append(self.allocator, first);
        while (self.atText(",")) {
            _ = self.advance();
            if (self.at(.newline) or self.at(.endmarker) or self.atText(";") or self.atText(")") or self.atText("]") or self.atText("}") or self.atText(":")) break;
            try items.append(self.allocator, try self.parseExpression(0));
        }
        return self.addNode(.tuple_display, .{ .start = self.node(first).span.start, .end = self.node(items.items[items.items.len - 1]).span.end }, "", 0, items.items);
    }

    fn parseExpression(self: *Parser, minimum_binding: u8) ParseError!NodeId {
        var left = try self.parsePrefix();
        while (true) {
            if (self.atText(".") and minimum_binding <= 140) {
                _ = self.advance();
                if (!self.at(.identifier)) return self.failAtCurrent("expected attribute name after '.'");
                const attribute = self.advance();
                left = try self.addNode(.attribute, .{ .start = self.node(left).span.start, .end = attribute.end }, self.tokenText(attribute), 0, &.{left});
                continue;
            }
            if (self.atText("(") and minimum_binding <= 140) {
                _ = self.advance();
                const arguments = try self.parseCallArguments();
                const closing = try self.expectText(")", "expected ')' after call arguments");
                var children = std.ArrayList(NodeId).empty;
                try children.append(self.allocator, left);
                try children.appendSlice(self.allocator, arguments);
                left = try self.addNode(.call, .{ .start = self.node(left).span.start, .end = closing.end }, "", 0, children.items);
                continue;
            }
            if (self.atText("[") and minimum_binding <= 140) {
                left = try self.parseSubscript(left);
                continue;
            }
            if (self.atOperator(":=") and minimum_binding <= 5) {
                const operator = self.advance();
                if (self.node(left).kind != .name) return self.failSpan("assignment expression target must be a name", self.node(left).span);
                const right = try self.parseExpression(5);
                left = try self.addNode(.named_expression, .{ .start = self.node(left).span.start, .end = self.node(right).span.end }, self.tokenText(operator), 0, &.{ left, right });
                continue;
            }
            if (self.atText("if") and minimum_binding <= 10) {
                _ = self.advance();
                const condition = try self.parseExpression(0);
                if (!self.atText("else")) return self.failAtCurrent("expected 'else' in conditional expression");
                _ = self.advance();
                const alternative = try self.parseExpression(10);
                left = try self.addNode(.conditional_expression, .{ .start = self.node(left).span.start, .end = self.node(alternative).span.end }, "if", 0, &.{ condition, left, alternative });
                continue;
            }
            if (self.comparisonAtCurrent()) |comparison| {
                if (minimum_binding > 40) break;
                var chain: std.ArrayList(NodeId) = .empty;
                try chain.append(self.allocator, left);
                var final_end = self.node(left).span.end;
                var op = comparison;
                while (true) {
                    const first_operator = self.current();
                    _ = self.advance();
                    var operator_text = self.tokenText(first_operator);
                    var operator_end = first_operator.end;
                    if (op.token_count == 2) {
                        const second = self.advance();
                        operator_end = second.end;
                        operator_text = if (std.mem.eql(u8, operator_text, "is")) "is not" else "not in";
                    }
                    const operator_node = try self.addNode(.operator, .{ .start = first_operator.start, .end = operator_end }, operator_text, 0, &.{});
                    try chain.append(self.allocator, operator_node);
                    const right = try self.parseExpression(41);
                    try chain.append(self.allocator, right);
                    final_end = self.node(right).span.end;
                    op = self.comparisonAtCurrent() orelse break;
                }
                left = try self.addNode(.comparison_chain, .{ .start = self.node(left).span.start, .end = final_end }, "", 0, chain.items);
                continue;
            }
            const binary = self.binaryAtCurrent() orelse break;
            if (binary.binding < minimum_binding) break;
            const operator = self.advance();
            const right = try self.parseExpression(if (binary.right_associative) binary.binding else binary.binding + 1);
            const kind: NodeKind = if (binary.is_boolean) .boolean_expression else .binary_expression;
            left = try self.addNode(kind, .{ .start = self.node(left).span.start, .end = self.node(right).span.end }, self.tokenText(operator), 0, &.{left, right});
        }
        return left;
    }

    fn parsePrefix(self: *Parser) ParseError!NodeId {
        const token = self.current();
        if (token.kind == .integer) return self.leaf(.integer_literal, token);
        if (token.kind == .float) return self.leaf(.float_literal, token);
        if (token.kind == .string) return self.leaf(.string_literal, token);
        if (token.kind == .bytes) return self.leaf(.bytes_literal, token);
        if (token.kind == .formatted_string) return self.failUnsupported(.later_commit, "f-string interior parsing is not implemented in this commit");
        if (token.kind == .identifier) {
            const text = self.tokenText(token);
            if (std.mem.eql(u8, text, "None")) return self.leaf(.none_literal, token);
            if (std.mem.eql(u8, text, "True") or std.mem.eql(u8, text, "False")) return self.leaf(.bool_literal, token);
            if (std.mem.eql(u8, text, "lambda")) return self.parseLambda();
            if (std.mem.eql(u8, text, "not")) {
                _ = self.advance();
                const operand = try self.parseExpression(35);
                return self.addNode(.unary_expression, .{ .start = token.start, .end = self.node(operand).span.end }, text, 0, &.{operand});
            }
            if (std.mem.eql(u8, text, "await")) return self.failUnsupported(.excluded, "async/await syntax is permanently excluded");
            if (std.mem.eql(u8, text, "yield")) {
                if (self.peekText(1, "from")) return self.failUnsupported(.excluded, "yield from syntax is permanently excluded");
                return self.failUnsupported(.later_commit, "yield expressions are not parsed in this commit");
            }
            if (isHardKeyword(text)) return self.failAtToken(token, "expected an expression");
            return self.leaf(.name, token);
        }
        if (token.kind == .operator and (self.atOperator("+") or self.atOperator("-") or self.atOperator("~"))) {
            _ = self.advance();
            const operand = try self.parseExpression(110);
            return self.addNode(.unary_expression, .{ .start = token.start, .end = self.node(operand).span.end }, self.tokenText(token), 0, &.{operand});
        }
        if (token.kind == .operator and (self.atOperator("*") or self.atOperator("**"))) {
            _ = self.advance();
            const operand = try self.parseExpression(110);
            return self.addNode(.starred, .{ .start = token.start, .end = self.node(operand).span.end }, self.tokenText(token), 0, &.{operand});
        }
        if (self.atText("(")) return self.parseParenthesized();
        if (self.atText("[")) return self.parseListDisplay();
        if (self.atText("{")) return self.parseBraceDisplay();
        return self.failAtCurrent("expected an expression");
    }

    fn parseLambda(self: *Parser) ParseError!NodeId {
        const start = self.advance();
        const parameters = try self.parseParameters(":", false);
        _ = try self.expectText(":", "expected ':' after lambda parameters");
        const body = try self.parseExpression(0);
        var children: std.ArrayList(NodeId) = .empty;
        try children.appendSlice(self.allocator, parameters);
        try children.append(self.allocator, body);
        return self.addNode(.lambda_expression, .{ .start = start.start, .end = self.node(body).span.end }, "lambda", 0, children.items);
    }

    fn parseParenthesized(self: *Parser) ParseError!NodeId {
        const opening = self.advance();
        if (self.atText(")")) {
            const closing = self.advance();
            return self.addNode(.tuple_display, .{ .start = opening.start, .end = closing.end }, "", 0, &.{});
        }
        const first = try self.parseExpression(0);
        if (self.atText("for")) return self.failUnsupported(.later_commit, "comprehensions are not parsed in this commit");
        if (!self.atText(",")) {
            const closing = try self.expectText(")", "expected ')' after expression");
            self.nodes.items[@intCast(first)].span = .{ .start = opening.start, .end = closing.end };
            return first;
        }
        var items: std.ArrayList(NodeId) = .empty;
        try items.append(self.allocator, first);
        while (self.atText(",")) {
            _ = self.advance();
            if (self.atText(")")) break;
            try items.append(self.allocator, try self.parseExpression(0));
            if (self.atText("for")) return self.failUnsupported(.later_commit, "comprehensions are not parsed in this commit");
        }
        const closing = try self.expectText(")", "expected ')' after tuple display");
        return self.addNode(.tuple_display, .{ .start = opening.start, .end = closing.end }, "", 0, items.items);
    }

    fn parseListDisplay(self: *Parser) ParseError!NodeId {
        const opening = self.advance();
        var items: std.ArrayList(NodeId) = .empty;
        if (self.atText("]")) {
            const closing = self.advance();
            return self.addNode(.list_display, .{ .start = opening.start, .end = closing.end }, "", 0, &.{});
        }
        while (true) {
            try items.append(self.allocator, try self.parseExpression(0));
            if (self.atText("for")) return self.failUnsupported(.later_commit, "comprehensions are not parsed in this commit");
            if (!self.atText(",")) break;
            _ = self.advance();
            if (self.atText("]")) break;
        }
        const closing = try self.expectText("]", "expected ']' after list display");
        return self.addNode(.list_display, .{ .start = opening.start, .end = closing.end }, "", 0, items.items);
    }

    fn parseBraceDisplay(self: *Parser) ParseError!NodeId {
        const opening = self.advance();
        var items: std.ArrayList(NodeId) = .empty;
        if (self.atText("}")) {
            const closing = self.advance();
            return self.addNode(.dict_display, .{ .start = opening.start, .end = closing.end }, "", 0, &.{});
        }
        var is_dict = false;
        while (true) {
            const key = try self.parseExpression(0);
            if (self.atText("for")) return self.failUnsupported(.later_commit, "comprehensions are not parsed in this commit");
            if (self.atText(":")) {
                if (!is_dict and items.items.len != 0) return self.failAtCurrent("cannot mix dictionary and set entries");
                is_dict = true;
                _ = self.advance();
                const value = try self.parseExpression(0);
                try items.appendSlice(self.allocator, &.{ key, value });
            } else {
                if (is_dict) return self.failAtCurrent("cannot mix dictionary and set entries");
                try items.append(self.allocator, key);
            }
            if (!self.atText(",")) break;
            _ = self.advance();
            if (self.atText("}")) break;
        }
        const closing = try self.expectText("}", "expected '}' after display");
        return self.addNode(if (is_dict) .dict_display else .set_display, .{ .start = opening.start, .end = closing.end }, "", 0, items.items);
    }

    fn parseCallArguments(self: *Parser) ParseError![]const NodeId {
        var arguments: std.ArrayList(NodeId) = .empty;
        if (self.atText(")")) return arguments.toOwnedSlice(self.allocator);
        while (true) {
            var argument: NodeId = undefined;
            if (self.atOperator("*") or self.atOperator("**")) {
                const marker = self.advance();
                const value = try self.parseExpression(0);
                argument = try self.addNode(.starred, .{ .start = marker.start, .end = self.node(value).span.end }, self.tokenText(marker), 0, &.{value});
            } else if (self.at(.identifier) and self.peekText(1, "=")) {
                const name = self.advance();
                _ = self.advance();
                const value = try self.parseExpression(0);
                argument = try self.addNode(.keyword_argument, .{ .start = name.start, .end = self.node(value).span.end }, self.tokenText(name), 0, &.{value});
            } else {
                argument = try self.parseExpression(0);
                if (self.atText("for")) return self.failUnsupported(.later_commit, "generator expressions are not parsed in this commit");
            }
            try arguments.append(self.allocator, argument);
            if (!self.atText(",")) break;
            _ = self.advance();
            if (self.atText(")")) break;
        }
        return arguments.toOwnedSlice(self.allocator);
    }

    fn parseSubscript(self: *Parser, value: NodeId) ParseError!NodeId {
        _ = self.advance();
        if (self.atText("]")) return self.failAtCurrent("empty subscript");
        var indices: std.ArrayList(NodeId) = .empty;
        try indices.append(self.allocator, try self.parseSliceItem());
        while (self.atText(",")) {
            _ = self.advance();
            if (self.atText("]")) break;
            try indices.append(self.allocator, try self.parseSliceItem());
        }
        const closing = try self.expectText("]", "expected ']' after subscript");
        const index = if (indices.items.len == 1) indices.items[0] else try self.addNode(.tuple_display, .{ .start = self.node(indices.items[0]).span.start, .end = self.node(indices.items[indices.items.len - 1]).span.end }, "", 0, indices.items);
        return self.addNode(.subscript, .{ .start = self.node(value).span.start, .end = closing.end }, "", 0, &.{ value, index });
    }

    fn parseSliceItem(self: *Parser) ParseError!NodeId {
        var lower: NodeId = undefined;
        var has_lower = false;
        if (!self.atText(":") and !self.atText(",") and !self.atText("]")) {
            lower = try self.parseExpression(0);
            has_lower = true;
        }
        if (!self.atText(":")) {
            if (!has_lower) return self.failAtCurrent("expected subscript expression");
            return lower;
        }
        const first_colon = self.advance();
        const missing = try self.addNode(.none_literal, .{ .start = first_colon.start, .end = first_colon.start }, "None", 0, &.{});
        var upper = missing;
        var step = missing;
        if (!self.atText(":") and !self.atText(",") and !self.atText("]")) upper = try self.parseExpression(0);
        if (self.atText(":")) {
            _ = self.advance();
            if (!self.atText(",") and !self.atText("]")) step = try self.parseExpression(0);
        }
        const lower_id = if (has_lower) lower else missing;
        const end = if (step != missing) self.node(step).span.end else if (upper != missing) self.node(upper).span.end else first_colon.end;
        return self.addNode(.slice, .{ .start = if (has_lower) self.node(lower).span.start else first_colon.start, .end = end }, "", 0, &.{ lower_id, upper, step });
    }

    fn comparisonAtCurrent(self: *const Parser) ?struct { token_count: usize } {
        if (self.stop_in_keyword != 0 and (self.atText("in") or (self.atText("not") and self.peekText(1, "in")))) return null;
        if (self.at(.operator) and isComparisonOperator(self.tokenText(self.current()))) return .{ .token_count = 1 };
        if (self.atText("is") and self.peekText(1, "not")) return .{ .token_count = 2 };
        if (self.atText("not") and self.peekText(1, "in")) return .{ .token_count = 2 };
        if (self.atText("in") or self.atText("is")) return .{ .token_count = 1 };
        return null;
    }

    fn binaryAtCurrent(self: *const Parser) ?struct { binding: u8, right_associative: bool, is_boolean: bool } {
        if (self.atText("or")) return .{ .binding = 20, .right_associative = false, .is_boolean = true };
        if (self.atText("and")) return .{ .binding = 30, .right_associative = false, .is_boolean = true };
        if (self.at(.operator)) {
            const op = self.tokenText(self.current());
            const binding: ?u8 = if (std.mem.eql(u8, op, "|")) 50 else if (std.mem.eql(u8, op, "^")) 60 else if (std.mem.eql(u8, op, "&")) 70 else if (std.mem.eql(u8, op, "<<") or std.mem.eql(u8, op, ">>")) 80 else if (std.mem.eql(u8, op, "+") or std.mem.eql(u8, op, "-")) 90 else if (std.mem.eql(u8, op, "*") or std.mem.eql(u8, op, "@") or std.mem.eql(u8, op, "/") or std.mem.eql(u8, op, "//") or std.mem.eql(u8, op, "%")) 100 else if (std.mem.eql(u8, op, "**")) 120 else null;
            if (binding) |value| return .{ .binding = value, .right_associative = value == 120, .is_boolean = false };
        }
        return null;
    }

    fn validateTarget(self: *Parser, id: NodeId, mode: TargetMode) ParseError!void {
        const value = self.node(id);
        switch (value.kind) {
            .name, .attribute, .subscript => return,
            .tuple_display, .list_display => {
                if (mode == .augmented or mode == .annotated) {
                    const message = if (mode == .augmented) "augmented assignment requires a single target" else "annotated assignment requires a single target";
                    return self.failSpan(message, value.span);
                }
                var starred_count: usize = 0;
                for (self.childrenOf(id)) |child| {
                    if (self.node(child).kind == .starred) {
                        starred_count += 1;
                        if (mode == .delete) return self.failSpan("starred target is not valid for delete", self.node(child).span);
                        if (starred_count > 1) return self.failSpan("multiple starred expressions in assignment target", self.node(child).span);
                        try self.validateTarget(self.childrenOf(child)[0], mode);
                    } else try self.validateTarget(child, mode);
                }
                return;
            },
            else => {},
        }
        const message = switch (mode) {
            .assignment => "cannot assign to this expression",
            .delete => "cannot delete this expression",
            .augmented => "invalid target for augmented assignment",
            .annotated => "invalid target for annotated assignment",
            .named => "assignment expression target must be a name",
        };
        return self.failSpan(message, value.span);
    }

    fn addNode(self: *Parser, kind: NodeKind, span: Span, text: []const u8, flags: u32, children: []const NodeId) std.mem.Allocator.Error!NodeId {
        const start: u32 = @intCast(self.edges.items.len);
        try self.edges.appendSlice(self.allocator, children);
        const id: NodeId = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{
            .kind = kind,
            .span = span,
            .text = text,
            .flags = flags,
            .children_start = start,
            .children_len = @intCast(children.len),
        });
        return id;
    }

    fn setChildren(self: *Parser, id: NodeId, children: []const NodeId) std.mem.Allocator.Error!void {
        const start: u32 = @intCast(self.edges.items.len);
        try self.edges.appendSlice(self.allocator, children);
        self.nodes.items[@intCast(id)].children_start = start;
        self.nodes.items[@intCast(id)].children_len = @intCast(children.len);
    }

    fn leaf(self: *Parser, kind: NodeKind, token: Token) ParseError!NodeId {
        _ = self.advance();
        return self.addNode(kind, tokenSpan(token), self.tokenText(token), 0, &.{});
    }

    fn expectText(self: *Parser, text: []const u8, message: []const u8) ParseError!Token {
        if (!self.atText(text)) return self.failAtCurrent(message);
        return self.advance();
    }

    fn failAtCurrent(self: *Parser, message: []const u8) error{ParseAbort} {
        return self.failAtToken(self.current(), message);
    }

    fn failAtToken(self: *Parser, token: Token, message: []const u8) error{ParseAbort} {
        self.failure = .{ .kind = .syntax_error, .message = message, .span = tokenSpan(token), .line = token.line, .column = token.column };
        return error.ParseAbort;
    }

    fn failSpan(self: *Parser, message: []const u8, span: Span) error{ParseAbort} {
        const location = sourceLocation(self.source, span.start);
        self.failure = .{ .kind = .syntax_error, .message = message, .span = span, .line = location.line, .column = location.column };
        return error.ParseAbort;
    }

    fn failUnsupported(self: *Parser, support: SupportStatus, message: []const u8) error{ParseAbort} {
        const token = self.current();
        self.failure = .{ .kind = .unsupported_feature, .support = support, .message = message, .span = tokenSpan(token), .line = token.line, .column = token.column };
        return error.ParseAbort;
    }

    fn current(self: *const Parser) Token {
        return self.tokens[@min(self.position, self.tokens.len - 1)];
    }

    fn peek(self: *const Parser, offset: usize) Token {
        return self.tokens[@min(self.position + offset, self.tokens.len - 1)];
    }

    fn advance(self: *Parser) Token {
        const token = self.current();
        if (token.kind != .endmarker) self.position += 1;
        return token;
    }

    fn at(self: *const Parser, kind: TokenKind) bool {
        return self.current().kind == kind;
    }

    fn atText(self: *const Parser, text: []const u8) bool {
        return std.mem.eql(u8, self.tokenText(self.current()), text);
    }

    fn atOperator(self: *const Parser, text: []const u8) bool {
        return self.at(.operator) and self.atText(text);
    }

    fn peekText(self: *const Parser, offset: usize, text: []const u8) bool {
        return std.mem.eql(u8, self.tokenText(self.peek(offset)), text);
    }

    fn peekKind(self: *const Parser, offset: usize, kind: TokenKind) bool {
        return self.peek(offset).kind == kind;
    }

    fn tokenText(self: *const Parser, token: Token) []const u8 {
        return self.source[token.start..token.end];
    }

    fn childrenOf(self: *const Parser, id: NodeId) []const NodeId {
        const node_value = self.nodes.items[@intCast(id)];
        const start: usize = node_value.children_start;
        const length: usize = node_value.children_len;
        return self.edges.items[start..][0..length];
    }

    fn node(self: *const Parser, id: NodeId) *const Node {
        return &self.nodes.items[@intCast(id)];
    }

    fn containsExceptStar(self: *const Parser) bool {
        var index = self.position;
        while (index + 1 < self.tokens.len and self.tokens[index].kind != .endmarker) : (index += 1) {
            const current_token = self.tokens[index];
            const next = self.tokens[index + 1];
            if (std.mem.eql(u8, self.tokenText(current_token), "except") and std.mem.eql(u8, self.tokenText(next), "*")) return true;
        }
        return false;
    }

    fn looksLikeMatchStatement(self: *const Parser) bool {
        if (self.peekText(1, "=") or self.peekText(1, ":")) return false;
        var index = self.position;
        var nesting: usize = 0;
        while (index < self.tokens.len) : (index += 1) {
            const token = self.tokens[index];
            if (token.kind == .newline or token.kind == .endmarker) return false;
            const text = self.tokenText(token);
            if (std.mem.eql(u8, text, "(") or std.mem.eql(u8, text, "[") or std.mem.eql(u8, text, "{")) nesting += 1 else if (std.mem.eql(u8, text, ")") or std.mem.eql(u8, text, "]") or std.mem.eql(u8, text, "}")) {
                if (nesting != 0) nesting -= 1;
            } else if (nesting == 0 and std.mem.eql(u8, text, ":")) return true;
        }
        return false;
    }
};

const TargetMode = enum { assignment, delete, augmented, annotated, named };

fn tokenSpan(token: Token) Span {
    return .{ .start = token.start, .end = token.end };
}

fn sourceLocation(source: []const u8, end: usize) struct { line: usize, column: usize } {
    var line: usize = 1;
    var column: usize = 1;
    var index: usize = if (std.mem.startsWith(u8, source, "\xef\xbb\xbf")) 3 else 0;
    while (index < end and index < source.len) {
        const c = source[index];
        if (c == '\r') {
            if (index + 1 < end and source[index + 1] == '\n') index += 1;
            index += 1;
            line += 1;
            column = 1;
        } else if (c == '\n') {
            index += 1;
            line += 1;
            column = 1;
        } else if (c == '\t') {
            index += 1;
            column = ((column - 1) / 8 + 1) * 8 + 1;
        } else {
            const length = utf8Length(c);
            index += @min(length, source.len - index);
            column += 1;
        }
    }
    return .{ .line = line, .column = column };
}

fn utf8Length(c: u8) usize {
    if (c <= 0x7f) return 1;
    if (c >= 0xc2 and c <= 0xdf) return 2;
    if (c >= 0xe0 and c <= 0xef) return 3;
    if (c >= 0xf0 and c <= 0xf4) return 4;
    return 1;
}

fn isComparisonOperator(text: []const u8) bool {
    return std.mem.eql(u8, text, "==") or std.mem.eql(u8, text, "!=") or std.mem.eql(u8, text, "<") or std.mem.eql(u8, text, ">") or std.mem.eql(u8, text, "<=") or std.mem.eql(u8, text, ">=");
}

fn isAugmentedOperator(text: []const u8) bool {
    const operators = [_][]const u8{ "+=", "-=", "*=", "@=", "/=", "//=", "%=", "&=", "|=", "^=", "<<=", ">>=", "**=" };
    for (operators) |operator| if (std.mem.eql(u8, text, operator)) return true;
    return false;
}

fn isHardKeyword(text: []const u8) bool {
    const keywords = [_][]const u8{ "False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield" };
    for (keywords) |keyword| if (std.mem.eql(u8, text, keyword)) return true;
    return false;
}
