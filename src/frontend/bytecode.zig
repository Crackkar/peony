const std = @import("std");
const gc = @import("runtime_gc");
const runtime_value = @import("runtime_value");

pub const Opcode = enum(u8) {
    load_const = 1,
    load_none,
    load_global,
    store_global,
    move,
    unary,
    binary,
    print,
    return_value,
    jump,
    jump_if_false,
    jump_if_true,
    truth,
    compare,
    make_range,
    get_iterator,
    for_next,
    load_local,
    store_local,
    call,
    make_function,
    make_sequence,
    make_slice,
    get_attribute,
    get_item,
    set_item,
    delete_item,
    delete_local,
    delete_global,
    unpack,
    materialize_star,
    make_mapping,
    mapping_set,
    mapping_update,
    materialize_dstar,
    list_append_value,
    format_value,
    make_generator,
    yield_value,
    enter_try,
    try_else,
    try_complete,
    try_unhandled,
    load_exception,
    match_exception,
    bind_exception,
    raise_value,
    raise_current,
    assert_failed,
    end_finally,
    unwind_jump,
    accept_exception,
    with_enter,
    with_exit,
    make_class,
    set_attribute,
    delete_attribute,
    store_annotation,
    import_module,
    import_member,
    import_star,
};

/// Fixed 64-bit register instruction. The least-significant byte is the opcode;
/// A, B, C occupy successive 16-bit fields, and flags occupy the high byte.
pub const Instruction = struct {
    word: u64,

    pub fn init(op: Opcode, operand_a: u32, operand_b: u32, operand_c: u32, instruction_flags: u8) error{RegisterOutOfRange}!Instruction {
        if (operand_a > std.math.maxInt(u16) or operand_b > std.math.maxInt(u16) or operand_c > std.math.maxInt(u16)) {
            return error.RegisterOutOfRange;
        }
        return .{ .word = pack(op, @intCast(operand_a), @intCast(operand_b), @intCast(operand_c), instruction_flags) };
    }

    pub fn withIndex32(op: Opcode, operand_a: u32, index: u32, instruction_flags: u8) error{RegisterOutOfRange}!Instruction {
        return init(op, operand_a, index >> 16, index & 0xffff, instruction_flags);
    }

    pub fn decode(word: u64) Instruction {
        return .{ .word = word };
    }

    pub fn encode(self: Instruction) u64 {
        return self.word;
    }

    pub fn opcode(self: Instruction) Opcode {
        return @enumFromInt(@as(u8, @truncate(self.word)));
    }

    pub fn opcodeTag(self: Instruction) ?Opcode {
        return switch (@as(u8, @truncate(self.word))) {
            1 => .load_const,
            2 => .load_none,
            3 => .load_global,
            4 => .store_global,
            5 => .move,
            6 => .unary,
            7 => .binary,
            8 => .print,
            9 => .return_value,
            10 => .jump,
            11 => .jump_if_false,
            12 => .jump_if_true,
            13 => .truth,
            14 => .compare,
            15 => .make_range,
            16 => .get_iterator,
            17 => .for_next,
            18 => .load_local,
            19 => .store_local,
            20 => .call,
            21 => .make_function,
            22 => .make_sequence,
            23 => .make_slice,
            24 => .get_attribute,
            25 => .get_item,
            26 => .set_item,
            27 => .delete_item,
            28 => .delete_local,
            29 => .delete_global,
            30 => .unpack,
            31 => .materialize_star,
            32 => .make_mapping,
            33 => .mapping_set,
            34 => .mapping_update,
            35 => .materialize_dstar,
            36 => .list_append_value,
            37 => .format_value,
            38 => .make_generator,
            39 => .yield_value,
            40 => .enter_try,
            41 => .try_else,
            42 => .try_complete,
            43 => .try_unhandled,
            44 => .load_exception,
            45 => .match_exception,
            46 => .bind_exception,
            47 => .raise_value,
            48 => .raise_current,
            49 => .assert_failed,
            50 => .end_finally,
            51 => .unwind_jump,
            52 => .accept_exception,
            53 => .with_enter,
            54 => .with_exit,
            55 => .make_class,
            56 => .set_attribute,
            57 => .delete_attribute,
            58 => .store_annotation,
            59 => .import_module,
            60 => .import_member,
            61 => .import_star,
            else => null,
        };
    }

    pub fn a(self: Instruction) u16 {
        return @truncate(self.word >> 8);
    }

    pub fn b(self: Instruction) u16 {
        return @truncate(self.word >> 24);
    }

    pub fn c(self: Instruction) u16 {
        return @truncate(self.word >> 40);
    }

    pub fn flags(self: Instruction) u8 {
        return @truncate(self.word >> 56);
    }

    pub fn index32(self: Instruction) u32 {
        return (@as(u32, self.b()) << 16) | self.c();
    }

    fn pack(op: Opcode, operand_a: u16, operand_b: u16, operand_c: u16, instruction_flags: u8) u64 {
        return @as(u64, @intFromEnum(op)) |
            (@as(u64, operand_a) << 8) |
            (@as(u64, operand_b) << 24) |
            (@as(u64, operand_c) << 40) |
            (@as(u64, instruction_flags) << 56);
    }
};

pub const SourcePosition = struct {
    start: u32,
    end: u32,
    line: u32,
    column: u32,
};

pub const Signature = struct {
    positional_count: u16 = 0,
    positional_only_count: u16 = 0,
    keyword_only_count: u16 = 0,
    var_positional: bool = false,
    var_keyword: bool = false,
};

