const std = @import("std");
const ast_module = @import("frontend_ast");

const Ast = ast_module.Ast;
const Node = ast_module.Node;
const NodeId = ast_module.NodeId;
const Kind = ast_module.Kind;
const Span = ast_module.Span;

pub const ScopeId = u32;

pub const ScopeKind = enum { module, function, class, comprehension };

pub const Binding = enum {
    local,
    cell,
    free,
    global_explicit,
    global_implicit,
    class_local,
};

pub const symbol_flags = struct {
    pub const use: u32 = 1 << 0;
    pub const assign: u32 = 1 << 1;
    pub const param: u32 = 1 << 2;
    pub const import: u32 = 1 << 3;
    pub const global_decl: u32 = 1 << 4;
    pub const nonlocal_decl: u32 = 1 << 5;
    pub const cell_required: u32 = 1 << 6;
    pub const delete: u32 = 1 << 7;
};

pub const Symbol = struct {
    name: []const u8,
    flags: u32,
    binding: Binding,
};

pub const ScopeInfo = struct {
    kind: ScopeKind,
    owner_node: NodeId,
    block_node: ?NodeId,
    parent: ?ScopeId,
    children: []const ScopeId,
    symbols: []const Symbol,
};

pub const DiagnosticKind = enum { syntax_error };

/// `name` borrows the spelling from the analyzed AST source. Successful
/// Analysis values copy all symbol names into their own arena.
pub const Diagnostic = struct {
    kind: DiagnosticKind,
    message: []const u8,
    name: []const u8,
    span: Span,
    line: usize,
    column: usize,
};

pub const AnalysisResult = union(enum) {
    analysis: Analysis,
    failure: Diagnostic,
};

pub const Analysis = struct {
    arena: std.heap.ArenaAllocator,
    scopes: []ScopeInfo,
    node_scopes: []ScopeId,
    node_bindings: []?Binding,

    pub fn deinit(self: *Analysis) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn scope(self: *const Analysis, id: ScopeId) *const ScopeInfo {
        return &self.scopes[@intCast(id)];
    }

    pub fn scopeForBlock(self: *const Analysis, block: NodeId) ?ScopeId {
        return self.scopeForNode(block);
    }

    pub fn scopeForNode(self: *const Analysis, node: NodeId) ?ScopeId {
        const index: usize = @intCast(node);
        if (index >= self.node_scopes.len) return null;
        const value = self.node_scopes[index];
        return if (value == no_scope) null else value;
    }

    pub fn bindingOf(self: *const Analysis, node: NodeId) ?Binding {
        const index: usize = @intCast(node);
        if (index >= self.node_bindings.len) return null;
        return self.node_bindings[index];
    }

    pub fn symbol(self: *const Analysis, scope_id: ScopeId, name: []const u8) ?Symbol {
        for (self.scope(scope_id).symbols) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }
};

const no_scope = std.math.maxInt(ScopeId);
const local_binding_mask = symbol_flags.assign | symbol_flags.param | symbol_flags.import | symbol_flags.delete;
const AnalyzeError = std.mem.Allocator.Error || error{ScopeAbort};

const SymbolState = struct {
    value: Symbol,
    first_use: ?usize = null,
    first_assign: ?usize = null,
    first_param: ?usize = null,
    global_node: ?NodeId = null,
    nonlocal_node: ?NodeId = null,
};

const MutableScope = struct {
    kind: ScopeKind,
    owner_node: NodeId,
    block_node: ?NodeId,
    parent: ?ScopeId,
    children: std.ArrayList(ScopeId) = .empty,
    symbols: std.ArrayList(SymbolState) = .empty,
    by_name: std.StringHashMap(usize),

    fn init(allocator: std.mem.Allocator, kind: ScopeKind, owner_node: NodeId, block_node: ?NodeId, parent: ?ScopeId) MutableScope {
        return .{
            .kind = kind,
            .owner_node = owner_node,
            .block_node = block_node,
            .parent = parent,
            .by_name = std.StringHashMap(usize).init(allocator),
        };
    }
};

