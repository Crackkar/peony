const std = @import("std");

pub const SessionAllocator = struct {
    backing: std.mem.Allocator,
    max_bytes: usize,
    live_bytes: usize = 0,
    peak_bytes: usize = 0,
    before_alloc_context: ?*anyopaque = null,
    before_alloc_fn: ?*const fn (*anyopaque, usize) void = null,

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    pub fn init(backing: std.mem.Allocator, max_bytes: usize) SessionAllocator {
        return .{
            .backing = backing,
            .max_bytes = max_bytes,
        };
    }

    pub fn allocator(self: *SessionAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn freeAligned(
        self: *SessionAllocator,
        memory: []u8,
        alignment: std.mem.Alignment,
    ) void {
        std.debug.assert(memory.len <= self.live_bytes);
        self.backing.rawFree(memory, alignment, 0);
        self.live_bytes -= memory.len;
    }

    pub fn setBeforeAllocHook(
        self: *SessionAllocator,
        context: *anyopaque,
        hook: *const fn (*anyopaque, usize) void,
    ) void {
        std.debug.assert(self.before_alloc_context == null or self.before_alloc_context == context);
        self.before_alloc_context = context;
        self.before_alloc_fn = hook;
    }

    pub fn clearBeforeAllocHook(self: *SessionAllocator, context: *anyopaque) void {
        if (self.before_alloc_context == context) {
            self.before_alloc_context = null;
            self.before_alloc_fn = null;
        }
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *SessionAllocator = @ptrCast(@alignCast(context));
        self.beforeAllocation(len);
        if (!self.canGrowBy(len)) return null;

        const memory = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.recordGrowth(len);
        return memory;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *SessionAllocator = @ptrCast(@alignCast(context));
        std.debug.assert(new_len != 0);

        if (new_len > memory.len) {
            const growth = new_len - memory.len;
            self.beforeAllocation(growth);
            if (!self.canGrowBy(growth)) return false;
            if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
            self.recordGrowth(growth);
            return true;
        }

        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.live_bytes -= memory.len - new_len;
        return true;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *SessionAllocator = @ptrCast(@alignCast(context));
        std.debug.assert(new_len != 0);

        if (new_len > memory.len) {
            const growth = new_len - memory.len;
            self.beforeAllocation(growth);
            if (!self.canGrowBy(growth)) return null;
            const result = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
            self.recordGrowth(growth);
            return result;
        }

        const result = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.live_bytes -= memory.len - new_len;
        return result;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *SessionAllocator = @ptrCast(@alignCast(context));
        _ = ret_addr;
        self.freeAligned(memory, alignment);
    }

    fn beforeAllocation(self: *SessionAllocator, requested: usize) void {
        if (self.before_alloc_fn) |hook| {
            if (self.before_alloc_context) |context| hook(context, requested);
        }
    }

    fn canGrowBy(self: *const SessionAllocator, requested: usize) bool {
        const projected = std.math.add(usize, self.live_bytes, requested) catch return false;
        return projected <= self.max_bytes;
    }

    fn recordGrowth(self: *SessionAllocator, amount: usize) void {
        self.live_bytes += amount;
        self.peak_bytes = @max(self.peak_bytes, self.live_bytes);
    }
};
