const std = @import("std");
const parser = @import("frontend_parser");
const ast_module = @import("frontend_ast");
const scope_module = @import("frontend_scope");

const Ast = ast_module.Ast;
const Kind = ast_module.Kind;
const NodeId = ast_module.NodeId;
const Span = ast_module.Span;
const Binding = scope_module.Binding;
const ScopeKind = scope_module.ScopeKind;
const flags = scope_module.symbol_flags;

pub fn testWholeBlockClassification() !void {
    const source = "x = 10\nif True:\n    block_only = 1\nif False:\n    pass\nfor loop_target in loop_iterable:\n    pass\ndef f():\n    print(x)\n    x = 1\n    return x\ndef g():\n    return x\n";
    var ast = try parseSource(source);
    defer ast.deinit();
    var analysis = try analyzeSource(&ast);
    defer analysis.deinit();

    const module_scope = analysis.scopeForBlock(ast.root).?;
    const function_id = functionNamed(&ast, "f");
    const function_scope = analysis.scopeForBlock(functionBody(&ast, function_id)).?;
    const read_before_store = nameAt(&ast, source, "x", offsetOf(source, "print(x)") + 6);
    const store = nameAt(&ast, source, "x", offsetOf(source, "    x = 1") + 4);
    const read_after_store = nameAt(&ast, source, "x", offsetOf(source, "return x") + 7);
    try std.testing.expectEqual(Binding.local, analysis.bindingOf(read_before_store).?);
    try std.testing.expectEqual(Binding.local, analysis.bindingOf(store).?);
    try std.testing.expectEqual(Binding.local, analysis.bindingOf(read_after_store).?);
    try std.testing.expectEqual(function_scope, analysis.scopeForNode(read_before_store).?);

    const function_x = analysis.symbol(function_scope, "x").?;
    try std.testing.expectEqual(Binding.local, function_x.binding);
    try std.testing.expect((function_x.flags & (flags.use | flags.assign)) == (flags.use | flags.assign));
    try std.testing.expectEqual(Binding.global_implicit, analysis.symbol(module_scope, "x").?.binding);

    const first_body = blockChild(&ast, ast.children(ast.root)[1], 1);
    const second_body = blockChild(&ast, ast.children(ast.root)[2], 1);
    try std.testing.expectEqual(module_scope, analysis.scopeForBlock(first_body).?);
    try std.testing.expectEqual(module_scope, analysis.scopeForBlock(second_body).?);
    try std.testing.expectEqual(Binding.global_implicit, analysis.symbol(module_scope, "loop_target").?.binding);
    try std.testing.expect((analysis.symbol(module_scope, "loop_target").?.flags & flags.assign) != 0);
    try std.testing.expect((analysis.symbol(module_scope, "loop_iterable").?.flags & flags.use) != 0);
    const second_scope = analysis.scopeForBlock(functionBody(&ast, functionNamed(&ast, "g"))).?;
    try std.testing.expectEqual(Binding.global_implicit, analysis.symbol(second_scope, "x").?.binding);
}

