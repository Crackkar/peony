const std = @import("std");
const builtin = @import("builtin");
const bytecode = @import("frontend_bytecode");
const compiler = @import("frontend_compiler");
const gc = @import("runtime_gc");
const value_module = @import("runtime_value");
const number = @import("runtime_number");
const string = @import("runtime_string");
const sequence = @import("runtime_sequence");
const hash_module = @import("runtime_hash");
const exceptions = @import("runtime_exception");
const iterator = @import("runtime_iterator");
const functions = @import("runtime_function");
const host = @import("runtime_host");
const vfs_module = @import("runtime_vfs");
const class_module = @import("runtime_class");
const native_types = @import("../stdlib/types.zig");
const byte_module = @import("runtime_bytes");
const dict_module = @import("runtime_dict");
const slice_module = @import("runtime_slice");
const file_module = @import("runtime_file");
const module_module = @import("runtime_module");

const Value = value_module.Value;
const Code = bytecode.Code;

var session_hash_nonce: u64 = 0;

pub const CompileOutcome = compiler.CompileOutcome;
pub const PythonException = exceptions.PythonException;
pub const PythonExceptionKind = exceptions.PythonExceptionKind;

pub const RunStatus = enum {
    completed,
    python_exception,
    timeslice,
    cancelled,
    engine_error,
    host_request,
    output_event,
    limit,
};

const default_quantum: u32 = 50_000;

const state = @import("state.zig");
const modules = @import("modules.zig");
const objects = @import("objects.zig");
const iteration = @import("iteration.zig");
const operations = @import("operations.zig");
const text_ops = @import("text.zig");
const builtins = @import("builtins.zig");
const calls = @import("calls.zig");
const control = @import("control.zig");
const native_tasks = @import("native_tasks.zig");
const GlobalEntry = state.GlobalEntry;
const TryPhase = state.TryPhase;
const PendingTransfer = state.PendingTransfer;
const TryBlock = state.TryBlock;
const Environment = state.Environment;
const TestContextManager = state.TestContextManager;
const traceTestContextManager = state.traceTestContextManager;
const destroyTestContextManager = state.destroyTestContextManager;
const Frame = state.Frame;
const PendingInput = state.PendingInput;
const SyncTaskOperation = state.SyncTaskOperation;
const SyncTaskPhase = state.SyncTaskPhase;
const SyncCallbackResult = state.SyncCallbackResult;
const SyncTask = state.SyncTask;
const destroyGeneratorFrameOpaque = state.destroyGeneratorFrameOpaque;
const environment_kind = state.environment_kind;
const traceEnvironment = state.traceEnvironment;
const destroyEnvironment = state.destroyEnvironment;

