const std = @import("std");
const binder = @import("runtime_binder");
const byte_module = @import("runtime_bytes");
const dict_module = @import("runtime_dict");
const exceptions = @import("runtime_exception");
const functions_module = @import("runtime_function");
const gc = @import("runtime_gc");
const host = @import("runtime_host");
const number = @import("runtime_number");
const sequence = @import("runtime_sequence");
const types = @import("types.zig");
const codec = @import("http.zig");
const json_values = @import("json_values.zig");

const Value = types.Value;

pub const urllib_request_functions = [_]types.FunctionSpec{
    .{ .id = 1, .name = "urlopen", .params = &.{
        .{ .name = "url" },
        .{ .name = "data", .default = .none },
        .{ .name = "timeout", .default = .none },
    } },
    .{ .id = 101, .name = "read", .params = &.{.{ .name = "size", .default = .none }}, .exported = false },
    .{ .id = 102, .name = "getcode", .exported = false },
    .{ .id = 103, .name = "close", .exported = false },
    .{ .id = 104, .name = "__enter__", .exported = false },
    .{ .id = 105, .name = "__exit__", .params = &.{ .{ .name = "exc_type" }, .{ .name = "exc" }, .{ .name = "traceback" } }, .exported = false },
};

pub const requests_functions = [_]types.FunctionSpec{
    .{ .id = 1, .name = "get", .params = &.{
        .{ .name = "url" },
        .{ .name = "params", .default = .none },
        .{ .name = "headers", .flags = binder.parameter_flags_module.keyword_only, .default = .none },
        .{ .name = "timeout", .flags = binder.parameter_flags_module.keyword_only, .default = .none },
    } },
    .{ .id = 2, .name = "post", .params = &.{
        .{ .name = "url" },
        .{ .name = "data", .default = .none },
        .{ .name = "json", .default = .none },
        .{ .name = "headers", .flags = binder.parameter_flags_module.keyword_only, .default = .none },
        .{ .name = "timeout", .flags = binder.parameter_flags_module.keyword_only, .default = .none },
        .{ .name = "params", .flags = binder.parameter_flags_module.keyword_only, .default = .none },
    } },
    .{ .id = 101, .name = "json", .exported = false },
    .{ .id = 102, .name = "raise_for_status", .exported = false },
};

pub const classes = [_]types.TypeSpec{
    .{ .type_id = .urllib_response, .module = .urllib_request, .name = "HTTPResponse", .exported = false },
    .{ .type_id = .requests_response, .module = .requests, .name = "Response" },
    .{ .type_id = .http_headers, .module = .requests, .name = "CaseInsensitiveHeaders", .exported = false },
};

const Api = enum { urllib, requests };
const RequestPhase = enum { request, complete, failed };

const RequestPayload = struct {
    allocator: std.mem.Allocator,
    api: Api,
    phase: RequestPhase = .request,
    method: []u8,
    url: []u8,
    header_block: []u8,
    body: []u8,
    timeout_bytes: [8]u8 = @splat(0),
    has_timeout: bool = false,
    sections: [5]host.Section = undefined,
    status_code: u16 = 0,
    response_headers: ?codec.Headers = null,
    response_body: ?[]u8 = null,
    error_classification: ?[]u8 = null,
    error_message: ?[]u8 = null,
};

const HeadersState = struct {
    headers: codec.Headers,
};

const UrllibResponseState = struct {
    allocator: std.mem.Allocator,
    status: u16,
    headers: Value,
    body: []u8,
    cursor: usize = 0,
    closed: bool = false,
};

const RequestsResponseState = struct {
    allocator: std.mem.Allocator,
    status: u16,
    headers: Value,
    body: []u8,
    explicit_encoding: ?codec.Encoding = null,
};

pub fn populate(comptime Runtime: type, self: *Runtime, module_id: types.ModuleId, environment: *gc.Header, line: u32, column: u32) bool {
    return switch (module_id) {
        .urllib => populateUrllibErrors(Runtime, self, environment, line, column),
        .urllib_error => aliasExceptionClasses(Runtime, self, environment, "urllib", &.{ "URLError", "HTTPError" }, line, column),
        .urllib_request => true,
        .requests => populateRequests(Runtime, self, environment, line, column),
        .requests_exceptions => aliasExceptionClasses(Runtime, self, environment, "requests", &.{ "RequestException", "ConnectionError", "Timeout", "HTTPError" }, line, column),
        else => self.engineFault(),
    };
}

fn populateUrllibErrors(comptime Runtime: type, self: *Runtime, environment: *gc.Header, line: u32, column: u32) bool {
    const url_error = createExceptionClass(Runtime, self, environment, "URLError", .os_error, null, line, column) orelse return false;
    _ = createExceptionClass(Runtime, self, environment, "HTTPError", .os_error, url_error, line, column) orelse return false;
    return true;
}

