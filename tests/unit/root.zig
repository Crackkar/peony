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
const comprehension_tests = @import("comprehension_tests");
const formatting_tests = @import("formatting_tests");
const exception_tests = @import("exception_tests");
const host_tests = @import("host_tests");
const host_codec_tests = @import("host_codec_tests");
const vfs_tests = @import("vfs_tests");
const file_tests = @import("file_tests");
const class_tests = @import("class_tests");
const generator_tests = @import("generator_tests");
const annotation_tests = @import("annotation_tests");
const match_tests = @import("match_tests");
const import_tests = @import("import_tests");
const library_bridge_tests = @import("library_bridge_tests");
const library_regex_tests = @import("library_regex_tests");
const library_http_tests = @import("library_http_tests");
const library_numeric_tests = @import("library_numeric_tests");
const library_data_tests = @import("library_data_tests");
const library_vfs_tests = @import("library_vfs_tests");
const library_collections_tests = @import("library_collections_tests");
const builtin_tail_tests = @import("builtin_tail_tests");
const string_tail_tests = @import("string_tail_tests");

test "builtin numeric and text tail" {
    try builtin_tail_tests.testNumericAndTextBuiltins();
}
test "builtin iterable reductions and short circuit" {
    try builtin_tail_tests.testIterableReductionsAndShortCircuit();
}
test "bytes constructor forms and errors" {
    try builtin_tail_tests.testBytesConstructorFormsAndErrors();
}
test "builtin tail errors and resumable work" {
    try builtin_tail_tests.testBuiltinErrorsAndResumableWork();
}
test "string tail runtime primitives" {
    try string_tail_tests.testStringTailRuntimePrimitives();
}
test "string tail VM methods" {
    try string_tail_tests.testStringTailVmMethods();
}
test "string tail errors and memory cap" {
    try string_tail_tests.testStringTailErrorsAndMemoryCap();
}

test "math contract" {
    try library_numeric_tests.testMathContract();
}
test "math errors and binding" {
    try library_numeric_tests.testMathErrorsAndBinding();
}
test "random contract and validation" {
    try library_numeric_tests.testRandomContractAndValidation();
}
test "random work budget and cancellation" {
    try library_numeric_tests.testRandomWorkBudgetAndCancellation();
}
test "statistics contract and one-pass iterables" {
    try library_numeric_tests.testStatisticsContractAndOnePassIterables();
}
test "numeric GC and reset isolation" {
    try library_numeric_tests.testNumericGcAndResetIsolation();
}
test "JSON loads dumps and options" {
    try library_data_tests.testJsonLoadsDumpsAndOptions();
}
test "native JSON Value adapter preserves bigint Unicode and GC roots" {
    try library_data_tests.testNativeJsonValueAdapter();
}
test "JSON errors metadata and cycles" {
    try library_data_tests.testJsonErrorsMetadataAndCycles();
}
test "JSON file-like callbacks" {
    try library_data_tests.testJsonFileLikeCallbacks();
}
test "CSV reader writer and Unicode" {
    try library_data_tests.testCsvReaderWriterAndUnicode();
}
test "CSV dictionary variants and errors" {
    try library_data_tests.testCsvDictionaryVariantsAndErrors();
}
test "data callbacks resume input once" {
    try library_data_tests.testDataCallbacksResumeInputOnce();
}
test "data GC cap and reset" {
    try library_data_tests.testDataGcCapAndReset();
}
test "large JSON parse and dump yield and cancel at native checkpoints" {
    try library_data_tests.testJsonLargeQuantumAndCancellation();
}
test "Path lexical contract" {
    try library_vfs_tests.testPathLexicalContract();
}
test "Path VFS methods and open protocol" {
    try library_vfs_tests.testPathVfsMethodsAndOpenProtocol();
}
test "os.path and mutation contract" {
    try library_vfs_tests.testOsPathAndMutationContract();
}
test "VFS readonly and error atomicity" {
    try library_vfs_tests.testVfsReadonlyAndErrorAtomicity();
}
test "VFS GC and reset persistence" {
    try library_vfs_tests.testVfsGcAndResetPersistence();
}
test "Counter construction and methods" {
    try library_collections_tests.testCounterConstructionAndMethods();
}
test "Counter operators and comparisons" {
    try library_collections_tests.testCounterOperatorsAndComparisons();
}
test "defaultdict contract" {
    try library_collections_tests.testDefaultdictContract();
}
test "copy graphs instances and resources" {
    try library_collections_tests.testCopyGraphsInstancesAndResources();
}
test "collection and copy hooks resume input once" {
    try library_collections_tests.testCollectionAndCopyHooksResumeInputOnce();
}
test "collections GC cap and reset" {
    try library_collections_tests.testCollectionsGcCapAndReset();
}

