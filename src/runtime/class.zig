const std = @import("std");
const gc = @import("runtime_gc");
const value_module = @import("runtime_value");
const exceptions = @import("runtime_exception");
const functions = @import("runtime_function");

pub const Value = value_module.Value;
pub const Result = exceptions.Result;

pub const Attribute = struct { name: []u8, value: Value };

pub const Class = struct {
    header: gc.Header align(8),
    allocator: std.mem.Allocator,
    name: []u8,
    bases: []*Class,
    mro: []*Class,
    attributes: std.ArrayList(Attribute) = .empty,
    class_cell: ?*functions.Cell = null,
};

pub const Instance = struct {
    header: gc.Header align(8),
    allocator: std.mem.Allocator,
    class: *Class,
    attributes: std.ArrayList(Attribute) = .empty,
};

pub const BoundMethod = struct {
    header: gc.Header align(8),
    callable: Value,
    receiver: Value,
};

pub const DescriptorKind = enum { property, staticmethod, classmethod };

pub const Descriptor = struct {
    header: gc.Header align(8),
    kind: DescriptorKind,
    getter: Value = Value.noneValue(),
    setter: Value = Value.noneValue(),
    deleter: Value = Value.noneValue(),
    callable: Value = Value.noneValue(),
};

pub const Super = struct {
    header: gc.Header align(8),
    start_class: *Class,
    instance: Value,
    owner_class: *Class,
};

const class_kind = gc.Kind{ .trace = traceClass, .destroy = destroyClass };
const instance_kind = gc.Kind{ .trace = traceInstance, .destroy = destroyInstance };
const bound_method_kind = gc.Kind{ .trace = traceBoundMethod };
const descriptor_kind = gc.Kind{ .trace = traceDescriptor };
const super_kind = gc.Kind{ .trace = traceSuper };

pub fn classFromHeader(header: *gc.Header) ?*Class {
    if (header.kind != &class_kind) return null;
    return @ptrCast(@alignCast(header));
}

pub fn instanceFromHeader(header: *gc.Header) ?*Instance {
    if (header.kind != &instance_kind) return null;
    return @ptrCast(@alignCast(header));
}

pub fn boundMethodFromHeader(header: *gc.Header) ?*BoundMethod {
    if (header.kind != &bound_method_kind) return null;
    return @ptrCast(@alignCast(header));
}

pub fn descriptorFromHeader(header: *gc.Header) ?*Descriptor {
    if (header.kind != &descriptor_kind) return null;
    return @ptrCast(@alignCast(header));
}

pub fn superFromHeader(header: *gc.Header) ?*Super {
    if (header.kind != &super_kind) return null;
    return @ptrCast(@alignCast(header));
}

pub fn createRootClass(heap: *gc.Heap) Result(*Class) {
    const class = heap.createObject(Class, &class_kind) catch return memoryError(*Class);
    class.* = .{ .header = class.header, .allocator = heap.allocator, .name = &.{}, .bases = &.{}, .mro = &.{} };
    var root = gc.Root{ .object = &class.header };
    var frame = gc.RootFrame{};
    frame.push(&heap.roots);
    frame.add(&root);
    defer frame.pop();
    const name = heap.allocator.dupe(u8, "object") catch return memoryError(*Class);
    const mro = heap.allocator.alloc(*Class, 1) catch {
        heap.allocator.free(name);
        return memoryError(*Class);
    };
    class.name = name;
    class.mro = mro;
    mro[0] = class;
    return .{ .value = class };
}