pub fn analyze(backing_allocator: std.mem.Allocator, ast: *const Ast) std.mem.Allocator.Error!AnalysisResult {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    var builder = try Builder.init(arena.allocator(), ast);
    const root_scope = builder.addScope(.module, ast.root, ast.root, null) catch return error.OutOfMemory;
    builder.visit(root_scope, ast.root) catch |err| {
        if (err == error.ScopeAbort) {
            const diagnostic = builder.failure.?;
            arena.deinit();
            return .{ .failure = diagnostic };
        }
        return error.OutOfMemory;
    };
    builder.resolve() catch |err| {
        if (err == error.ScopeAbort) {
            const diagnostic = builder.failure.?;
            arena.deinit();
            return .{ .failure = diagnostic };
        }
        return error.OutOfMemory;
    };
    return .{ .analysis = try builder.finish(arena) };
}

const Builder = struct {
    allocator: std.mem.Allocator,
    ast: *const Ast,
    scopes: std.ArrayList(MutableScope) = .empty,
    node_scopes: []ScopeId,
    node_bindings: []?Binding,
    failure: ?Diagnostic = null,

    fn init(allocator: std.mem.Allocator, ast: *const Ast) std.mem.Allocator.Error!Builder {
        const node_scopes = try allocator.alloc(ScopeId, ast.nodes.len);
        @memset(node_scopes, no_scope);
        const node_bindings = try allocator.alloc(?Binding, ast.nodes.len);
        @memset(node_bindings, null);
        return .{ .allocator = allocator, .ast = ast, .node_scopes = node_scopes, .node_bindings = node_bindings };
    }

    fn addScope(self: *Builder, kind: ScopeKind, owner: NodeId, block: ?NodeId, parent: ?ScopeId) std.mem.Allocator.Error!ScopeId {
        const id: ScopeId = @intCast(self.scopes.items.len);
        try self.scopes.append(self.allocator, MutableScope.init(self.allocator, kind, owner, block, parent));
        if (parent) |parent_id| try self.scopes.items[@intCast(parent_id)].children.append(self.allocator, id);
        return id;
    }

    fn visit(self: *Builder, scope_id: ScopeId, node_id: NodeId) AnalyzeError!void {
        if (self.failure != null) return error.ScopeAbort;
        self.node_scopes[@intCast(node_id)] = scope_id;
        const node = self.ast.node(node_id);
        switch (node.kind) {
            .module, .block => try self.visitChildren(scope_id, node_id),
            .name => try self.visitName(scope_id, node_id),
            .function_definition => try self.visitFunction(scope_id, node_id),
            .lambda_expression => try self.visitLambda(scope_id, node_id),
            .class_definition => try self.visitClass(scope_id, node_id),
            .comprehension_expression => try self.visitComprehension(scope_id, node_id),
            .comprehension_clause => try self.visitChildren(scope_id, node_id),
            .call => try self.visitCall(scope_id, node_id),
            .global_statement => try self.visitDeclaration(scope_id, node_id, symbol_flags.global_decl),
            .nonlocal_statement => try self.visitDeclaration(scope_id, node_id, symbol_flags.nonlocal_decl),
            .import_statement => try self.visitImport(scope_id, node_id),
            .assignment => try self.visitAssignment(scope_id, node_id),
            .annotated_assignment => try self.visitAnnotatedAssignment(scope_id, node_id),
            .augmented_assignment => try self.visitAugmentedAssignment(scope_id, node_id),
            .delete_statement => try self.visitDelete(scope_id, node_id),
            .for_statement => try self.visitFor(scope_id, node_id),
            .try_statement => try self.visitTry(scope_id, node_id),
            .with_statement => try self.visitWith(scope_id, node_id),
            .named_expression => try self.visitNamedExpression(scope_id, node_id),
            .parameter => try self.visitChildren(scope_id, node_id),
            else => try self.visitChildren(scope_id, node_id),
        }
    }

    fn visitCall(self: *Builder, scope_id: ScopeId, node_id: NodeId) AnalyzeError!void {
        const children = self.ast.children(node_id);
        if (children.len == 1) {
            const callee = self.ast.node(children[0]);
            if (callee.kind == .name and std.mem.eql(u8, callee.text, "super")) {
                if (self.enclosingClass(scope_id)) |class_scope| {
                    try self.requireClassCell(class_scope);
                    const function_index = try self.ensureSymbol(scope_id, "__class__");
                    self.scopes.items[@intCast(scope_id)].symbols.items[function_index].value.flags |= symbol_flags.use;
                }
            }
        }
        try self.visitChildren(scope_id, node_id);
    }

    fn visitName(self: *Builder, scope_id: ScopeId, node_id: NodeId) AnalyzeError!void {
        const node = self.ast.node(node_id);
        try self.note(scope_id, node.text, symbol_flags.use, node_id);
        if (std.mem.eql(u8, node.text, "__class__") and self.scopes.items[@intCast(scope_id)].kind == .function) {
            if (self.enclosingClass(scope_id)) |class_scope| try self.requireClassCell(class_scope);
        }
    }

    fn requireClassCell(self: *Builder, class_scope: ScopeId) std.mem.Allocator.Error!void {
        const class_index = try self.ensureSymbol(class_scope, "__class__");
        self.scopes.items[@intCast(class_scope)].symbols.items[class_index].value.flags |= symbol_flags.assign | symbol_flags.cell_required;
        self.scopes.items[@intCast(class_scope)].symbols.items[class_index].value.binding = .cell;
    }

    fn enclosingClass(self: *const Builder, scope_id: ScopeId) ?ScopeId {
        var cursor = self.scopes.items[@intCast(scope_id)].parent;
        while (cursor) |parent_id| {
            const parent = self.scopes.items[@intCast(parent_id)];
            if (parent.kind == .class) return parent_id;
            cursor = parent.parent;
        }
        return null;
    }

    fn visitChildren(self: *Builder, scope_id: ScopeId, node_id: NodeId) AnalyzeError!void {
        for (self.ast.children(node_id)) |child| try self.visit(scope_id, child);
    }

    fn visitFunction(self: *Builder, parent_scope: ScopeId, function_id: NodeId) AnalyzeError!void {
        const function = self.ast.node(function_id);
        try self.note(parent_scope, function.text, symbol_flags.assign, function_id);
        const children = self.ast.children(function_id);
        if (children.len == 0) return;
        const body_id = children[children.len - 1];
        const function_scope = try self.addScope(.function, function_id, body_id, parent_scope);
        for (children[0 .. children.len - 1]) |child| {
            const child_node = self.ast.node(child);
            if (child_node.kind == .parameter) {
                self.node_scopes[@intCast(child)] = function_scope;
                try self.note(function_scope, child_node.text, symbol_flags.param | symbol_flags.assign, child);
                try self.visitChildren(parent_scope, child);
            } else try self.visit(parent_scope, child);
        }
        try self.visit(function_scope, body_id);
    }

    fn visitLambda(self: *Builder, parent_scope: ScopeId, lambda_id: NodeId) AnalyzeError!void {
        const children = self.ast.children(lambda_id);
        if (children.len == 0) return;
        const body_id = children[children.len - 1];
        const lambda_scope = try self.addScope(.function, lambda_id, body_id, parent_scope);
        self.node_scopes[@intCast(lambda_id)] = lambda_scope;
        for (children[0 .. children.len - 1]) |child| {
            const parameter = self.ast.node(child);
            if (parameter.kind == .parameter) {
                self.node_scopes[@intCast(child)] = lambda_scope;
                try self.note(lambda_scope, parameter.text, symbol_flags.param | symbol_flags.assign, child);
                try self.visitChildren(parent_scope, child);
            } else try self.visit(parent_scope, child);
        }
        try self.visit(lambda_scope, body_id);
    }

    fn visitClass(self: *Builder, parent_scope: ScopeId, class_id: NodeId) AnalyzeError!void {
        const class_node = self.ast.node(class_id);
        try self.note(parent_scope, class_node.text, symbol_flags.assign, class_id);
        const children = self.ast.children(class_id);
        if (children.len == 0) return;
        const body_id = children[children.len - 1];
        for (children[0 .. children.len - 1]) |base| try self.visit(parent_scope, base);
        const class_scope = try self.addScope(.class, class_id, body_id, parent_scope);
        try self.visit(class_scope, body_id);
    }

    fn visitComprehension(self: *Builder, parent_scope: ScopeId, expression_id: NodeId) AnalyzeError!void {
        if (try self.findNamedExpression(expression_id)) |named_expression| {
            return self.abortAt("assignment expressions are not supported in comprehensions", "", named_expression);
        }
        const children = self.ast.children(expression_id);
        if (children.len < 2) return;
        const first_clause_id = children[0];
        const first_clause = self.ast.children(first_clause_id);
        if (first_clause.len < 2) return;
        try self.visit(parent_scope, first_clause[1]);
        const comprehension_scope = try self.addScope(.comprehension, expression_id, null, parent_scope);
        self.node_scopes[@intCast(expression_id)] = comprehension_scope;
        self.node_scopes[@intCast(first_clause_id)] = comprehension_scope;
        try self.visitTarget(comprehension_scope, first_clause[0], .assignment);
        for (first_clause[2..]) |filter| try self.visit(comprehension_scope, filter);
        for (children[1 .. children.len - 1]) |clause_id| {
            self.node_scopes[@intCast(clause_id)] = comprehension_scope;
            const clause = self.ast.children(clause_id);
            if (clause.len < 2) continue;
            try self.visit(comprehension_scope, clause[1]);
            try self.visitTarget(comprehension_scope, clause[0], .assignment);
            for (clause[2..]) |filter| try self.visit(comprehension_scope, filter);
        }
        try self.visit(comprehension_scope, children[children.len - 1]);
    }

    fn findNamedExpression(self: *Builder, node_id: NodeId) std.mem.Allocator.Error!?NodeId {
        if (self.ast.node(node_id).kind == .named_expression) return node_id;
        for (self.ast.children(node_id)) |child| {
            if (try self.findNamedExpression(child)) |found| return found;
        }
        return null;
    }

    fn visitDeclaration(self: *Builder, scope_id: ScopeId, node_id: NodeId, declaration_flag: u32) AnalyzeError!void {
        for (self.ast.children(node_id)) |child| {
            self.node_scopes[@intCast(child)] = scope_id;
            const name = self.ast.node(child);
            if (name.kind != .name) {
                try self.visit(scope_id, child);
                continue;
            }
            try self.note(scope_id, name.text, declaration_flag, child);
            const index = self.symbolIndex(scope_id, name.text).?;
            if (declaration_flag == symbol_flags.global_decl) {
                if (self.scopes.items[@intCast(scope_id)].symbols.items[index].global_node == null) self.scopes.items[@intCast(scope_id)].symbols.items[index].global_node = child;
            } else if (self.scopes.items[@intCast(scope_id)].symbols.items[index].nonlocal_node == null) {
                self.scopes.items[@intCast(scope_id)].symbols.items[index].nonlocal_node = child;
            }
        }
    }

    fn visitImport(self: *Builder, scope_id: ScopeId, node_id: NodeId) AnalyzeError!void {
        for (self.ast.children(node_id)) |alias_id| {
            const alias = self.ast.node(alias_id);
            self.node_scopes[@intCast(alias_id)] = scope_id;
            if (alias.kind == .import_alias) try self.note(scope_id, alias.text, symbol_flags.import | symbol_flags.assign, alias_id) else try self.visit(scope_id, alias_id);
        }
    }

    fn visitAssignment(self: *Builder, scope_id: ScopeId, node_id: NodeId) AnalyzeError!void {
        const children = self.ast.children(node_id);
        if (children.len == 0) return;
        for (children[0 .. children.len - 1]) |target| try self.visitTarget(scope_id, target, .assignment);
        try self.visit(scope_id, children[children.len - 1]);
    }

    fn visitAnnotatedAssignment(self: *Builder, scope_id: ScopeId, node_id: NodeId) AnalyzeError!void {
        const children = self.ast.children(node_id);
        if (children.len == 0) return;
        try self.visitTarget(scope_id, children[0], .assignment);
        for (children[1..]) |expression| try self.visit(scope_id, expression);
    }

    fn visitAugmentedAssignment(self: *Builder, scope_id: ScopeId, node_id: NodeId) AnalyzeError!void {
        const children = self.ast.children(node_id);
        if (children.len < 2) return;
        const target = self.ast.node(children[0]);
        if (target.kind == .name) {
            try self.note(scope_id, target.text, symbol_flags.use | symbol_flags.assign, children[0]);
            self.node_scopes[@intCast(children[0])] = scope_id;
        } else try self.visit(scope_id, children[0]);
        try self.visit(scope_id, children[1]);
    }

    fn visitDelete(self: *Builder, scope_id: ScopeId, node_id: NodeId) AnalyzeError!void {
        for (self.ast.children(node_id)) |target| try self.visitTarget(scope_id, target, .delete);
    }

    fn visitFor(self: *Builder, scope_id: ScopeId, node_id: NodeId) AnalyzeError!void {
        const children = self.ast.children(node_id);
        if (children.len < 2) return;
        try self.visitTarget(scope_id, children[0], .assignment);
        try self.visit(scope_id, children[1]);
        for (children[2..]) |child| try self.visit(scope_id, child);
    }

    fn visitTry(self: *Builder, scope_id: ScopeId, node_id: NodeId) AnalyzeError!void {
        const node = self.ast.node(node_id);
        const children = self.ast.children(node_id);
        const handler_count: usize = node.flags >> ast_module.try_flags.handler_count_shift;
        if (children.len < 1 + handler_count) return error.ScopeAbort;
        try self.visit(scope_id, children[0]);
        var cursor: usize = 1;
        for (children[1 .. 1 + handler_count]) |handler_id| {
            const handler = self.ast.node(handler_id);
            self.node_scopes[@intCast(handler_id)] = scope_id;
            const handler_children = self.ast.children(handler_id);
            if (handler.flags & ast_module.handler_flags.has_type != 0) {
                if (handler_children.len == 0) return error.ScopeAbort;
                try self.visit(scope_id, handler_children[0]);
            }
            const body_index: usize = @intFromBool(handler.flags & ast_module.handler_flags.has_type != 0);
            if (handler.flags & ast_module.handler_flags.has_target != 0) {
                try self.note(scope_id, handler.text, symbol_flags.assign, handler_id);
            }
            if (body_index >= handler_children.len) return error.ScopeAbort;
            try self.visit(scope_id, handler_children[body_index]);
            cursor += 1;
        }
        if (node.flags & ast_module.try_flags.has_else != 0) {
            if (cursor >= children.len) return error.ScopeAbort;
            try self.visit(scope_id, children[cursor]);
            cursor += 1;
        }
        if (node.flags & ast_module.try_flags.has_finally != 0) {
            if (cursor >= children.len) return error.ScopeAbort;
            try self.visit(scope_id, children[cursor]);
        }
    }

    fn visitWith(self: *Builder, scope_id: ScopeId, node_id: NodeId) AnalyzeError!void {
        const node = self.ast.node(node_id);
        const children = self.ast.children(node_id);
        const item_count: usize = node.flags;
        if (item_count == 0 or children.len != item_count + 1) return error.ScopeAbort;
        for (children[0..item_count]) |item_id| {
            const item = self.ast.node(item_id);
            const item_children = self.ast.children(item_id);
            if (item_children.len == 0) return error.ScopeAbort;
            try self.visit(scope_id, item_children[0]);
            if (item.flags & ast_module.with_item_flags.has_target != 0) {
                if (item_children.len != 2) return error.ScopeAbort;
                try self.visitTarget(scope_id, item_children[1], .assignment);
            }
        }
        try self.visit(scope_id, children[item_count]);
    }

    fn visitNamedExpression(self: *Builder, scope_id: ScopeId, node_id: NodeId) AnalyzeError!void {
        const children = self.ast.children(node_id);
        if (children.len < 2) return;
        try self.visitTarget(scope_id, children[0], .assignment);
        try self.visit(scope_id, children[1]);
    }

    const TargetMode = enum { assignment, delete };

    fn visitTarget(self: *Builder, scope_id: ScopeId, node_id: NodeId, mode: TargetMode) AnalyzeError!void {
        self.node_scopes[@intCast(node_id)] = scope_id;
        const node = self.ast.node(node_id);
        switch (node.kind) {
            .name => try self.note(scope_id, node.text, if (mode == .delete) symbol_flags.delete else symbol_flags.assign, node_id),
            .tuple_display, .list_display, .starred => try self.visitChildrenTarget(scope_id, node_id, mode),
            else => try self.visit(scope_id, node_id),
        }
    }

    fn visitChildrenTarget(self: *Builder, scope_id: ScopeId, node_id: NodeId, mode: TargetMode) AnalyzeError!void {
        for (self.ast.children(node_id)) |child| try self.visitTarget(scope_id, child, mode);
    }

    fn note(self: *Builder, scope_id: ScopeId, name: []const u8, added_flags: u32, node_id: NodeId) std.mem.Allocator.Error!void {
        const index = try self.ensureSymbol(scope_id, name);
        const state = &self.scopes.items[@intCast(scope_id)].symbols.items[index];
        state.value.flags |= added_flags;
        const position = self.ast.node(node_id).span.start;
        if (added_flags & symbol_flags.use != 0) state.first_use = minPosition(state.first_use, position);
        if (added_flags & (symbol_flags.assign | symbol_flags.import | symbol_flags.delete) != 0) state.first_assign = minPosition(state.first_assign, position);
        if (added_flags & symbol_flags.param != 0) state.first_param = minPosition(state.first_param, position);
    }

    fn ensureSymbol(self: *Builder, scope_id: ScopeId, name: []const u8) std.mem.Allocator.Error!usize {
        const scope = &self.scopes.items[@intCast(scope_id)];
        if (scope.by_name.get(name)) |index| return index;
        const owned_name = try self.allocator.dupe(u8, name);
        const index = scope.symbols.items.len;
        try scope.symbols.append(self.allocator, .{ .value = .{ .name = owned_name, .flags = 0, .binding = .global_implicit } });
        try scope.by_name.put(owned_name, index);
        return index;
    }

    fn symbolIndex(self: *const Builder, scope_id: ScopeId, name: []const u8) ?usize {
        return self.scopes.items[@intCast(scope_id)].by_name.get(name);
    }

    fn resolve(self: *Builder) AnalyzeError!void {
        try self.validateDeclarations();
        for (self.scopes.items, 0..) |*scope, scope_index| {
            for (scope.symbols.items) |*symbol| {
                if (symbol.value.flags & symbol_flags.nonlocal_decl != 0) {
                    if (!try self.resolveNonlocal(@intCast(scope_index), symbol.value.name)) return self.abortAt("no binding for nonlocal name", symbol.value.name, symbol.nonlocal_node orelse scope.owner_node);
                    continue;
                }
                if (symbol.value.flags & (symbol_flags.global_decl | local_binding_mask) != 0) continue;
                if (symbol.value.flags & symbol_flags.use == 0) continue;
                if (try self.resolveFree(@intCast(scope_index), symbol.value.name)) symbol.value.binding = .free;
            }
        }
        for (self.scopes.items) |*scope| {
            for (scope.symbols.items) |*symbol| {
                if (symbol.value.flags & symbol_flags.global_decl != 0) {
                    symbol.value.binding = .global_explicit;
                    continue;
                }
                if (symbol.value.flags & symbol_flags.nonlocal_decl != 0) {
                    symbol.value.binding = .free;
                    continue;
                }
                if (symbol.value.binding == .cell or symbol.value.binding == .free) continue;
                if (scope.kind == .module) {
                    symbol.value.binding = .global_implicit;
                } else if (scope.kind == .class) {
                    symbol.value.binding = if (symbol.value.flags & local_binding_mask != 0) .class_local else .global_implicit;
                } else {
                    symbol.value.binding = if (symbol.value.flags & local_binding_mask != 0) .local else .global_implicit;
                }
            }
        }
        try self.assignOccurrenceBindings();
    }

    fn validateDeclarations(self: *Builder) AnalyzeError!void {
        for (self.scopes.items, 0..) |scope, scope_index| {
            for (scope.symbols.items) |symbol| {
                const value = symbol.value;
                const has_global = value.flags & symbol_flags.global_decl != 0;
                const has_nonlocal = value.flags & symbol_flags.nonlocal_decl != 0;
                if (has_global and has_nonlocal) return self.abortAt("both global and nonlocal declarations conflict", value.name, scope.symbols.items[self.symbolIndex(@intCast(scope_index), value.name).?].nonlocal_node orelse scope.owner_node);
                if (!has_global and !has_nonlocal) continue;
                const declaration_node = if (has_global) symbol.global_node else symbol.nonlocal_node;
                if (symbol.first_param != null) return self.abortAt(if (has_global) "parameter and global declaration conflict" else "parameter and nonlocal declaration conflict", value.name, declaration_node orelse scope.owner_node);
                if (has_global) {
                    if (symbol.first_use != null and symbol.first_use.? < self.ast.node(declaration_node orelse scope.owner_node).span.start) return self.abortAt("name used before global declaration", value.name, declaration_node orelse scope.owner_node);
                    if (symbol.first_assign != null and symbol.first_assign.? < self.ast.node(declaration_node orelse scope.owner_node).span.start) return self.abortAt("name assigned before global declaration", value.name, declaration_node orelse scope.owner_node);
                } else {
                    if (scope.kind == .module) return self.abortAt("nonlocal declaration at module scope", value.name, declaration_node orelse scope.owner_node);
                    if (symbol.first_use != null and symbol.first_use.? < self.ast.node(declaration_node orelse scope.owner_node).span.start) return self.abortAt("name used before nonlocal declaration", value.name, declaration_node orelse scope.owner_node);
                    if (symbol.first_assign != null and symbol.first_assign.? < self.ast.node(declaration_node orelse scope.owner_node).span.start) return self.abortAt("name assigned before nonlocal declaration", value.name, declaration_node orelse scope.owner_node);
                }
            }
        }
    }

    fn resolveNonlocal(self: *Builder, scope_id: ScopeId, name: []const u8) AnalyzeError!bool {
        var current = self.scopes.items[@intCast(scope_id)].parent;
        var bridges: std.ArrayList(ScopeId) = .empty;
        while (current) |parent_id| {
            const parent = &self.scopes.items[@intCast(parent_id)];
            if (parent.kind == .module) break;
            if (parent.kind == .function or parent.kind == .comprehension) {
                if (self.symbolIndex(parent_id, name)) |index| {
                    const outer = &parent.symbols.items[index];
                    if (outer.value.flags & symbol_flags.global_decl != 0) {
                        current = parent.parent;
                        continue;
                    }
                    if (outer.value.flags & symbol_flags.nonlocal_decl != 0) {
                        try bridges.append(self.allocator, parent_id);
                        current = parent.parent;
                        continue;
                    }
                    if (outer.value.flags & local_binding_mask != 0) {
                        try self.capture(parent_id, index);
                        try self.markBridges(bridges.items, name);
                        self.setBinding(scope_id, name, .free);
                        return true;
                    }
                }
                try bridges.append(self.allocator, parent_id);
            }
            current = parent.parent;
        }
        return false;
    }

    fn resolveFree(self: *Builder, scope_id: ScopeId, name: []const u8) AnalyzeError!bool {
        var current = self.scopes.items[@intCast(scope_id)].parent;
        var bridges: std.ArrayList(ScopeId) = .empty;
        while (current) |parent_id| {
            const parent = &self.scopes.items[@intCast(parent_id)];
            if (parent.kind == .module) break;
            if (parent.kind == .class and std.mem.eql(u8, name, "__class__")) {
                if (self.symbolIndex(parent_id, name)) |index| {
                    if (parent.symbols.items[index].value.flags & symbol_flags.cell_required != 0) {
                        try self.capture(parent_id, index);
                        try self.markBridges(bridges.items, name);
                        return true;
                    }
                }
            }
            if (parent.kind == .function or parent.kind == .comprehension) {
                if (self.symbolIndex(parent_id, name)) |index| {
                    const outer = &parent.symbols.items[index];
                    if (outer.value.flags & symbol_flags.global_decl != 0) break;
                    if (outer.value.flags & symbol_flags.nonlocal_decl != 0) {
                        try bridges.append(self.allocator, parent_id);
                        current = parent.parent;
                        continue;
                    }
                    if (outer.value.flags & local_binding_mask != 0) {
                        try self.capture(parent_id, index);
                        try self.markBridges(bridges.items, name);
                        return true;
                    }
                }
                try bridges.append(self.allocator, parent_id);
            }
            current = parent.parent;
        }
        return false;
    }

    fn capture(self: *Builder, scope_id: ScopeId, symbol_index: usize) std.mem.Allocator.Error!void {
        const target = &self.scopes.items[@intCast(scope_id)].symbols.items[symbol_index];
        target.value.flags |= symbol_flags.cell_required;
        target.value.binding = .cell;
    }

    fn markBridges(self: *Builder, bridges: []const ScopeId, name: []const u8) std.mem.Allocator.Error!void {
        for (bridges) |bridge_id| {
            const bridge = &self.scopes.items[@intCast(bridge_id)];
            if (bridge.kind != .function and bridge.kind != .comprehension) continue;
            const index = try self.ensureSymbol(bridge_id, name);
            const symbol = &self.scopes.items[@intCast(bridge_id)].symbols.items[index];
            if (symbol.value.flags & local_binding_mask == 0 and symbol.value.flags & symbol_flags.global_decl == 0) {
                symbol.value.flags |= symbol_flags.use;
                symbol.value.binding = .free;
            }
        }
    }

    fn setBinding(self: *Builder, scope_id: ScopeId, name: []const u8, binding: Binding) void {
        if (self.symbolIndex(scope_id, name)) |index| self.scopes.items[@intCast(scope_id)].symbols.items[index].value.binding = binding;
    }

    fn assignOccurrenceBindings(self: *Builder) std.mem.Allocator.Error!void {
        for (self.ast.nodes, 0..) |node, index| {
            if ((node.kind != .name and node.kind != .except_handler) or self.node_scopes[index] == no_scope) continue;
            const scope_id = self.node_scopes[index];
            if (self.symbolIndex(scope_id, node.text)) |symbol_index| {
                self.node_bindings[index] = self.scopes.items[@intCast(scope_id)].symbols.items[symbol_index].value.binding;
            }
        }
    }

    fn abortAt(self: *Builder, message: []const u8, name: []const u8, node_id: NodeId) error{ScopeAbort} {
        const span = self.ast.node(node_id).span;
        const location = sourceLocation(self.ast.source, span.start);
        self.failure = .{ .kind = .syntax_error, .message = message, .name = name, .span = span, .line = location.line, .column = location.column };
        return error.ScopeAbort;
    }

    fn finish(self: *Builder, arena: std.heap.ArenaAllocator) std.mem.Allocator.Error!Analysis {
        const completed = try self.allocator.alloc(ScopeInfo, self.scopes.items.len);
        for (self.scopes.items, 0..) |*scope, index| {
            const symbols = try self.allocator.alloc(Symbol, scope.symbols.items.len);
            for (scope.symbols.items, 0..) |state, symbol_index| symbols[symbol_index] = state.value;
            completed[index] = .{
                .kind = scope.kind,
                .owner_node = scope.owner_node,
                .block_node = scope.block_node,
                .parent = scope.parent,
                .children = try scope.children.toOwnedSlice(self.allocator),
                .symbols = symbols,
            };
        }
        return .{
            .arena = arena,
            .scopes = completed,
            .node_scopes = self.node_scopes,
            .node_bindings = self.node_bindings,
        };
    }
};

fn minPosition(current: ?usize, candidate: usize) ?usize {
    return if (current) |value| @min(value, candidate) else candidate;
}

fn sourceLocation(source: []const u8, end: usize) struct { line: usize, column: usize } {
    var line: usize = 1;
    var column: usize = 1;
    var index: usize = if (std.mem.startsWith(u8, source, "\xef\xbb\xbf")) 3 else 0;
    while (index < end and index < source.len) {
        const byte = source[index];
        if (byte == '\r') {
            if (index + 1 < end and source[index + 1] == '\n') index += 1;
            index += 1;
            line += 1;
            column = 1;
        } else if (byte == '\n') {
            index += 1;
            line += 1;
            column = 1;
        } else if (byte == '\t') {
            index += 1;
            column = ((column - 1) / 8 + 1) * 8 + 1;
        } else {
            index += utf8Length(byte);
            column += 1;
        }
    }
    return .{ .line = line, .column = column };
}

fn utf8Length(byte: u8) usize {
    if (byte <= 0x7f) return 1;
    if (byte >= 0xc2 and byte <= 0xdf) return 2;
    if (byte >= 0xe0 and byte <= 0xef) return 3;
    if (byte >= 0xf0 and byte <= 0xf4) return 4;
    return 1;
}