test "native registry precedence and first-class binder" {
    try library_bridge_tests.testNativeRegistryPrecedenceAndFirstClassBinder();
}

test "primitive type identity and callable instance keywords" {
    try library_bridge_tests.testPrimitiveTypeIdentityAndCallableKeywords();
}

test "native stream callable identity and binder" {
    try library_bridge_tests.testNativeStreamCallableIdentityAndBinder();
}

test "lazy sys streams and metadata under cap" {
    try library_bridge_tests.testLazySysStreamsAndRunMetadataUnderCap();
}

test "nested native factory callback resumes input once" {
    try library_bridge_tests.testNestedNativeFactoryCallbackResumesInputOnce();
}

test "native task callback resumes input at quantum one without replay" {
    try library_bridge_tests.testNativeTaskCallInputQuantumOneNoReplay();
}

test "native task chunks share one bounded run quantum" {
    try library_bridge_tests.testNativeTaskChunksShareOneRunQuantum();
}

test "native task next resumes a generator with two input requests at quantum one" {
    try library_bridge_tests.testNativeTaskNextGeneratorInputQuantumOne();
}

test "native task calls a callable instance with keyword binding and input" {
    try library_bridge_tests.testNativeTaskCallableInstanceKeywordsInput();
}

test "native task next resumes a user iterator and consumes StopIteration" {
    try library_bridge_tests.testNativeTaskNextUserIteratorStopIteration();
}

test "regex syntax flags Unicode and bytes" {
    try library_regex_tests.testRegexSyntaxFlagsUnicodeAndBytes();
}

test "regex ordered captures objects and positions" {
    try library_regex_tests.testRegexOrderedCapturesObjectsAndPositions();
}

test "regex split sub templates escape and pattern methods" {
    try library_regex_tests.testRegexSplitSubTemplatesEscapeAndPatternMethods();
}

test "regex callable replacement resumes input exactly once" {
    try library_regex_tests.testRegexCallableReplacementResumesInputExactlyOnce();
}

test "regex work limit GC and reset" {
    try library_regex_tests.testRegexWorkLimitGcAndReset();
}

test "urlopen response cursor context SSL and validation" {
    try library_http_tests.testUrlopenResponseCursorContextSslAndValidation();
}

test "urlopen POST context manager and errors" {
    try library_http_tests.testUrlopenPostContextManagerAndErrors();
}

test "requests query form headers encoding and JSON" {
    try library_http_tests.testRequestsQueryFormHeadersEncodingAndJson();
}

test "requests status and transport exceptions" {
    try library_http_tests.testRequestsStatusAndTransportExceptions();
}

test "time clock sleep validation and cancellation" {
    try library_http_tests.testTimeClockSleepValidationAndCancellation();
}

test "SSLContext identity constructor and mutation" {
    try library_http_tests.testSslContextTypeAndMutation();
}

