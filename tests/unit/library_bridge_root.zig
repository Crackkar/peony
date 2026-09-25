const bridge = @import("library_bridge_tests");

test "native task chunks share one bounded run quantum" {
    try bridge.testNativeTaskChunksShareOneRunQuantum();
}

test "primitive int constructor works in direct and resumed map calls" {
    try bridge.testPrimitiveIntConstructorInCallbacks();
}

test "sys argv copies host arguments and resets per run" {
    try bridge.testSysArgvCopiedAndReset();
}

test "regex draft module shares the engine root" {
    try @import("std").testing.expect(@import("runtime_vm").RegexDraft.functions.len > 0);
    try @import("std").testing.expect(@import("runtime_vm").HttpDraft.urllib_request_functions.len > 0);
    try @import("std").testing.expect(@import("runtime_vm").HttpDraft.requests_functions.len > 0);
}

test "native object protocols use the VM object" {
    try bridge.testNativeObjectProtocols();
}

test "suspended native next completes items and signals done" {
    try bridge.testSuspendedNativeNextAndTerminalDone();
}

test "statistics draft shares the engine root" {
    try bridge.testStatisticsDraftCompile();
}

test "native exception class identity and catch ancestry" {
    try bridge.testNativeExceptionClassIdentity();
}

test "native exception transport and attributes survive VM dispatch" {
    try bridge.testNativeExceptionTransportAndAttributes();
}

test "native registry precedence and first-class binder" {
    try bridge.testNativeRegistryPrecedenceAndFirstClassBinder();
}

test "primitive type identity and callable instance keywords" {
    try bridge.testPrimitiveTypeIdentityAndCallableKeywords();
}

test "native stream callable identity and binder" {
    try bridge.testNativeStreamCallableIdentityAndBinder();
}

test "lazy sys streams and metadata under cap" {
    try bridge.testLazySysStreamsAndRunMetadataUnderCap();
}

test "nested native factory callback resumes input once" {
    try bridge.testNestedNativeFactoryCallbackResumesInputOnce();
}

test "native task callback resumes input at quantum one without replay" {
    try bridge.testNativeTaskCallInputQuantumOneNoReplay();
}

test "native task next resumes a generator with two input requests at quantum one" {
    try bridge.testNativeTaskNextGeneratorInputQuantumOne();
}

test "native task calls a callable instance with keyword binding and input" {
    try bridge.testNativeTaskCallableInstanceKeywordsInput();
}

test "native task next resumes a user iterator and consumes StopIteration" {
    try bridge.testNativeTaskNextUserIteratorStopIteration();
}
