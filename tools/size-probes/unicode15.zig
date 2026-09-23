const property_blob = @embedFile("unicode15-property-prototype.bin");

export fn peony_probe_unicode15(index: u32) u32 {
    const offset: usize = @intCast(index);
    return property_blob[offset % property_blob.len];
}
