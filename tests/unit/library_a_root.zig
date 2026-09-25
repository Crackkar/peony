const numeric = @import("library_numeric_tests");
const data = @import("library_data_tests");
const vfs = @import("library_vfs_tests");
const collections = @import("library_collections_tests");

test "math contract" { try numeric.testMathContract(); }
test "math errors and binding" { try numeric.testMathErrorsAndBinding(); }
test "random contract and validation" { try numeric.testRandomContractAndValidation(); }
test "random work budget and cancellation" { try numeric.testRandomWorkBudgetAndCancellation(); }
test "statistics contract and one-pass iterables" { try numeric.testStatisticsContractAndOnePassIterables(); }
test "numeric GC and reset isolation" { try numeric.testNumericGcAndResetIsolation(); }

test "JSON loads dumps and options" { try data.testJsonLoadsDumpsAndOptions(); }
test "native JSON Value adapter preserves bigint Unicode and GC roots" { try data.testNativeJsonValueAdapter(); }
test "JSON errors metadata and cycles" { try data.testJsonErrorsMetadataAndCycles(); }
test "JSON file-like callbacks" { try data.testJsonFileLikeCallbacks(); }
test "CSV reader writer and Unicode" { try data.testCsvReaderWriterAndUnicode(); }
test "CSV dictionary variants and errors" { try data.testCsvDictionaryVariantsAndErrors(); }
test "data callbacks resume input once" { try data.testDataCallbacksResumeInputOnce(); }
test "data GC cap and reset" { try data.testDataGcCapAndReset(); }
test "large JSON parse and dump yield and cancel at native checkpoints" { try data.testJsonLargeQuantumAndCancellation(); }

test "Path lexical contract" { try vfs.testPathLexicalContract(); }
test "Path VFS methods and open protocol" { try vfs.testPathVfsMethodsAndOpenProtocol(); }
test "os.path and mutation contract" { try vfs.testOsPathAndMutationContract(); }
test "VFS readonly and error atomicity" { try vfs.testVfsReadonlyAndErrorAtomicity(); }
test "VFS GC and reset persistence" { try vfs.testVfsGcAndResetPersistence(); }

test "Counter construction and methods" { try collections.testCounterConstructionAndMethods(); }
test "Counter operators and comparisons" { try collections.testCounterOperatorsAndComparisons(); }
test "defaultdict contract" { try collections.testDefaultdictContract(); }
test "copy graphs instances and resources" { try collections.testCopyGraphsInstancesAndResources(); }
test "collection and copy hooks resume input once" { try collections.testCollectionAndCopyHooksResumeInputOnce(); }
test "collections GC cap and reset" { try collections.testCollectionsGcCapAndReset(); }
