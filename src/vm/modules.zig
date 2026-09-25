const std = @import("std");
const builtin = @import("builtin");
const bytecode = @import("frontend_bytecode");
const compiler = @import("frontend_compiler");
const gc = @import("runtime_gc");
const value_module = @import("runtime_value");
const string = @import("runtime_string");
const sequence = @import("runtime_sequence");
const dict_module = @import("runtime_dict");
const exceptions = @import("runtime_exception");
const class_module = @import("runtime_class");
const module_module = @import("runtime_module");
const functions_module = @import("runtime_function");
const native_registry = @import("../stdlib/registry.zig");
const native_sys = @import("../stdlib/sys.zig");

const Runtime = @import("runtime.zig").Runtime;
const state = @import("state.zig");
const GlobalEntry = state.GlobalEntry;
const TryPhase = state.TryPhase;
const PendingTransfer = state.PendingTransfer;
const TryBlock = state.TryBlock;
const Environment = state.Environment;
const TestContextManager = state.TestContextManager;
const Frame = state.Frame;
const PendingInput = state.PendingInput;
const SyncTaskOperation = state.SyncTaskOperation;
const SyncTaskPhase = state.SyncTaskPhase;
const SyncCallbackResult = state.SyncCallbackResult;
const SyncTask = state.SyncTask;
const environment_kind = state.environment_kind;
const Value = value_module.Value;
const Code = bytecode.Code;
const PythonException = exceptions.PythonException;
const PythonExceptionKind = exceptions.PythonExceptionKind;
const ResolvedModule = Runtime.ResolvedModule;
const setFrameEnvironment = @import("runtime.zig").Runtime.setFrameEnvironment;
const sourceLine = @import("control.zig").sourceLine;
const indexOfName = @import("runtime.zig").indexOfName;
const frameNameValue = @import("calls.zig").frameNameValue;
const compareOrder = @import("operations.zig").compareOrder;
const compareNumericOrder = @import("operations.zig").compareNumericOrder;
const isAlign = @import("text.zig").isAlign;
const builtinNative = @import("builtins.zig").builtinNative;
const attributeNative = @import("objects.zig").attributeNative;
const exceptionName = @import("control.zig").exceptionName;
const appendExceptionText = @import("control.zig").appendExceptionText;
const dictKeysEqual = @import("operations.zig").dictKeysEqual;
const DictEqualityContext = @import("operations.zig").DictEqualityContext;
const mroContains = @import("objects.zig").mroContains;
const truncateUtf8 = @import("text.zig").truncateUtf8;
const trimInputEnding = @import("runtime.zig").trimInputEnding;
const trimFloatZeros = @import("text.zig").trimFloatZeros;
const roundDecimalTieEven = @import("text.zig").roundDecimalTieEven;

pub fn attachImportedChild(self: *Runtime, selected: *module_module.Module, line: u32, column: u32) bool {
    const separator = std.mem.lastIndexOfScalar(u8, selected.name, '.') orelse return true;
    const parent_name = selected.name[0..separator];
    const child_name = selected.name[separator + 1 ..];
    const parent = self.findCachedModule(parent_name) orelse return true;
    if (!self.environmentStore(parent.environment, child_name, Value.object(&selected.header))) {
        self.setException(exceptions.memoryError(), line, column, null);
        return false;
    }
    return true;
}

