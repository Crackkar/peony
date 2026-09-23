const gc_tests = @import("runtime_gc_tests");
const value_tests = @import("value_number_tests");
const string_tests = @import("string_bytes_tests");

test "ABI module compiles" {
    _ = @import("abi");
}

test "session allocator accounting" {
    try gc_tests.testSessionAllocatorAccounting();
}

test "session allocator cap" {
    try gc_tests.testSessionAllocatorCap();
}

test "allocation edge cases" {
    try gc_tests.testAllocationEdges();
}

test "session isolation" {
    try gc_tests.testSessionIsolation();
}

test "roots and cycles" {
    try gc_tests.testRootsAndCycles();
}

test "destructor storage release" {
    try gc_tests.testDestructorStorage();
}

test "marking without allocation" {
    try gc_tests.testMarkingWithoutAllocation();
}

test "allocation threshold growth" {
    try gc_tests.testThresholdGrowth();
}

test "value tags and identity" {
    try value_tests.testValueTagsAndIdentity();
}

test "float NaNs are canonicalized" {
    try value_tests.testFloatNanCanonicalization();
}

test "small integer overflow promotes to bigint" {
    try value_tests.testSmallIntOverflowPromotion();
}

test "floor division and modulo follow Python signs" {
    try value_tests.testFloorDivisionModulo();
}

test "negative shifts report ValueError and bitwise operations use signed integers" {
    try value_tests.testShiftAndBitwise();
}

test "huge shifts and powers keep bounded results and permit budgeted sizes" {
    try value_tests.testHugeBoundedOperations();
}

test "integer powers and float conversion" {
    try value_tests.testPowerAndFloatConversion();
}

test "bool integer and float equality share hashes" {
    try value_tests.testNumericEqualityAndHash();
}

test "large integer float conversion reports OverflowError" {
    try value_tests.testLargeIntegerFloatOverflow();
}

test "numeric faults use Python exception transport" {
    try value_tests.testPythonExceptionTransport();
}

test "memory cap produces a Python MemoryError and keeps the heap usable" {
    try value_tests.testMemoryErrorKeepsEngineUsable();
}

test "collecting a bigint reclaims its limbs" {
    try value_tests.testBigIntLimbReclamation();
}

test "UTF-8 strings validate and index by code point" {
    try string_tests.testUtf8IndexAndSlice();
}

test "strings compare hash and concatenate by content" {
    try string_tests.testStringEqualityAndConcat();
}

test "Unicode 15 casing classification and casefold" {
    try string_tests.testUnicodeOperations();
}

test "string search split join strip replace count and prefixes" {
    try string_tests.testStringOperations();
}

test "immutable bytes index slice encode and decode" {
    try string_tests.testBytesOperations();
}

test "invalid UTF-8 bytes decode as UnicodeDecodeError" {
    try string_tests.testInvalidBytesDecode();
}

test "string and bytes storage obey the session cap and GC" {
    try string_tests.testStringBytesAccounting();
}