fn populateRequests(comptime Runtime: type, self: *Runtime, environment: *gc.Header, line: u32, column: u32) bool {
    const response_class = self.ensureNativeClass(.requests_response, "Response", line, column) orelse return false;
    if (!storeValue(Runtime, self, environment, "Response", Value.object(&response_class.header), line, column)) return false;
    const request_error = createExceptionClass(Runtime, self, environment, "RequestException", .exception, null, line, column) orelse return false;
    _ = createExceptionClass(Runtime, self, environment, "ConnectionError", .exception, request_error, line, column) orelse return false;
    _ = createExceptionClass(Runtime, self, environment, "Timeout", .exception, request_error, line, column) orelse return false;
    _ = createExceptionClass(Runtime, self, environment, "HTTPError", .exception, request_error, line, column) orelse return false;
    return true;
}

fn createExceptionClass(
    comptime Runtime: type,
    self: *Runtime,
    environment: *gc.Header,
    name: []const u8,
    base_kind: exceptions.PythonExceptionKind,
    parent: ?*exceptions.ExceptionClass,
    line: u32,
    column: u32,
) ?*exceptions.ExceptionClass {
    const class = switch (exceptions.createNativeClass(&self.heap, name, base_kind, parent)) {
        .value => |created| created,
        .python_exception => |exception| {
            self.setException(exception, line, column, null);
            return null;
        },
        .engine_error => {
            _ = self.engineFault();
            return null;
        },
    };
    if (!storeValue(Runtime, self, environment, name, Value.object(&class.header), line, column)) return null;
    return class;
}

fn aliasExceptionClasses(
    comptime Runtime: type,
    self: *Runtime,
    environment: *gc.Header,
    parent_module_name: []const u8,
    names: []const []const u8,
    line: u32,
    column: u32,
) bool {
    const parent_module = self.findCachedModule(parent_module_name) orelse return self.engineFault();
    for (names) |name| {
        const value = Runtime.environmentLookup(parent_module.environment, name) orelse return self.engineFault();
        if (exceptions.classFromHeader(value.asObject() orelse return self.engineFault()) == null) return self.engineFault();
        if (!storeValue(Runtime, self, environment, name, value, line, column)) return false;
    }
    return true;
}

pub fn executeUrllib(
    comptime Runtime: type,
    self: *Runtime,
    destination: u16,
    function_id: u16,
    receiver: Value,
    args: []const Value,
    extra: []const binder.Keyword,
    line: u32,
    column: u32,
) bool {
    if (extra.len != 0) return self.nativeTypeError(line, column, "unexpected keyword argument");
    return switch (function_id) {
        1 => startUrlopen(Runtime, self, destination, args, line, column),
        101 => urllibRead(Runtime, self, destination, receiver, args[0], line, column),
        102 => urllibGetCode(self, destination, receiver),
        103 => urllibClose(self, destination, receiver),
        104 => urllibEnter(self, destination, receiver, line, column),
        105 => urllibExit(self, destination, receiver),
        else => self.engineFault(),
    };
}

pub fn executeRequests(
    comptime Runtime: type,
    self: *Runtime,
    destination: u16,
    function_id: u16,
    receiver: Value,
    args: []const Value,
    extra: []const binder.Keyword,
    line: u32,
    column: u32,
) bool {
    if (extra.len != 0) return self.nativeTypeError(line, column, "unexpected keyword argument");
    return switch (function_id) {
        1 => startRequests(Runtime, self, destination, false, args, line, column),
        2 => startRequests(Runtime, self, destination, true, args, line, column),
        101 => responseJson(Runtime, self, destination, receiver, line, column),
        102 => responseRaiseForStatus(Runtime, self, destination, receiver, line, column),
        else => self.engineFault(),
    };
}

fn startUrlopen(comptime Runtime: type, self: *Runtime, destination: u16, args: []const Value, line: u32, column: u32) bool {
    const url = self.valueString(args[0]) orelse return self.nativeTypeError(line, column, "urlopen() url must be str");
    codec.validateUrl(url) catch return urlValueError(self, line, column);
    const body: []const u8 = if (args[1].tag() == .none) "" else self.valueBytes(args[1]) orelse return self.nativeTypeError(line, column, "urlopen() data must be bytes");
    const timeout = timeoutValue(Runtime, self, args[2], line, column) orelse if (args[2].tag() == .none) null else return false;
    var headers = codec.Headers.init(self.heap.allocator);
    defer headers.deinit();
    return startHttpTask(Runtime, self, destination, .urllib, if (args[1].tag() == .none) "GET" else "POST", url, &headers, body, timeout, args, line, column);
}

