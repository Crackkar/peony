export fn peony_probe_json() u32 {
    const allocator = std.heap.wasm_allocator;
    const encoded = std.json.Stringify.valueAlloc(allocator, .{
        .peony = @as(u32, 1),
        .wasm = true,
        .features = .{ "json", "abi" },
    }, .{}) catch return 0;
    defer allocator.free(encoded);
    return @intCast(encoded.len);
}
