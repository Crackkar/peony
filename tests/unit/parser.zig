const std = @import("std");
const parser = @import("frontend_parser");
const ast_module = @import("frontend_ast");

const Ast = ast_module.Ast;
const Kind = ast_module.Kind;

pub fn testStatementsAndSuites() !void {
    const source = "x = 1\nif x < 2:\n    x += 1\nelse:\n    x = 3\n";
    var ast = try expectAst(source);
    defer ast.deinit();

    const module_children = ast.children(0);
    try std.testing.expectEqual(@as(usize, 2), module_children.len);
    const assign = ast.node(module_children[0]);
    try std.testing.expectEqual(Kind.assignment, assign.kind);
    try std.testing.expectEqual(@as(usize, 0), assign.span.start);
    try std.testing.expectEqual(@as(usize, 5), assign.span.end);
    const if_node = ast.node(module_children[1]);
    try std.testing.expectEqual(Kind.if_statement, if_node.kind);
    const if_children = ast.children(module_children[1]);
    try std.testing.expectEqual(@as(usize, 3), if_children.len);
    try std.testing.expectEqual(Kind.comparison_chain, ast.node(if_children[0]).kind);
    const body = ast.node(if_children[1]);
    try std.testing.expectEqual(Kind.block, body.kind);
    const body_items = ast.children(if_children[1]);
    try std.testing.expectEqual(@as(usize, 1), body_items.len);
    try std.testing.expectEqual(Kind.augmented_assignment, ast.node(body_items[0]).kind);
    try std.testing.expectEqual(Kind.block, ast.node(if_children[2]).kind);
    try std.testing.expectEqual(Kind.assignment, ast.node(ast.children(if_children[2])[0]).kind);

    var loops = try expectAst("while ready:\n    pass\nelse:\n    pass\nfor left, right in pairs:\n    break\nelse:\n    pass\n");
    defer loops.deinit();
    const while_id = loops.children(0)[0];
    try std.testing.expectEqual(Kind.while_statement, loops.node(while_id).kind);
    const while_children = loops.children(while_id);
    try std.testing.expectEqual(@as(usize, 3), while_children.len);
    try std.testing.expectEqual(Kind.name, loops.node(while_children[0]).kind);
    try std.testing.expectEqual(Kind.block, loops.node(while_children[1]).kind);
    try std.testing.expectEqual(Kind.block, loops.node(while_children[2]).kind);
    const for_id = loops.children(0)[1];
    try std.testing.expectEqual(Kind.for_statement, loops.node(for_id).kind);
    const for_children = loops.children(for_id);
    try std.testing.expectEqual(@as(usize, 4), for_children.len);
    try std.testing.expectEqual(Kind.tuple_display, loops.node(for_children[0]).kind);
    try std.testing.expectEqual(Kind.name, loops.node(for_children[1]).kind);
    try std.testing.expectEqual(Kind.block, loops.node(for_children[2]).kind);
    try std.testing.expectEqual(Kind.block, loops.node(for_children[3]).kind);
}

pub fn testPrecedence() !void {
    const source = "-2**2\n2**3**2\na or b and c\na < b < c\n";
    var ast = try expectAst(source);
    defer ast.deinit();
    const statements = ast.children(0);
    try std.testing.expectEqual(@as(usize, 4), statements.len);

    const unary_id = ast.children(statements[0])[0];
    const unary = ast.node(unary_id);
    try std.testing.expectEqual(Kind.unary_expression, unary.kind);
    try std.testing.expectEqualStrings("-", unary.text);
    const power = ast.node(ast.children(unary_id)[0]);
    try std.testing.expectEqual(Kind.binary_expression, power.kind);
    try std.testing.expectEqualStrings("**", power.text);

    const right_associative_id = ast.children(statements[1])[0];
    const right_associative = ast.node(right_associative_id);
    try std.testing.expectEqual(Kind.binary_expression, right_associative.kind);
    try std.testing.expectEqual(Kind.binary_expression, ast.node(ast.children(right_associative_id)[1]).kind);
    try std.testing.expectEqualStrings("**", ast.node(ast.children(right_associative_id)[1]).text);

    const boolean_or_id = ast.children(statements[2])[0];
    const boolean_or = ast.node(boolean_or_id);
    try std.testing.expectEqual(Kind.boolean_expression, boolean_or.kind);
    try std.testing.expectEqualStrings("or", boolean_or.text);
    const boolean_and = ast.node(ast.children(boolean_or_id)[1]);
    try std.testing.expectEqualStrings("and", boolean_and.text);

    const chain_id = ast.children(statements[3])[0];
    const chain = ast.node(chain_id);
    try std.testing.expectEqual(Kind.comparison_chain, chain.kind);
    try std.testing.expectEqual(@as(usize, 5), ast.children(chain_id).len);
    try std.testing.expectEqualStrings("<", ast.node(ast.children(chain_id)[1]).text);
    try std.testing.expectEqualStrings("<", ast.node(ast.children(chain_id)[3]).text);
}