fn startRequests(comptime Runtime: type, self: *Runtime, destination: u16, post: bool, args: []const Value, line: u32, column: u32) bool {
    const url = self.valueString(args[0]) orelse return self.nativeTypeError(line, column, "request URL must be str");
    const params_value = if (post) args[5] else args[1];
    const encoded_params = encodeMapping(Runtime, self, params_value, line, column) orelse if (params_value.tag() == .none) null else return false;
    defer if (encoded_params) |owned| self.heap.allocator.free(owned);
    const final_url = if (encoded_params) |params|
        codec.appendQuery(self.heap.allocator, url, params) catch {
            self.setException(exceptions.memoryError(), line, column, null);
            return false;
        }
    else
        self.heap.allocator.dupe(u8, url) catch {
            self.setException(exceptions.memoryError(), line, column, null);
            return false;
        };
    defer self.heap.allocator.free(final_url);
    codec.validateUrl(final_url) catch return urlValueError(self, line, column);

    const headers_value = if (post) args[3] else args[2];
    var headers = headersFromValue(Runtime, self, headers_value, line, column) orelse if (headers_value.tag() == .none) codec.Headers.init(self.heap.allocator) else return false;
    defer headers.deinit();
    const timeout_arg = if (post) args[4] else args[3];
    const timeout = timeoutValue(Runtime, self, timeout_arg, line, column) orelse if (timeout_arg.tag() == .none) null else return false;

    var body_owned: ?[]u8 = null;
    defer if (body_owned) |owned| self.heap.allocator.free(owned);
    if (post) {
        const data_value = args[1];
        const json_value = args[2];
        if (data_value.tag() != .none and json_value.tag() != .none) return self.nativeTypeError(line, column, "data and json cannot be supplied together");
        if (json_value.tag() != .none) {
            body_owned = switch (json_values.serializeUtf8(Runtime, self, json_value, .{}, line, column)) {
                .value => |bytes| bytes,
                .python_exception => |exception| {
                    self.setException(exception, line, column, null);
                    return false;
                },
                .engine_error => return self.engineFault(),
            };
            if (!headers.contains("Content-Type")) headers.append("Content-Type", "application/json") catch return headerFailure(self, line, column);
        } else if (data_value.tag() != .none) {
            if (self.valueBytes(data_value)) |bytes| {
                body_owned = self.heap.allocator.dupe(u8, bytes) catch return memoryFailure(self, line, column);
            } else if (self.valueString(data_value)) |text| {
                body_owned = self.heap.allocator.dupe(u8, text) catch return memoryFailure(self, line, column);
            } else {
                body_owned = encodeMapping(Runtime, self, data_value, line, column) orelse return self.nativeTypeError(line, column, "request data must be bytes, str, or a form mapping");
                if (!headers.contains("Content-Type")) headers.append("Content-Type", "application/x-www-form-urlencoded") catch return headerFailure(self, line, column);
            }
        }
    }
    return startHttpTask(Runtime, self, destination, .requests, if (post) "POST" else "GET", final_url, &headers, body_owned orelse "", timeout, args, line, column);
}

fn startHttpTask(
    comptime Runtime: type,
    self: *Runtime,
    destination: u16,
    api: Api,
    method: []const u8,
    url: []const u8,
    headers: *const codec.Headers,
    body: []const u8,
    timeout: ?f64,
    inputs: []const Value,
    line: u32,
    column: u32,
) bool {
    _ = self.ensureNativeClass(.http_headers, "CaseInsensitiveHeaders", line, column) orelse return false;
    _ = self.ensureNativeClass(if (api == .urllib) .urllib_response else .requests_response, if (api == .urllib) "HTTPResponse" else "Response", line, column) orelse return false;
    const payload = self.heap.allocator.create(RequestPayload) catch return memoryFailure(self, line, column);
    payload.* = .{
        .allocator = self.heap.allocator,
        .api = api,
        .method = self.heap.allocator.dupe(u8, method) catch {
            self.heap.allocator.destroy(payload);
            return memoryFailure(self, line, column);
        },
        .url = &.{},
        .header_block = &.{},
        .body = &.{},
    };
    payload.url = self.heap.allocator.dupe(u8, url) catch {
        destroyRequestPayload(payload, self.heap.allocator);
        return memoryFailure(self, line, column);
    };
    payload.header_block = headers.serialize(self.heap.allocator) catch {
        destroyRequestPayload(payload, self.heap.allocator);
        return headerFailure(self, line, column);
    };
    payload.body = self.heap.allocator.dupe(u8, body) catch {
        destroyRequestPayload(payload, self.heap.allocator);
        return memoryFailure(self, line, column);
    };
    if (timeout) |seconds| {
        payload.has_timeout = true;
        std.mem.writeInt(u64, &payload.timeout_bytes, @bitCast(seconds), .little);
    }
    const lengths = if (payload.has_timeout)
        [_]usize{ payload.method.len, payload.url.len, payload.header_block.len, payload.body.len, 8 }
    else
        [_]usize{ payload.method.len, payload.url.len, payload.header_block.len, payload.body.len, 0 };
    const packet_lengths = if (payload.has_timeout) lengths[0..5] else lengths[0..4];
    _ = codec.packetSize(packet_lengths) catch {
        destroyRequestPayload(payload, self.heap.allocator);
        self.setException(.{ .kind = .value_error, .message = "HTTP request exceeds packet limit" }, line, column, null);
        return false;
    };
    const caller = self.top_frame orelse {
        destroyRequestPayload(payload, self.heap.allocator);
        return self.engineFault();
    };
    const task = types.createTask(
        &self.heap,
        self.currentNativeTask(),
        if (api == .urllib) .urllib_request else .requests,
        1,
        @ptrCast(caller),
        destination,
        line,
        column,
        inputs,
        requestTaskOps(Runtime),
    ) catch {
        destroyRequestPayload(payload, self.heap.allocator);
        return memoryFailure(self, line, column);
    };
    task.payload = payload;
    return self.startNativeTask(task);
}