pub fn testClosuresAndShadowing() !void {
    const source =
        "def outer():\n" ++
        "    value = 1\n" ++
        "    def middle():\n" ++
        "        def inner():\n" ++
        "            return value\n" ++
        "        return inner\n" ++
        "    def sibling():\n" ++
        "        return value\n" ++
        "    def shadow():\n" ++
        "        value = 2\n" ++
        "        return value\n" ++
        "    maker = lambda arg=default_value: value + arg\n" ++
        "    return middle\n";
    var ast = try parseSource(source);
    defer ast.deinit();
    var analysis = try analyzeSource(&ast);
    defer analysis.deinit();

    const outer_scope = analysis.scopeForBlock(functionBody(&ast, functionNamed(&ast, "outer"))).?;
    const middle_scope = analysis.scopeForBlock(functionBody(&ast, functionNamed(&ast, "middle"))).?;
    const inner_scope = analysis.scopeForBlock(functionBody(&ast, functionNamed(&ast, "inner"))).?;
    const sibling_scope = analysis.scopeForBlock(functionBody(&ast, functionNamed(&ast, "sibling"))).?;
    const shadow_scope = analysis.scopeForBlock(functionBody(&ast, functionNamed(&ast, "shadow"))).?;
    const lambda_id = firstKind(&ast, .lambda_expression);
    const lambda_children = ast.children(lambda_id);
    const lambda_scope = analysis.scopeForBlock(lambda_children[lambda_children.len - 1]).?;

    try std.testing.expectEqual(Binding.cell, analysis.symbol(outer_scope, "value").?.binding);
    try std.testing.expect((analysis.symbol(outer_scope, "value").?.flags & flags.cell_required) != 0);
    try std.testing.expectEqual(Binding.free, analysis.symbol(middle_scope, "value").?.binding);
    try std.testing.expectEqual(Binding.free, analysis.symbol(inner_scope, "value").?.binding);
    try std.testing.expectEqual(Binding.free, analysis.symbol(sibling_scope, "value").?.binding);
    try std.testing.expectEqual(Binding.local, analysis.symbol(shadow_scope, "value").?.binding);
    try std.testing.expectEqual(Binding.cell, analysis.symbol(outer_scope, "value").?.binding);
    try std.testing.expectEqual(Binding.local, analysis.symbol(lambda_scope, "arg").?.binding);
    try std.testing.expectEqual(Binding.free, analysis.symbol(lambda_scope, "value").?.binding);
    try std.testing.expectEqual(Binding.global_implicit, analysis.symbol(outer_scope, "default_value").?.binding);
    try std.testing.expect((analysis.scope(outer_scope).children.len) >= 3);
}

pub fn testDeclarationsAndErrors() !void {
    const source =
        "global_value = 0\n" ++
        "def set_global():\n" ++
        "    global global_value\n" ++
        "    global_value = 1\n" ++
        "    return global_value\n" ++
        "def outer():\n" ++
        "    value = 0\n" ++
        "    def middle():\n" ++
        "        value = 1\n" ++
        "        def inner():\n" ++
        "            nonlocal value\n" ++
        "            value = 2\n" ++
        "            return value\n" ++
        "        return inner\n" ++
        "    return middle\n";
    var ast = try parseSource(source);
    defer ast.deinit();
    var analysis = try analyzeSource(&ast);
    defer analysis.deinit();

    const module_scope = analysis.scopeForBlock(ast.root).?;
    const setter_scope = analysis.scopeForBlock(functionBody(&ast, functionNamed(&ast, "set_global"))).?;
    const outer_scope = analysis.scopeForBlock(functionBody(&ast, functionNamed(&ast, "outer"))).?;
    const middle_scope = analysis.scopeForBlock(functionBody(&ast, functionNamed(&ast, "middle"))).?;
    const inner_scope = analysis.scopeForBlock(functionBody(&ast, functionNamed(&ast, "inner"))).?;
    try std.testing.expectEqual(Binding.global_implicit, analysis.symbol(module_scope, "global_value").?.binding);
    try std.testing.expectEqual(Binding.global_explicit, analysis.symbol(setter_scope, "global_value").?.binding);
    try std.testing.expect((analysis.symbol(setter_scope, "global_value").?.flags & flags.global_decl) != 0);
    try std.testing.expectEqual(Binding.local, analysis.symbol(outer_scope, "value").?.binding);
    try std.testing.expectEqual(Binding.cell, analysis.symbol(middle_scope, "value").?.binding);
    try std.testing.expectEqual(Binding.free, analysis.symbol(inner_scope, "value").?.binding);

    try expectFailure("def f():\n    print(x)\n    global x\n", "used before global declaration");
    try expectFailure("def f():\n    x = 1\n    nonlocal x\n", "assigned before nonlocal declaration");
    try expectFailure("def f(x):\n    global x\n", "parameter and global");
    try expectFailure("def f():\n    global x\n    nonlocal x\n", "both global and nonlocal");
    try expectFailure("def f():\n    nonlocal missing\n", "no binding for nonlocal");
}

