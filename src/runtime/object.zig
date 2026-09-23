const std = @import("std");

pub const Kind = struct {
    trace: *const fn (*Header, *Tracer) void = traceNothing,
    destroy: *const fn (*Header, std.mem.Allocator) void = destroyNothing,
};

pub const Header = struct {
    kind: *const Kind,
    marked: bool,
    allocated_next: ?*Header,
    gray_next: ?*Header,
    allocation_size: usize,
    allocation_alignment: std.mem.Alignment,
};

pub const Tracer = struct {
    context: *anyopaque,
    visit_fn: *const fn (*anyopaque, *Header) void,

    pub fn visit(self: *Tracer, object: ?*Header) void {
        if (object) |value| self.visit_fn(self.context, value);
    }
};

fn traceNothing(_: *Header, _: *Tracer) void {}

fn destroyNothing(_: *Header, _: std.mem.Allocator) void {}