fn requestTaskOps(comptime Runtime: type) *const types.TaskOps {
    return &struct {
        fn step(context: *anyopaque, task: *types.Task) types.TaskStep {
            const self: *Runtime = @ptrCast(@alignCast(context));
            return requestTaskStep(Runtime, self, task);
        }

        fn hostReply(context: *anyopaque, task: *types.Task, packet: *const host.DecodedPacket) bool {
            const self: *Runtime = @ptrCast(@alignCast(context));
            return requestHostReply(Runtime, self, task, packet);
        }

        const ops = types.TaskOps{ .step = step, .host_reply = hostReply, .destroy_payload = destroyRequestPayload };
    }.ops;
}

fn requestTaskStep(comptime Runtime: type, self: *Runtime, task: *types.Task) types.TaskStep {
    const payload = requestPayload(task) orelse return .{ .raise = .{ .kind = .runtime_error, .message = "invalid HTTP task state" } };
    return switch (payload.phase) {
        .request => blk: {
            payload.sections[0] = .{ .kind = .utf8, .bytes = payload.method };
            payload.sections[1] = .{ .kind = .utf8, .bytes = payload.url };
            payload.sections[2] = .{ .kind = .utf8, .bytes = payload.header_block };
            payload.sections[3] = .{ .kind = .binary, .bytes = payload.body };
            if (payload.has_timeout) payload.sections[4] = .{ .kind = .binary, .bytes = &payload.timeout_bytes };
            break :blk .{ .host = .{ .kind = .http, .request_id = 1, .sections = if (payload.has_timeout) payload.sections[0..5] else payload.sections[0..4] } };
        },
        .failed => httpTaskFailure(Runtime, self, task, payload),
        .complete => createResponse(Runtime, self, task, payload),
    };
}

fn requestHostReply(comptime Runtime: type, self: *Runtime, task: *types.Task, packet: *const host.DecodedPacket) bool {
    const payload = requestPayload(task) orelse return false;
    if (payload.phase != .request) return false;
    const lengths = if (packet.status == .host_error)
        [_]usize{ packet.sections[0].bytes.len, packet.sections[1].bytes.len, 0 }
    else
        [_]usize{ packet.sections[0].bytes.len, packet.sections[1].bytes.len, packet.sections[2].bytes.len };
    const packet_lengths = if (packet.status == .host_error) lengths[0..2] else lengths[0..3];
    _ = codec.packetSize(packet_lengths) catch return false;
    if (packet.status == .host_error) {
        const classification = packet.sections[0].bytes;
        if (!std.mem.eql(u8, classification, "connection") and !std.mem.eql(u8, classification, "policy") and !std.mem.eql(u8, classification, "timeout")) return false;
        payload.error_classification = self.heap.allocator.dupe(u8, packet.sections[0].bytes) catch {
            payload.phase = .failed;
            return true;
        };
        payload.error_message = self.heap.allocator.dupe(u8, packet.sections[1].bytes) catch {
            self.heap.allocator.free(payload.error_classification.?);
            payload.error_classification = null;
            payload.phase = .failed;
            return true;
        };
        payload.phase = .failed;
        return true;
    }
    payload.status_code = std.mem.readInt(u16, packet.sections[0].bytes[0..2], .little);
    payload.response_headers = codec.Headers.parse(self.heap.allocator, packet.sections[1].bytes) catch |err| {
        if (err != error.OutOfMemory) return false;
        payload.phase = .failed;
        return true;
    };
    payload.response_body = self.heap.allocator.dupe(u8, packet.sections[2].bytes) catch {
        payload.response_headers.?.deinit();
        payload.response_headers = null;
        payload.error_classification = self.heap.allocator.dupe(u8, "memory") catch null;
        payload.phase = .failed;
        return true;
    };
    payload.phase = .complete;
    return true;
}

fn createResponse(comptime Runtime: type, self: *Runtime, task: *types.Task, payload: *RequestPayload) types.TaskStep {
    const headers_state = self.heap.allocator.create(HeadersState) catch return .{ .raise = exceptions.memoryError() };
    headers_state.* = .{ .headers = payload.response_headers.? };
    payload.response_headers = null;
    const headers_class = self.ensureNativeClass(.http_headers, "CaseInsensitiveHeaders", task.line, task.column) orelse {
        headers_state.headers.deinit();
        self.heap.allocator.destroy(headers_state);
        return .propagate;
    };
    const headers_object = types.createObject(&self.heap, headers_class, .http_headers) catch {
        headers_state.headers.deinit();
        self.heap.allocator.destroy(headers_state);
        return .{ .raise = exceptions.memoryError() };
    };
    headers_object.payload = headers_state;
    headers_object.destroy_payload = destroyHeaders;
    headers_object.ops = headersOps(Runtime);
    var headers_root = gc.Root{ .object = &headers_object.header };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&headers_root);
    defer roots.pop();

    if (payload.api == .urllib and payload.status_code >= 400) {
        return .{ .raise = nativeHttpException(Runtime, self, "urllib", "HTTPError", .os_error, "HTTP status error") };
    }
    const response_type: types.TypeId = if (payload.api == .urllib) .urllib_response else .requests_response;
    const response_class = self.ensureNativeClass(response_type, if (payload.api == .urllib) "HTTPResponse" else "Response", task.line, task.column) orelse return .propagate;
    const response_object = types.createObject(&self.heap, response_class, response_type) catch return .{ .raise = exceptions.memoryError() };
    var response_root = gc.Root{ .object = &response_object.header };
    roots.add(&response_root);
    const body = payload.response_body.?;
    payload.response_body = null;
    if (payload.api == .urllib) {
        const state = self.heap.allocator.create(UrllibResponseState) catch {
            self.heap.allocator.free(body);
            return .{ .raise = exceptions.memoryError() };
        };
        state.* = .{ .allocator = self.heap.allocator, .status = payload.status_code, .headers = Value.object(&headers_object.header), .body = body };
        response_object.payload = state;
        response_object.trace_payload = traceUrllibResponse;
        response_object.destroy_payload = destroyUrllibResponse;
        response_object.ops = urllibResponseOps(Runtime);
    } else {
        const state = self.heap.allocator.create(RequestsResponseState) catch {
            self.heap.allocator.free(body);
            return .{ .raise = exceptions.memoryError() };
        };
        state.* = .{ .allocator = self.heap.allocator, .status = payload.status_code, .headers = Value.object(&headers_object.header), .body = body };
        response_object.payload = state;
        response_object.trace_payload = traceRequestsResponse;
        response_object.destroy_payload = destroyRequestsResponse;
    }
    return .{ .complete = Value.object(&response_object.header) };
}