test "host reply identity schema and size retain pending request" {
    try library_http_tests.testHostReplyIdentitySchemaAndSizeDoNotConsumePendingRequest();
}

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
    try @import("std").testing.expectEqual(@as(u32, 10), @intFromEnum(status.host_request));
    try @import("std").testing.expectEqual(@as(u32, 11), @intFromEnum(status.output_event));
    try @import("std").testing.expectEqual(@as(u32, 12), @intFromEnum(status.limit));
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

test "Python exception hierarchy follows builtin inheritance" {
    try exception_tests.testExceptionHierarchy();
}

test "try except else finally and assert control flow" {
    try exception_tests.testTryExceptElseFinallyAndAssert();
}

test "finally runs during return and loop control flow" {
    try exception_tests.testFinallyRunsForReturnBreakAndContinue();
}

test "raise from and exception target cleanup" {
    try exception_tests.testRaiseCauseAndExceptTargetCleanup();
}

test "full-cap MemoryError remains catchable and session recovers" {
    try exception_tests.testCappedMemoryErrorHandlerAndSessionRecovery();
}

test "try/finally transfer preserves nesting and handler binding cleanup" {
    try exception_tests.testNestedFinallyLoopTransferAndHandlerCleanup();
}

test "raise cause/context and traceback frame behavior" {
    try exception_tests.testRaiseContextCauseAndTracebackFrames();
}

test "generator and synchronous callback errors unwind through their own finally" {
    try exception_tests.testGeneratorAndCallbackFailuresRunInnerFinally();
}

test "unhandled synchronous callback traceback includes caller site" {
    try exception_tests.testUnhandledSynchronousCallbackAddsCallerTraceback();
}

test "with managers enter left to right and exit in reverse" {
    try exception_tests.testWithManagersEnterInOrderAndExitInReverse();
}

test "with suppression and enter failure semantics" {
    try exception_tests.testWithSuppressionAndEnterFailure();
}

test "with target binding failure and return still call exit" {
    try exception_tests.testWithTargetBindFailureStillExitsAndReturnExits();
}

test "with cancellation skips exit and resets" {
    try exception_tests.testWithCancellationSkipsExit();
}

test "with exit runs for loop break and continue transfers" {
    try exception_tests.testWithExitRunsForLoopTransfers();
}

test "a loop jump inside finally preserves the active try block" {
    try exception_tests.testJumpInsideFinallyPreservesTheTryBlock();
}

test "pending exceptions resume through nested finally across timeslices" {
    try exception_tests.testPendingExceptionContinuationSurvivesNestedTryAcrossTimeslices();
}

test "pending exceptions resume through called frames across timeslices" {
    try exception_tests.testPendingExceptionContinuationSurvivesCalledFrameAcrossTimeslices();
}

test "assertion message survives GC and reset" {
    try exception_tests.testAssertionMessageSurvivesCollectionAndReset();
}

test "input evaluates its prompt once and suspends for the host" {
    try host_tests.testInputEvaluatesPromptOnceAndSuspends();
}

test "resumed input roots the value and dispatches EOF and host errors" {
    try host_tests.testInputResumeRootsValueAndDispatchesEofAndHostErrors();
}

test "input resumes inside a nested Python frame at quantum one" {
    try host_tests.testInputSuspendsInsideNestedFrameAtQuantumOne();
}

test "print flush returns an output boundary" {
    try host_tests.testPrintFlushProducesOutputBoundary();
}

test "large flushed output uses a small output event marker" {
    try host_tests.testLargeFlushedOutputUsesOnlyAnEventMarker();
}

test "host packet codec roundtrips deterministically" {
    try host_codec_tests.testHostPacketRoundTripIsDeterministic();
    try host_codec_tests.testHostPacketRoundTripWithNoSectionsDoesNotLeak();
}

test "host packet codec rejects oversized envelopes before copying" {
    try host_codec_tests.testHostPacketRejectsOversizedEnvelopeBeforeCopying();
}

test "host packet codec rejects malformed envelopes" {
    try host_codec_tests.testHostPacketRejectsMalformedEnvelopeWithoutOwnedPartialState();
}