pub fn createClass(heap: *gc.Heap, name: []const u8, bases: []const *Class, object_class: *Class) Result(*Class) {
    var chosen_bases = bases;
    var default_bases: [1]*Class = .{object_class};
    if (bases.len == 0) chosen_bases = &default_bases;
    const root_count = chosen_bases.len + 2;
    const root_slots = heap.allocator.alloc(gc.Root, root_count) catch return memoryError(*Class);
    defer heap.allocator.free(root_slots);
    @memset(root_slots, .{ .object = null });
    var root_frame = gc.RootFrame{};
    root_frame.push(&heap.roots);
    for (root_slots) |*root| root_frame.add(root);
    defer root_frame.pop();
    root_slots[0].object = &object_class.header;
    for (chosen_bases, 0..) |base, index| root_slots[index + 1].object = &base.header;

    const class = heap.createObject(Class, &class_kind) catch return memoryError(*Class);
    class.* = .{ .header = class.header, .allocator = heap.allocator, .name = &.{}, .bases = &.{}, .mro = &.{} };
    root_slots[root_count - 1].object = &class.header;
    const owned_name = heap.allocator.dupe(u8, name) catch return memoryError(*Class);
    class.name = owned_name;
    const owned_bases = heap.allocator.dupe(*Class, chosen_bases) catch return memoryError(*Class);
    class.bases = owned_bases;
    const inherited_mro = calculateMro(heap.allocator, chosen_bases) catch |err| {
        if (err == error.InconsistentMro) return .{ .python_exception = .{ .kind = .type_error, .message = "cannot create a consistent method resolution order" } };
        return memoryError(*Class);
    };
    defer heap.allocator.free(inherited_mro);
    const mro = heap.allocator.alloc(*Class, inherited_mro.len + 1) catch return memoryError(*Class);
    mro[0] = class;
    @memcpy(mro[1..], inherited_mro);
    class.mro = mro;
    return .{ .value = class };
}

pub fn createInstance(heap: *gc.Heap, class: *Class) Result(*Instance) {
    var root = gc.Root{ .object = &class.header };
    var frame = gc.RootFrame{};
    frame.push(&heap.roots);
    frame.add(&root);
    defer frame.pop();
    const instance = heap.createObject(Instance, &instance_kind) catch return memoryError(*Instance);
    instance.* = .{ .header = instance.header, .allocator = heap.allocator, .class = class };
    return .{ .value = instance };
}

pub fn createBoundMethod(heap: *gc.Heap, callable: Value, receiver: Value) Result(*BoundMethod) {
    var roots = gc.RootFrame{};
    var callable_root = gc.Root{ .object = callable.asObject() };
    var receiver_root = gc.Root{ .object = receiver.asObject() };
    roots.push(&heap.roots);
    roots.add(&callable_root);
    roots.add(&receiver_root);
    defer roots.pop();
    const method = heap.createObject(BoundMethod, &bound_method_kind) catch return memoryError(*BoundMethod);
    method.* = .{ .header = method.header, .callable = callable, .receiver = receiver };
    return .{ .value = method };
}

pub fn createDescriptor(heap: *gc.Heap, kind: DescriptorKind, callable: Value) Result(*Descriptor) {
    var root = gc.Root{ .object = callable.asObject() };
    var frame = gc.RootFrame{};
    frame.push(&heap.roots);
    frame.add(&root);
    defer frame.pop();
    const descriptor = heap.createObject(Descriptor, &descriptor_kind) catch return memoryError(*Descriptor);
    descriptor.* = .{ .header = descriptor.header, .kind = kind, .callable = callable };
    if (kind == .property) descriptor.getter = callable;
    return .{ .value = descriptor };
}

pub fn copyProperty(heap: *gc.Heap, property: *Descriptor, setter: ?Value, deleter: ?Value) Result(*Descriptor) {
    var roots = [_]gc.Root{
        .{ .object = &property.header },
        .{ .object = if (setter) |v| v.asObject() else null },
        .{ .object = if (deleter) |v| v.asObject() else null },
    };
    var frame = gc.RootFrame{};
    frame.push(&heap.roots);
    for (&roots) |*root| frame.add(root);
    defer frame.pop();
    const object = heap.createObject(Descriptor, &descriptor_kind) catch return memoryError(*Descriptor);
    object.* = .{
        .header = object.header,
        .kind = .property,
        .getter = property.getter,
        .setter = setter orelse property.setter,
        .deleter = deleter orelse property.deleter,
    };
    return .{ .value = object };
}