fn httpTaskFailure(comptime Runtime: type, self: *Runtime, task: *types.Task, payload: *RequestPayload) types.TaskStep {
    const classification = payload.error_classification orelse "memory";
    const message = payload.error_message orelse if (std.mem.eql(u8, classification, "memory")) "session memory limit exceeded" else "HTTP transport failed";
    if (std.mem.eql(u8, classification, "memory")) return .{ .raise = exceptions.memoryError() };
    _ = task;
    if (payload.api == .urllib) return .{ .raise = nativeHttpException(Runtime, self, "urllib", "URLError", .os_error, message) };
    if (std.mem.eql(u8, classification, "timeout")) return .{ .raise = nativeHttpException(Runtime, self, "requests", "Timeout", .exception, message) };
    return .{ .raise = nativeHttpException(Runtime, self, "requests", "ConnectionError", .exception, message) };
}

fn requestPayload(task: *types.Task) ?*RequestPayload {
    if (task.owner != .urllib_request and task.owner != .requests) return null;
    return @ptrCast(@alignCast(task.payload orelse return null));
}

fn destroyRequestPayload(raw: ?*anyopaque, allocator: std.mem.Allocator) void {
    const payload: *RequestPayload = @ptrCast(@alignCast(raw orelse return));
    allocator.free(payload.method);
    if (payload.url.len != 0) allocator.free(payload.url);
    if (payload.header_block.len != 0) allocator.free(payload.header_block);
    if (payload.body.len != 0) allocator.free(payload.body);
    if (payload.response_headers) |*headers| headers.deinit();
    if (payload.response_body) |body| allocator.free(body);
    if (payload.error_classification) |value| allocator.free(value);
    if (payload.error_message) |value| allocator.free(value);
    allocator.destroy(payload);
}

pub fn getAttribute(comptime Runtime: type, self: *Runtime, object: *types.NativeObject, name: []const u8, line: u32, column: u32) ?Value {
    return switch (object.type_id) {
        .urllib_response => urllibAttribute(Runtime, self, object, name, line, column),
        .requests_response => requestsAttribute(Runtime, self, object, name, line, column),
        else => null,
    };
}

pub fn setAttribute(comptime Runtime: type, self: *Runtime, object: *types.NativeObject, name: []const u8, value: Value, line: u32, column: u32) bool {
    if (object.type_id != .requests_response or !std.mem.eql(u8, name, "encoding")) return self.nativeAttributeError(line, column, "native attribute is read-only");
    const state = requestsState(object) orelse return self.engineFault();
    if (value.tag() == .none) {
        state.explicit_encoding = null;
        return true;
    }
    const text = self.valueString(value) orelse return self.nativeTypeError(line, column, "encoding must be str or None");
    state.explicit_encoding = codec.parseEncoding(text) catch {
        self.setException(.{ .kind = .lookup_error, .message = "unknown response encoding" }, line, column, null);
        return false;
    };
    return true;
}

pub fn headerGetItem(comptime Runtime: type, self: *Runtime, object: *types.NativeObject, key: Value, line: u32, column: u32) ?Value {
    const state = headersState(object) orelse return null;
    const name = self.valueString(key) orelse {
        _ = self.nativeTypeError(line, column, "header name must be str");
        return null;
    };
    const value = state.headers.get(name) orelse {
        self.setException(.{ .kind = .key_error, .message = "header not found" }, line, column, null);
        return null;
    };
    return self.createStringValue(value, line, column);
}

fn headersOps(comptime Runtime: type) *const types.NativeObjectOps {
    return &struct {
        fn getItem(context: *anyopaque, object: *types.NativeObject, key: Value, destination: u16, line: u32, column: u32) ?Value {
            _ = destination;
            const self: *Runtime = @ptrCast(@alignCast(context));
            return headerGetItem(Runtime, self, object, key, line, column);
        }

        fn contains(context: *anyopaque, object: *types.NativeObject, key: Value, line: u32, column: u32) ?bool {
            const self: *Runtime = @ptrCast(@alignCast(context));
            const state = headersState(object) orelse return null;
            const name = self.valueString(key) orelse {
                _ = self.nativeTypeError(line, column, "header name must be str");
                return null;
            };
            return state.headers.contains(name);
        }

        const ops = types.NativeObjectOps{ .get_item = getItem, .contains = contains };
    }.ops;
}