pub const LocalBinding = enum(u8) { local, cell, free };

pub const CallArgument = struct {
    register: u16,
    keyword_name: u32 = std.math.maxInt(u32),
    starred: bool = false,
    double_starred: bool = false,
};

pub const CallSite = struct {
    argument_start: u32,
    argument_count: u16,
};

pub const DstarSite = struct {
    previous_start: u32,
    previous_count: u16,
};

pub const FunctionSite = struct {
    code_index: u32,
    value_start: u32,
    default_count: u16,
    annotation_count: u16,
    has_return_annotation: bool,
};

pub const ClassSite = struct {
    code_index: u32,
    name_index: u32,
    decorator_start: u32,
    decorator_count: u16,
    base_start: u32,
    base_count: u16,
};

pub const UnpackSite = struct {
    destination_start: u32,
    destination_count: u16,
    star_index: u16 = std.math.maxInt(u16),
};

pub const SequenceSite = struct {
    argument_start: u32,
    argument_count: u16,
    is_tuple: bool,
};

pub const SliceSite = struct {
    start: u16,
    stop: u16,
    step: u16,
};

pub const FormatSite = struct {
    spec: []const u8,
};

pub const ImportKind = enum { module, member, star };

pub const ImportSite = struct {
    kind: ImportKind,
    module_name: []const u8 = "",
    name: []const u8 = "",
    relative_level: u8 = 0,
    bind_root: bool = false,
};

pub const TrySite = struct {
    body_start_ip: u32 = 0,
    handler_ip: u32 = 0,
    finalizer_ip: u32 = std.math.maxInt(u32),
    end_ip: u32 = 0,
    handler_count: u16 = 0,
};

pub const code_flags = struct {
    pub const function: u32 = 1 << 0;
    pub const class_body: u32 = 1 << 1;
    pub const generator: u32 = 1 << 2;
};

pub const GlobalCache = struct {
    environment_address: usize = 0,
    shape_version: u64 = 0,
    entry_index: u32 = std.math.maxInt(u32),
};

pub const Code = struct {
    allocator: std.mem.Allocator,
    instructions: []Instruction = &.{},
    constants: []runtime_value.Value = &.{},
    names: []const []const u8 = &.{},
    global_caches: []GlobalCache = &.{},
    local_names: []const []const u8 = &.{},
    cell_names: []const []const u8 = &.{},
    free_names: []const []const u8 = &.{},
    parameter_names: []const []const u8 = &.{},
    parameter_flags: []u32 = &.{},
    argument_registers: []u16 = &.{},
    call_arguments: []CallArgument = &.{},
    call_sites: []CallSite = &.{},
    dstar_previous_arguments: []CallArgument = &.{},
    dstar_sites: []DstarSite = &.{},
    function_sites: []FunctionSite = &.{},
    class_sites: []ClassSite = &.{},
    unpack_sites: []UnpackSite = &.{},
    sequence_sites: []SequenceSite = &.{},
    slice_sites: []SliceSite = &.{},
    format_sites: []FormatSite = &.{},
    import_sites: []ImportSite = &.{},
    try_sites: []TrySite = &.{},
    nested_codes: []*Code = &.{},
    positions: []SourcePosition = &.{},
    source: []u8 = &.{},
    filename: []const u8 = "",
    display_name: []const u8 = "<module>",
    register_count: u32 = 0,
    flags: u32 = 0,
    signature: Signature = .{},
    root_frame: gc.RootFrame = .{},
    root_slots: []gc.Root = &.{},

    pub fn deinit(self: *Code, heap: *gc.Heap) void {
        for (self.nested_codes) |child| child.deinit(heap);
        for (self.parameter_names) |name| self.allocator.free(name);
        if (self.root_frame.stack != null) self.root_frame.pop();
        for (self.names) |name| self.allocator.free(name);
        for (self.local_names) |name| self.allocator.free(name);
        for (self.cell_names) |name| self.allocator.free(name);
        for (self.free_names) |name| self.allocator.free(name);
        self.allocator.free(self.instructions);
        self.allocator.free(self.constants);
        self.allocator.free(self.names);
        self.allocator.free(self.global_caches);
        self.allocator.free(self.local_names);
        self.allocator.free(self.cell_names);
        self.allocator.free(self.free_names);
        self.allocator.free(self.parameter_names);
        self.allocator.free(self.parameter_flags);
        self.allocator.free(self.argument_registers);
        self.allocator.free(self.call_arguments);
        self.allocator.free(self.call_sites);
        self.allocator.free(self.dstar_previous_arguments);
        self.allocator.free(self.dstar_sites);
        self.allocator.free(self.function_sites);
        self.allocator.free(self.class_sites);
        self.allocator.free(self.unpack_sites);
        self.allocator.free(self.sequence_sites);
        self.allocator.free(self.slice_sites);
        for (self.format_sites) |site| self.allocator.free(site.spec);
        self.allocator.free(self.format_sites);
        for (self.import_sites) |site| {
            if (site.module_name.len != 0) self.allocator.free(site.module_name);
            if (site.name.len != 0) self.allocator.free(site.name);
        }
        self.allocator.free(self.import_sites);
        self.allocator.free(self.try_sites);
        self.allocator.free(self.nested_codes);
        self.allocator.free(self.positions);
        if (self.source.len != 0) self.allocator.free(self.source);
        self.allocator.free(self.filename);
        self.allocator.free(self.display_name);
        self.allocator.free(self.root_slots);
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};