pub fn testDefinitionEvaluationAndTargets() !void {
    const source =
        "default_value = 1\n" ++
        "annotation = 2\n" ++
        "return_type = 3\n" ++
        "def f(p: annotation = default_value) -> return_type:\n" ++
        "    receiver.attr = rhs\n" ++
        "    receiver[index] = rhs\n" ++
        "    del deleted\n" ++
        "    target += rhs\n" ++
        "    left, *right = values\n" ++
        "    named = (assigned := p)\n" ++
        "    return p\n";
    var ast = try parseSource(source);
    defer ast.deinit();
    var analysis = try analyzeSource(&ast);
    defer analysis.deinit();

    const module_scope = analysis.scopeForBlock(ast.root).?;
    const function_scope = analysis.scopeForBlock(functionBody(&ast, functionNamed(&ast, "f"))).?;
    for ([_][]const u8{ "default_value", "annotation", "return_type" }) |name| {
        try std.testing.expectEqual(Binding.global_implicit, analysis.symbol(module_scope, name).?.binding);
    }
    try std.testing.expectEqual(Binding.local, analysis.symbol(function_scope, "p").?.binding);
    try std.testing.expect((analysis.symbol(function_scope, "p").?.flags & flags.param) != 0);
    try std.testing.expect((analysis.symbol(function_scope, "p").?.flags & flags.assign) != 0);
    try std.testing.expectEqual(Binding.global_implicit, analysis.symbol(function_scope, "receiver").?.binding);
    try std.testing.expect((analysis.symbol(function_scope, "receiver").?.flags & flags.use) != 0);
    try std.testing.expectEqual(Binding.global_implicit, analysis.symbol(function_scope, "index").?.binding);
    try std.testing.expectEqual(Binding.local, analysis.symbol(function_scope, "deleted").?.binding);
    try std.testing.expect((analysis.symbol(function_scope, "deleted").?.flags & flags.delete) != 0);
    try std.testing.expectEqual(Binding.local, analysis.symbol(function_scope, "target").?.binding);
    try std.testing.expect((analysis.symbol(function_scope, "target").?.flags & flags.use) != 0);
    try std.testing.expect((analysis.symbol(function_scope, "target").?.flags & flags.assign) != 0);
    try std.testing.expectEqual(Binding.local, analysis.symbol(function_scope, "left").?.binding);
    try std.testing.expectEqual(Binding.local, analysis.symbol(function_scope, "right").?.binding);
    try std.testing.expectEqual(Binding.global_implicit, analysis.symbol(function_scope, "rhs").?.binding);
    try std.testing.expectEqual(Binding.global_implicit, analysis.symbol(function_scope, "values").?.binding);
    try std.testing.expectEqual(Binding.local, analysis.symbol(function_scope, "assigned").?.binding);
    try std.testing.expect((analysis.symbol(function_scope, "assigned").?.flags & flags.assign) != 0);
}