pub fn createSuper(heap: *gc.Heap, start: *Class, instance: Value, owner: *Class) Result(*Super) {
    var roots = [_]gc.Root{ .{ .object = &start.header }, .{ .object = instance.asObject() }, .{ .object = &owner.header } };
    var frame = gc.RootFrame{};
    frame.push(&heap.roots);
    for (&roots) |*root| frame.add(root);
    defer frame.pop();
    const object = heap.createObject(Super, &super_kind) catch return memoryError(*Super);
    object.* = .{ .header = object.header, .start_class = start, .instance = instance, .owner_class = owner };
    return .{ .value = object };
}

pub fn classAttribute(class: *Class, name: []const u8) ?Value {
    for (class.mro) |base| if (findAttribute(base.attributes.items, name)) |entry| return entry.value;
    return null;
}

pub fn superClassAttribute(owner: *Class, start: *Class, name: []const u8) ?Value {
    var after_start = false;
    for (owner.mro) |base| {
        if (after_start) {
            if (ownClassAttribute(base, name)) |value| return value;
        } else if (base == start) {
            after_start = true;
        }
    }
    return null;
}

pub fn ownClassAttribute(class: *Class, name: []const u8) ?Value {
    const found = findAttribute(class.attributes.items, name) orelse return null;
    return found.value;
}

pub fn instanceAttribute(instance: *Instance, name: []const u8) ?Value {
    const found = findAttribute(instance.attributes.items, name) orelse return null;
    return found.value;
}

pub fn setClassAttribute(heap: *gc.Heap, class: *Class, name: []const u8, value: Value) error{OutOfMemory}!void {
    try setAttribute(heap.allocator, &class.attributes, name, value);
}

pub fn deleteClassAttribute(heap: *gc.Heap, class: *Class, name: []const u8) bool {
    return deleteAttribute(heap.allocator, &class.attributes, name);
}

pub fn setInstanceAttribute(heap: *gc.Heap, instance: *Instance, name: []const u8, value: Value) error{OutOfMemory}!void {
    try setAttribute(heap.allocator, &instance.attributes, name, value);
}

pub fn deleteInstanceAttribute(heap: *gc.Heap, instance: *Instance, name: []const u8) bool {
    return deleteAttribute(heap.allocator, &instance.attributes, name);
}

fn deleteAttribute(allocator: std.mem.Allocator, attributes: *std.ArrayList(Attribute), name: []const u8) bool {
    for (attributes.items, 0..) |*entry, index| {
        if (!std.mem.eql(u8, entry.name, name)) continue;
        allocator.free(entry.name);
        _ = attributes.orderedRemove(index);
        return true;
    }
    return false;
}

fn setAttribute(allocator: std.mem.Allocator, attributes: *std.ArrayList(Attribute), name: []const u8, value: Value) error{OutOfMemory}!void {
    for (attributes.items) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            entry.value = value;
            return;
        }
    }
    const owned = try allocator.dupe(u8, name);
    errdefer allocator.free(owned);
    try attributes.append(allocator, .{ .name = owned, .value = value });
}

fn findAttribute(attributes: []const Attribute, name: []const u8) ?*const Attribute {
    for (attributes) |*entry| if (std.mem.eql(u8, entry.name, name)) return entry;
    return null;
}

