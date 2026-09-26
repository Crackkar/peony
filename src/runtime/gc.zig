const std = @import("std");
const allocator_module = @import("allocator.zig");
const object = @import("object.zig");
const roots = @import("roots.zig");

pub const SessionAllocator = allocator_module.SessionAllocator;
pub const Header = object.Header;
pub const Kind = object.Kind;
pub const Tracer = object.Tracer;
pub const Root = roots.Root;
pub const RootFrame = roots.RootFrame;
pub const RootStack = roots.RootStack;

pub const Config = struct {
    initial_threshold: usize = 64 * 1024,
    threshold_growth_floor: usize = 4096,
};

pub const Heap = struct {
    session: ?*SessionAllocator = null,
    allocator: std.mem.Allocator = undefined,
    objects: ?*Header = null,
    gray: ?*Header = null,
    roots: RootStack = .{},
    object_count: usize = 0,
    collection_count: usize = 0,
    collection_threshold: usize = 64 * 1024,
    threshold_growth_floor: usize = 4096,
    collecting: bool = false,

    pub fn init(self: *Heap, session: *SessionAllocator, config: Config) void {
        std.debug.assert(self.session == null);
        self.session = session;
        self.allocator = session.allocator();
        self.collection_threshold = config.initial_threshold;
        self.threshold_growth_floor = config.threshold_growth_floor;
        session.setBeforeAllocHook(self, beforeAllocation, &self.collection_threshold);
    }

    pub fn createObject(self: *Heap, comptime T: type, kind: *const Kind) std.mem.Allocator.Error!*T {
        if (!@hasField(T, "header")) @compileError("GC objects must contain a first-field `header`");
        if (@offsetOf(T, "header") != 0) @compileError("GC object header must be the first field");

        const value = try self.allocator.create(T);
        value.header = .{
            .kind = kind,
            .marked = false,
            .allocated_next = self.objects,
            .gray_next = null,
            .allocation_size = @sizeOf(T),
            .allocation_alignment = .fromByteUnits(@alignOf(T)),
        };
        self.objects = &value.header;
        self.object_count += 1;
        return value;
    }

    /// Returns the number of objects swept. Marking and sweeping use only object headers.
    pub fn collect(self: *Heap) usize {
        std.debug.assert(!self.collecting);
        self.collecting = true;
        defer self.collecting = false;

        self.collection_count += 1;
        var tracer = object.Tracer{
            .context = self,
            .visit_fn = markFromTracer,
        };
        self.roots.visit(&tracer);

        while (self.gray) |gray_object| {
            self.gray = gray_object.gray_next;
            gray_object.gray_next = null;
            gray_object.kind.trace(gray_object, &tracer);
        }

        var swept: usize = 0;
        var link = &self.objects;
        while (link.*) |current| {
            if (current.marked) {
                current.marked = false;
                link = &current.allocated_next;
            } else {
                link.* = current.allocated_next;
                self.destroyObject(current);
                self.object_count -= 1;
                swept += 1;
            }
        }

        const session = self.session orelse unreachable;
        self.collection_threshold = growThreshold(
            self.collection_threshold,
            session.live_bytes,
            0,
            self.threshold_growth_floor,
        );
        return swept;
    }

    pub fn deinit(self: *Heap) void {
        if (self.session) |session| {
            session.clearBeforeAllocHook(self);
            while (self.objects) |current| {
                self.objects = current.allocated_next;
                self.destroyObject(current);
                self.object_count -= 1;
            }
        }
        self.* = .{};
    }

    fn beforeAllocation(context: *anyopaque, requested: usize) void {
        const self: *Heap = @ptrCast(@alignCast(context));
        if (self.collecting) return;
        const session = self.session orelse return;
        _ = self.collect();
        self.collection_threshold = growThreshold(
            self.collection_threshold,
            session.live_bytes,
            requested,
            self.threshold_growth_floor,
        );
    }

    fn markFromTracer(context: *anyopaque, value: *Header) void {
        const self: *Heap = @ptrCast(@alignCast(context));
        if (value.marked) return;
        value.marked = true;
        value.gray_next = self.gray;
        self.gray = value;
    }

    fn destroyObject(self: *Heap, value: *Header) void {
        value.kind.destroy(value, self.allocator);
        const bytes: [*]u8 = @ptrCast(value);
        const session = self.session orelse unreachable;
        session.freeAligned(bytes[0..value.allocation_size], value.allocation_alignment);
    }
};

fn growThreshold(old_threshold: usize, live_bytes: usize, pending_bytes: usize, growth_floor: usize) usize {
    const doubled_threshold = saturatingMul(old_threshold, 2);
    const doubled_live = saturatingMul(live_bytes, 2);
    const reserve = @max(pending_bytes, growth_floor);
    const pending_allowance = saturatingAdd(live_bytes, saturatingMul(reserve, 2));
    const floor_allowance = saturatingAdd(live_bytes, growth_floor);
    return @max(@max(doubled_threshold, doubled_live), @max(pending_allowance, floor_allowance));
}

fn saturatingAdd(left: usize, right: usize) usize {
    return std.math.add(usize, left, right) catch std.math.maxInt(usize);
}

fn saturatingMul(left: usize, right: usize) usize {
    return std.math.mul(usize, left, right) catch std.math.maxInt(usize);
}