pub fn storeAnnotation(self: *Runtime, name: []const u8, annotation: Value, class_scope: bool, line: u32, column: u32) bool {
    const class = if (class_scope) (self.top_frame orelse return self.engineFault()).class_namespace else null;
    if (class_scope and class == null) return self.engineFault();
    var mapping: *dict_module.Dict = undefined;
    if (class) |selected_class| {
        if (class_module.ownClassAttribute(selected_class, "__annotations__")) |existing| {
            const header = existing.asObject() orelse return self.nativeTypeError(line, column, "'__annotations__' must be a dict");
            mapping = dict_module.dictFromHeader(header) orelse return self.nativeTypeError(line, column, "'__annotations__' must be a dict");
        } else {
            mapping = switch (dict_module.create(&self.heap, false)) {
                .value => |created| created,
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            };
            var roots = [_]gc.Root{ .{ .object = &selected_class.header }, .{ .object = &mapping.header } };
            var root_frame = gc.RootFrame{};
            root_frame.push(&self.heap.roots);
            for (&roots) |*root| root_frame.add(root);
            defer root_frame.pop();
            class_module.setClassAttribute(&self.heap, selected_class, "__annotations__", Value.object(&mapping.header)) catch {
                self.setException(exceptions.memoryError(), line, column, null);
                return false;
            };
            return self.storeAnnotationEntry(mapping, name, annotation, line, column);
        }
    } else if (self.globalValue("__annotations__")) |existing| {
        const header = existing.asObject() orelse return self.nativeTypeError(line, column, "'__annotations__' must be a dict");
        mapping = dict_module.dictFromHeader(header) orelse return self.nativeTypeError(line, column, "'__annotations__' must be a dict");
    } else {
        mapping = switch (dict_module.create(&self.heap, false)) {
            .value => |created| created,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        var roots = [_]gc.Root{ .{ .object = &mapping.header }, .{ .object = annotation.asObject() } };
        var root_frame = gc.RootFrame{};
        root_frame.push(&self.heap.roots);
        for (&roots) |*root| root_frame.add(root);
        defer root_frame.pop();
        if (!self.storeGlobal("__annotations__", Value.object(&mapping.header))) {
            self.setException(exceptions.memoryError(), line, column, null);
            return false;
        }
        return self.storeAnnotationEntry(mapping, name, annotation, line, column);
    }
    return self.storeAnnotationEntry(mapping, name, annotation, line, column);
}

pub fn storeAnnotationEntry(self: *Runtime, mapping: *dict_module.Dict, name: []const u8, annotation: Value, line: u32, column: u32) bool {
    var roots = [_]gc.Root{ .{ .object = &mapping.header }, .{ .object = annotation.asObject() }, .{ .object = null } };
    var root_frame = gc.RootFrame{};
    root_frame.push(&self.heap.roots);
    for (&roots) |*root| root_frame.add(root);
    defer root_frame.pop();
    const key = switch (string.create(&self.heap, name)) {
        .value => |value| value,
        .python_exception => |exception| {
            self.setException(exception, line, column, null);
            return false;
        },
        .engine_error => return self.engineFault(),
    };
    roots[2].object = &key.header;
    return self.setMappingValue(mapping, Value.object(&key.header), annotation, line, column);
}

pub fn executeDeleteGlobal(self: *Runtime, name: []const u8, line: u32, column: u32) bool {
    for (self.environment.entries.items, 0..) |entry, index| {
        if (!std.mem.eql(u8, entry.name, name)) continue;
        self.heap.allocator.free(entry.name);
        _ = self.environment.entries.orderedRemove(index);
        return true;
    }
    self.setException(.{ .kind = .name_error, .message = "name is not defined" }, line, column, name);
    return false;
}

pub fn globalValue(self: *const Runtime, name: []const u8) ?Value {
    const environment = self.currentEnvironmentObject();
    for (environment.entries.items) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.value;
    return null;
}

pub fn currentEnvironment(self: *const Runtime) *gc.Header {
    if (self.top_frame) |frame| return frame.environment;
    return &self.environment.header;
}

pub fn currentEnvironmentObject(self: *const Runtime) *Environment {
    return @ptrCast(@alignCast(self.currentEnvironment()));
}

pub fn environmentLookup(environment_header: *gc.Header, name: []const u8) ?Value {
    const environment: *Environment = @ptrCast(@alignCast(environment_header));
    for (environment.entries.items) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.value;
    return null;
}

pub fn environmentStore(self: *Runtime, environment_header: *gc.Header, name: []const u8, value: Value) bool {
    var roots = [_]gc.Root{ .{ .object = environment_header }, .{ .object = value.asObject() } };
    var root_frame = gc.RootFrame{};
    root_frame.push(&self.heap.roots);
    for (&roots) |*root| root_frame.add(root);
    defer root_frame.pop();
    const environment: *Environment = @ptrCast(@alignCast(environment_header));
    for (environment.entries.items) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            entry.value = value;
            return true;
        }
    }
    const owned_name = self.heap.allocator.dupe(u8, name) catch return false;
    environment.entries.append(self.heap.allocator, .{ .name = owned_name, .value = value }) catch {
        self.heap.allocator.free(owned_name);
        return false;
    };
    return true;
}

pub fn createEnvironment(self: *Runtime, line: u32, column: u32) ?*Environment {
    const environment = self.heap.createObject(Environment, &environment_kind) catch {
        self.setException(exceptions.memoryError(), line, column, null);
        return null;
    };
    environment.entries = .empty;
    environment.module_owner = null;
    return environment;
}