fn urllibResponseOps(comptime Runtime: type) *const types.NativeObjectOps {
    return &struct {
        fn enter(context: *anyopaque, object: *types.NativeObject, line: u32, column: u32) ?Value {
            const self: *Runtime = @ptrCast(@alignCast(context));
            const state = urllibState(object) orelse return null;
            if (state.closed) {
                self.setException(.{ .kind = .value_error, .message = "I/O operation on closed response" }, line, column, null);
                return null;
            }
            return Value.object(&object.header);
        }

        fn exit(context: *anyopaque, object: *types.NativeObject, line: u32, column: u32) ?bool {
            _ = context;
            _ = line;
            _ = column;
            const state = urllibState(object) orelse return null;
            state.closed = true;
            return true;
        }

        const ops = types.NativeObjectOps{ .enter = enter, .exit = exit };
    }.ops;
}

fn urllibAttribute(comptime Runtime: type, self: *Runtime, object: *types.NativeObject, name: []const u8, line: u32, column: u32) ?Value {
    const state = urllibState(object) orelse return null;
    if (std.mem.eql(u8, name, "status")) return Value.fromSmallInt(state.status);
    if (std.mem.eql(u8, name, "headers")) return state.headers;
    const method: u16 = if (std.mem.eql(u8, name, "read")) 101 else if (std.mem.eql(u8, name, "getcode")) 102 else if (std.mem.eql(u8, name, "close")) 103 else if (std.mem.eql(u8, name, "__enter__")) 104 else if (std.mem.eql(u8, name, "__exit__")) 105 else return null;
    return boundMethod(Runtime, self, .urllib_request, method, Value.object(&object.header), line, column);
}

fn requestsAttribute(comptime Runtime: type, self: *Runtime, object: *types.NativeObject, name: []const u8, line: u32, column: u32) ?Value {
    const state = requestsState(object) orelse return null;
    if (std.mem.eql(u8, name, "status_code")) return Value.fromSmallInt(state.status);
    if (std.mem.eql(u8, name, "ok")) return if (state.status < 400) Value.trueValue() else Value.falseValue();
    if (std.mem.eql(u8, name, "headers")) return state.headers;
    if (std.mem.eql(u8, name, "content")) return createBytes(Runtime, self, state.body, line, column);
    if (std.mem.eql(u8, name, "encoding")) {
        const encoding = effectiveEncoding(state) catch {
            self.setException(.{ .kind = .lookup_error, .message = "unknown response encoding" }, line, column, null);
            return null;
        };
        return self.createStringValue(encodingName(encoding), line, column);
    }
    if (std.mem.eql(u8, name, "text")) {
        const encoding = effectiveEncoding(state) catch {
            self.setException(.{ .kind = .lookup_error, .message = "unknown response encoding" }, line, column, null);
            return null;
        };
        const decoded = codec.decodeText(self.heap.allocator, state.body, encoding) catch {
            self.setException(exceptions.memoryError(), line, column, null);
            return null;
        };
        defer self.heap.allocator.free(decoded);
        return self.createStringValue(decoded, line, column);
    }
    const method: u16 = if (std.mem.eql(u8, name, "json")) 101 else if (std.mem.eql(u8, name, "raise_for_status")) 102 else return null;
    return boundMethod(Runtime, self, .requests, method, Value.object(&object.header), line, column);
}

fn urllibRead(comptime Runtime: type, self: *Runtime, destination: u16, receiver: Value, size_value: Value, line: u32, column: u32) bool {
    const state = urllibStateFromValue(receiver) orelse return self.engineFault();
    if (state.closed) {
        self.setException(.{ .kind = .value_error, .message = "I/O operation on closed response" }, line, column, null);
        return false;
    }
    var size = state.body.len - state.cursor;
    if (size_value.tag() != .none) {
        const requested = number.toInt(i64, size_value) orelse return self.nativeTypeError(line, column, "read size must be an integer");
        if (requested >= 0) size = @min(size, @as(usize, @intCast(requested)));
    }
    const value = createBytes(Runtime, self, state.body[state.cursor..][0..size], line, column) orelse return false;
    state.cursor += size;
    self.setRegister(destination, value);
    return true;
}

fn urllibGetCode(self: anytype, destination: u16, receiver: Value) bool {
    const state = urllibStateFromValue(receiver) orelse return self.engineFault();
    self.setRegister(destination, Value.fromSmallInt(state.status).?);
    return true;
}

fn urllibClose(self: anytype, destination: u16, receiver: Value) bool {
    const state = urllibStateFromValue(receiver) orelse return self.engineFault();
    state.closed = true;
    self.setRegister(destination, Value.noneValue());
    return true;
}