pub fn testSyntheticClassAndComprehensionScopes() !void {
    // Class and comprehension nodes are assembled directly because the parser
    // intentionally adds those source forms in later commits.
    var class_ast = try makeClassAst(std.testing.allocator, true, false);
    const outer_body = outerBodyFromAst(&class_ast);
    const method_body = functionBody(&class_ast, functionNamed(&class_ast, "method"));
    var class_analysis = try expectAnalysis(&class_ast);
    class_ast.deinit();
    defer class_analysis.deinit();

    const outer_scope = class_analysis.scopeForBlock(outer_body).?;
    const class_scope = scopeOfKind(&class_analysis, .class).?;
    const method_scope = class_analysis.scopeForBlock(method_body).?;
    try std.testing.expectEqual(Binding.cell, class_analysis.symbol(outer_scope, "shared").?.binding);
    try std.testing.expectEqual(Binding.class_local, class_analysis.symbol(class_scope, "shared").?.binding);
    try std.testing.expectEqual(Binding.free, class_analysis.symbol(method_scope, "shared").?.binding);
    try std.testing.expectEqual(Binding.cell, class_analysis.symbol(class_scope, "__class__").?.binding);
    try std.testing.expect((class_analysis.symbol(class_scope, "__class__").?.flags & flags.cell_required) != 0);
    try std.testing.expectEqual(Binding.free, class_analysis.symbol(method_scope, "__class__").?.binding);
    try std.testing.expectEqual(outer_scope, class_analysis.scope(class_scope).parent.?);
    try std.testing.expectEqual(class_scope, class_analysis.scope(method_scope).parent.?);

    var direct_class_ast = try makeClassAst(std.testing.allocator, false, false);
    const direct_method_body = functionBody(&direct_class_ast, functionNamed(&direct_class_ast, "method"));
    var direct_analysis = try expectAnalysis(&direct_class_ast);
    direct_class_ast.deinit();
    defer direct_analysis.deinit();
    const direct_class_scope = scopeOfKind(&direct_analysis, .class).?;
    const direct_method_scope = direct_analysis.scopeForBlock(direct_method_body).?;
    const direct_cell = direct_analysis.symbol(direct_class_scope, "__class__");
    try std.testing.expect(direct_cell != null);
    if (direct_cell) |cell| {
        try std.testing.expectEqual(Binding.cell, cell.binding);
        try std.testing.expect((cell.flags & flags.cell_required) != 0);
    }
    try std.testing.expectEqual(Binding.free, direct_analysis.symbol(direct_method_scope, "__class__").?.binding);

    var local_class_ast = try makeClassAst(std.testing.allocator, true, true);
    const local_method_body = functionBody(&local_class_ast, functionNamed(&local_class_ast, "method"));
    var local_analysis = try expectAnalysis(&local_class_ast);
    local_class_ast.deinit();
    defer local_analysis.deinit();
    const local_class_scope = scopeOfKind(&local_analysis, .class).?;
    const local_method_scope = local_analysis.scopeForBlock(local_method_body).?;
    try std.testing.expectEqual(Binding.cell, local_analysis.symbol(local_class_scope, "__class__").?.binding);
    try std.testing.expectEqual(Binding.local, local_analysis.symbol(local_method_scope, "__class__").?.binding);

    var comp_ast = try makeComprehensionAst(std.testing.allocator, false);
    defer comp_ast.deinit();
    var comp_analysis = try analyzeSource(&comp_ast);
    defer comp_analysis.deinit();
    const comp_outer = comp_analysis.scopeForBlock(functionBody(&comp_ast, functionNamed(&comp_ast, "outer"))).?;
    const comp_scope = scopeOfKind(&comp_analysis, .comprehension).?;
    const comp_node = firstKind(&comp_ast, .comprehension_expression);
    const comp_clause = comp_ast.children(comp_node)[0];
    const comp_target = comp_ast.children(comp_clause)[0];
    const outer_iterable = comp_ast.children(comp_clause)[1];
    try std.testing.expectEqual(Binding.cell, comp_analysis.symbol(comp_outer, "captured").?.binding);
    try std.testing.expectEqual(Binding.free, comp_analysis.symbol(comp_scope, "captured").?.binding);
    try std.testing.expectEqual(Binding.local, comp_analysis.symbol(comp_scope, "item").?.binding);
    try std.testing.expect((comp_analysis.symbol(comp_scope, "item").?.flags & flags.assign) != 0);
    try std.testing.expect(comp_analysis.symbol(comp_outer, "item") == null);
    try std.testing.expectEqual(Binding.local, comp_analysis.symbol(comp_outer, "iterable").?.binding);
    try std.testing.expectEqual(comp_scope, comp_analysis.scopeForNode(comp_node).?);
    try std.testing.expectEqual(comp_scope, comp_analysis.scopeForNode(comp_target).?);
    try std.testing.expectEqual(comp_outer, comp_analysis.scopeForNode(outer_iterable).?);
    try std.testing.expectEqual(comp_outer, comp_analysis.scope(comp_scope).parent.?);

    var invalid_comp = try makeComprehensionAst(std.testing.allocator, true);
    defer invalid_comp.deinit();
    try expectAstFailure(&invalid_comp, "assignment expressions are not supported in comprehensions");
}

pub fn testImportFlagsAndOwnedNames() !void {
    var ast = try makeImportAst(std.testing.allocator);
    var analysis = try expectAnalysis(&ast);
    ast.deinit();
    defer analysis.deinit();
    const module_scope = analysis.scope(0);
    const imported = analysis.symbol(0, "json").?;
    try std.testing.expectEqual(Binding.global_implicit, imported.binding);
    try std.testing.expect((imported.flags & flags.import) != 0);
    try std.testing.expect((imported.flags & flags.assign) != 0);
    try std.testing.expect(module_scope.symbols.len == 1);
    try std.testing.expectEqualStrings("json", imported.name);
}