pub fn createStringValue(self: *Runtime, text: []const u8, line: u32, column: u32) ?Value {
    return switch (string.create(&self.heap, text)) {
        .value => |created| Value.object(&created.header),
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

pub fn moduleCache(self: *const Runtime) ?*dict_module.Dict {
    const header = self.module_cache_root.object orelse return null;
    return dict_module.dictFromHeader(header);
}

pub fn countCodeRoots(code: *bytecode.Code) ?usize {
    var total = code.root_slots.len;
    for (code.nested_codes) |nested| {
        total = std.math.add(usize, total, countCodeRoots(nested) orelse return null) catch return null;
    }
    return total;
}

pub fn copyCodeRoots(code: *bytecode.Code, destination: []?*gc.Header, cursor: *usize) void {
    for (code.root_slots) |root| {
        destination[cursor.*] = root.object;
        cursor.* += 1;
    }
    for (code.nested_codes) |nested| copyCodeRoots(nested, destination, cursor);
}

pub fn detachRootsTo(self: *Runtime, boundary: ?*gc.RootFrame) bool {
    while (self.heap.roots.top_frame != boundary) {
        const frame = self.heap.roots.top_frame orelse return false;
        frame.pop();
    }
    return true;
}

pub fn findCachedModule(self: *const Runtime, name: []const u8) ?*module_module.Module {
    const mapping = self.moduleCache() orelse return null;
    for (mapping.entries.items) |entry| {
        if (!entry.alive) continue;
        const key_header = entry.key.asObject() orelse continue;
        const key = string.fromHeader(key_header) orelse continue;
        if (!std.mem.eql(u8, string.content(key), name)) continue;
        const module_header = entry.value.asObject() orelse return null;
        return module_module.fromHeader(module_header);
    }
    return null;
}

pub fn cacheModule(self: *Runtime, selected: *module_module.Module, line: u32, column: u32) bool {
    const mapping = self.moduleCache() orelse return self.engineFault();
    var roots = [_]gc.Root{ .{ .object = &mapping.header }, .{ .object = &selected.header }, .{ .object = null } };
    var root_frame = gc.RootFrame{};
    root_frame.push(&self.heap.roots);
    for (&roots) |*root| root_frame.add(root);
    defer root_frame.pop();
    const key = self.createStringValue(selected.name, line, column) orelse return false;
    roots[2].object = key.asObject();
    return self.setMappingValue(mapping, key, Value.object(&selected.header), line, column);
}

pub fn removeCachedModule(self: *Runtime, selected: *module_module.Module) void {
    const mapping = self.moduleCache() orelse return;
    for (mapping.entries.items) |entry| {
        if (!entry.alive or entry.value.asObject() != &selected.header) continue;
        var context = DictEqualityContext{ .runtime = self, .line = 1, .column = 1 };
        _ = dict_module.delete(mapping, entry.key, entry.hash, &context, dictKeysEqual);
        return;
    }
}

pub fn initializeModuleWorld(self: *Runtime, line: u32, column: u32) bool {
    if (self.moduleCache() != null) return true;
    const created_cache = dict_module.create(&self.heap, false);
    const cache = switch (created_cache) {
        .value => |mapping| mapping,
        .python_exception => |exception| {
            self.setException(exception, line, column, null);
            return false;
        },
        .engine_error => return self.engineFault(),
    };
    self.module_cache_root.object = &cache.header;

    const sys_environment = self.createEnvironment(line, column) orelse return false;
    var sys_env_root = gc.Root{ .object = &sys_environment.header };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&sys_env_root);
    defer roots.pop();
    const sys_created = module_module.create(&self.heap, "sys", "", "<built-in>", "", &sys_environment.header, false);
    const sys = switch (sys_created) {
        .value => |module| module,
        .python_exception => |exception| {
            self.setException(exception, line, column, null);
            return false;
        },
    };
    sys_environment.module_owner = &sys.header;
    var sys_root = gc.Root{ .object = &sys.header };
    roots.add(&sys_root);
    if (!self.cacheModule(sys, line, column)) return false;
    const filename = if (self.code) |code| code.filename else "<string>";
    const main_created = module_module.create(&self.heap, "__main__", "", filename, "", &self.environment.header, false);
    const main_module = switch (main_created) {
        .value => |module| module,
        .python_exception => |exception| {
            self.setException(exception, line, column, null);
            return false;
        },
    };
    self.environment.module_owner = &main_module.header;
    var main_root = gc.Root{ .object = &main_module.header };
    roots.add(&main_root);
    if (!self.cacheModule(main_module, line, column)) return false;
    var main_name_root = gc.Root{ .object = null };
    var main_file_root = gc.Root{ .object = null };
    var main_package_root = gc.Root{ .object = null };
    roots.add(&main_name_root);
    roots.add(&main_file_root);
    roots.add(&main_package_root);
    const main_name = self.createStringValue("__main__", line, column) orelse return false;
    main_name_root.object = main_name.asObject();
    const main_file = self.createStringValue(filename, line, column) orelse return false;
    main_file_root.object = main_file.asObject();
    const empty_package = self.createStringValue("", line, column) orelse return false;
    main_package_root.object = empty_package.asObject();
    if (!self.environmentStore(&self.environment.header, "__name__", main_name) or
        !self.environmentStore(&self.environment.header, "__package__", empty_package) or
        !self.environmentStore(&self.environment.header, "__file__", main_file))
    {
        self.setException(exceptions.memoryError(), line, column, null);
        return false;
    }
    return true;
}

pub fn moduleForEnvironment(self: *const Runtime, environment: *gc.Header) ?*module_module.Module {
    const mapping = self.moduleCache() orelse return null;
    for (mapping.entries.items) |entry| {
        if (!entry.alive) continue;
        const header = entry.value.asObject() orelse continue;
        const selected = module_module.fromHeader(header) orelse continue;
        if (selected.environment == environment) return selected;
    }
    return null;
}

pub fn resolveImportName(self: *Runtime, raw_name: []const u8, relative_level: u8, line: u32, column: u32) ?[]u8 {
    if (relative_level == 0) return self.heap.allocator.dupe(u8, raw_name) catch {
        self.setException(exceptions.memoryError(), line, column, null);
        return null;
    };
    const importing_module = self.moduleForEnvironment(self.currentEnvironment()) orelse {
        self.setException(.{ .kind = .import_error, .message = "attempted relative import with no known parent package" }, line, column, null);
        return null;
    };
    if (importing_module.package.len == 0) {
        self.setException(.{ .kind = .import_error, .message = "attempted relative import with no known parent package" }, line, column, null);
        return null;
    }
    var package_end = importing_module.package.len;
    var level: u8 = 1;
    while (level < relative_level) : (level += 1) {
        if (std.mem.lastIndexOfScalar(u8, importing_module.package[0..package_end], '.')) |separator| {
            package_end = separator;
        } else {
            self.setException(.{ .kind = .import_error, .message = "attempted relative import beyond top-level package" }, line, column, null);
            return null;
        }
    }
    const base = importing_module.package[0..package_end];
    const separator: usize = @intFromBool(base.len != 0 and raw_name.len != 0);
    const total = std.math.add(usize, base.len + separator, raw_name.len) catch {
        self.setException(exceptions.memoryError(), line, column, null);
        return null;
    };
    const result = self.heap.allocator.alloc(u8, total) catch {
        self.setException(exceptions.memoryError(), line, column, null);
        return null;
    };
    @memcpy(result[0..base.len], base);
    if (separator != 0) result[base.len] = '.';
    @memcpy(result[base.len + separator ..], raw_name);
    return result;
}

pub fn resolveModuleFile(self: *Runtime, name: []const u8) std.mem.Allocator.Error!?ResolvedModule {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |separator| {
        if (self.findCachedModule(name[0..separator])) |parent| {
            if (!parent.is_package) return null;
            return self.resolveModuleFileUnder(parent.search_path, name[separator + 1 ..]);
        }
    }
    const roots = [_][]const u8{"/home", "/course", "/tmp"};
    for (roots) |root| {
        if (try self.resolveModuleFileUnder(root, name)) |resolved| return resolved;
    }
    return null;
}

pub fn resolveModuleFileUnder(self: *Runtime, root: []const u8, name: []const u8) std.mem.Allocator.Error!?ResolvedModule {
    var base = std.ArrayList(u8).empty;
    defer base.deinit(self.heap.allocator);
    try base.appendSlice(self.heap.allocator, root);
    if (root.len == 0 or root[root.len - 1] != '/') try base.append(self.heap.allocator, '/');
    for (name) |character| try base.append(self.heap.allocator, if (character == '.') '/' else character);

    var package_path = std.ArrayList(u8).empty;
    defer package_path.deinit(self.heap.allocator);
    try package_path.appendSlice(self.heap.allocator, base.items);
    try package_path.appendSlice(self.heap.allocator, "/__init__.py");
    if (self.vfs.existsNormalized(package_path.items)) return .{ .filename = try self.heap.allocator.dupe(u8, package_path.items), .is_package = true };

    var module_path = std.ArrayList(u8).empty;
    defer module_path.deinit(self.heap.allocator);
    try module_path.appendSlice(self.heap.allocator, base.items);
    try module_path.appendSlice(self.heap.allocator, ".py");
    if (self.vfs.existsNormalized(module_path.items)) return .{ .filename = try self.heap.allocator.dupe(u8, module_path.items), .is_package = false };
    return null;
}

pub fn executeImportModule(self: *Runtime, destination: u16, site_index: u32, line: u32, column: u32) bool {
    const code = self.activeCode() orelse return self.engineFault();
    if (!self.validRegister(destination) or site_index >= code.import_sites.len) return self.engineFault();
    const site = code.import_sites[site_index];
    if (site.kind != .module) return self.engineFault();
    if (!self.initializeModuleWorld(line, column)) return false;
    const name = self.resolveImportName(site.module_name, site.relative_level, line, column) orelse return false;
    defer self.heap.allocator.free(name);
    return self.startImportedModule(name, destination, line, column);
}

pub fn startImportedModule(self: *Runtime, name: []const u8, destination: u16, line: u32, column: u32) bool {
    if (self.findCachedModule(name)) |cached| {
        if (native_registry.moduleId(name) == .sys and !cached.initialized) {
            if (!native_sys.populate(Runtime, self, cached.environment, line, column)) {
                const environment: *Environment = @ptrCast(@alignCast(cached.environment));
                for (environment.entries.items) |entry| self.heap.allocator.free(@constCast(entry.name));
                environment.entries.clearRetainingCapacity();
                return false;
            }
            cached.initialized = true;
        }
        self.setRegister(destination, Value.object(&cached.header));
        return true;
    }
    if (native_registry.moduleId(name)) |native_id| {
        if (std.mem.lastIndexOfScalar(u8, name, '.')) |separator| {
            const parent_name = name[0..separator];
            if (self.findCachedModule(parent_name) == null) if (native_registry.moduleId(parent_name)) |parent_id| {
                if (!self.startNativeModule(parent_name, parent_id, destination, line, column)) return false;
            };
        }
        return self.startNativeModule(name, native_id, destination, line, column);
    }
    const resolved = self.resolveModuleFile(name) catch {
        self.setException(exceptions.memoryError(), line, column, null);
        return false;
    } orelse {
        self.setException(.{ .kind = .module_not_found_error, .message = "No module named in the session VFS" }, line, column, name);
        return false;
    };
    defer self.heap.allocator.free(resolved.filename);
    const source = self.vfs.readNormalized(resolved.filename) catch {
        self.setException(.{ .kind = .module_not_found_error, .message = "No module named in the session VFS" }, line, column, name);
        return false;
    };

    const environment = self.createEnvironment(line, column) orelse return false;
    var environment_root = gc.Root{ .object = &environment.header };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&environment_root);
    var roots_active = true;
    defer if (roots_active) roots.pop();
    const package_name = if (resolved.is_package) name else if (std.mem.lastIndexOfScalar(u8, name, '.')) |separator| name[0..separator] else "";
    const search_path = if (resolved.is_package) std.fs.path.dirname(resolved.filename) orelse "" else "";
    const created = module_module.create(&self.heap, name, package_name, resolved.filename, search_path, &environment.header, resolved.is_package);
    const selected = switch (created) {
        .value => |module| module,
        .python_exception => |exception| {
            self.setException(exception, line, column, null);
            return false;
        },
    };
    environment.module_owner = &selected.header;
    var module_root = gc.Root{ .object = &selected.header };
    roots.add(&module_root);
    var cache_registered = false;
    var frame_scheduled = false;
    defer if (cache_registered and !frame_scheduled) self.removeCachedModule(selected);
    if (!self.cacheModule(selected, line, column)) return false;
    cache_registered = true;

    var name_root = gc.Root{ .object = null };
    var package_root = gc.Root{ .object = null };
    var file_root = gc.Root{ .object = null };
    roots.add(&name_root);
    roots.add(&package_root);
    roots.add(&file_root);
    const name_value = self.createStringValue(name, line, column) orelse return false;
    name_root.object = name_value.asObject();
    const package_value = self.createStringValue(package_name, line, column) orelse return false;
    package_root.object = package_value.asObject();
    const file_value = self.createStringValue(resolved.filename, line, column) orelse return false;
    file_root.object = file_value.asObject();
    if (!self.environmentStore(&environment.header, "__name__", name_value) or
        !self.environmentStore(&environment.header, "__package__", package_value) or
        !self.environmentStore(&environment.header, "__file__", file_value))
    {
        self.setException(exceptions.memoryError(), line, column, null);
        return false;
    }
    if (resolved.is_package) {
        const path_text = self.createStringValue(search_path, line, column) orelse return false;
        var path_text_root = gc.Root{ .object = path_text.asObject() };
        roots.add(&path_text_root);
        const path_values = [_]Value{path_text};
        const path_list = switch (sequence.createList(&self.heap, &path_values)) {
            .value => |list| list,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
            .engine_error => return self.engineFault(),
        };
        var path_root = gc.Root{ .object = &path_list.header };
        roots.add(&path_root);
        if (!self.environmentStore(&environment.header, "__path__", Value.object(&path_list.header))) {
            self.setException(exceptions.memoryError(), line, column, null);
            return false;
        }
    }

    // The importer cache now roots selected -> environment and all metadata.
    // Pop this temporary frame before compile() pushes the Code's persistent roots.
    roots.pop();
    roots_active = false;
    const root_boundary = self.heap.roots.top_frame;
    const outcome = compiler.compile(&self.heap, source, resolved.filename);
    const module_code = switch (outcome) {
        .ready => |module_code| module_code,
        .python_exception => |exception| {
            self.setException(exception, line, column, null);
            return false;
        },
        .syntax_error => |diagnostic| {
            self.setException(.{ .kind = .syntax_error, .message = diagnostic.message }, line, column, null);
            return false;
        },
        .unsupported => |diagnostic| {
            self.setException(.{ .kind = .syntax_error, .message = diagnostic.message }, line, column, null);
            return false;
        },
    };
    const code_root_count = countCodeRoots(module_code) orelse {
        module_code.deinit(&self.heap);
        self.setException(exceptions.memoryError(), line, column, null);
        return false;
    };
    if (code_root_count != 0) {
        selected.code_roots = self.heap.allocator.alloc(?*gc.Header, code_root_count) catch {
            module_code.deinit(&self.heap);
            self.setException(exceptions.memoryError(), line, column, null);
            return false;
        };
        var root_cursor: usize = 0;
        copyCodeRoots(module_code, selected.code_roots, &root_cursor);
    }
    if (!self.detachRootsTo(root_boundary)) {
        module_code.deinit(&self.heap);
        return self.engineFault();
    }
    self.imported_codes.append(self.heap.allocator, module_code) catch {
        module_code.deinit(&self.heap);
        self.setException(exceptions.memoryError(), line, column, null);
        return false;
    };
    const frame = self.allocateFrame(module_code, destination) catch {
        _ = self.imported_codes.pop();
        module_code.deinit(&self.heap);
        self.setException(exceptions.memoryError(), line, column, null);
        return false;
    };
    setFrameEnvironment(frame, &environment.header);
    frame.module_initializing = selected;
    frame.return_override = Value.object(&selected.header);
    frame.roots[frame.returnOverrideRootIndex()].object = &selected.header;
    frame_scheduled = true;
    return true;
}

