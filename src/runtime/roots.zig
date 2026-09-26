const std = @import("std");
const object = @import("object.zig");

pub const RootStack = struct {
    top_frame: ?*RootFrame = null,

    pub fn visit(self: *const RootStack, tracer: *object.Tracer) void {
        var frame = self.top_frame;
        while (frame) |active| : (frame = active.previous) {
            var root = active.roots;
            while (root) |slot| : (root = slot.previous) tracer.visit(slot.object);
        }
    }
};

pub const RootFrame = struct {
    stack: ?*RootStack = null,
    previous: ?*RootFrame = null,
    roots: ?*Root = null,

    pub fn push(self: *RootFrame, stack: *RootStack) void {
        std.debug.assert(self.stack == null);
        self.stack = stack;
        self.previous = stack.top_frame;
        self.roots = null;
        stack.top_frame = self;
    }

    pub fn add(self: *RootFrame, root: *Root) void {
        const stack = self.stack orelse unreachable;
        std.debug.assert(stack.top_frame == self);
        root.previous = self.roots;
        self.roots = root;
    }

    pub fn pop(self: *RootFrame) void {
        const stack = self.stack orelse unreachable;
        std.debug.assert(stack.top_frame == self);
        stack.top_frame = self.previous;

        var root = self.roots;
        while (root) |slot| {
            const next = slot.previous;
            slot.previous = null;
            root = next;
        }
        self.* = .{};
    }

    /// A call may start a resumable task whose root frame outlives the call's
    /// temporary frame. Remove the temporary frame without disturbing the task.
    pub fn detach(self: *RootFrame) void {
        const stack = self.stack orelse unreachable;
        if (stack.top_frame == self) return self.pop();
        var above = stack.top_frame orelse unreachable;
        while (above.previous) |previous| : (above = previous) {
            if (previous != self) continue;
            above.previous = self.previous;
            var root = self.roots;
            while (root) |slot| {
                const next = slot.previous;
                slot.previous = null;
                root = next;
            }
            self.* = .{};
            return;
        }
        unreachable;
    }
};

pub const Root = struct {
    object: ?*object.Header,
    previous: ?*Root = null,
};
