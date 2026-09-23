pub const Kind = enum {
    identifier,
    integer,
    float,
    string,
    bytes,
    formatted_string,
    operator,
    delimiter,
    newline,
    indent,
    dedent,
    endmarker,
};

/// Source offsets are byte offsets; line and column are one-based physical positions.
pub const Token = struct {
    kind: Kind,
    start: usize,
    end: usize,
    line: usize,
    column: usize,
};