pub fn testPostfixesAndDisplays() !void {
    const source = "f(a, key=1).x[1:2:3]\n(a,)\n[]\n{}\n{1, 2}\n{1: 2}\n";
    var ast = try expectAst(source);
    defer ast.deinit();
    const statements = ast.children(0);
    try std.testing.expectEqual(@as(usize, 6), statements.len);

    const subscript = onlyExpression(&ast, statements[0]);
    try std.testing.expectEqual(Kind.subscript, subscript.kind);
    const expression = ast.children(statements[0])[0];
    const attribute = ast.children(expression)[0];
    try std.testing.expectEqual(Kind.attribute, ast.node(attribute).kind);
    const call = ast.children(attribute)[0];
    try std.testing.expectEqual(Kind.call, ast.node(call).kind);
    const slice = ast.children(expression)[1];
    try std.testing.expectEqual(Kind.slice, ast.node(slice).kind);
    try std.testing.expectEqual(@as(usize, 3), ast.children(slice).len);

    try std.testing.expectEqual(Kind.tuple_display, onlyExpression(&ast, statements[1]).kind);
    try std.testing.expectEqual(Kind.list_display, onlyExpression(&ast, statements[2]).kind);
    try std.testing.expectEqual(Kind.dict_display, onlyExpression(&ast, statements[3]).kind);
    try std.testing.expectEqual(Kind.set_display, onlyExpression(&ast, statements[4]).kind);
    try std.testing.expectEqual(Kind.dict_display, onlyExpression(&ast, statements[5]).kind);

    try expectError("{1, 2: 3}\n", .syntax_error, "cannot mix dictionary and set entries");
    try expectError("{1: 2, 3}\n", .syntax_error, "cannot mix dictionary and set entries");
}

pub fn testCallArgumentOrderingErrors() !void {
    try expectError("f(a=1, 2)\n", .syntax_error, "positional argument follows keyword argument");
    try expectError("f(a=1, a=2)\n", .syntax_error, "keyword argument repeated");

    // Iterable unpacking remains deferred to a later runtime commit, but its syntax is valid.
    var unpacked = try expectAst("f(a=1, *xs)\n");
    defer unpacked.deinit();
}

pub fn testFunctionSignature() !void {
    const source = "def f(a, b=1, /, c: int=2, *args, d, **kwargs):\n    return a\n";
    var ast = try expectAst(source);
    defer ast.deinit();
    const function = ast.node(ast.children(0)[0]);
    try std.testing.expectEqual(Kind.function_definition, function.kind);
    const children = ast.children(ast.children(0)[0]);
    try std.testing.expectEqual(@as(usize, 7), children.len);
    const a = ast.node(children[0]);
    const b = ast.node(children[1]);
    const c = ast.node(children[2]);
    const args = ast.node(children[3]);
    const d = ast.node(children[4]);
    const kwargs = ast.node(children[5]);
    try std.testing.expectEqualStrings("a", a.text);
    try std.testing.expectEqualStrings("b", b.text);
    try std.testing.expectEqualStrings("c", c.text);
    try std.testing.expectEqualStrings("args", args.text);
    try std.testing.expectEqualStrings("d", d.text);
    try std.testing.expectEqualStrings("kwargs", kwargs.text);
    try std.testing.expect((a.flags & ast_module.parameter_flags.positional_only) != 0);
    try std.testing.expect((b.flags & ast_module.parameter_flags.positional_only) != 0);
    try std.testing.expect((b.flags & ast_module.parameter_flags.has_default) != 0);
    try std.testing.expect((c.flags & ast_module.parameter_flags.has_annotation) != 0);
    try std.testing.expect((args.flags & ast_module.parameter_flags.var_positional) != 0);
    try std.testing.expect((d.flags & ast_module.parameter_flags.keyword_only) != 0);
    try std.testing.expect((kwargs.flags & ast_module.parameter_flags.var_keyword) != 0);
    try std.testing.expectEqual(Kind.block, ast.node(children[6]).kind);
    try std.testing.expectEqual(Kind.return_statement, ast.node(ast.children(children[6])[0]).kind);

    try expectError("def f(a=1, /, b):\n    pass\n", .syntax_error, "non-default argument");
    var annotated = try expectAst("def f() -> int:\n    pass\n");
    defer annotated.deinit();
    const annotated_function_id = annotated.children(0)[0];
    const annotated_function = annotated.node(annotated_function_id);
    const annotated_children = annotated.children(annotated_function_id);
    try std.testing.expect((annotated_function.flags & ast_module.function_flags.has_return_annotation) != 0);
    try std.testing.expectEqual(@as(usize, 2), annotated_children.len);
    try std.testing.expectEqual(Kind.name, annotated.node(annotated_children[0]).kind);
    try std.testing.expectEqualStrings("int", annotated.node(annotated_children[0]).text);
    try std.testing.expectEqual(Kind.block, annotated.node(annotated_children[1]).kind);
    try expectError("while True:\n    def f():\n        break\n", .syntax_error, "break outside loop");
}