fn parseSource(source: []const u8) !Ast {
    const result = try parser.parse(std.testing.allocator, source);
    return switch (result) {
        .ast => |ast| ast,
        .failure => |diagnostic| {
            std.debug.print("unexpected parser diagnostic at {d}:{d}: {s}\n", .{ diagnostic.line, diagnostic.column, diagnostic.message });
            return error.UnexpectedParseDiagnostic;
        },
    };
}

fn analyzeSource(ast: *const Ast) !scope_module.Analysis {
    return expectAnalysis(ast);
}

fn expectAnalysis(ast: *const Ast) !scope_module.Analysis {
    const result = try scope_module.analyze(std.testing.allocator, ast);
    return switch (result) {
        .analysis => |analysis| analysis,
        .failure => |diagnostic| {
            std.debug.print("unexpected scope diagnostic at {d}:{d}: {s}\n", .{ diagnostic.line, diagnostic.column, diagnostic.message });
            return error.UnexpectedScopeDiagnostic;
        },
    };
}

fn expectFailure(source: []const u8, fragment: []const u8) !void {
    var ast = try parseSource(source);
    defer ast.deinit();
    try expectAstFailure(&ast, fragment);
}

fn expectAstFailure(ast: *const Ast, fragment: []const u8) !void {
    const result = try scope_module.analyze(std.testing.allocator, ast);
    if (result == .analysis) {
        var analysis = result.analysis;
        analysis.deinit();
        return error.ExpectedScopeDiagnostic;
    }
    try std.testing.expectEqual(scope_module.DiagnosticKind.syntax_error, result.failure.kind);
    try std.testing.expect(std.mem.indexOf(u8, result.failure.message, fragment) != null);
    try std.testing.expect(result.failure.span.start <= result.failure.span.end);
    try std.testing.expect(result.failure.line >= 1);
    try std.testing.expect(result.failure.column >= 1);
}

fn functionNamed(ast: *const Ast, name: []const u8) NodeId {
    for (ast.nodes, 0..) |node, index| {
        if (node.kind == .function_definition and std.mem.eql(u8, node.text, name)) return @intCast(index);
    }
    unreachable;
}

fn firstKind(ast: *const Ast, kind: Kind) NodeId {
    for (ast.nodes, 0..) |node, index| if (node.kind == kind) return @intCast(index);
    unreachable;
}

fn functionBody(ast: *const Ast, function_id: NodeId) NodeId {
    const children = ast.children(function_id);
    return children[children.len - 1];
}

fn blockChild(ast: *const Ast, statement: NodeId, index: usize) NodeId {
    return ast.children(statement)[index];
}

fn nameAt(ast: *const Ast, source: []const u8, name: []const u8, start: usize) NodeId {
    _ = source;
    for (ast.nodes, 0..) |node, index| {
        if (node.kind == .name and node.span.start == start and std.mem.eql(u8, node.text, name)) return @intCast(index);
    }
    unreachable;
}

fn offsetOf(source: []const u8, needle: []const u8) usize {
    return std.mem.indexOf(u8, source, needle) orelse unreachable;
}

fn scopeOfKind(analysis: *const scope_module.Analysis, kind: ScopeKind) ?scope_module.ScopeId {
    for (analysis.scopes, 0..) |scope, index| if (scope.kind == kind) return @intCast(index);
    return null;
}

fn outerBodyFromAst(ast: *const Ast) NodeId {
    return functionBody(ast, functionNamed(ast, "outer"));
}

fn makeClassAst(backing_allocator: std.mem.Allocator, with_super: bool, assign_class_local: bool) !Ast {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    var builder = AstBuilder.init(arena.allocator());

    const outer_shared = try builder.name("shared");
    const outer_value = try builder.integer("1");
    const outer_assign = try builder.add(.assignment, "=", &.{ outer_shared, outer_value });
    const class_shared = try builder.name("shared");
    const class_value = try builder.integer("2");
    const class_assign = try builder.add(.assignment, "=", &.{ class_shared, class_value });

    const self_parameter = try builder.parameter("self", ast_module.parameter_flags.positional_only);
    const method_shared = try builder.name("shared");
    const class_reference = if (with_super) blk: {
        const super_name = try builder.name("super");
        break :blk try builder.add(.call, "", &.{super_name});
    } else try builder.name("__class__");
    const return_tuple = try builder.add(.tuple_display, "", &.{ method_shared, class_reference });
    const return_stmt = try builder.add(.return_statement, "", &.{return_tuple});
    const method_body = if (assign_class_local) blk: {
        const class_local_name = try builder.name("__class__");
        const class_local_value = try builder.integer("1");
        const class_local_assign = try builder.add(.assignment, "=", &.{ class_local_name, class_local_value });
        break :blk try builder.add(.block, "", &.{ class_local_assign, return_stmt });
    } else try builder.add(.block, "", &.{return_stmt});
    const method = try builder.add(.function_definition, "method", &.{ self_parameter, method_body });

    const class_body = try builder.add(.block, "", &.{ class_assign, method });
    const class = try builder.add(.class_definition, "C", &.{class_body});
    const outer_body = try builder.add(.block, "", &.{ outer_assign, class });
    const outer = try builder.add(.function_definition, "outer", &.{outer_body});
    const root = try builder.add(.module, "", &.{outer});
    return builder.finish(arena, root, "");
}