fn urllibEnter(self: anytype, destination: u16, receiver: Value, line: u32, column: u32) bool {
    const state = urllibStateFromValue(receiver) orelse return self.engineFault();
    if (state.closed) {
        self.setException(.{ .kind = .value_error, .message = "I/O operation on closed response" }, line, column, null);
        return false;
    }
    self.setRegister(destination, receiver);
    return true;
}

fn urllibExit(self: anytype, destination: u16, receiver: Value) bool {
    const state = urllibStateFromValue(receiver) orelse return self.engineFault();
    state.closed = true;
    self.setRegister(destination, Value.noneValue());
    return true;
}

fn responseJson(comptime Runtime: type, self: *Runtime, destination: u16, receiver: Value, line: u32, column: u32) bool {
    const state = requestsStateFromValue(receiver) orelse return self.engineFault();
    return json_values.startParseBytesTask(Runtime, self, destination, state.body, line, column);
}

fn responseRaiseForStatus(comptime Runtime: type, self: *Runtime, destination: u16, receiver: Value, line: u32, column: u32) bool {
    const state = requestsStateFromValue(receiver) orelse return self.engineFault();
    if (state.status >= 400) {
        self.setException(nativeHttpException(Runtime, self, "requests", "HTTPError", .exception, "HTTP status error"), line, column, null);
        return false;
    }
    self.setRegister(destination, Value.noneValue());
    return true;
}

fn effectiveEncoding(state: *const RequestsResponseState) codec.Error!codec.Encoding {
    if (state.explicit_encoding) |encoding| return encoding;
    const headers = headersStateFromValue(state.headers) orelse return .utf8;
    return codec.contentTypeEncoding(headers.headers.get("Content-Type"));
}

fn encodingName(encoding: codec.Encoding) []const u8 {
    return switch (encoding) {
        .utf8 => "utf-8",
        .ascii => "ascii",
        .latin1 => "latin-1",
    };
}

fn headersFromValue(comptime Runtime: type, self: *Runtime, value: Value, line: u32, column: u32) ?codec.Headers {
    var result = codec.Headers.init(self.heap.allocator);
    if (value.tag() == .none) return result;
    const header = value.asObject() orelse {
        _ = self.nativeTypeError(line, column, "headers must be a mapping");
        result.deinit();
        return null;
    };
    const mapping = dict_module.dictFromHeader(header) orelse {
        _ = self.nativeTypeError(line, column, "headers must be a mapping");
        result.deinit();
        return null;
    };
    if (mapping.is_set) {
        _ = self.nativeTypeError(line, column, "headers must be a mapping");
        result.deinit();
        return null;
    }
    for (mapping.entries.items) |entry| {
        if (!entry.alive) continue;
        const name = self.valueString(entry.key) orelse {
            _ = self.nativeTypeError(line, column, "header names must be str");
            result.deinit();
            return null;
        };
        const content = self.valueString(entry.value) orelse {
            _ = self.nativeTypeError(line, column, "header values must be str");
            result.deinit();
            return null;
        };
        result.append(name, content) catch |err| {
            result.deinit();
            if (err == error.OutOfMemory) _ = memoryFailure(self, line, column) else _ = headerFailure(self, line, column);
            return null;
        };
    }
    return result;
}

fn encodeMapping(comptime Runtime: type, self: *Runtime, value: Value, line: u32, column: u32) ?[]u8 {
    if (value.tag() == .none) return null;
    const header = value.asObject() orelse {
        _ = self.nativeTypeError(line, column, "parameters must be a mapping");
        return null;
    };
    const mapping = dict_module.dictFromHeader(header) orelse {
        _ = self.nativeTypeError(line, column, "parameters must be a mapping");
        return null;
    };
    if (mapping.is_set) {
        _ = self.nativeTypeError(line, column, "parameters must be a mapping");
        return null;
    }
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(self.heap.allocator);
    for (mapping.entries.items) |entry| {
        if (!entry.alive) continue;
        const key = scalarText(Runtime, self, entry.key, line, column) orelse return null;
        defer self.heap.allocator.free(key);
        const item = scalarText(Runtime, self, entry.value, line, column) orelse return null;
        defer self.heap.allocator.free(item);
        codec.appendFormPair(self.heap.allocator, &output, key, item) catch |err| {
            if (err == error.OutOfMemory) _ = memoryFailure(self, line, column) else _ = self.nativeTypeError(line, column, "parameters must contain text-compatible values");
            return null;
        };
    }
    return output.toOwnedSlice(self.heap.allocator) catch {
        _ = memoryFailure(self, line, column);
        return null;
    };
}

fn scalarText(comptime Runtime: type, self: *Runtime, value: Value, line: u32, column: u32) ?[]u8 {
    if (self.valueString(value)) |text| return self.heap.allocator.dupe(u8, text) catch {
        _ = memoryFailure(self, line, column);
        return null;
    };
    if (!number.isIntegerValue(value) and value.tag() != .float and value.tag() != .boolean and value.tag() != .none) {
        _ = self.nativeTypeError(line, column, "parameters must contain scalar values");
        return null;
    }
    return self.renderValueOwned(value, false, line, column);
}