pub fn testTargets() !void {
    var valid = try expectAst("a, *b = values\nobj.x += 1\ndel a[0]\n");
    defer valid.deinit();
    const valid_stmts = valid.children(0);
    try std.testing.expectEqual(Kind.assignment, valid.node(valid_stmts[0]).kind);
    try std.testing.expectEqual(Kind.augmented_assignment, valid.node(valid_stmts[1]).kind);
    try std.testing.expectEqual(Kind.delete_statement, valid.node(valid_stmts[2]).kind);

    try expectError("1 = 2\n", .syntax_error, "assign");
    try expectError("f() = 2\n", .syntax_error, "assign");
    try expectError("a, *b, *c = values\n", .syntax_error, "starred");
    try expectError("del 1\n", .syntax_error, "delete");
    try expectError("(a, b) += value\n", .syntax_error, "augmented");
}

pub fn testWalrusAndSoftKeywords() !void {
    const source = "match = 1\ncase = 2\ntype = 3\nx = (y := 4)\n";
    var ast = try expectAst(source);
    defer ast.deinit();
    try std.testing.expectEqual(@as(usize, 4), ast.children(0).len);
    const named = ast.node(ast.children(ast.children(0)[3])[1]);
    try std.testing.expectEqual(Kind.named_expression, named.kind);
    try std.testing.expectEqualStrings(":=", named.text);
}

pub fn testSuiteErrors() !void {
    try expectError("if x\n    pass\n", .syntax_error, "':'");
    try expectError("if x:\npass\n", .syntax_error, "indented block");
    const result = try parser.parse(std.testing.allocator, "if x:\n    pass\n");
    switch (result) {
        .ast => |ast_value| {
            var ast = ast_value;
            ast.deinit();
        },
        .failure => |diagnostic| {
            try std.testing.expect(diagnostic.line >= 1);
            try std.testing.expect(diagnostic.column >= 1);
            try std.testing.expect(diagnostic.span.start <= diagnostic.span.end);
        },
    }
}

pub fn testUnsupportedFeatures() !void {
    var comp_ast = try expectAst("items = [x for x in values]\n");
    comp_ast.deinit();
    var fstring_ast = try expectAst("message = f'{name}'\n");
    fstring_ast.deinit();
    try expectUnsupported("try:\n    pass\n", .later_commit, "try");
    try expectUnsupported("async def f():\n    pass\n", .excluded, "async");
    try expectUnsupported("result = (yield from values)\n", .excluded, "yield from");
    try expectUnsupported("type Point = tuple[int, int]\n", .excluded, "type statement");
    try expectUnsupported("try:\n    pass\nexcept* Error:\n    pass\n", .excluded, "except*");
    try expectUnsupported("match value:\n    case 1:\n        pass\n", .later_commit, "match");
}

fn expectAst(source: []const u8) !Ast {
    const result = try parser.parse(std.testing.allocator, source);
    return switch (result) {
        .ast => |ast| ast,
        .failure => |diagnostic| {
            std.debug.print("unexpected parser diagnostic at {d}:{d}: {s}\n", .{ diagnostic.line, diagnostic.column, diagnostic.message });
            return error.UnexpectedParseDiagnostic;
        },
    };
}

fn expectError(source: []const u8, kind: parser.DiagnosticKind, fragment: []const u8) !void {
    const result = try parser.parse(std.testing.allocator, source);
    if (result == .ast) {
        var ast = result.ast;
        ast.deinit();
        return error.ExpectedParseDiagnostic;
    }
    try std.testing.expectEqual(kind, result.failure.kind);
    try std.testing.expect(std.mem.indexOf(u8, result.failure.message, fragment) != null);
    try std.testing.expect(result.failure.line >= 1);
    try std.testing.expect(result.failure.column >= 1);
}

fn expectUnsupported(source: []const u8, support: parser.SupportStatus, fragment: []const u8) !void {
    try expectError(source, .unsupported_feature, fragment);
    const result = try parser.parse(std.testing.allocator, source);
    if (result == .ast) {
        var ast = result.ast;
        ast.deinit();
        return error.ExpectedUnsupportedFeature;
    }
    try std.testing.expectEqual(support, result.failure.support.?);
}

fn onlyExpression(ast: *const Ast, statement: ast_module.NodeId) *const ast_module.Node {
    return ast.node(ast.children(statement)[0]);
}