pub fn startNativeModule(self: *Runtime, name: []const u8, native_id: @import("../stdlib/types.zig").ModuleId, destination: u16, line: u32, column: u32) bool {
    const environment = self.createEnvironment(line, column) orelse return false;
    var env_root = gc.Root{ .object = &environment.header };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&env_root);
    defer roots.pop();
    const package_name = if (std.mem.lastIndexOfScalar(u8, name, '.')) |separator| name[0..separator] else "";
    const is_package = native_id == .urllib or native_id == .requests;
    const native_module = switch (module_module.create(&self.heap, name, package_name, "<native>", "", &environment.header, is_package)) {
        .value => |selected| selected,
        .python_exception => |exception| {
            self.setException(exception, line, column, null);
            return false;
        },
    };
    environment.module_owner = &native_module.header;
    var module_root = gc.Root{ .object = &native_module.header };
    roots.add(&module_root);
    if (!self.cacheModule(native_module, line, column)) return false;
    var completed = false;
    var eager_child: ?*module_module.Module = null;
    defer if (!completed) {
        if (eager_child) |child| self.removeCachedModule(child);
        self.removeCachedModule(native_module);
    };

    var name_root = gc.Root{ .object = null };
    var package_root = gc.Root{ .object = null };
    var file_root = gc.Root{ .object = null };
    roots.add(&name_root);
    roots.add(&package_root);
    roots.add(&file_root);
    const name_value = self.createStringValue(name, line, column) orelse return false;
    name_root.object = name_value.asObject();
    const package_value = self.createStringValue(package_name, line, column) orelse return false;
    package_root.object = package_value.asObject();
    const file_value = self.createStringValue("<native>", line, column) orelse return false;
    file_root.object = file_value.asObject();
    if (!self.environmentStore(&environment.header, "__name__", name_value) or
        !self.environmentStore(&environment.header, "__package__", package_value) or
        !self.environmentStore(&environment.header, "__file__", file_value))
    {
        self.setException(exceptions.memoryError(), line, column, null);
        return false;
    }

    for (native_registry.functionSpecs(native_id)) |spec| {
        if (!spec.exported or native_id == .random or native_id == .statistics or native_id == .json or native_id == .csv or native_id == .copy) continue;
        const created = functions_module.createLibrary(&self.heap, @intFromEnum(native_id), spec.id, Value.noneValue());
        const function = switch (created) {
            .value => |selected| selected,
            .python_exception => |exception| {
                self.setException(exception, line, column, null);
                return false;
            },
        };
        var function_root = gc.Root{ .object = &function.header };
        var function_frame = gc.RootFrame{};
        function_frame.push(&self.heap.roots);
        function_frame.add(&function_root);
        const stored = self.environmentStore(&environment.header, spec.name, Value.object(&function.header));
        function_frame.pop();
        if (!stored) {
            self.setException(exceptions.memoryError(), line, column, null);
            return false;
        }
    }
    if (!native_registry.populate(Runtime, self, native_id, &environment.header, line, column)) return false;
    if (native_id == .requests or native_id == .os) {
        const child_name: []const u8 = if (native_id == .requests) "requests.exceptions" else "os.path";
        const child_id: @import("../stdlib/types.zig").ModuleId = if (native_id == .requests) .requests_exceptions else .os_path;
        if (!self.startNativeModule(child_name, child_id, destination, line, column)) return false;
        eager_child = self.findCachedModule(child_name) orelse return self.engineFault();
    }
    native_module.initialized = true;
    if (!self.attachImportedChild(native_module, line, column)) return false;
    self.setRegister(destination, Value.object(&native_module.header));
    completed = true;
    return true;
}