/// One interpreter session. Keep this value at a stable address after init;
/// its heap's allocation hook and root frames point into it.
pub const Runtime = struct {
    pub const ResolvedModule = struct { filename: []u8, is_package: bool };
    session_allocator: gc.SessionAllocator = undefined,
    heap: gc.Heap = .{},
    vfs: vfs_module.Vfs = undefined,
    vfs_output: []const u8 = &.{},
    vfs_output_owned: bool = false,
    environment: *Environment = undefined,
    environment_frame: gc.RootFrame = .{},
    environment_root: gc.Root = .{ .object = null },
    builtin_frame: gc.RootFrame = .{},
    module_cache_root: gc.Root = .{ .object = null },
    native_task_root: gc.Root = .{ .object = null },
    json_decode_error_root: gc.Root = .{ .object = null },
    print_builtin_root: gc.Root = .{ .object = null },
    input_builtin_root: gc.Root = .{ .object = null },
    range_builtin_root: gc.Root = .{ .object = null },
    object_class_root: gc.Root = .{ .object = null },
    type_class_root: gc.Root = .{ .object = null },
    native_class_roots: [@typeInfo(native_types.TypeId).@"enum".fields.len]gc.Root = @splat(.{ .object = null }),
    primitive_class_roots: [@typeInfo(class_module.PrimitiveType).@"enum".fields.len]gc.Root = @splat(.{ .object = null }),
    exception_frame: gc.RootFrame = .{},
    exception_root: gc.Root = .{ .object = null },
    emergency_exception_root: gc.Root = .{ .object = null },
    active_exception: ?*exceptions.ExceptionInstance = null,
    code: ?*Code = null,
    imported_codes: std.ArrayList(*Code) = .empty,
    top_frame: ?*Frame = null,
    frame_cache: ?*Frame = null,
    frame_cache_count: usize = 0,
    registers: []Value = &.{},
    register_roots: []gc.Root = &.{},
    register_frame: gc.RootFrame = .{},
    instruction_pointer: usize = 0,
    resuming_generator: ?*iterator.Iterator = null,
    suspended_exception_frame: ?*Frame = null,
    synchronous_work_remaining: ?usize = null,
    sync_root_frame: gc.RootFrame = .{},
    sync_roots: [8]gc.Root = @splat(.{ .object = null }),
    sync_task: ?SyncTask = null,
    sync_task_quantum: u32 = default_quantum,
    sync_yield_requested: bool = false,
    resumed_exception_pending: bool = false,
    sync_callback_depth: usize = 0,
    pending_input: ?PendingInput = null,
    event_packet: ?[]u8 = null,
    next_host_request_id: u32 = 1,
    output_event_pending: bool = false,
    max_instructions: u64 = 50_000_000,
    instructions_executed: u64 = 0,
    work_executed: u64 = 0,
    limit_reached: bool = false,
    configured_quantum: u32 = default_quantum,
    stdout_bytes: std.ArrayList(u8) = .empty,
    stderr_bytes: std.ArrayList(u8) = .empty,
    argv_items: std.ArrayList([]u8) = .empty,
    repr_path: std.ArrayList(*gc.Header) = .empty,
    value_equality_depth: usize = 0,
    hash_seed: u64 = 0,
    random_seed: u64 = 0x7065_6f6e_792d_7631,
    last_exception: ?PythonException = null,
    error_text_owned: ?[]u8 = null,
    error_text_static: []const u8 = "",
    traceback_json_owned: ?[]u8 = null,
    cancel_requested: bool = false,
    engine_failed: bool = false,
    initialized: bool = false,

    // Internal implementation aliases grouped by VM ownership. Bodies live in
    // the domain module; Runtime remains the single stateful owner.
    // Frame roots, control transfer, and exception handling.
    pub const allocateFrame = control.allocateFrame;
    pub const freeFrameStorage = control.freeFrameStorage;
    pub const clearFrameCache = control.clearFrameCache;
    pub const activateFrame = control.activateFrame;
    pub const popFrame = control.popFrame;
    pub const unwindFrames = control.unwindFrames;
    pub const unwindFramesUntil = control.unwindFramesUntil;
    pub const hasExceptionContinuation = control.hasExceptionContinuation;
    pub const frameHasExceptionContinuation = control.frameHasExceptionContinuation;
    pub const unwindPythonException = control.unwindPythonException;
    pub const unwindPythonExceptionUntil = control.unwindPythonExceptionUntil;
    pub const appendTracebackCaller = control.appendTracebackCaller;

    pub const tryRootIndex = control.tryRootIndex;
    pub const savePendingException = control.savePendingException;
    pub const restorePendingException = control.restorePendingException;
    pub const setFrameInstruction = control.setFrameInstruction;
    pub const clearExceptionTarget = control.clearExceptionTarget;
    pub const popTryBlock = control.popTryBlock;
    pub const beginJumpTransfer = control.beginJumpTransfer;
    pub const performReturn = control.performReturn;
    pub const framePreviousIsTask = control.framePreviousIsTask;
    pub const beginReturnTransfer = control.beginReturnTransfer;
    pub const enterTry = control.enterTry;
    pub const testContextManager = control.testContextManager;
    pub const executeWithEnter = control.executeWithEnter;
    pub const executeWithExit = control.executeWithExit;
    pub const activeExceptionKind = control.activeExceptionKind;
    pub const matchesExceptionType = control.matchesExceptionType;
    pub const storeBoundValue = control.storeBoundValue;
    pub const acceptCurrentException = control.acceptCurrentException;
    pub const completeTry = control.completeTry;
    pub const completeFinally = control.completeFinally;
    pub const raiseExisting = control.raiseExisting;
    pub const executeRaise = control.executeRaise;

    // Argument binding, callable dispatch, and frame-local name handling.
    pub const executeCall = calls.executeCall;
    pub const executeExceptionConstructor = calls.executeExceptionConstructor;
    pub const appendCallKeyword = calls.appendCallKeyword;
    pub const executeMaterializeStar = calls.executeMaterializeStar;
    pub const extendListFromIterable = calls.extendListFromIterable;
    pub const invokeCallableSync = calls.invokeCallableSync;
    pub const invokeSpecialSync = calls.invokeSpecialSync;
    pub const invokeValueSync = calls.invokeValueSync;
    pub const restoreFrameRegister = calls.restoreFrameRegister;
    pub const invokePythonSync = calls.invokePythonSync;
    pub const currentNativeTask = native_tasks.currentNativeTask;
    pub const startNativeTask = native_tasks.startNativeTask;
    pub const processNativeTask = native_tasks.processNativeTask;
    pub const startTaskCall = native_tasks.startTaskCall;
    pub const startTaskNext = native_tasks.startTaskNext;
    pub const pendingNativeHost = native_tasks.pendingNativeHost;
    pub const resumeNativeHost = native_tasks.resumeNativeHost;
    pub const executeMakeFunction = calls.executeMakeFunction;
    pub const executeMakeClass = calls.executeMakeClass;
    pub const setBinderException = calls.setBinderException;
    pub const storeFrameLocal = calls.storeFrameLocal;
    pub const findCell = calls.findCell;
    pub const loadLocal = calls.loadLocal;
    pub const storeLocal = calls.storeLocal;
    pub const isCallable = calls.isCallable;

    // Builtin functions and native methods.
    pub const executeNativeCall = builtins.executeNativeCall;
    pub const executeOtherNativeCall = builtins.executeOtherNativeCall;
    pub const executeGeneratorSend = builtins.executeGeneratorSend;
    pub const executeGeneratorClose = builtins.executeGeneratorClose;
    pub const executeOpen = builtins.executeOpen;
    pub const executeFileNative = builtins.executeFileNative;
    pub const fileInteger = builtins.fileInteger;
    pub const executeMappingConstructor = builtins.executeMappingConstructor;
    pub const updateDictFromValue = builtins.updateDictFromValue;
    pub const updateSetFromIterable = builtins.updateSetFromIterable;
    pub const executeMappingMethod = builtins.executeMappingMethod;
    pub const setMappingResult = builtins.setMappingResult;
    pub const storeDictResult = builtins.storeDictResult;
    pub const executeStringNative = builtins.executeStringNative;
    pub const executeBytesNative = builtins.executeBytesNative;
    pub const nativeTypeError = builtins.nativeTypeError;
    pub const nativeAttributeError = builtins.nativeAttributeError;
    pub const suppressAttributeError = builtins.suppressAttributeError;
    pub const nativeArity = builtins.nativeArity;
    pub const storeVoidResult = builtins.storeVoidResult;
    pub const storeValueResult = builtins.storeValueResult;
    pub const storeListResult = builtins.storeListResult;
    pub const storeTupleResult = builtins.storeTupleResult;
    pub const setSmallInt = builtins.setSmallInt;
    pub const executeSliceBuiltin = builtins.executeSliceBuiltin;
    pub const valueBytes = builtins.valueBytes;
    pub const valueIsUtf8 = builtins.valueIsUtf8;
    pub const splitStringResult = builtins.splitStringResult;
    pub const splitStringWhitespaceResult = builtins.splitStringWhitespaceResult;
    pub const splitStringIteratorResult = builtins.splitStringIteratorResult;
    pub const splitBytesResult = builtins.splitBytesResult;
    pub const joinStringResult = builtins.joinStringResult;

    // Formatting, repr, and output buffering.
    pub const executeFormatValue = text_ops.executeFormatValue;
    pub const executeStrFormat = text_ops.executeStrFormat;
    pub const makeFormattedText = text_ops.makeFormattedText;
    pub const renderValueOwned = text_ops.renderValueOwned;
    pub const asciiEscape = text_ops.asciiEscape;
    pub const applyFormatSpec = text_ops.applyFormatSpec;
    pub const padSignedNumeric = text_ops.padSignedNumeric;
    pub const padFormatted = text_ops.padFormatted;
    pub const formatFloat = text_ops.formatFloat;
    pub const formatGeneralFloat = text_ops.formatGeneralFloat;
    pub const normalizedScientific = text_ops.normalizedScientific;
    pub const scientificMantissaToFixed = text_ops.scientificMantissaToFixed;
    pub const groupThousands = text_ops.groupThousands;
    pub const remainingSessionBytes = text_ops.remainingSessionBytes;
    pub const formatMemoryFailure = text_ops.formatMemoryFailure;
    pub const formatValueError = text_ops.formatValueError;
    pub const formatTypeError = text_ops.formatTypeError;
    pub const executePercentFormat = text_ops.executePercentFormat;
    pub const executePrint = text_ops.executePrint;
    pub const executePrintValues = text_ops.executePrintValues;
    pub const appendValue = text_ops.appendValue;
    pub const appendValueMode = text_ops.appendValueMode;
    pub const appendSequence = text_ops.appendSequence;
    pub const appendMapping = text_ops.appendMapping;
    pub const appendMappingView = text_ops.appendMappingView;
    pub const appendQuoted = text_ops.appendQuoted;
    pub const appendRange = text_ops.appendRange;
    pub const appendInteger = text_ops.appendInteger;
    pub const appendFormatted = text_ops.appendFormatted;
    pub const appendOutput = text_ops.appendOutput;

    // Operators, comparisons, hashing, and work accounting.
    pub const executeBinary = operations.executeBinary;
    pub const storeNumberResult = operations.storeNumberResult;
    pub const storeFloatResult = operations.storeFloatResult;
    pub const valueTruthy = operations.valueTruthy;
    pub const normalizeSearchBound = operations.normalizeSearchBound;
    pub const compareValues = operations.compareValues;
    pub const containsValue = operations.containsValue;
    pub const containsUserIterable = operations.containsUserIterable;
    pub const findListItem = operations.findListItem;
    pub const valuesEqual = operations.valuesEqual;
    pub const compareWithUserEquality = operations.compareWithUserEquality;
    pub const sortOrder = operations.sortOrder;
    pub const beginSynchronousWork = operations.beginSynchronousWork;
    pub const endSynchronousWork = operations.endSynchronousWork;
    pub const chargeSynchronousWork = operations.chargeSynchronousWork;
    pub const chargeBulkWork = operations.chargeBulkWork;
    pub const repeatResultFitsSessionHeap = operations.repeatResultFitsSessionHeap;
    pub const executeSequenceRepeat = operations.executeSequenceRepeat;
    pub const chargeBytecode = operations.chargeBytecode;
    pub const chargeNestedInstruction = operations.chargeNestedInstruction;
    pub const rightReflectedHasPriority = operations.rightReflectedHasPriority;
    pub const pythonHash = operations.pythonHash;
    pub const setMappingValueWithHash = operations.setMappingValueWithHash;
    pub const mappingContains = operations.mappingContains;
    pub const storeSetOperation = operations.storeSetOperation;
    pub const valueString = operations.valueString;

    // Iterators, generators, synchronous tasks, and sorting.
    pub const createIteratorResult = iteration.createIteratorResult;
    pub const createVmIterator = iteration.createVmIterator;
    pub const storeIteratorOutcome = iteration.storeIteratorOutcome;
    pub const nextIteratorValue = iteration.nextIteratorValue;
    pub const nextEnumerateIteratorValue = iteration.nextEnumerateIteratorValue;
    pub const nextZipIteratorValue = iteration.nextZipIteratorValue;
    pub const resumeGenerator = iteration.resumeGenerator;
    pub const setIteratorStopIteration = iteration.setIteratorStopIteration;
    pub const createGeneratorFrame = iteration.createGeneratorFrame;
    pub const beginSyncTaskRoots = iteration.beginSyncTaskRoots;
    pub const releaseSyncCallbackDepth = iteration.releaseSyncCallbackDepth;
    pub const takeCompletedSyncCallback = iteration.takeCompletedSyncCallback;
    pub const invokeSyncTaskCallback = iteration.invokeSyncTaskCallback;
    pub const clearSyncTask = iteration.clearSyncTask;
    pub const pauseSyncTask = iteration.pauseSyncTask;
    pub const continueSyncTaskAfterCallback = iteration.continueSyncTaskAfterCallback;
    pub const iteratorHasPendingCallback = iteration.iteratorHasPendingCallback;
    pub const startSortedTask = iteration.startSortedTask;
    pub const startListSortTask = iteration.startListSortTask;
    pub const startNextTask = iteration.startNextTask;
    pub const prepareSyncSort = iteration.prepareSyncSort;
    pub const completeSyncTask = iteration.completeSyncTask;
    pub const finishSyncSort = iteration.finishSyncSort;
    pub const advanceSyncTask = iteration.advanceSyncTask;
    pub const materializeSequence = iteration.materializeSequence;
    pub const materializeSequenceImmediate = iteration.materializeSequenceImmediate;
    pub const sortList = iteration.sortList;
    pub const sortListWithKey = iteration.sortListWithKey;

    // Objects, attributes, sequence access, and collection mutation.
    pub const executeMakeSequence = objects.executeMakeSequence;
    pub const executeMakeMapping = objects.executeMakeMapping;
    pub const executeMappingSet = objects.executeMappingSet;
    pub const executeMappingUpdate = objects.executeMappingUpdate;
    pub const executeMakeSlice = objects.executeMakeSlice;
    pub const lookupAttributeValue = objects.lookupAttributeValue;
    pub const setUserAttribute = objects.setUserAttribute;
    pub const deleteUserAttribute = objects.deleteUserAttribute;
    pub const executeGetAttribute = objects.executeGetAttribute;
    pub const createBoundMethodResult = objects.createBoundMethodResult;
    pub const executeSetAttribute = objects.executeSetAttribute;
    pub const executeDeleteAttribute = objects.executeDeleteAttribute;
    pub const executeGetItem = objects.executeGetItem;
    pub const executeIndexedSequence = objects.executeIndexedSequence;
    pub const storeStringIndex = objects.storeStringIndex;
    pub const executeSliceItem = objects.executeSliceItem;
    pub const sliceSequence = objects.sliceSequence;
    pub const storeStringResult = objects.storeStringResult;
    pub const stringValueResult = objects.stringValueResult;
    pub const storeBytesResult = objects.storeBytesResult;
    pub const executeSetItem = objects.executeSetItem;
    pub const executeDeleteItem = objects.executeDeleteItem;
    pub const executeUnpack = objects.executeUnpack;
    pub const setMappingValue = objects.setMappingValue;

    // Module namespaces, imports, and module cache.
    pub const attachImportedChild = modules.attachImportedChild;
    pub const storeAnnotation = modules.storeAnnotation;
    pub const storeAnnotationEntry = modules.storeAnnotationEntry;
    pub const executeDeleteGlobal = modules.executeDeleteGlobal;
    pub const globalValue = modules.globalValue;
    pub const cachedGlobalValue = modules.cachedGlobalValue;
    pub const currentEnvironment = modules.currentEnvironment;
    pub const currentEnvironmentObject = modules.currentEnvironmentObject;
    pub const environmentLookup = modules.environmentLookup;
    pub const environmentStore = modules.environmentStore;
    pub const createEnvironment = modules.createEnvironment;
    pub const createStringValue = modules.createStringValue;
    pub const moduleCache = modules.moduleCache;
    pub const countCodeRoots = modules.countCodeRoots;
    pub const copyCodeRoots = modules.copyCodeRoots;
    pub const detachRootsTo = modules.detachRootsTo;
    pub const findCachedModule = modules.findCachedModule;
    pub const cacheModule = modules.cacheModule;
    pub const removeCachedModule = modules.removeCachedModule;
    pub const initializeModuleWorld = modules.initializeModuleWorld;
    pub const moduleForEnvironment = modules.moduleForEnvironment;
    pub const resolveImportName = modules.resolveImportName;
    pub const resolveModuleFile = modules.resolveModuleFile;
    pub const resolveModuleFileUnder = modules.resolveModuleFileUnder;
    pub const executeImportModule = modules.executeImportModule;
    pub const startImportedModule = modules.startImportedModule;
    pub const startNativeModule = modules.startNativeModule;
    pub const executeImportMember = modules.executeImportMember;
    pub const executeImportStar = modules.executeImportStar;
    pub const storeGlobal = modules.storeGlobal;
    pub const storeCachedGlobal = modules.storeCachedGlobal;

    pub const executeMaterializeDstar = calls.executeMaterializeDstar;
    pub const mappingHasStringKey = calls.mappingHasStringKey;
    pub const duplicateCallKeyword = calls.duplicateCallKeyword;

    pub const executeDeleteLocal = calls.executeDeleteLocal;

    pub const setException = control.setException;
    pub const currentFilename = control.currentFilename;
    pub const prepareExceptionDiagnostics = control.prepareExceptionDiagnostics;
    pub const prepareCompileDiagnostic = control.prepareCompileDiagnostic;

    pub fn init(self: *Runtime, backing: std.mem.Allocator, max_bytes: usize) std.mem.Allocator.Error!void {
        const vfs_limit = @min(8 * 1024 * 1024, @max(@as(usize, 1024), max_bytes / 2));
        const file_limit = @min(2 * 1024 * 1024, vfs_limit);
        return self.initWithVfsLimits(backing, max_bytes, vfs_limit, file_limit);
    }

    pub fn initWithConfig(self: *Runtime, backing: std.mem.Allocator, config: host.Config) std.mem.Allocator.Error!void {
        try self.initWithVfsLimits(
            backing,
            @intCast(config.max_memory_bytes),
            @intCast(config.max_vfs_bytes),
            @intCast(config.max_file_bytes),
        );
        self.configureHost(config);
    }

    fn initWithVfsLimits(
        self: *Runtime,
        backing: std.mem.Allocator,
        max_bytes: usize,
        vfs_limit: usize,
        file_limit: usize,
    ) std.mem.Allocator.Error!void {
        self.* = .{};
        session_hash_nonce +%= 1;
        self.hash_seed = hash_module.mixSessionSeed(session_hash_nonce, @intFromPtr(self));
        self.session_allocator = gc.SessionAllocator.init(backing, max_bytes);
        self.heap.init(&self.session_allocator, .{});
        self.vfs = vfs_module.Vfs.init(self.heap.allocator, vfs_limit, file_limit) catch {
            self.heap.deinit();
            self.* = .{};
            return error.OutOfMemory;
        };
        const environment = self.heap.createObject(Environment, &environment_kind) catch {
            self.vfs.deinit();
            self.heap.deinit();
            self.* = .{};
            return error.OutOfMemory;
        };
        environment.entries = .empty;
        environment.module_owner = null;
        environment.shape_version = 1;
        self.environment = environment;
        self.environment_root.object = &environment.header;
        self.environment_frame.push(&self.heap.roots);
        self.environment_frame.add(&self.environment_root);
        self.builtin_frame.push(&self.heap.roots);
        self.builtin_frame.add(&self.print_builtin_root);
        self.builtin_frame.add(&self.input_builtin_root);
        self.builtin_frame.add(&self.range_builtin_root);
        self.builtin_frame.add(&self.object_class_root);
        self.builtin_frame.add(&self.type_class_root);
        self.builtin_frame.add(&self.module_cache_root);
        self.builtin_frame.add(&self.native_task_root);
        self.builtin_frame.add(&self.json_decode_error_root);
        for (&self.native_class_roots) |*root| self.builtin_frame.add(root);
        for (&self.primitive_class_roots) |*root| self.builtin_frame.add(root);
        self.exception_frame.push(&self.heap.roots);
        self.exception_frame.add(&self.exception_root);
        self.exception_frame.add(&self.emergency_exception_root);
        const print_builtin = functions.createNative(&self.heap, .print);
        switch (print_builtin) {
            .value => |function| self.print_builtin_root.object = &function.header,
            .python_exception => {
                self.exception_frame.pop();
                self.builtin_frame.pop();
                self.environment_frame.pop();
                self.vfs.deinit();
                self.heap.deinit();
                self.* = .{};
                return error.OutOfMemory;
            },
        }
        const range_builtin = functions.createNative(&self.heap, .range);
        switch (range_builtin) {
            .value => |function| self.range_builtin_root.object = &function.header,
            .python_exception => {
                self.exception_frame.pop();
                self.builtin_frame.pop();
                self.environment_frame.pop();
                self.vfs.deinit();
                self.heap.deinit();
                self.* = .{};
                return error.OutOfMemory;
            },
        }
        const input_builtin = functions.createNative(&self.heap, .input);
        switch (input_builtin) {
            .value => |function| self.input_builtin_root.object = &function.header,
            .python_exception => {
                self.exception_frame.pop();
                self.builtin_frame.pop();
                self.environment_frame.pop();
                self.vfs.deinit();
                self.heap.deinit();
                self.* = .{};
                return error.OutOfMemory;
            },
        }
        switch (exceptions.createInstance(&self.heap, .memory_error, "session memory limit exceeded")) {
            .value => |instance| self.emergency_exception_root.object = &instance.header,
            .python_exception, .engine_error => {
                self.failInitialization();
                return error.OutOfMemory;
            },
        }
        self.initialized = true;
    }

    pub fn deinit(self: *Runtime) void {
        if (!self.initialized) return;
        self.resetProgram(false);
        self.clearVfsOutput();
        self.vfs.deinit();
        self.stdout_bytes.deinit(self.heap.allocator);
        self.stderr_bytes.deinit(self.heap.allocator);
        self.imported_codes.deinit(self.heap.allocator);
        self.repr_path.deinit(self.heap.allocator);
        if (self.traceback_json_owned) |json| self.heap.allocator.free(json);
        self.traceback_json_owned = null;
        if (self.exception_frame.stack != null) self.exception_frame.pop();
        if (self.builtin_frame.stack != null) self.builtin_frame.pop();
        if (self.environment_frame.stack != null) self.environment_frame.pop();
        self.heap.deinit();
        std.debug.assert(self.session_allocator.live_bytes == 0);
        self.* = .{};
    }

    pub fn compileAndStart(self: *Runtime, source: []const u8, filename: []const u8) CompileOutcome {
        return self.compileAndStartArgs(source, filename, &.{});
    }

    pub fn compileAndStartArgs(self: *Runtime, source: []const u8, filename: []const u8, argv: []const []const u8) CompileOutcome {
        self.vfs.clearTemporary();
        self.clearVfsOutput();
        self.resetProgram(true);
        self.instructions_executed = 0;
        self.work_executed = 0;
        self.limit_reached = false;
        for (argv) |argument| {
            const owned = self.heap.allocator.dupe(u8, argument) catch {
                const exception = PythonException{ .kind = .memory_error, .message = "session memory limit exceeded" };
                self.setException(exception, 1, 1, null);
                return .{ .python_exception = exception };
            };
            self.argv_items.append(self.heap.allocator, owned) catch {
                self.heap.allocator.free(owned);
                const exception = PythonException{ .kind = .memory_error, .message = "session memory limit exceeded" };
                self.setException(exception, 1, 1, null);
                return .{ .python_exception = exception };
            };
        }
        const outcome = compiler.compile(&self.heap, source, filename);
        switch (outcome) {
            .ready => |code| {
                self.code = code;
                if (self.prepareRegisters(code)) {
                    if (!self.initializeModuleWorld(1, 1)) {
                        const exception = self.last_exception orelse PythonException{ .kind = .memory_error, .message = "session memory limit exceeded" };
                        return .{ .python_exception = exception };
                    }
                    return .{ .ready = code };
                }
                code.deinit(&self.heap);
                self.code = null;
                const exception = PythonException{ .kind = .memory_error, .message = "session memory limit exceeded" };
                self.setException(exception, 1, 1, null);
                return .{ .python_exception = exception };
            },
            .syntax_error => |diagnostic| {
                self.setStaticError(diagnostic.message);
                self.prepareCompileDiagnostic(source, filename, diagnostic.line, diagnostic.column);
                return .{ .syntax_error = diagnostic };
            },
            .unsupported => |diagnostic| {
                self.setStaticError(diagnostic.message);
                self.prepareCompileDiagnostic(source, filename, diagnostic.line, diagnostic.column);
                return .{ .unsupported = diagnostic };
            },
            .python_exception => |exception| {
                self.setException(exception, 1, 1, null);
                return .{ .python_exception = exception };
            },
        }
    }

    pub fn run(self: *Runtime, requested_quantum: u32) RunStatus {
        // `vfs_output` may borrow an entry's byte storage. A running Python
        // program can replace that entry, so expire any prior VFS view before
        // execution can mutate the filesystem.
        self.clearVfsOutput();
        if (self.engine_failed) return .engine_error;
        if (self.cancel_requested) {
            self.cancel_requested = false;
            self.resetProgram(false);
            return .cancelled;
        }
        if (self.pending_input != null) return .host_request;
        if (self.currentNativeTask()) |task| if (task.stage == .waiting_host) return .host_request;
        if (self.limit_reached) return .limit;
        if (self.resumed_exception_pending) {
            self.resumed_exception_pending = false;
            if (self.last_exception != null and !self.unwindPythonException()) {
                if (self.engine_failed) return .engine_error;
                self.prepareExceptionDiagnostics();
                return .python_exception;
            }
        }
        if (self.last_exception != null and !self.hasExceptionContinuation()) {
            self.prepareExceptionDiagnostics();
            return .python_exception;
        }
        if (self.top_frame == null) return .completed;

        self.invalidateEvent();
        const quantum = if (requested_quantum == 0) self.configured_quantum else requested_quantum;
        self.sync_task_quantum = quantum;
        self.sync_yield_requested = false;
        var executed: u32 = 0;
        var native_work_in_run: u64 = 0;
        const native_work_budget: u64 = quantum;
        while (executed < quantum) : (executed += 1) {
            if (self.currentNativeTask()) |task| {
                if (task.stage == .ready) {
                    const before_work = self.work_executed;
                    if (self.processNativeTask(task)) |status| return status;
                    if (self.limit_reached) return .limit;
                    native_work_in_run += self.work_executed - before_work;
                    if (native_work_in_run >= native_work_budget) return .timeslice;
                    continue;
                }
            }
            const frame = self.top_frame orelse return .completed;
            if (frame.ip >= frame.code.instructions.len or frame.code.positions.len != frame.code.instructions.len) {
                _ = self.engineFault();
                self.unwindFrames();
                return .engine_error;
            }
            const current = frame.code.positions[frame.ip];
            const instruction = frame.code.instructions[frame.ip];
            const executing_generator = frame.generator_owner;
            if (executing_generator != null) self.resuming_generator = executing_generator;
            if (!self.chargeBytecode()) return .limit;
            frame.ip += 1;
            self.instruction_pointer = frame.ip;
            if (!self.execute(instruction, frame.code, current.line, current.column)) {
                if (self.limit_reached) {
                    if (self.sync_task) |task| if (!task.callback_in_progress) self.clearSyncTask();
                    return .limit;
                }
                if (self.sync_task) |task| if (!task.callback_in_progress) self.clearSyncTask();
                if (!self.engine_failed and self.last_exception != null and self.unwindPythonException()) {
                    if (self.sync_task) |task| if (task.callback_failed or !task.callback_in_progress) self.clearSyncTask();
                    continue;
                }
                if (self.sync_task) |task| {
                    if (task.callback_in_progress) self.unwindFramesUntil(task.frame);
                    if (self.sync_task != null) self.clearSyncTask();
                }
                self.unwindFrames();
                if (self.engine_failed) return .engine_error;
                self.prepareExceptionDiagnostics();
                return .python_exception;
            }
            if (self.top_frame == frame) {
                frame.ip = self.instruction_pointer;
            }
            if (executing_generator) |generator| {
                if (self.currentNativeTask()) |task| {
                    if (task.stage == .waiting_next and task.next_iterator.asObject() == &generator.header and self.top_frame != frame) {
                        if (generator.generator_yielded) |item| {
                            generator.generator_yielded = null;
                            task.child_value = item;
                            task.child_done = false;
                            task.child_ready = true;
                            task.stage = .ready;
                            self.resuming_generator = null;
                        } else if (generator.generator_done) {
                            task.child_value = Value.noneValue();
                            task.child_done = true;
                            task.child_ready = true;
                            task.stage = .ready;
                            self.resuming_generator = null;
                        }
                    }
                }
            }
            if (self.sync_task != null and self.sync_task.?.complete) self.clearSyncTask();
            if (self.limit_reached) {
                if (self.sync_task != null) self.clearSyncTask();
                return .limit;
            }
            if (self.pending_input != null) return .host_request;
            if (self.output_event_pending) {
                self.output_event_pending = false;
                return .output_event;
            }
            if (self.sync_yield_requested) {
                self.sync_yield_requested = false;
                return .timeslice;
            }
            if (self.top_frame == null) return .completed;
        }
        return if (self.top_frame == null) .completed else .timeslice;
    }

    pub fn cancel(self: *Runtime) void {
        self.pending_input = null;
        self.native_task_root.object = null;
        self.invalidateEvent();
        self.output_event_pending = false;
        self.cancel_requested = true;
    }

    pub fn configureHost(self: *Runtime, config: host.Config) void {
        self.max_instructions = config.max_instructions;
        self.configured_quantum = config.quantum;
        if (config.seed.len != 0) {
            self.hash_seed = hash_module.mixSessionSeed(std.hash.Wyhash.hash(0, config.seed), @intFromPtr(self));
            self.random_seed = std.hash.Wyhash.hash(0x7065_6f6e_792d_7631, config.seed);
        }
    }

    pub fn instructionCount(self: *const Runtime) u64 {
        return self.instructions_executed;
    }

    pub fn workCount(self: *const Runtime) u64 {
        return self.work_executed;
    }

    pub fn remainingNativeWork(self: *const Runtime) u64 {
        return self.max_instructions -| self.work_executed;
    }

    pub fn mountCourseFile(self: *Runtime, path: []const u8, bytes: []const u8) vfs_module.Error!void {
        self.clearVfsOutput();
        try self.vfs.mountCourse(path, bytes);
    }

    pub fn writeVfsFile(self: *Runtime, path: []const u8, bytes: []const u8) vfs_module.Error!void {
        self.clearVfsOutput();
        try self.vfs.write(path, bytes, .replace);
    }

    pub fn readVfsFile(self: *Runtime, path: []const u8) vfs_module.Error![]const u8 {
        self.clearVfsOutput();
        self.vfs_output = try self.vfs.read(path);
        return self.vfs_output;
    }

    pub fn listVfsFiles(self: *Runtime, path: []const u8) vfs_module.Error![]const u8 {
        self.clearVfsOutput();
        self.vfs_output = try self.vfs.list(path);
        self.vfs_output_owned = true;
        return self.vfs_output;
    }

    pub fn listVfsDirectories(self: *Runtime, path: []const u8) vfs_module.Error![]const u8 {
        self.clearVfsOutput();
        self.vfs_output = try self.vfs.listDirectories(path);
        self.vfs_output_owned = true;
        return self.vfs_output;
    }

    pub fn mkdirVfsDirectory(self: *Runtime, path: []const u8) vfs_module.Error!void {
        self.clearVfsOutput();
        try self.vfs.mkdir(path, true, true);
    }

    pub fn vfsData(self: *const Runtime) []const u8 {
        return self.vfs_output;
    }

    pub fn clearVfsOutput(self: *Runtime) void {
        if (self.vfs_output_owned and self.vfs_output.len != 0) self.heap.allocator.free(@constCast(self.vfs_output));
        self.vfs_output = &.{};
        self.vfs_output_owned = false;
    }

    pub fn eventBytes(self: *const Runtime) []const u8 {
        return self.event_packet orelse "";
    }

    pub fn pendingInputRequestId(self: *const Runtime) ?u32 {
        const pending = self.pending_input orelse return null;
        return pending.request_id;
    }

    pub fn reset(self: *Runtime) void {
        self.vfs.clearTemporary();
        self.clearVfsOutput();
        self.resetProgram(true);
        self.instructions_executed = 0;
        self.work_executed = 0;
        self.limit_reached = false;
    }

    /// Accepts a fully decoded packet. A false return leaves the suspended input and event untouched.
    pub fn resumeHost(self: *Runtime, packet: *const host.DecodedPacket) bool {
        if (!host.validDecodedPacket(packet)) return false;
        if (self.pending_input == null) return self.resumeNativeHost(packet);
        const pending = self.pending_input orelse return false;
        if (packet.kind != .input or packet.request_id != pending.request_id or packet.flags != 0) return false;
        switch (packet.status) {
            .ok => if (packet.sections.len != 1 or packet.sections[0].kind != .utf8) return false,
            .eof => if (packet.sections.len != 0) return false,
            .host_error => if (packet.sections.len != 1 or packet.sections[0].kind != .utf8) return false,
        }

        self.pending_input = null;
        self.invalidateEvent();
        switch (packet.status) {
            .ok => {
                const line = trimInputEnding(packet.sections[0].bytes);
                const created = string.create(&self.heap, line);
                switch (created) {
                    .value => |text| {
                        const position: usize = pending.destination;
                        if (position >= pending.frame.registers.len or pending.frame.roots.len < pending.frame.registers.len) {
                            _ = self.engineFault();
                            return true;
                        }
                        const value = Value.object(&text.header);
                        pending.frame.registers[position] = value;
                        pending.frame.roots[position].object = &text.header;
                    },
                    .python_exception => |exception| {
                        self.setException(exception, pending.line, pending.column, null);
                        self.resumed_exception_pending = true;
                    },
                    .engine_error => _ = self.engineFault(),
                }
            },
            .eof => {
                self.setException(.{ .kind = .eof_error, .message = "EOF when reading a line" }, pending.line, pending.column, null);
                self.resumed_exception_pending = true;
            },
            .host_error => {
                self.setException(.{ .kind = .os_error, .message = packet.sections[0].bytes }, pending.line, pending.column, null);
                self.resumed_exception_pending = true;
            },
        }
        if (self.currentNativeTask()) |task| {
            if (task.stage == .waiting_call and task.caller_frame == @as(*anyopaque, @ptrCast(pending.frame))) {
                if (self.last_exception != null) {
                    task.child_error = self.active_exception;
                    task.child_done = false;
                    self.last_exception = null;
                    self.active_exception = null;
                    self.exception_root.object = null;
                    self.resumed_exception_pending = false;
                    self.clearErrorText();
                } else {
                    task.child_value = pending.frame.registers[pending.destination];
                    task.child_error = null;
                }
                task.child_ready = true;
                task.stage = .ready;
            }
        }
        return true;
    }

    pub fn stdout(self: *const Runtime) []const u8 {
        return self.stdout_bytes.items;
    }

    pub fn stderr(self: *const Runtime) []const u8 {
        return self.stderr_bytes.items;
    }

    pub fn appendStderr(self: *Runtime, text: []const u8) bool {
        self.stderr_bytes.appendSlice(self.heap.allocator, text) catch return false;
        return true;
    }

    pub fn consumeStdout(self: *Runtime, length: usize) bool {
        if (length > self.stdout_bytes.items.len) return false;
        self.invalidateEvent();
        const remaining = self.stdout_bytes.items.len - length;
        if (remaining != 0) std.mem.copyForwards(u8, self.stdout_bytes.items[0..remaining], self.stdout_bytes.items[length..]);
        self.stdout_bytes.items.len = remaining;
        return true;
    }

    pub fn consumeStderr(self: *Runtime, length: usize) bool {
        if (length > self.stderr_bytes.items.len) return false;
        self.invalidateEvent();
        const remaining = self.stderr_bytes.items.len - length;
        if (remaining != 0) std.mem.copyForwards(u8, self.stderr_bytes.items[0..remaining], self.stderr_bytes.items[length..]);
        self.stderr_bytes.items.len = remaining;
        return true;
    }

    pub fn pythonException(self: *const Runtime) ?PythonException {
        return self.last_exception;
    }

    pub fn errorText(self: *const Runtime) []const u8 {
        return self.error_text_owned orelse self.error_text_static;
    }

    pub fn tracebackJson(self: *const Runtime) []const u8 {
        return self.traceback_json_owned orelse "";
    }

    /// Installs a synthetic context-manager object for native protocol tests.
    /// The method is deliberately unavailable in product builds and is not part
    /// of Peony's Python or WASM API.
    pub fn installTestContextManager(
        self: *Runtime,
        name: []const u8,
        label: []const u8,
        entered: Value,
        suppress: bool,
        enter_error: ?PythonExceptionKind,
    ) std.mem.Allocator.Error!void {
        if (comptime !builtin.is_test) @compileError("native test helper is unavailable in product builds");
        const manager = try self.heap.createObject(TestContextManager, &state.test_context_manager_kind);
        const header = manager.header;
        manager.* = .{
            .header = header,
            .entered = entered,
            .label = &.{},
            .suppress = suppress,
            .enter_error = enter_error,
        };
        var root = gc.Root{ .object = &manager.header };
        var roots = gc.RootFrame{};
        roots.push(&self.heap.roots);
        roots.add(&root);
        defer roots.pop();
        manager.label = try self.heap.allocator.dupe(u8, label);
        if (!self.storeGlobal(name, Value.object(&manager.header))) return error.OutOfMemory;
    }

    fn prepareRegisters(self: *Runtime, code: *Code) bool {
        _ = self.allocateFrame(code, null) catch return false;
        return true;
    }

    fn resetProgram(self: *Runtime, clear_output: bool) void {
        self.suspended_exception_frame = null;
        self.resuming_generator = null;
        if (self.sync_task) |task| {
            if (task.callback_in_progress) self.unwindFramesUntil(task.frame);
        }
        if (self.sync_task != null) self.clearSyncTask();
        self.unwindFrames();
        self.clearFrameCache();

        self.pending_input = null;
        self.native_task_root.object = null;
        self.output_event_pending = false;
        self.invalidateEvent();

        self.clearGlobals();
        for (self.argv_items.items) |argument| self.heap.allocator.free(argument);
        self.argv_items.deinit(self.heap.allocator);
        self.argv_items = .empty;
        self.module_cache_root.object = null;
        while (self.imported_codes.items.len != 0) {
            const imported = self.imported_codes.pop().?;
            imported.deinit(&self.heap);
        }
        if (self.code) |code| {
            code.deinit(&self.heap);
            self.code = null;
        }
        self.instruction_pointer = 0;
        self.cancel_requested = false;
        self.engine_failed = false;
        self.last_exception = null;
        self.resumed_exception_pending = false;
        self.active_exception = null;
        self.exception_root.object = null;
        self.clearErrorText();
        if (self.traceback_json_owned) |json| self.heap.allocator.free(json);
        self.traceback_json_owned = null;
        if (clear_output) self.stdout_bytes.clearRetainingCapacity();
        if (clear_output) self.stderr_bytes.clearRetainingCapacity();
        for (&self.native_class_roots) |*root| root.object = null;
        self.json_decode_error_root.object = null;
        for (&self.primitive_class_roots) |*root| root.object = null;
        _ = self.heap.collect();
    }

    pub fn invalidateEvent(self: *Runtime) void {
        if (self.event_packet) |packet| self.heap.allocator.free(packet);
        self.event_packet = null;
    }

    pub fn createEventPacket(self: *Runtime, packet: host.Packet) bool {
        self.invalidateEvent();
        self.event_packet = host.encode(self.heap.allocator, packet) catch return false;
        return true;
    }

    pub fn nextEventId(self: *Runtime) u32 {
        const result = self.next_host_request_id;
        self.next_host_request_id +%= 1;
        if (self.next_host_request_id == 0) self.next_host_request_id = 1;
        if (result != 0) return result;
        return self.nextEventId();
    }

    pub fn beginInputRequest(self: *Runtime, destination: u16, prompt: []const u8, line: u32, column: u32) bool {
        if (!self.appendOutput(prompt)) {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        }
        const request_id = self.nextEventId();
        const sections = [_]host.Section{.{ .kind = .utf8, .bytes = prompt }};
        if (!self.createEventPacket(.{ .kind = .input, .request_id = request_id, .sections = &sections })) {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        }
        const frame = self.top_frame orelse return self.engineFault();
        self.pending_input = .{ .frame = frame, .destination = destination, .request_id = request_id, .line = line, .column = column };
        return true;
    }

    pub fn beginOutputEvent(self: *Runtime, line: u32, column: u32) bool {
        const event_id = self.nextEventId();
        if (!self.createEventPacket(.{ .kind = .output, .request_id = event_id })) {
            self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
            return false;
        }
        self.output_event_pending = true;
        return true;
    }

    fn failInitialization(self: *Runtime) void {
        if (self.exception_frame.stack != null) self.exception_frame.pop();
        if (self.builtin_frame.stack != null) self.builtin_frame.pop();
        if (self.environment_frame.stack != null) self.environment_frame.pop();
        self.clearVfsOutput();
        self.vfs.deinit();
        self.heap.deinit();
        self.* = .{};
    }

    pub fn forgetGeneratorFrame(self: *Runtime, frame: *Frame) void {
        _ = self;
        if (frame.generator_owner) |owner| {
            if (owner.generator_frame == @as(*anyopaque, @ptrCast(frame))) {
                owner.generator_frame = null;
                owner.generator_roots = &.{};
                owner.generator_done = true;
            }
        }
    }

    fn clearGlobals(self: *Runtime) void {
        for (self.environment.entries.items) |entry| self.heap.allocator.free(entry.name);
        self.environment.entries.deinit(self.heap.allocator);
        self.environment.entries = .empty;
        self.environment.module_owner = null;
        self.environment.shape_version +%= 1;
    }

    pub fn execute(self: *Runtime, instruction: bytecode.Instruction, code: *Code, line: u32, column: u32) bool {
        const op = instruction.opcodeTag() orelse return self.engineFault();
        switch (op) {
            .load_const => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                const index: usize = @intCast(instruction.index32());
                if (index >= code.constants.len) return self.engineFault();
                self.setRegister(instruction.a(), code.constants[index]);
            },
            .load_none => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                self.setRegister(instruction.a(), Value.noneValue());
            },
            .enter_try => return self.enterTry(instruction.index32(), line, column),
            .with_enter => {
                if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b())) return self.engineFault();
                return self.executeWithEnter(instruction.a(), self.registers[instruction.b()], line, column);
            },
            .with_exit => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                return self.executeWithExit(instruction.a(), self.registers[instruction.a()], line, column);
            },
            .try_else => {
                const frame = self.top_frame orelse return self.engineFault();
                if (frame.try_blocks.items.len == 0) return self.engineFault();
                const block = &frame.try_blocks.items[frame.try_blocks.items.len - 1];
                if (block.site_index != instruction.index32() or block.phase != .body) return self.engineFault();
                block.phase = .else_body;
            },
            .try_complete => {
                const frame = self.top_frame orelse return self.engineFault();
                return self.completeTry(frame, instruction.index32());
            },
            .try_unhandled => {
                const frame = self.top_frame orelse return self.engineFault();
                if (frame.try_blocks.items.len == 0) return self.engineFault();
                const block = &frame.try_blocks.items[frame.try_blocks.items.len - 1];
                if (block.site_index != instruction.index32() or self.last_exception == null) return self.engineFault();
                const site = frame.code.try_sites[block.site_index];
                if (site.finalizer_ip != std.math.maxInt(u32)) {
                    self.savePendingException(frame, block);
                    block.phase = .finally_body;
                    return self.setFrameInstruction(frame, site.finalizer_ip);
                }
                _ = self.popTryBlock(frame, false);
                return false;
            },
            .load_exception => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                const active = self.active_exception orelse {
                    self.setException(exceptions.memoryError(), line, column, null);
                    return false;
                };
                self.setRegister(instruction.a(), Value.object(&active.header));
            },
            .match_exception => {
                if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b())) return self.engineFault();
                const kind = self.activeExceptionKind() orelse return self.engineFault();
                const matched = self.matchesExceptionType(self.registers[instruction.b()], kind, line, column) orelse return false;
                self.setRegister(instruction.a(), if (matched) Value.trueValue() else Value.falseValue());
            },
            .bind_exception => {
                const frame = self.top_frame orelse return self.engineFault();
                if (instruction.index32() >= frame.code.names.len or frame.try_blocks.items.len == 0) return self.engineFault();
                const active = self.active_exception orelse return self.engineFault();
                const name = frame.code.names[instruction.index32()];
                if (!self.storeBoundValue(frame, name, instruction.flags(), Value.object(&active.header), line, column)) return false;
                const block = &frame.try_blocks.items[frame.try_blocks.items.len - 1];
                block.cleanup_name_index = instruction.index32();
                block.cleanup_binding = instruction.flags();
            },
            .accept_exception => {
                const frame = self.top_frame orelse return self.engineFault();
                return self.acceptCurrentException(frame, instruction.index32());
            },
            .raise_value, .raise_current => return self.executeRaise(instruction, line, column),
            .assert_failed => {
                var message: []const u8 = "";
                var owned: ?[]u8 = null;
                if (instruction.flags() & 1 != 0) {
                    if (!self.validRegister(instruction.a())) return self.engineFault();
                    owned = self.renderValueOwned(self.registers[instruction.a()], false, line, column) orelse return false;
                    message = owned.?;
                }
                defer if (owned) |text| self.heap.allocator.free(text);
                self.setException(.{ .kind = .assertion_error, .message = message }, line, column, null);
                return false;
            },
            .end_finally => {
                const frame = self.top_frame orelse return self.engineFault();
                return self.completeFinally(frame, instruction.index32(), line, column);
            },
            .load_global => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                const name_index = instruction.index32();
                const name = self.codeName(name_index) orelse return self.engineFault();
                if (self.cachedGlobalValue(code, name_index)) |value| {
                    self.setRegister(instruction.a(), value);
                } else if (std.mem.eql(u8, name, "object") or std.mem.eql(u8, name, "type")) {
                    if (!self.ensureBuiltinClasses(line, column)) return false;
                    const root = if (std.mem.eql(u8, name, "object")) self.object_class_root.object else self.type_class_root.object;
                    self.setRegister(instruction.a(), Value.object(root orelse return self.engineFault()));
                } else if (Runtime.primitiveBuiltin(name)) |primitive| {
                    const class = self.ensurePrimitiveClass(primitive, line, column) orelse return false;
                    self.setRegister(instruction.a(), Value.object(&class.header));
                } else if (self.builtinValue(name)) |value| {
                    self.setRegister(instruction.a(), value);
                } else if (builtins.builtinNative(name)) |native| {
                    switch (functions.createNative(&self.heap, native)) {
                        .value => |function| self.setRegister(instruction.a(), Value.object(&function.header)),
                        .python_exception => |exception| {
                            self.setException(exception, line, column, null);
                            return false;
                        },
                    }
                } else if (exceptions.builtinKind(name)) |kind| {
                    self.setRegister(instruction.a(), Value.exceptionClass(@intCast(@intFromEnum(kind))));
                } else {
                    self.setException(.{ .kind = .name_error, .message = "name is not defined" }, line, column, name);
                    return false;
                }
            },
            .store_global => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                if (!self.storeCachedGlobal(code, instruction.index32(), self.registers[instruction.a()])) {
                    self.setException(.{ .kind = .memory_error, .message = "session memory limit exceeded" }, line, column, null);
                    return false;
                }
            },
            .store_annotation => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                const name = self.codeName(instruction.index32()) orelse return self.engineFault();
                return self.storeAnnotation(name, self.registers[instruction.a()], instruction.flags() != 0, line, column);
            },
            .import_module => return self.executeImportModule(instruction.a(), instruction.index32(), line, column),
            .import_member => return self.executeImportMember(instruction, line, column),
            .import_star => return self.executeImportStar(instruction.a(), instruction.b(), line, column),
            .load_local => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                if (!self.loadLocal(instruction.a(), instruction.index32(), instruction.flags(), line, column)) return false;
            },
            .store_local => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                if (!self.storeLocal(instruction.a(), instruction.index32(), instruction.flags(), line, column)) return false;
            },
            .move => {
                if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b())) return self.engineFault();
                self.setRegister(instruction.a(), self.registers[instruction.b()]);
            },
            .unary => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                const input = self.registers[instruction.a()];
                if (input.asObject()) |header| if (native_types.fromHeader(header)) |object| if (object.ops) |ops| if (ops.unary) |unary| {
                    if (unary(self, object, @intCast(instruction.flags()), line, column)) |value| {
                        self.setRegister(instruction.a(), value);
                        return true;
                    }
                    if (self.last_exception != null) return false;
                };
                if (instruction.flags() == 3) {
                    const truth = self.valueTruthy(input, line, column) orelse return false;
                    self.setRegister(instruction.a(), if (truth) Value.falseValue() else Value.trueValue());
                    return true;
                }
                const result = switch (@as(u8, instruction.flags())) {
                    0 => number.positive(&self.heap, input),
                    1 => number.negative(&self.heap, input),
                    2 => number.bitNot(&self.heap, input),
                    else => return self.engineFault(),
                };
                if (!self.storeNumberResult(instruction.a(), result, line, column)) return false;
            },
            .binary => {
                if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b())) return self.engineFault();
                const left = self.registers[instruction.a()];
                const right = self.registers[instruction.b()];
                if (!self.executeBinary(instruction.a(), left, right, instruction.flags(), line, column)) return false;
            },
            .print => {
                if (self.globalValue("print") != null) {
                    self.setException(.{ .kind = .type_error, .message = "'int' object is not callable" }, line, column, null);
                    return false;
                }
                const start: usize = @intCast(instruction.index32());
                const count: usize = instruction.a();
                if (start > code.argument_registers.len or count > code.argument_registers.len - start) return self.engineFault();
                for (code.argument_registers[start..][0..count]) |register| if (!self.validRegister(register)) return self.engineFault();
                if (!self.executePrint(code.argument_registers[start..][0..count], line, column)) return false;
            },
            .return_value => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                const result = self.registers[instruction.a()];
                const frame = self.top_frame orelse return self.engineFault();
                return self.beginReturnTransfer(frame, result, line, column);
            },
            .call => {
                if (!self.validRegister(instruction.a()) or !self.executeCall(instruction, line, column)) return false;
            },
            .make_function => {
                if (!self.validRegister(instruction.a()) or !self.executeMakeFunction(instruction, line, column)) return false;
            },
            .make_class => {
                if (!self.validRegister(instruction.a()) or !self.executeMakeClass(instruction, line, column)) return false;
            },
            .make_sequence => return self.executeMakeSequence(instruction, line, column),
            .list_append_value => {
                if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b())) return self.engineFault();
                const header = self.registers[instruction.a()].asObject() orelse return self.engineFault();
                const list = sequence.listFromHeader(header) orelse return self.engineFault();
                return switch (sequence.append(&self.heap, list, self.registers[instruction.b()])) {
                    .value => true,
                    .python_exception => |exception| blk: {
                        self.setException(exception, line, column, null);
                        break :blk false;
                    },
                    .engine_error => self.engineFault(),
                };
            },
            .format_value => {
                if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b())) return self.engineFault();
                const site: usize = instruction.c();
                if (site >= code.format_sites.len) return self.engineFault();
                return self.executeFormatValue(instruction.a(), self.registers[instruction.b()], code.format_sites[site].spec, instruction.flags(), line, column);
            },
            .make_generator => {
                if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b()) or !self.validRegister(instruction.c())) return self.engineFault();
                const created = iterator.createGenerator(&self.heap, self.registers[instruction.b()], self.registers[instruction.c()]);
                return self.storeIteratorOutcome(instruction.a(), created, line, column);
            },
            .yield_value => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                const selected = self.resuming_generator orelse return self.engineFault();
                const frame = self.top_frame orelse return self.engineFault();
                if (frame.generator_owner != selected) return self.engineFault();
                selected.generator_yielded = self.registers[instruction.a()];
                selected.generator_yield_register = instruction.a();
                if (frame.root_frame.stack != null) frame.root_frame.pop();
                self.top_frame = frame.previous;
                frame.previous = null;
                if (self.top_frame) |caller| self.activateFrame(caller) else return self.engineFault();
            },
            .make_mapping => return self.executeMakeMapping(instruction, line, column),
            .mapping_set => return self.executeMappingSet(instruction, line, column),
            .mapping_update => return self.executeMappingUpdate(instruction, line, column),
            .materialize_dstar => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                return self.executeMaterializeDstar(instruction.a(), instruction.index32(), line, column);
            },
            .make_slice => return self.executeMakeSlice(instruction, line, column),
            .get_attribute => return self.executeGetAttribute(instruction, line, column),
            .set_attribute => return self.executeSetAttribute(instruction, line, column),
            .delete_attribute => return self.executeDeleteAttribute(instruction, line, column),
            .get_item => return self.executeGetItem(instruction, line, column),
            .set_item => return self.executeSetItem(instruction, line, column),
            .delete_item => return self.executeDeleteItem(instruction, line, column),
            .delete_local => {
                const name = self.codeName(instruction.index32()) orelse return self.engineFault();
                return self.executeDeleteLocal(name, instruction.flags(), line, column);
            },
            .delete_global => {
                const name = self.codeName(instruction.index32()) orelse return self.engineFault();
                return self.executeDeleteGlobal(name, line, column);
            },
            .unpack => return self.executeUnpack(instruction, line, column),
            .materialize_star => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                return self.executeMaterializeStar(instruction.a(), line, column);
            },
            .jump => {
                if (!self.validJump(instruction.index32())) return self.engineFault();
                self.instruction_pointer = instruction.index32();
            },
            .unwind_jump => {
                const frame = self.top_frame orelse return self.engineFault();
                return self.beginJumpTransfer(frame, instruction.index32());
            },
            .jump_if_false, .jump_if_true => {
                if (!self.validRegister(instruction.a()) or !self.validJump(instruction.index32())) return self.engineFault();
                const truth = self.valueTruthy(self.registers[instruction.a()], line, column) orelse return false;
                if ((op == .jump_if_false and !truth) or (op == .jump_if_true and truth)) self.instruction_pointer = instruction.index32();
            },
            .truth => {
                if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b())) return self.engineFault();
                const truth = self.valueTruthy(self.registers[instruction.b()], line, column) orelse return false;
                self.setRegister(instruction.a(), if (truth) Value.trueValue() else Value.falseValue());
            },
            .compare => {
                if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b()) or !self.validRegister(instruction.c())) return self.engineFault();
                const result = self.compareValues(self.registers[instruction.b()], self.registers[instruction.c()], instruction.flags(), line, column) orelse return false;
                self.setRegister(instruction.a(), if (result) Value.trueValue() else Value.falseValue());
            },
            .make_range => {
                if (!self.validRegister(instruction.a())) return self.engineFault();
                const start: usize = @intCast(instruction.index32());
                const count: usize = instruction.flags();
                if (start > code.argument_registers.len or count > code.argument_registers.len - start) return self.engineFault();
                for (code.argument_registers[start..][0..count]) |register| if (!self.validRegister(register)) return self.engineFault();
                if (self.globalValue("range") != null) {
                    self.setException(.{ .kind = .type_error, .message = "'int' object is not callable" }, line, column, null);
                    return false;
                }
                if (count == 0 or count > 3) {
                    self.setException(.{ .kind = .type_error, .message = "range expected 1 to 3 arguments" }, line, column, null);
                    return false;
                }
                var args: [3]Value = undefined;
                for (code.argument_registers[start..][0..count], 0..) |register, index| args[index] = self.registers[register];
                switch (iterator.createRange(&self.heap, args[0..count])) {
                    .value => |range| self.setRegister(instruction.a(), Value.object(&range.header)),
                    .python_exception => |exception| {
                        self.setException(exception, line, column, null);
                        return false;
                    },
                    .engine_error => return self.engineFault(),
                }
            },
            .get_iterator => {
                if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b())) return self.engineFault();
                return self.storeIteratorOutcome(instruction.a(), self.createVmIterator(self.registers[instruction.b()], line, column), line, column);
            },
            .for_next => {
                if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b()) or !self.validRegister(instruction.c())) return self.engineFault();
                const header = self.registers[instruction.b()].asObject() orelse return self.engineFault();
                const loop_iterator = iterator.iteratorFromHeader(header) orelse return self.engineFault();
                const previous_task = self.currentNativeTask();
                switch (self.nextIteratorValue(loop_iterator, instruction.a(), line, column)) {
                    .item => |item| {
                        self.setRegister(instruction.a(), item);
                        self.setRegister(instruction.c(), Value.trueValue());
                    },
                    .done => self.setRegister(instruction.c(), Value.falseValue()),
                    .suspended => {
                        const task = self.currentNativeTask() orelse return self.engineFault();
                        const caller = self.top_frame orelse return self.engineFault();
                        if (task == previous_task or task.caller_frame != @as(*anyopaque, @ptrCast(caller)) or task.destination != instruction.a()) return self.engineFault();
                        task.item_presence_destination = instruction.c();
                    },
                    .python_exception => |exception| {
                        self.setException(exception, line, column, null);
                        return false;
                    },
                    .engine_error => return self.engineFault(),
                }
            },
        }
        return true;
    }

    pub fn setRegister(self: *Runtime, index: u16, value: Value) void {
        const position: usize = index;
        if (position >= self.registers.len) unreachable;
        self.registers[position] = value;
        self.register_roots[position].object = value.asObject();
    }

    pub fn validRegister(self: *const Runtime, index: u16) bool {
        return @as(usize, index) < self.registers.len;
    }

    fn validJump(self: *const Runtime, target: u32) bool {
        const code = self.activeCode() orelse return false;
        return @as(usize, target) <= code.instructions.len;
    }

    pub fn codeName(self: *const Runtime, index: u32) ?[]const u8 {
        const code = self.activeCode() orelse return null;
        const position: usize = @intCast(index);
        if (position >= code.names.len) return null;
        return code.names[position];
    }

    pub fn setFrameEnvironment(frame: *Frame, environment: *gc.Header) void {
        frame.environment = environment;
        frame.roots[frame.environmentRootIndex()].object = environment;
    }

    pub fn builtinValue(self: *const Runtime, name: []const u8) ?Value {
        if (std.mem.eql(u8, name, "print")) return if (self.print_builtin_root.object) |header| Value.object(header) else null;
        if (std.mem.eql(u8, name, "input")) return if (self.input_builtin_root.object) |header| Value.object(header) else null;
        if (std.mem.eql(u8, name, "range")) return if (self.range_builtin_root.object) |header| Value.object(header) else null;
        if (std.mem.eql(u8, name, "object")) return if (self.object_class_root.object) |header| Value.object(header) else null;
        if (std.mem.eql(u8, name, "type")) return if (self.type_class_root.object) |header| Value.object(header) else null;
        if (std.mem.eql(u8, name, "NotImplemented")) return Value.exceptionClass(std.math.maxInt(u8));
        return null;
    }

    pub fn ensureBuiltinClasses(self: *Runtime, line: u32, column: u32) bool {
        if (self.object_class_root.object == null) {
            switch (class_module.createRootClass(&self.heap)) {
                .value => |object_class| self.object_class_root.object = &object_class.header,
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            }
        }
        if (self.type_class_root.object == null) {
            const object_header = self.object_class_root.object orelse return self.engineFault();
            const object_class = class_module.classFromHeader(object_header) orelse return self.engineFault();
            switch (class_module.createClass(&self.heap, "type", &.{object_class}, object_class)) {
                .value => |type_class| self.type_class_root.object = &type_class.header,
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            }
        }
        return true;
    }

    pub fn typeClass(self: *const Runtime) ?*class_module.Class {
        const header = self.type_class_root.object orelse return null;
        return class_module.classFromHeader(header);
    }

    pub fn ensureNativeClass(self: *Runtime, type_id: native_types.TypeId, name: []const u8, line: u32, column: u32) ?*class_module.Class {
        return self.ensureNativeClassWithBase(type_id, name, null, line, column);
    }

    /// Shared per-run JSON exception identity for `json.loads` and HTTP Response.json.
    pub fn ensureJsonDecodeErrorClass(self: *Runtime, line: u32, column: u32) ?*exceptions.ExceptionClass {
        if (self.json_decode_error_root.object) |header| return exceptions.classFromHeader(header);
        const created = exceptions.createNativeClass(&self.heap, "JSONDecodeError", .value_error, null);
        return switch (created) {
            .value => |class| blk: {
                self.json_decode_error_root.object = &class.header;
                break :blk class;
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk null;
            },
            .engine_error => blk: {
                _ = self.engineFault();
                break :blk null;
            },
        };
    }

    pub fn ensureNativeClassWithBase(self: *Runtime, type_id: native_types.TypeId, name: []const u8, base_primitive: ?class_module.PrimitiveType, line: u32, column: u32) ?*class_module.Class {
        const index = @intFromEnum(type_id);
        if (self.native_class_roots[index].object) |header| return class_module.classFromHeader(header);
        if (!self.ensureBuiltinClasses(line, column)) return null;
        const object_header = self.object_class_root.object orelse return null;
        const object_class = class_module.classFromHeader(object_header) orelse return null;
        const base = if (base_primitive) |primitive| self.ensurePrimitiveClass(primitive, line, column) orelse return null else object_class;
        return switch (class_module.createClass(&self.heap, name, &.{base}, object_class)) {
            .value => |class| blk: {
                class.native_type_id = @intFromEnum(type_id) + 1;
                self.native_class_roots[index].object = &class.header;
                break :blk class;
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk null;
            },
            .engine_error => blk: {
                _ = self.engineFault();
                break :blk null;
            },
        };
    }

    pub fn ensurePrimitiveClass(self: *Runtime, primitive: class_module.PrimitiveType, line: u32, column: u32) ?*class_module.Class {
        const index = @intFromEnum(primitive);
        if (self.primitive_class_roots[index].object) |header| return class_module.classFromHeader(header);
        if (!self.ensureBuiltinClasses(line, column)) return null;
        const object_header = self.object_class_root.object orelse return null;
        const object_class = class_module.classFromHeader(object_header) orelse return null;
        const base = if (primitive == .bool_type)
            self.ensurePrimitiveClass(.int_type, line, column) orelse return null
        else
            object_class;
        const name: []const u8 = switch (primitive) {
            .none_type => "NoneType",
            .bool_type => "bool",
            .int_type => "int",
            .float_type => "float",
            .str_type => "str",
            .bytes_type => "bytes",
            .list_type => "list",
            .tuple_type => "tuple",
            .dict_type => "dict",
            .set_type => "set",
            .range_type => "range",
            .slice_type => "slice",
            .function_type => "function",
            .module_type => "module",
            .file_type => "TextIO",
            .iterator_type => "iterator",
        };
        return switch (class_module.createClass(&self.heap, name, &.{base}, object_class)) {
            .value => |class| blk: {
                class.primitive = primitive;
                self.primitive_class_roots[index].object = &class.header;
                break :blk class;
            },
            .python_exception => |exception| blk: {
                self.setException(exception, line, column, null);
                break :blk null;
            },
            .engine_error => blk: {
                _ = self.engineFault();
                break :blk null;
            },
        };
    }

    pub fn primitiveBuiltin(name: []const u8) ?class_module.PrimitiveType {
        const map = .{
            .{ "bool", class_module.PrimitiveType.bool_type },
            .{ "int", class_module.PrimitiveType.int_type },
            .{ "float", class_module.PrimitiveType.float_type },
            .{ "str", class_module.PrimitiveType.str_type },
            .{ "bytes", class_module.PrimitiveType.bytes_type },
            .{ "list", class_module.PrimitiveType.list_type },
            .{ "tuple", class_module.PrimitiveType.tuple_type },
            .{ "dict", class_module.PrimitiveType.dict_type },
            .{ "set", class_module.PrimitiveType.set_type },
            .{ "range", class_module.PrimitiveType.range_type },
            .{ "slice", class_module.PrimitiveType.slice_type },
        };
        inline for (map) |entry| if (std.mem.eql(u8, name, entry[0])) return entry[1];
        return null;
    }

    pub fn pythonTypeOf(self: *Runtime, value: Value, line: u32, column: u32) ?Value {
        const primitive: class_module.PrimitiveType = switch (value.tag()) {
            .none => .none_type,
            .boolean => .bool_type,
            .small_int => .int_type,
            .float => .float_type,
            .exception_class => return if (self.typeClass()) |class| Value.object(&class.header) else null,
            .heap_object => blk: {
                const header = value.asObject().?;
                if (class_module.instanceFromHeader(header)) |instance| return Value.object(&instance.class.header);
                if (native_types.fromHeader(header)) |object| return Value.object(&object.class.header);
                if (exceptions.instanceFromHeader(header)) |instance| {
                    if (instance.native_class) |class| return Value.object(&class.header);
                    return Value.exceptionClass(@intCast(@intFromEnum(instance.kind)));
                }
                if (exceptions.classFromHeader(header) != null) return if (self.typeClass()) |class| Value.object(&class.header) else null;
                if (class_module.classFromHeader(header) != null) return if (self.typeClass()) |class| Value.object(&class.header) else null;
                if (number.isIntegerValue(value)) break :blk .int_type;
                if (string.fromHeader(header) != null) break :blk .str_type;
                if (byte_module.fromHeader(header) != null) break :blk .bytes_type;
                if (sequence.listFromHeader(header) != null) break :blk .list_type;
                if (sequence.tupleFromHeader(header) != null) break :blk .tuple_type;
                if (dict_module.dictFromHeader(header)) |mapping| break :blk if (mapping.is_set) .set_type else .dict_type;
                if (iterator.rangeFromHeader(header) != null) break :blk .range_type;
                if (slice_module.fromHeader(header) != null) break :blk .slice_type;
                if (functions.functionFromHeader(header) != null) break :blk .function_type;
                if (module_module.fromHeader(header) != null) break :blk .module_type;
                if (file_module.fromHeader(header) != null) break :blk .file_type;
                if (iterator.iteratorFromHeader(header) != null) break :blk .iterator_type;
                break :blk .none_type;
            },
            .unbound, .deleted => return null,
        };
        const class = self.ensurePrimitiveClass(primitive, line, column) orelse return null;
        return Value.object(&class.header);
    }

    pub fn activeCode(self: *const Runtime) ?*Code {
        const frame = self.top_frame orelse return null;
        return frame.code;
    }

    fn setStaticError(self: *Runtime, text: []const u8) void {
        self.last_exception = null;
        self.clearErrorText();
        self.error_text_static = text;
    }

    pub fn clearErrorText(self: *Runtime) void {
        if (self.error_text_owned) |owned| self.heap.allocator.free(owned);
        self.error_text_owned = null;
        self.error_text_static = "";
    }

    pub fn engineFault(self: *Runtime) bool {
        self.engine_failed = true;
        return false;
    }
};

pub fn indexOfName(names: []const []const u8, name: []const u8) ?usize {
    for (names, 0..) |candidate, index| if (std.mem.eql(u8, candidate, name)) return index;
    return null;
}

fn trimInputEnding(input: []const u8) []const u8 {
    if (std.mem.endsWith(u8, input, "\r\n")) return input[0 .. input.len - 2];
    if (std.mem.endsWith(u8, input, "\n") or std.mem.endsWith(u8, input, "\r")) return input[0 .. input.len - 1];
    return input;
}