fn makeComprehensionAst(backing_allocator: std.mem.Allocator, with_named_expression: bool) !Ast {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    var builder = AstBuilder.init(arena.allocator());

    const captured_target = try builder.name("captured");
    const one = try builder.integer("1");
    const captured_assign = try builder.add(.assignment, "=", &.{ captured_target, one });
    const iterable_target = try builder.name("iterable");
    const iterable_value = try builder.integer("0");
    const iterable_assign = try builder.add(.assignment, "=", &.{ iterable_target, iterable_value });
    const item_target = try builder.name("item");
    const iterable_read = try builder.name("iterable");
    const clause = try builder.add(.comprehension_clause, "", &.{ item_target, iterable_read });
    const result: NodeId = if (with_named_expression) blk: {
        const target = try builder.name("leak");
        const value = try builder.name("captured");
        break :blk try builder.add(.named_expression, ":=", &.{ target, value });
    } else try builder.name("captured");
    const comprehension = try builder.add(.comprehension_expression, "", &.{ clause, result });
    const list_target = try builder.name("values");
    const list_assign = try builder.add(.assignment, "=", &.{ list_target, comprehension });
    const body = try builder.add(.block, "", &.{ captured_assign, iterable_assign, list_assign });
    const function = try builder.add(.function_definition, "outer", &.{body});
    const root = try builder.add(.module, "", &.{function});
    return builder.finish(arena, root, "");
}

fn makeImportAst(backing_allocator: std.mem.Allocator) !Ast {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    var builder = AstBuilder.init(arena.allocator());
    const alias = try builder.add(.import_alias, "json", &.{});
    const import_stmt = try builder.add(.import_statement, "", &.{alias});
    const root = try builder.add(.module, "", &.{import_stmt});
    return builder.finish(arena, root, "");
}

const AstBuilder = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(ast_module.Node) = .empty,
    children: std.ArrayList(NodeId) = .empty,

    fn init(allocator: std.mem.Allocator) AstBuilder {
        return .{ .allocator = allocator };
    }

    fn add(self: *AstBuilder, kind: Kind, text: []const u8, children: []const NodeId) !NodeId {
        const start: u32 = @intCast(self.children.items.len);
        try self.children.appendSlice(self.allocator, children);
        const id: NodeId = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{
            .kind = kind,
            .span = .{ .start = 0, .end = 0 },
            .text = text,
            .children_start = start,
            .children_len = @intCast(children.len),
        });
        return id;
    }

    fn name(self: *AstBuilder, text: []const u8) !NodeId {
        return self.add(.name, text, &.{});
    }

    fn integer(self: *AstBuilder, text: []const u8) !NodeId {
        return self.add(.integer_literal, text, &.{});
    }

    fn parameter(self: *AstBuilder, text: []const u8, parameter_flags: u32) !NodeId {
        const id = try self.add(.parameter, text, &.{});
        self.nodes.items[@intCast(id)].flags = parameter_flags;
        return id;
    }

    fn finish(self: *AstBuilder, arena: std.heap.ArenaAllocator, root: NodeId, source: []const u8) !Ast {
        return .{
            .arena = arena,
            .source = source,
            .nodes = try self.nodes.toOwnedSlice(self.allocator),
            .children_data = try self.children.toOwnedSlice(self.allocator),
            .root = root,
        };
    }
};
