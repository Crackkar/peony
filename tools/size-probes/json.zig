export fn peony_probe_json() u32 {
    const allocator = std.heap.wasm_allocator;
    const source = "{\"rows\":[{\"id\":1,\"big\":123456789012345678901234567890,\"text\":\"snow\",\"nested\":[true,null,2]}]}";
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, source, .{ .duplicate_field_behavior = .use_last }) catch return 0;
    defer parsed.deinit();
    const rows = parsed.value.object.get("rows") orelse return 0;
    if (rows != .array) return 0;
    const encoded = std.json.Stringify.valueAlloc(allocator, parsed.value, .{}) catch return 0;
    defer allocator.free(encoded);
    return @intCast(encoded.len + rows.array.items.len);
}