pub fn executeImportMember(self: *Runtime, instruction: bytecode.Instruction, line: u32, column: u32) bool {
    const code = self.activeCode() orelse return self.engineFault();
    const site_index: usize = instruction.c();
    if (!self.validRegister(instruction.a()) or !self.validRegister(instruction.b()) or site_index >= code.import_sites.len) return self.engineFault();
    const site = code.import_sites[site_index];
    if (site.kind != .member or site.name.len == 0) return self.engineFault();
    const base_header = self.registers[instruction.b()].asObject() orelse return self.nativeTypeError(line, column, "from-import base is not a module");
    const base = module_module.fromHeader(base_header) orelse return self.nativeTypeError(line, column, "from-import base is not a module");
    if (environmentLookup(base.environment, site.name)) |value| {
        self.setRegister(instruction.a(), value);
        return true;
    }
    if (!base.is_package) {
        self.setException(.{ .kind = .import_error, .message = "cannot import name from module" }, line, column, site.name);
        return false;
    }
    const child_name = std.fmt.allocPrint(self.heap.allocator, "{s}.{s}", .{ base.name, site.name }) catch {
        self.setException(exceptions.memoryError(), line, column, null);
        return false;
    };
    defer self.heap.allocator.free(child_name);
    if (self.findCachedModule(child_name) == null and native_registry.moduleId(child_name) == null) {
        const child_file = self.resolveModuleFile(child_name) catch {
            self.setException(exceptions.memoryError(), line, column, null);
            return false;
        } orelse {
            self.setException(.{ .kind = .import_error, .message = "cannot import name from package" }, line, column, site.name);
            return false;
        };
        self.heap.allocator.free(child_file.filename);
    }
    if (!self.startImportedModule(child_name, instruction.a(), line, column)) return false;
    return true;
}

