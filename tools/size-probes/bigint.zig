export fn peony_probe_bigint() u32 {
    const allocator = std.heap.wasm_allocator;
    var left = std.math.big.int.Managed.initSet(allocator, (@as(u128, 1) << 127) - 1) catch return 0;
    defer left.deinit();
    var product = std.math.big.int.Managed.init(allocator) catch return 0;
    defer product.deinit();
    product.mul(&left, &left) catch return 0;
    return @intCast(product.bitCountAbs());
}