fn calculateMro(allocator: std.mem.Allocator, bases: []const *Class) error{OutOfMemory, InconsistentMro}![]*Class {
    var result: std.ArrayList(*Class) = .empty;
    errdefer result.deinit(allocator);
    var sequences: std.ArrayList([]const *Class) = .empty;
    defer sequences.deinit(allocator);
    for (bases) |base| try sequences.append(allocator, base.mro);
    try sequences.append(allocator, bases);
    try result.ensureTotalCapacity(allocator, totalMroSize(bases));
    // C3 merge; caller inserts the class itself at index zero.
    var cursors = try allocator.alloc(usize, sequences.items.len);
    defer allocator.free(cursors);
    @memset(cursors, 0);
    while (true) {
        var any = false;
        var selected: ?*Class = null;
        for (sequences.items, 0..) |sequence, seq_index| {
            const cursor = cursors[seq_index];
            if (cursor >= sequence.len) continue;
            any = true;
            const candidate = sequence[cursor];
            var appears_in_tail = false;
            for (sequences.items, 0..) |other, other_index| {
                const other_cursor = cursors[other_index];
                if (other_cursor + 1 >= other.len) continue;
                for (other[other_cursor + 1 ..]) |later| if (later == candidate) {
                    appears_in_tail = true;
                    break;
                };
                if (appears_in_tail) break;
            }
            if (!appears_in_tail) {
                selected = candidate;
                break;
            }
        }
        if (!any) break;
        const head = selected orelse return error.InconsistentMro;
        try result.append(allocator, head);
        for (sequences.items, 0..) |sequence, seq_index| {
            if (cursors[seq_index] < sequence.len and sequence[cursors[seq_index]] == head) cursors[seq_index] += 1;
        }
    }
    return result.toOwnedSlice(allocator);
}

fn totalMroSize(bases: []const *Class) usize {
    var size: usize = bases.len;
    for (bases) |base| size += base.mro.len;
    return size;
}

fn traceClass(header: *gc.Header, tracer: *gc.Tracer) void {
    const class: *Class = @ptrCast(@alignCast(header));
    for (class.bases) |base| tracer.visit(&base.header);
    if (class.class_cell) |cell| tracer.visit(&cell.header);
    for (class.attributes.items) |entry| tracer.visit(entry.value.asObject());
}

fn destroyClass(header: *gc.Header, allocator: std.mem.Allocator) void {
    const class: *Class = @ptrCast(@alignCast(header));
    allocator.free(class.name);
    if (class.bases.len != 0) allocator.free(class.bases);
    allocator.free(class.mro);
    for (class.attributes.items) |entry| allocator.free(entry.name);
    class.attributes.deinit(allocator);
}

fn traceInstance(header: *gc.Header, tracer: *gc.Tracer) void {
    const instance: *Instance = @ptrCast(@alignCast(header));
    tracer.visit(&instance.class.header);
    for (instance.attributes.items) |entry| tracer.visit(entry.value.asObject());
}

fn destroyInstance(header: *gc.Header, allocator: std.mem.Allocator) void {
    const instance: *Instance = @ptrCast(@alignCast(header));
    for (instance.attributes.items) |entry| allocator.free(entry.name);
    instance.attributes.deinit(allocator);
}

fn traceBoundMethod(header: *gc.Header, tracer: *gc.Tracer) void {
    const method: *BoundMethod = @ptrCast(@alignCast(header));
    tracer.visit(method.callable.asObject());
    tracer.visit(method.receiver.asObject());
}

fn traceDescriptor(header: *gc.Header, tracer: *gc.Tracer) void {
    const descriptor: *Descriptor = @ptrCast(@alignCast(header));
    tracer.visit(descriptor.getter.asObject());
    tracer.visit(descriptor.setter.asObject());
    tracer.visit(descriptor.deleter.asObject());
    tracer.visit(descriptor.callable.asObject());
}

fn traceSuper(header: *gc.Header, tracer: *gc.Tracer) void {
    const value: *Super = @ptrCast(@alignCast(header));
    tracer.visit(&value.start_class.header);
    tracer.visit(value.instance.asObject());
    tracer.visit(&value.owner_class.header);
}

fn memoryError(comptime T: type) Result(T) {
    return .{ .python_exception = .{ .kind = .memory_error, .message = "session memory limit exceeded" } };
}