pub fn executeImportStar(self: *Runtime, module_register: u16, destination: u16, line: u32, column: u32) bool {
    if (!self.validRegister(module_register) or !self.validRegister(destination)) return self.engineFault();
    const header = self.registers[module_register].asObject() orelse return self.nativeTypeError(line, column, "from-import base is not a module");
    const selected = module_module.fromHeader(header) orelse return self.nativeTypeError(line, column, "from-import base is not a module");
    if (environmentLookup(selected.environment, "__all__")) |all_value| {
        const all_header = all_value.asObject() orelse return self.nativeTypeError(line, column, "module __all__ must be a sequence of strings");
        const names = if (sequence.listFromHeader(all_header)) |list|
            list.items.items
        else if (sequence.tupleFromHeader(all_header)) |tuple|
            tuple.items
        else
            return self.nativeTypeError(line, column, "module __all__ must be a sequence of strings");
        for (names) |item| {
            const item_header = item.asObject() orelse return self.nativeTypeError(line, column, "item in module __all__ must be a string");
            const text = string.fromHeader(item_header) orelse return self.nativeTypeError(line, column, "item in module __all__ must be a string");
            const imported_name = string.content(text);
            var value = environmentLookup(selected.environment, imported_name);
            if (value == null and selected.is_package) {
                const child_name = std.fmt.allocPrint(self.heap.allocator, "{s}.{s}", .{ selected.name, imported_name }) catch {
                    self.setException(exceptions.memoryError(), line, column, null);
                    return false;
                };
                defer self.heap.allocator.free(child_name);
                if (self.findCachedModule(child_name)) |cached| {
                    value = Value.object(&cached.header);
                    if (!self.environmentStore(selected.environment, imported_name, value.?)) {
                        self.setException(exceptions.memoryError(), line, column, null);
                        return false;
                    }
                } else {
                    const child_file = self.resolveModuleFile(child_name) catch {
                        self.setException(exceptions.memoryError(), line, column, null);
                        return false;
                    } orelse {
                        self.setException(.{ .kind = .attribute_error, .message = "module does not define name in __all__" }, line, column, imported_name);
                        return false;
                    };
                    self.heap.allocator.free(child_file.filename);
                    const caller = self.top_frame orelse return self.engineFault();
                    if (!self.startImportedModule(child_name, destination, line, column)) return false;
                    if (self.top_frame != caller) {
                        if (caller.ip == 0) return self.engineFault();
                        return self.setFrameInstruction(caller, @intCast(caller.ip - 1));
                    }
                    value = self.registers[destination];
                    if (!self.environmentStore(selected.environment, imported_name, value.?)) {
                        self.setException(exceptions.memoryError(), line, column, null);
                        return false;
                    }
                }
            }
            const selected_value = value orelse {
                self.setException(.{ .kind = .attribute_error, .message = "module does not define name in __all__" }, line, column, imported_name);
                return false;
            };
            if (!self.storeGlobal(imported_name, selected_value)) {
                self.setException(exceptions.memoryError(), line, column, null);
                return false;
            }
        }
        return true;
    }
    const environment: *Environment = @ptrCast(@alignCast(selected.environment));
    for (environment.entries.items) |entry| {
        if (entry.name.len != 0 and entry.name[0] == '_') continue;
        if (!self.storeGlobal(entry.name, entry.value)) {
            self.setException(exceptions.memoryError(), line, column, null);
            return false;
        }
    }
    return true;
}

pub fn storeGlobal(self: *Runtime, name: []const u8, value: Value) bool {
    const environment = self.currentEnvironmentObject();
    for (environment.entries.items) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            entry.value = value;
            return true;
        }
    }
    const owned_name = self.heap.allocator.dupe(u8, name) catch return false;
    environment.entries.append(self.heap.allocator, .{ .name = owned_name, .value = value }) catch {
        self.heap.allocator.free(owned_name);
        return false;
    };
    return true;
}