test "host config codec validates and preserves defaults" {
    try host_codec_tests.testHostConfigRoundTripAndValidation();
}

test "generator work yields across run quanta without replay" {
    try host_tests.testLongGeneratorYieldsAcrossRunQuantumWithoutReplay();
}

test "map and filter callbacks yield across run quanta" {
    try host_tests.testLongMapAndFilterCallbacksYieldAcrossRunQuantum();
}

test "keyed sorting yields across run quanta without replaying keys" {
    try host_tests.testKeyedSortingYieldsAcrossRunQuantumWithoutRepeatingKeys();
}

test "long Python callbacks yield and can be cancelled" {
    try host_tests.testLongPythonCallbackYieldsAndCanBeCancelled();
}

test "nested callback materialization obeys configured work limit" {
    try host_tests.testNestedCallbackMaterializationHonorsConfiguredWorkLimit();
}

test "enumerate and zip resume generator and map children at quantum one" {
    try host_tests.testEnumerateAndZipResumeGeneratorAndMapChildrenAtQuantumOne();
}

test "multi-source map preserves values across generator suspension" {
    try host_tests.testMultiSourceMapPreservesValuesAcrossGeneratorSuspension();
}

test "plain sorting does not trip a fixed synchronous work ceiling" {
    try host_tests.testPlainSortUsesResumableWorkBudget();
}

test "native sort work stops at the configured limit without counter overshoot" {
    try host_tests.testSortLimitCapsNativeWorkBeforeOvershoot();
}

test "bytecode continuation cannot overshoot native work limit" {
    try host_tests.testBytecodeContinuationCannotOvershootNativeWorkLimit();
}

test "plain sort checkpoints and can be cancelled before its finally" {
    try host_tests.testPlainSortYieldsInsideSortAndCancellationSkipsFinally();
}