fn timeoutValue(comptime Runtime: type, self: *Runtime, value: Value, line: u32, column: u32) ?f64 {
    if (value.tag() == .none) return null;
    const seconds = switch (number.toFloat(&self.heap, value)) {
        .value => |selected| selected,
        .python_exception => |exception| {
            self.setException(exception, line, column, null);
            return null;
        },
        .engine_error => {
            _ = self.engineFault();
            return null;
        },
    };
    if (!std.math.isFinite(seconds) or seconds < 0) {
        self.setException(.{ .kind = .value_error, .message = "timeout must be finite and non-negative" }, line, column, null);
        return null;
    }
    return seconds;
}

fn boundMethod(comptime Runtime: type, self: *Runtime, module: types.ModuleId, id: u16, receiver: Value, line: u32, column: u32) ?Value {
    return switch (functions_module.createLibrary(&self.heap, @intFromEnum(module), id, receiver)) {
        .value => |function| Value.object(&function.header),
        .python_exception => |exception| blk: {
            self.setException(exception, line, column, null);
            break :blk null;
        },
    };
}

fn createBytes(comptime Runtime: type, self: *Runtime, content: []const u8, line: u32, column: u32) ?Value {
    return switch (byte_module.create(&self.heap, content)) {
        .value => |bytes| Value.object(&bytes.header),
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

fn headersState(object: *types.NativeObject) ?*HeadersState {
    if (object.type_id != .http_headers) return null;
    return @ptrCast(@alignCast(object.payload orelse return null));
}

fn headersStateFromValue(value: Value) ?*HeadersState {
    const object = types.fromHeader(value.asObject() orelse return null) orelse return null;
    return headersState(object);
}

fn urllibState(object: *types.NativeObject) ?*UrllibResponseState {
    if (object.type_id != .urllib_response) return null;
    return @ptrCast(@alignCast(object.payload orelse return null));
}

fn urllibStateFromValue(value: Value) ?*UrllibResponseState {
    const object = types.fromHeader(value.asObject() orelse return null) orelse return null;
    return urllibState(object);
}

fn requestsState(object: *types.NativeObject) ?*RequestsResponseState {
    if (object.type_id != .requests_response) return null;
    return @ptrCast(@alignCast(object.payload orelse return null));
}

fn requestsStateFromValue(value: Value) ?*RequestsResponseState {
    const object = types.fromHeader(value.asObject() orelse return null) orelse return null;
    return requestsState(object);
}

fn traceUrllibResponse(raw: ?*anyopaque, tracer: *gc.Tracer) void {
    const state: *UrllibResponseState = @ptrCast(@alignCast(raw orelse return));
    tracer.visit(state.headers.asObject());
}

fn traceRequestsResponse(raw: ?*anyopaque, tracer: *gc.Tracer) void {
    const state: *RequestsResponseState = @ptrCast(@alignCast(raw orelse return));
    tracer.visit(state.headers.asObject());
}

fn destroyHeaders(raw: ?*anyopaque, allocator: std.mem.Allocator) void {
    const state: *HeadersState = @ptrCast(@alignCast(raw orelse return));
    state.headers.deinit();
    allocator.destroy(state);
}

fn destroyUrllibResponse(raw: ?*anyopaque, allocator: std.mem.Allocator) void {
    const state: *UrllibResponseState = @ptrCast(@alignCast(raw orelse return));
    allocator.free(state.body);
    allocator.destroy(state);
}

fn destroyRequestsResponse(raw: ?*anyopaque, allocator: std.mem.Allocator) void {
    const state: *RequestsResponseState = @ptrCast(@alignCast(raw orelse return));
    allocator.free(state.body);
    allocator.destroy(state);
}

fn storeValue(comptime Runtime: type, self: *Runtime, environment: *gc.Header, name: []const u8, value: Value, line: u32, column: u32) bool {
    var root = gc.Root{ .object = value.asObject() };
    var roots = gc.RootFrame{};
    roots.push(&self.heap.roots);
    roots.add(&root);
    defer roots.pop();
    if (self.environmentStore(environment, name, value)) return true;
    return memoryFailure(self, line, column);
}

fn nativeHttpException(
    comptime Runtime: type,
    self: *Runtime,
    module_name: []const u8,
    class_name: []const u8,
    fallback_kind: exceptions.PythonExceptionKind,
    message: []const u8,
) exceptions.PythonException {
    const module = self.findCachedModule(module_name) orelse return .{ .kind = fallback_kind, .message = message };
    const value = Runtime.environmentLookup(module.environment, class_name) orelse return .{ .kind = fallback_kind, .message = message };
    const class = exceptions.classFromHeader(value.asObject() orelse return .{ .kind = fallback_kind, .message = message }) orelse return .{ .kind = fallback_kind, .message = message };
    return .{ .kind = class.kind, .message = message, .native_class = class };
}

fn memoryFailure(self: anytype, line: u32, column: u32) bool {
    self.setException(exceptions.memoryError(), line, column, null);
    return false;
}

fn headerFailure(self: anytype, line: u32, column: u32) bool {
    self.setException(.{ .kind = .value_error, .message = "invalid HTTP header" }, line, column, null);
    return false;
}

fn urlValueError(self: anytype, line: u32, column: u32) bool {
    self.setException(.{ .kind = .value_error, .message = "invalid or unsupported URL" }, line, column, null);
    return false;
}
