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
};

pub const CallSite = struct {
    argument_start: u32,
    argument_count: u16,
};

pub const FunctionSite = struct {
    code_index: u32,
    value_start: u32,
    default_count: u16,
    annotation_count: u16,
    has_return_annotation: bool,
};

pub const code_flags = struct {
    pub const function: u32 = 1 << 0;
};

pub const Code = struct {
    allocator: std.mem.Allocator,
    instructions: []Instruction = &.{},
    constants: []runtime_value.Value = &.{},
    names: []const []const u8 = &.{},
    local_names: []const []const u8 = &.{},
    cell_names: []const []const u8 = &.{},
    free_names: []const []const u8 = &.{},
    parameter_names: []const []const u8 = &.{},
    parameter_flags: []u32 = &.{},
    argument_registers: []u16 = &.{},
    call_arguments: []CallArgument = &.{},
    call_sites: []CallSite = &.{},
    function_sites: []FunctionSite = &.{},
    nested_codes: []*Code = &.{},
    positions: []SourcePosition = &.{},
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
        self.allocator.free(self.local_names);
        self.allocator.free(self.cell_names);
        self.allocator.free(self.free_names);
        self.allocator.free(self.parameter_names);
        self.allocator.free(self.parameter_flags);
        self.allocator.free(self.argument_registers);
        self.allocator.free(self.call_arguments);
        self.allocator.free(self.call_sites);
        self.allocator.free(self.function_sites);
        self.allocator.free(self.nested_codes);
        self.allocator.free(self.positions);
        self.allocator.free(self.filename);
        self.allocator.free(self.display_name);
        self.allocator.free(self.root_slots);
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};