test "cancellation inside chunked generator skips finally and recovers" {
    try host_tests.testCancellationInsideChunkedGeneratorStopsWithoutFinally();
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

test "sequence repetition preflights native work and recovers" {
    try sequence_tests.testRepeatPreflightsNativeWorkAndRecovers();
}

test "sequence repetition preserves MemoryError before the work limit" {
    try sequence_tests.testRepeatPreservesMemoryErrorBeforeWorkLimit();
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

test "empty double-star call expansion accepts an empty mapping" {
    try functions_tests.testEmptyDoubleStarExpansion();
}

test "comprehension scopes, nested clauses and late binding" {
    try comprehension_tests.testComprehensionScopesNestedClausesAndLateBinding();
}

test "generator expressions defer filters and bodies and retain roots" {
    try comprehension_tests.testGeneratorExpressionsAreLazyAndRooted();
}

test "lambda and walrus execute while comprehension walrus is rejected" {
    try comprehension_tests.testLambdaWalrusAndComprehensionWalrusBoundary();
}

test "map filter sorted stable sort and list index bounds" {
    try comprehension_tests.testLazyMapFilterSortedStableSortAndListIndexBounds();
}

test "map supports multiple iterables native callables and filter None" {
    try comprehension_tests.testMapMultipleIterablesFilterNoneAndNativeCallbacks();
}

test "keyed list sort reports callback mutation" {
    try comprehension_tests.testKeySortRejectsListMutation();
}

test "temporary keyed-sort receiver and callback stay rooted through GC" {
    try comprehension_tests.testTemporaryReceiverAndCallbackSurviveSortCollection();
}

test "sorting spends the shared synchronous work budget" {
    try comprehension_tests.testSortUsesSharedSynchronousWorkLimit();
}

test "generator work cap recovery and outer cancellation checkpoint" {
    try comprehension_tests.testGeneratorWorkLimitCancelCheckpointAndReuse();
}

test "synchronous callback allocation failure cleans up and recovers" {
    try comprehension_tests.testSyncCallbackAllocationFailureRecoversSession();
}

test "f-string conversions and expressions evaluate in order" {
    try formatting_tests.testFStringConversionsFormattingAndEvaluationOrder();
}

test "format builtin str format and percent operators use shared outputs" {
    try formatting_tests.testSharedFormatBuiltinStringFormatAndPercentOperators();
}

test "format errors and large width respect the session budget" {
    try formatting_tests.testFormattingErrorsAndHugePrecisionAreBounded();
}

test "f-string dynamic spec and debug equals boundaries are explicit" {
    try formatting_tests.testDeferredFStringSpecAndDebugSyntaxBoundaries();
}

test "formatting supports signs characters float types and converted string specs" {
    try formatting_tests.testFormatSignsCharacterFloatTypesAndConvertedStringSpec();
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

test "dictionary perturbation probes survive repeated early indices" {
    try mapping_tests.testPerturbationProbeReachesEmptyBucketAfterRepeatedIndices();
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

test "VFS home survives reset while temporary files clear" {
    try vfs_tests.testHomeSurvivesResetAndTemporaryFilesClear();
}

test "VFS paths are case sensitive and session local" {
    try vfs_tests.testVfsPathsAreCaseSensitiveAndSessionLocal();
}

test "VFS rejects traversal and missing parents atomically" {
    try vfs_tests.testVfsRejectsTraversalAndMissingParentsWithoutMutation();
}

test "nested course mounts create every parent directory" {
    try vfs_tests.testNestedCourseMountCreatesEveryParentDirectory();
}

test "home persists between programs while temporary files clear" {
    try vfs_tests.testHomeSurvivesNewProgramWhileTemporaryFilesClear();
}

test "VFS capacity failures are atomic and recover" {
    try vfs_tests.testVfsCapacityFailureIsAtomicAndRecovers();
}

test "VFS reads borrow content without a second session allocation" {
    try vfs_tests.testVfsReadReturnsBorrowedContentWithoutSessionDuplication();
}

test "Python file writes invalidate borrowed VFS read views" {
    try vfs_tests.testPythonFileWriteInvalidatesBorrowedVfsRead();
}

test "text files implement reads and universal newlines" {
    try file_tests.testTextFileMethodsAndUniversalNewlines();
}

test "binary files implement seek tell and truncate" {
    try file_tests.testBinaryFilesSeekTellAndTruncate();
}

test "binary read after seeking past end preserves position" {
    try file_tests.testBinaryReadAfterSeekPastEndPreservesPosition();
}

test "file mode errors and text tell seek cookies match Python" {
    try file_tests.testOpenModeErrorsAndTextTellSeekCookie();
}

test "preserved CRLF text reads respect character size" {
    try file_tests.testPreservedCrLfReadsRespectTextCharacterSize();
}

test "readlines hint counts text characters" {
    try file_tests.testReadlinesHintCountsTextCharacters();
}

test "writelines accepts a generator expression" {
    try file_tests.testWritelinesAcceptsGeneratorExpression();
}

test "writelines resumes generators at tiny quantum without replay" {
    try file_tests.testWritelinesGeneratorResumesAtTinyQuantumWithoutReplay();
}

test "writelines charges long work and allows session recovery" {
    try file_tests.testWritelinesChargesLongSynchronousWorkAndRecovers();
}

test "file modes context management and closed errors" {
    try file_tests.testFileModesContextAndClosedErrors();
}

test "file contexts close on exception and return" {
    try file_tests.testFileContextClosesDuringExceptionAndReturn();
}

test "closed file tell raises ValueError" {
    try file_tests.testClosedTellRaisesValueError();
}

test "getattr and hasattr expose file object fields" {
    try file_tests.testGetattrAndHasattrExposeFileFields();
}

test "invalid UTF-8 text read releases partial buffer and allows reuse" {
    try file_tests.testInvalidTextReadReleasesPartialBufferAndAllowsReuse();
}

test "class parser and scope classify class locals and method closures" {
    try class_tests.testParserAndClassScope();
}

test "class decorators, class body, bases and methods preserve evaluation order" {
    try class_tests.testClassDefinitionOrderAndMethodBinding();
}

test "class body LOAD_NAME falls back to globals before assignment" {
    try class_tests.testClassBodyLoadNameFallsBackToGlobals();
}

test "ordinary classes use C3 MRO, super and the implicit class cell" {
    try class_tests.testC3MroSuperAndClassCell();
}

test "super binds inherited property getters to the instance" {
    try class_tests.testSuperBindsInheritedPropertyGetter();
}

test "properties, static methods, class methods and init validation work" {
    try class_tests.testDescriptorsAndConstructorValidation();
}

test "data descriptors shadow same-named instance attributes" {
    try class_tests.testDataDescriptorShadowsInstanceAttribute();
}

test "isinstance distinguishes class objects from primitive instances" {
    try class_tests.testIsinstanceTypeObjectDistinguishesInstances();
}

test "getattr default handles property AttributeError and preserves direct access" {
    try class_tests.testGetattrDefaultHandlesPropertyAttributeError();
}

test "AttributeError suppression preserves a handled exception for bare raise" {
    try class_tests.testAttributeErrorSuppressionPreservesHandledException();
}

test "special methods use type lookup and reflected NotImplemented" {
    try class_tests.testSpecialMethodsAndReflectedFallback();
}

test "user class context managers enter, suppress and exit in order" {
    try class_tests.testUserClassWithProtocol();
}

test "with exit truthiness runs while the pending exception is rooted" {
    try class_tests.testWithExitTruthinessWhileExceptionIsPending();
}

test "eq without hash makes instances unhashable" {
    try class_tests.testEqualityDisablesHashWithoutOverride();
}

test "subclass equality without hash overrides inherited hash" {
    try class_tests.testSubclassEqWithoutHashOverridesInheritedHash();
}

test "dict equality tries a user lookup key's right equality" {
    try class_tests.testDictKeyEqualityTriesLookupKeyRightEq();
}

test "dict string keys try a user lookup key's right equality" {
    try class_tests.testDictStringKeyEqualityTriesLookupKeyRightEq();
}

test "a right subclass reflected method has arithmetic priority" {
    try class_tests.testRightSubclassReflectedArithmeticHasPriority();
}

test "contains falls back to a user iterator when needed" {
    try class_tests.testContainsFallsBackToUserIterator();
}

test "contains converts suspended user iteration into catchable RuntimeError and recovers" {
    try class_tests.testContainsSuspendedIteratorRaisesCatchableRuntimeErrorAndRecovers();
}

test "contains roots a fresh user iterator item through allocating equality" {
    try class_tests.testContainsRootsFreshUserIteratorItemDuringAllocatingEquality();
}

test "classes and bound methods survive collection and cancellation recovery" {
    try class_tests.testClassGcQuantumCancelAndReset();
}

test "long class initializer timeslices and can suspend for host input" {
    try class_tests.testLongInitializerTimeslicesAndSuspendsForInput();
}

test "dynamic type and metaclass construction remain explicitly unsupported" {
    try class_tests.testUnsupportedDynamicTypeAndMetaclass();
}

test "shadowed builtin type remains callable in module and local scopes" {
    try class_tests.testShadowedTypeNameRemainsCallable();
}

test "yield is a resumable expression with send and StopIteration.value" {
    try generator_tests.testYieldSendReturnValueAndExhaustion();
}

test "resumed generator exceptions unwind inside and outside the frame" {
    try generator_tests.testGeneratorExceptionsInsideAndOutsideResumedFrame();
}

test "generator close runs finally once and rejects yielding during close" {
    try generator_tests.testGeneratorCloseRunsFinallyOnceAndRejectsYieldDuringClose();
}

test "generator resumes across host input at quantum one" {
    try generator_tests.testGeneratorResumesAcrossHostInputAtQuantumOne();
}

test "yield from and throw remain explicitly unsupported" {
    try generator_tests.testYieldFromAndThrowRemainExplicitlyUnsupported();
}

test "yield is invalid in a class suite but valid inside a method" {
    try generator_tests.testYieldIsRejectedInClassSuiteButAllowedInMethod();
}

test "function annotations evaluate in Python order and are stored" {
    try annotation_tests.testFunctionAnnotationsEvaluateInPythonOrderAndAreStored();
}

test "module class target and local annotation rules" {
    try annotation_tests.testModuleClassTargetAndLocalAnnotationRules();
}

test "future annotations is explicitly unsupported" {
    try annotation_tests.testFutureAnnotationsIsExplicitlyUnsupported();
}

test "match literal singleton capture guards and subject-once behavior" {
    try match_tests.testLiteralSingletonOrCaptureGuardAndSubjectOnce();
}

test "singleton match patterns use identity while numeric literals use equality" {
    try match_tests.testSingletonPatternsUseIdentity();
}

test "signed numeric match patterns" {
    try match_tests.testSignedNumericPatterns();
}

test "irrefutable OR alternatives have syntax diagnostics" {
    try match_tests.testIrrefutableOrAlternativesHaveSyntaxDiagnostics();
}

test "match invalid captures and irrefutable cases have diagnostics" {
    try match_tests.testInvalidMatchCapturesAndIrrefutableCaseDiagnostics();
}

test "excluded pattern forms have specific unsupported diagnostics" {
    try match_tests.testExcludedPatternFormsHaveSpecificDiagnostics();
}

test "imports cache modules, bind aliases, expose metadata, and use module globals" {
    try import_tests.testImportCacheMetadataAndModuleGlobals();
}

test "packages resolve relative imports and prefer package initializers" {
    try import_tests.testPackagesRelativeImportsAndPackagePrecedence();
}

test "circular imports observe initialized state and failed imports roll back" {
    try import_tests.testCircularImportsAndFailedImportRollback();
}

test "missing top-level import raises ModuleNotFoundError" {
    try import_tests.testMissingTopLevelModuleUsesModuleNotFoundError();
}

test "missing module member raises ImportError" {
    try import_tests.testMissingModuleMemberUsesImportError();
}

test "missing package child raises ImportError" {
    try import_tests.testMissingPackageMemberUsesImportError();
}

test "relative import outside a package raises ImportError" {
    try import_tests.testRelativeImportOutsidePackageUsesImportError();
}

test "star imports honor private names and tuple __all__" {
    try import_tests.testStarImportsHonorVisibilityAndTupleAll();
}

test "star import loads listed child modules with scheduled execution" {
    try import_tests.testPackageAllLoadsUninitializedChildThroughScheduledFrame();
}

test "star import missing listed name raises AttributeError" {
    try import_tests.testStarImportMissingListedNameRaisesAttributeError();
}

test "main module metadata exists without import statements and resets cleanly" {
    try import_tests.testMainMetadataIsInitializedWithoutImportStatements();
}

test "main metadata allocation failure reports MemoryError and recovers" {
    try import_tests.testMainMetadataAllocationFailureIsReportedAndRecoverable();
}

test "dotted relative from-import initializes intermediate packages" {
    try import_tests.testDottedRelativeFromImportInitializesIntermediatePackages();
}

test "a module cannot be used as a package for dotted imports" {
    try import_tests.testCannotImportChildOfSelectedModule();
}

test "imported modules run on scheduled frames and suspend for input" {
    try import_tests.testImportedModuleRunsOnMainFrameAndSuspendsForInput();
}

test "import cache resets while home modules persist without retention" {
    try import_tests.testImportCacheResetsAndHomeModulesPersistWithoutRetention();
}
