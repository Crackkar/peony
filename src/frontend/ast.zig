const std = @import("std");

pub const NodeId = u32;

pub const Span = struct {
    start: usize,
    end: usize,
};

pub const Kind = enum {
    module,
    block,
    expression_statement,
    assignment,
    annotated_assignment,
    augmented_assignment,
    delete_statement,
    pass_statement,
    break_statement,
    continue_statement,
    return_statement,
    raise_statement,
    assert_statement,
    global_statement,
    nonlocal_statement,
    if_statement,
    while_statement,
    for_statement,
    try_statement,
    except_handler,
    with_statement,
    with_item,
    match_statement,
    match_case,
    capture_pattern,
    wildcard_pattern,
    or_pattern,
    function_definition,
    class_definition,
    parameter,
    import_statement,
    import_alias,
    name,
    integer_literal,
    float_literal,
    string_literal,
    bytes_literal,
    formatted_string_literal,
    formatted_value,
    string_concatenation,
    none_literal,
    bool_literal,
    tuple_display,
    list_display,
    set_display,
    dict_display,
    attribute,
    subscript,
    slice,
    call,
    keyword_argument,
    starred,
    unary_expression,
    binary_expression,
    boolean_expression,
    comparison_chain,
    operator,
    conditional_expression,
    lambda_expression,
    named_expression,
    yield_expression,
    comprehension_expression,
    comprehension_clause,
};

pub const parameter_flags = struct {
    pub const positional_only: u32 = 1 << 0;
    pub const keyword_only: u32 = 1 << 1;
    pub const var_positional: u32 = 1 << 2;
    pub const var_keyword: u32 = 1 << 3;
    pub const has_default: u32 = 1 << 4;
    pub const has_annotation: u32 = 1 << 5;
};

pub const function_flags = struct {
    pub const has_return_annotation: u32 = 1 << 0;
    pub const decorator_count_shift: u5 = 8;
    pub const decorator_count_mask: u32 = 0xff << decorator_count_shift;
};

pub const class_flags = struct {
    pub const decorator_count_shift: u5 = 0;
    pub const decorator_count_mask: u32 = 0xff;
};

pub const comprehension_flags = struct {
    pub const list: u32 = 1;
    pub const set: u32 = 2;
    pub const dict: u32 = 3;
    pub const generator: u32 = 4;
};

pub const try_flags = struct {
    pub const has_else: u32 = 1 << 0;
    pub const has_finally: u32 = 1 << 1;
    pub const handler_count_shift: u5 = 2;
};

pub const handler_flags = struct {
    pub const has_type: u32 = 1 << 0;
    pub const has_target: u32 = 1 << 1;
};

pub const with_item_flags = struct {
    pub const has_target: u32 = 1 << 0;
};

pub const import_flags = struct {
    pub const from_import: u32 = 1 << 0;
    pub const wildcard: u32 = 1 << 1;
    pub const relative_shift: u5 = 8;
    pub const relative_mask: u32 = 0xff << relative_shift;
};

pub const import_alias_flags = struct {
    pub const has_alias: u32 = 1 << 0;
};

pub const match_case_flags = struct {
    pub const has_guard: u32 = 1 << 0;
};

/// Children occupy one contiguous range in Ast.children. Names, literal spellings,
/// and operator spellings borrow bytes from the compilation source. Function
/// nodes store decorator expressions, parameters, an optional return annotation
/// when marked by `function_flags.has_return_annotation`, and the body last.
/// Class nodes store decorator expressions, base expressions, then a block. Future comprehension
/// nodes store clause nodes followed by their result expression; each clause
/// stores target, iterable, then zero or more filters. Import alias text is the
/// bound local name.
pub const Node = struct {
    kind: Kind,
    span: Span,
    text: []const u8 = "",
    flags: u32 = 0,
    children_start: u32 = 0,
    children_len: u32 = 0,
};

/// A compilation-owned tree. Deinitializing its arena releases tokens, nodes,
/// edges, and any parser scratch storage with one operation.
pub const Ast = struct {
    arena: std.heap.ArenaAllocator,
    source: []const u8,
    nodes: []Node,
    children_data: []NodeId,
    root: NodeId,

    pub fn deinit(self: *Ast) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn node(self: *const Ast, id: NodeId) *const Node {
        return &self.nodes[@intCast(id)];
    }

    pub fn children(self: *const Ast, id: NodeId) []const NodeId {
        const value = self.node(id);
        const start: usize = value.children_start;
        const length: usize = value.children_len;
        return self.children_data[start..][0..length];
    }
};
