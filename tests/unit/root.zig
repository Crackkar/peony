const gc_tests = @import("runtime_gc_tests");
const value_tests = @import("value_number_tests");
const string_tests = @import("string_bytes_tests");
const lexer_tests = @import("lexer_tests");
const parser_tests = @import("parser_tests");
const scope_tests = @import("scope_tests");
const compiler_vm_tests = @import("compiler_vm_tests");
const control_flow_tests = @import("control_flow_tests");
const functions_tests = @import("functions_tests");
const sequence_tests = @import("sequence_tests");
const mapping_tests = @import("mapping_tests");

test "ABI module compiles" {
    _ = @import("abi");
}

test "ABI v1 appends execution statuses without renumbering existing values" {
    const status = @import("abi").Status;
    try @import("std").testing.expectEqual(@as(u32, 0), @intFromEnum(status.ok));
    try @import("std").testing.expectEqual(@as(u32, 4), @intFromEnum(status.out_of_memory));
    try @import("std").testing.expectEqual(@as(u32, 5), @intFromEnum(status.completed));
    try @import("std").testing.expectEqual(@as(u32, 6), @intFromEnum(status.python_exception));
    try @import("std").testing.expectEqual(@as(u32, 7), @intFromEnum(status.timeslice));
    try @import("std").testing.expectEqual(@as(u32, 8), @intFromEnum(status.cancelled));
    try @import("std").testing.expectEqual(@as(u32, 9), @intFromEnum(status.internal_error));
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

test "lexer classifies tokens and records byte spans and physical locations" {
    try lexer_tests.testTokenSpans();
}

test "lexer normalizes newline forms and preserves physical lines" {
    try lexer_tests.testNewlineForms();
}

test "lexer skips blank comments and separates simple statements" {
    try lexer_tests.testCommentsAndSemicolons();
}

test "lexer expands tab stops and diagnoses ambiguous indentation" {
    try lexer_tests.testIndentationAndTabError();
}

test "lexer diagnoses unmatched dedent" {
    try lexer_tests.testUnmatchedDedent();
}

test "lexer handles implicit and explicit line continuation" {
    try lexer_tests.testContinuations();
}

test "lexer recognizes numeric forms and rejects malformed or complex literals" {
    try lexer_tests.testNumbers();
}

test "lexer recognizes walrus and not-equal as single operators" {
    try lexer_tests.testOperators();
}

test "parser builds span-aware statements and suites" {
    try parser_tests.testStatementsAndSuites();
}

test "Pratt parser follows Python precedence and associativity" {
    try parser_tests.testPrecedence();
}

test "parser handles calls attributes subscripts slices and displays" {
    try parser_tests.testPostfixesAndDisplays();
}

test "parser rejects invalid keyword and positional call argument order" {
    try parser_tests.testCallArgumentOrderingErrors();
}

test "parser retains function signature markers and defaults" {
    try parser_tests.testFunctionSignature();
}

test "parser validates assignment and delete targets" {
    try parser_tests.testTargets();
}

test "parser supports walrus and soft keyword assignments" {
    try parser_tests.testWalrusAndSoftKeywords();
}

test "parser reports suite syntax errors with source locations" {
    try parser_tests.testSuiteErrors();
}

test "parser marks deferred and permanently excluded syntax" {
    try parser_tests.testUnsupportedFeatures();
}

test "scope analysis classifies whole blocks and sibling scopes" {
    try scope_tests.testWholeBlockClassification();
}

test "scope analysis resolves transitive closures and shadowing" {
    try scope_tests.testClosuresAndShadowing();
}

test "scope analysis enforces global and nonlocal declarations" {
    try scope_tests.testDeclarationsAndErrors();
}

test "scope analysis separates definition expressions and target effects" {
    try scope_tests.testDefinitionEvaluationAndTargets();
}

test "scope analysis handles synthetic class and comprehension scopes" {
    try scope_tests.testSyntheticClassAndComprehensionScopes();
}

test "scope analysis preserves import flags and owns names" {
    try scope_tests.testImportFlagsAndOwnedNames();
}

test "64-bit bytecode packs operands and rejects register overflow" {
    try compiler_vm_tests.testInstructionPackingAndOperandLimits();
}

test "compiler temporaries are reused and register bounded" {
    try compiler_vm_tests.testTemporaryRegistersAreReusedAndBounded();
}

test "straight-line compiler and VM own source metadata" {
    try compiler_vm_tests.testStraightLineCompilationAndOwnership();
}

test "VM executes bigint and string literals with correct output" {
    try compiler_vm_tests.testBigIntegersStringsAndTemporaryReuse();
}

test "VM resolves builtin print and transports Python exceptions" {
    try compiler_vm_tests.testBuiltinFallbackShadowingAndPythonExceptions();
}

test "UnboundLocalError follows NameError hierarchy" {
    try compiler_vm_tests.testUnboundLocalErrorHierarchy();
}

test "lists alias and mutate through methods, repr, cycles and equality" {
    try sequence_tests.testListAliasMutationMethodsCyclesAndEquality();
    try sequence_tests.testSequenceRepresentationQuotesEscapesAndBoundsDepth();
}

test "list extend accepts arbitrary iterables" {
    try sequence_tests.testListExtendAcceptsRangesStringsAndExistingIterators();
    try sequence_tests.testListExtendKeepsIteratorItemsRootedDuringGrowth();
    try sequence_tests.testListExtendSelfIteratorStopsAtSessionCap();
}

test "str.split without a separator uses Unicode whitespace" {
    try sequence_tests.testNoArgumentSplitUsesUnicodeWhitespace();
}

test "bytes truthiness follows its length" {
    try sequence_tests.testBytesTruthinessUsesLength();
}

test "bytes membership validates integer and bytes probes" {
    try sequence_tests.testBytesMembershipMatchesPythonProbes();
}

test "list pop and sort keyword bounds match Python behavior" {
    try sequence_tests.testListMethodBoundParity();
}

test "tuples are immutable values and list iteration observes mutation" {
    try sequence_tests.testTupleValuesAndMutableIteration();
}

test "sequences and Unicode strings and bytes support indexing and slicing" {
    try sequence_tests.testIndexingSlicingAndUnicodeStringBytesBridge();
}

test "list insert indices use the Python ssize range" {
    try sequence_tests.testInsertUsesPythonSsizeRange();
}

test "sequence repetition uses ssize range even for empty input" {
    try sequence_tests.testRepeatUsesPythonSsizeRangeEvenForEmptyInput();
}

test "Python sequence bounds do not vary with WASM pointer width" {
    try sequence_tests.testPythonSsizeValuesBeyondWasmIndexRange();
}

test "sequence repetition accepts integer left operands" {
    try sequence_tests.testRepeatSupportsIntegerLeftOperand();
}

test "lazy range indexing and sequence builtins retain big integers" {
    try sequence_tests.testLazyRangeIndexingSlicingAndSequenceBuiltins();
}

test "negative BigInt range slices survive collection" {
    try sequence_tests.testNegativeBigintRangeSliceSurvivesCollection();
    try sequence_tests.testRangeSliceReportsCappedNegativeStepMemoryError();
}

test "sequence unpacking, variadic calls and deletion preserve Python errors" {
    try sequence_tests.testUnpackingVariadicCallsAndNameDeletion();
}

test "unpacking sizes known iterables and preserves shape errors under cap" {
    try sequence_tests.testUnpackCapacityAndKnownRangeSizing();
}

test "sequence growth survives collection and reports memory exhaustion" {
    try sequence_tests.testSequenceGrowthSurvivesCollectionAndReportsMemoryError();
}

test "corrupt bytecode faults stay outside Python exception flow" {
    try compiler_vm_tests.testInternalBytecodeFaultIsNotAPythonException();
}

test "compiler rejects later syntax explicitly and reports MemoryError" {
    try compiler_vm_tests.testUnsupportedSyntaxAndMemoryLimitTransport();
}

test "VM runs truthiness, short circuit and conditional expressions" {
    try control_flow_tests.testTruthinessShortCircuitAndConditionalExpressions();
}

test "VM compares and short circuits chained comparisons" {
    try control_flow_tests.testComparisonsIdentityMembershipAndChaining();
}

test "VM executes nested loops, break, continue and loop else" {
    try control_flow_tests.testIfWhileForBreakContinueAndLoopElse();
}

test "VM lazily iterates bigint ranges and Unicode strings" {
    try control_flow_tests.testLazyBigIntRangesAndUnicodeStringIteration();
}

test "VM reports range errors and rejects unsupported loops before execution" {
    try control_flow_tests.testRangeErrorsShadowingAndUnsupportedInputs();
}

test "range and iterator values remain rooted across garbage collection" {
    try control_flow_tests.testRangeAndIteratorStayRootedDuringCollection();
}

test "range membership accepts float probes and roots bigint intermediates" {
    try control_flow_tests.testRangeFloatMembershipAndMembershipRooting();
}

test "VM calls functions and retains callable builtins" {
    try functions_tests.testBasicFunctionsReturnsAndCallableValues();
}

test "VM evaluates function callees and arguments once in order" {
    try functions_tests.testCallsEvaluateCalleeAndArgumentsOnceLeftToRight();
    try functions_tests.testStarredArgumentsExpandBeforeLaterArguments();
}

test "function defaults and annotations run at definition time" {
    try functions_tests.testDefinitionTimeDefaultsAndAnnotations();
}

test "function binder supports positional-only and keyword-only parameters" {
    try functions_tests.testPositionalOnlyKeywordOnlyAndDefaultBinding();
}

test "function binder errors preserve call-site lines" {
    try functions_tests.testFunctionBinderErrorsAndCallSiteLines();
}

test "function scopes distinguish local reads and global writes" {
    try functions_tests.testWholeBlockLocalsAndExplicitGlobal();
}

test "closures capture shared mutable and transitive cells" {
    try functions_tests.testClosuresCaptureMutableCellsAndTransitiveFreeNames();
}

test "variadic closure roots survive cell construction collection" {
    try functions_tests.testVariadicClosureRootsSurviveCellConstructionCollection();
}

test "recursive frames and closures survive GC and timeslices" {
    try functions_tests.testRecursiveFramesSurviveCollectionAndTimeslices();
}

test "builtin callable survives collection and reset" {
    try functions_tests.testBuiltinCallableCollectionAndReset();
}

test "unsupported function default cleans nested code once" {
    try functions_tests.testUnsupportedFunctionDefaultCleansNestedCodeOnce();
}

test "function construction cap failure reports MemoryError and recovers" {
    try functions_tests.testFunctionConstructionMemoryErrorAndRecovery();
}

test "dictionary unpacking stays explicitly unsupported" {
    try functions_tests.testDictionaryUnpackingRemainsExplicitlyUnsupported();
}

test "ordered mapping keys preserve Python numeric equality and order" {
    try mapping_tests.testOrderedDictAndSetNumericKeys();
}

test "dict methods and views remain live and detect size mutation" {
    try mapping_tests.testDictMethodsAndLiveViews();
}

test "set methods and mapping view representations" {
    try mapping_tests.testSetMethodsAndMappingViewRepresentations();
}

test "dict view repr is cycle safe" {
    try mapping_tests.testMappingViewReprIsCycleSafe();
}

test "colliding numeric dict keys survive tombstones" {
    try mapping_tests.testMappingCollisionsSurviveTombstones();
}

test "dict and set constructors, displays and operators" {
    try mapping_tests.testMappingConstructorsDisplaysAndSetOperators();
}

test "mapping keyword arguments expand in source order" {
    try mapping_tests.testKeywordMappingsExpandInSourceOrder();
    try mapping_tests.testPositionalOnlyNameCanBeCapturedByKwargs();
}

test "double-star call errors follow Python evaluation order" {
    try mapping_tests.testDstarErrorsFollowPythonEvaluationOrder();
}

test "hashing and mapping errors follow Python types" {
    try mapping_tests.testHashingAndMappingErrors();
}

test "string and bytes hashes vary across sessions" {
    try mapping_tests.testStringHashSeedVariesAcrossSessions();
}

test "dict insertion roots object keys and values across growth" {
    try mapping_tests.testDictSetRootsObjectKeyAndValueAcrossGrowth();
}

test "dict resize allocation failure releases partial buffers" {
    try mapping_tests.testDictResizeAllocationFailureReleasesBuckets();
}

test "clearing an empty dictionary keeps its iterator valid" {
    try mapping_tests.testEmptyDictClearDoesNotInvalidateIterator();
}

test "an exhausted dict iterator stays exhausted after growth" {
    try mapping_tests.testExhaustedDictIteratorStaysExhaustedAfterGrowth();
}

test "lexer recognizes literal prefixes and triple quotes" {
    try lexer_tests.testStringLiterals();
}

test "lexer accepts UTF-8 cookies and rejects unsupported encodings" {
    try lexer_tests.testEncodingCookies();
}

test "lexer accepts Unicode string data and rejects Unicode identifiers" {
    try lexer_tests.testUnicodeSource();
}

test "Python soft keywords remain identifiers" {
    try lexer_tests.testSoftKeywords();
}
