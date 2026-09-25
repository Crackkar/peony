const std = @import("std");
const vm = @import("runtime_vm");
const host = @import("runtime_host");

fn compileUrllibDraftGeneric(runtime: *vm.Runtime) bool {
    const Value = vm.NativeTypes.Value;
    const args = [_]Value{ Value.noneValue(), Value.noneValue(), Value.noneValue(), Value.noneValue() };
    return vm.HttpDraft.executeUrllib(vm.Runtime, runtime, 0, 1, Value.noneValue(), &args, &.{}, 1, 1);
}

fn compileRequestsDraftGeneric(runtime: *vm.Runtime) bool {
    const Value = vm.NativeTypes.Value;
    const args = [_]Value{ Value.noneValue(), Value.noneValue(), Value.noneValue(), Value.noneValue(), Value.noneValue(), Value.noneValue() };
    return vm.HttpDraft.executeRequests(vm.Runtime, runtime, 0, 2, Value.noneValue(), &args, &.{}, 1, 1);
}

fn ready(runtime: *vm.Runtime, source: []const u8) !void {
    switch (runtime.compileAndStart(source, "library-http.py")) {
        .ready => {},
        .syntax_error => |diagnostic| {
            std.debug.print("HTTP test syntax error at {d}:{d}: {s}\n", .{ diagnostic.line, diagnostic.column, diagnostic.message });
            return error.ExpectedCompiledHttpProgram;
        },
        .unsupported => |diagnostic| {
            std.debug.print("HTTP test unsupported syntax at {d}:{d}: {s}\n", .{ diagnostic.line, diagnostic.column, diagnostic.message });
            return error.ExpectedCompiledHttpProgram;
        },
        .python_exception => |exception| {
            std.debug.print("HTTP test compile exception: {s}\n", .{exception.message});
            return error.ExpectedCompiledHttpProgram;
        },
    }
}

fn boundary(runtime: *vm.Runtime, quantum: u32) !vm.RunStatus {
    var status = vm.RunStatus.timeslice;
    for (0..200_000) |_| {
        status = runtime.run(quantum);
        if (status != .timeslice and status != .output_event) return status;
    }
    return error.NoHttpExecutionBoundary;
}

fn decodeRequest(runtime: *vm.Runtime, expected: host.Kind) !host.DecodedPacket {
    var request = try host.decode(std.testing.allocator, runtime.eventBytes());
    errdefer request.deinit(std.testing.allocator);
    try std.testing.expectEqual(expected, request.kind);
    return request;
}

fn resumePacket(runtime: *vm.Runtime, kind: host.Kind, request_id: u32, status: host.Status, sections: []host.Section) !void {
    var packet = host.DecodedPacket{
        .kind = kind,
        .request_id = request_id,
        .status = status,
        .flags = 0,
        .sections = sections,
        .storage = &.{},
    };
    try std.testing.expect(runtime.resumeHost(&packet));
}

fn putFloat(buffer: *[8]u8, value: f64) void {
    std.mem.writeInt(u64, buffer, @bitCast(value), .little);
}

fn makeIntegerArrayJson(allocator: std.mem.Allocator, count: usize) ![]u8 {
    if (count == 0) return allocator.dupe(u8, "[]");
    const length = try std.math.add(usize, try std.math.mul(usize, count, 2), 1);
    const bytes = try allocator.alloc(u8, length);
    bytes[0] = '[';
    for (0..count) |index| {
        bytes[1 + index * 2] = '0';
        bytes[2 + index * 2] = if (index + 1 == count) ']' else ',';
    }
    return bytes;
}

fn expectHttpRequest(request: *const host.DecodedPacket, method: []const u8, url: []const u8, body: []const u8) !void {
    try std.testing.expectEqual(host.Kind.http, request.kind);
    try std.testing.expect(request.sections.len == 4 or request.sections.len == 5);
    try std.testing.expectEqual(host.SectionKind.utf8, request.sections[0].kind);
    try std.testing.expectEqualStrings(method, request.sections[0].bytes);
    try std.testing.expectEqual(host.SectionKind.utf8, request.sections[1].kind);
    try std.testing.expectEqualStrings(url, request.sections[1].bytes);
    try std.testing.expectEqual(host.SectionKind.utf8, request.sections[2].kind);
    try std.testing.expectEqual(host.SectionKind.binary, request.sections[3].kind);
    try std.testing.expectEqualSlices(u8, body, request.sections[3].bytes);
}

fn httpOk(runtime: *vm.Runtime, request_id: u32, status_code: u16, headers: []const u8, body: []const u8) !void {
    var status_bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &status_bytes, status_code, .little);
    var sections = [_]host.Section{
        .{ .kind = .binary, .bytes = &status_bytes },
        .{ .kind = .utf8, .bytes = headers },
        .{ .kind = .binary, .bytes = body },
    };
    try resumePacket(runtime, .http, request_id, .ok, &sections);
}

pub fn testUrlopenResponseCursorContextSslAndValidation() !void {
    _ = &compileUrllibDraftGeneric;
    _ = &compileRequestsDraftGeneric;
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 16 * 1024 * 1024);
    defer runtime.deinit();
    try ready(&runtime,
        \\from urllib.request import urlopen
        \\from urllib.error import URLError, HTTPError
        \\import ssl
        \\context = ssl.create_default_context()
        \\print(isinstance(context, ssl.SSLContext), context.check_hostname, context.verify_mode == ssl.CERT_REQUIRED)
        \\context.check_hostname = False
        \\context.verify_mode = ssl.CERT_NONE
        \\response = urlopen("https://example.test/data", timeout=2.5, context=context)
        \\print(response.status, response.getcode(), response.headers["content-type"])
        \\print(response.read(2), response.read(-1), response.read())
        \\response.close()
        \\try:
        \\    response.read()
        \\except ValueError:
        \\    print("closed")
        \\try:
        \\    ssl.SSLContext().verify_mode = 99
        \\except ValueError:
        \\    print("bad verify")
        \\try:
        \\    urlopen("ftp://example.test/file")
        \\except ValueError:
        \\    print("bad scheme")
        \\try:
        \\    urlopen("https://example.test/", data="text")
        \\except TypeError:
        \\    print("bad data")
        \\try:
        \\    urlopen("https://example.test/", context=1)
        \\except TypeError:
        \\    print("bad context")
        \\try:
        \\    urlopen("https://example.test/", timeout=-1)
        \\except ValueError:
        \\    print("bad timeout")
    );

    try std.testing.expectEqual(vm.RunStatus.host_request, try boundary(&runtime, 1));
    var request = try decodeRequest(&runtime, .http);
    defer request.deinit(std.testing.allocator);
    try expectHttpRequest(&request, "GET", "https://example.test/data", "");
    try std.testing.expectEqual(@as(usize, 5), request.sections.len);
    try std.testing.expectEqual(host.SectionKind.binary, request.sections[4].kind);
    try std.testing.expectEqual(@as(usize, 8), request.sections[4].bytes.len);
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 2.5))), std.mem.readInt(u64, request.sections[4].bytes[0..8], .little));
    try httpOk(&runtime, request.request_id, 200, "Content-Type: text/plain; charset=utf-8\r\nX-Test: yes\r\n", "hello");
    const result = try boundary(&runtime, 1);
    if (result != .completed) std.debug.print("urlopen result={s}: {s}\n", .{ @tagName(result), runtime.errorText() });
    try std.testing.expectEqual(vm.RunStatus.completed, result);
    try std.testing.expectEqualStrings(
        "True True True\n200 200 text/plain; charset=utf-8\nb'he' b'llo' b''\nclosed\nbad verify\nbad scheme\nbad data\nbad context\nbad timeout\n",
        runtime.stdout(),
    );
}

pub fn testSslContextTypeAndMutation() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 4 * 1024 * 1024);
    defer runtime.deinit();
    try ready(&runtime,
        \\import ssl
        \\first = ssl.SSLContext()
        \\second = ssl.create_default_context()
        \\print(type(first) is ssl.SSLContext, isinstance(second, ssl.SSLContext))
        \\print(first.check_hostname, first.verify_mode == ssl.CERT_REQUIRED)
        \\try:
        \\    first.verify_mode = ssl.CERT_NONE
        \\except ValueError:
        \\    print("hostname guard")
        \\first.check_hostname = False
        \\first.verify_mode = ssl.CERT_NONE
        \\print(first.check_hostname, first.verify_mode == ssl.CERT_NONE)
        \\first.check_hostname = True
        \\print(first.check_hostname, first.verify_mode == ssl.CERT_REQUIRED)
        \\try:
        \\    first.verify_mode = 99
        \\except ValueError:
        \\    print("invalid mode")
        \\try:
        \\    first.check_hostname = "yes"
        \\except TypeError:
        \\    print("invalid hostname")
        \\try:
        \\    first.extra = 1
        \\except AttributeError:
        \\    print("readonly")
    );
    const result = try boundary(&runtime, 1);
    if (result != .completed) std.debug.print("ssl result={s}: {s}\n", .{ @tagName(result), runtime.errorText() });
    try std.testing.expectEqual(vm.RunStatus.completed, result);
    try std.testing.expectEqualStrings("True True\nTrue True\nhostname guard\nFalse True\nTrue True\ninvalid mode\ninvalid hostname\nreadonly\n", runtime.stdout());
}

pub fn testUrlopenPostContextManagerAndErrors() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 16 * 1024 * 1024);
    defer runtime.deinit();
    try ready(&runtime,
        \\from urllib.request import urlopen
        \\from urllib.error import URLError, HTTPError
        \\with urlopen("http://example.test/post", data=b"payload") as response:
        \\    print(response.status, response.read())
        \\empty = urlopen("http://example.test/empty", data=b"")
        \\print(empty.status, empty.read())
        \\try:
        \\    with urlopen("http://example.test/context-error") as failed_context:
        \\        raise ValueError("body")
        \\except ValueError:
        \\    print("body error")
        \\try:
        \\    failed_context.read()
        \\except ValueError:
        \\    print("closed after error")
        \\try:
        \\    urlopen("https://example.test/missing")
        \\except HTTPError as problem:
        \\    print("http", isinstance(problem, URLError), isinstance(problem, OSError))
        \\try:
        \\    urlopen("https://example.test/offline")
        \\except URLError:
        \\    print("transport")
    );

    const first_boundary = try boundary(&runtime, 1);
    if (first_boundary != .host_request) std.debug.print("urlopen POST first boundary={s}: {s}\n", .{ @tagName(first_boundary), runtime.errorText() });
    try std.testing.expectEqual(vm.RunStatus.host_request, first_boundary);
    var post = try decodeRequest(&runtime, .http);
    try expectHttpRequest(&post, "POST", "http://example.test/post", "payload");
    try httpOk(&runtime, post.request_id, 201, "Content-Type: application/octet-stream\r\n", "ok");
    post.deinit(std.testing.allocator);

    const second_boundary = try boundary(&runtime, 1);
    if (second_boundary != .host_request) std.debug.print("urlopen POST second boundary={s}: {s}\n", .{ @tagName(second_boundary), runtime.errorText() });
    try std.testing.expectEqual(vm.RunStatus.host_request, second_boundary);
    var empty_post = try decodeRequest(&runtime, .http);
    try expectHttpRequest(&empty_post, "POST", "http://example.test/empty", "");
    try httpOk(&runtime, empty_post.request_id, 204, "Content-Type: application/octet-stream\r\n", "");
    empty_post.deinit(std.testing.allocator);

    try std.testing.expectEqual(vm.RunStatus.host_request, try boundary(&runtime, 1));
    var context_error = try decodeRequest(&runtime, .http);
    try expectHttpRequest(&context_error, "GET", "http://example.test/context-error", "");
    try httpOk(&runtime, context_error.request_id, 200, "Content-Type: text/plain\r\n", "unused");
    context_error.deinit(std.testing.allocator);

    try std.testing.expectEqual(vm.RunStatus.host_request, try boundary(&runtime, 1));
    var missing = try decodeRequest(&runtime, .http);
    try httpOk(&runtime, missing.request_id, 404, "Content-Type: text/plain\r\n", "missing");
    missing.deinit(std.testing.allocator);

    const third_boundary = try boundary(&runtime, 1);
    if (third_boundary != .host_request) std.debug.print("urlopen POST third boundary={s}: {s}\n", .{ @tagName(third_boundary), runtime.errorText() });
    try std.testing.expectEqual(vm.RunStatus.host_request, third_boundary);
    var offline = try decodeRequest(&runtime, .http);
    var error_sections = [_]host.Section{
        .{ .kind = .utf8, .bytes = "connection" },
        .{ .kind = .utf8, .bytes = "offline" },
    };
    try resumePacket(&runtime, .http, offline.request_id, .host_error, &error_sections);
    offline.deinit(std.testing.allocator);

    const result = try boundary(&runtime, 1);
    if (result != .completed) std.debug.print("urlopen errors result={s}: {s}\n", .{ @tagName(result), runtime.errorText() });
    try std.testing.expectEqual(vm.RunStatus.completed, result);
    try std.testing.expectEqualStrings("201 b'ok'\n204 b''\nbody error\nclosed after error\nhttp True True\ntransport\n", runtime.stdout());
}

pub fn testRequestsQueryFormHeadersEncodingAndJson() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 24 * 1024 * 1024);
    defer runtime.deinit();
    try ready(&runtime,
        \\import requests
        \\print(requests.exceptions.Timeout is requests.Timeout)
        \\from requests.exceptions import ConnectionError as ImportedConnectionError
        \\print(ImportedConnectionError is requests.ConnectionError)
        \\response = requests.get("https://api.test/items", params={"q": "x y", "page": 2}, headers={"X-Test": "yes"}, timeout=3)
        \\print(response.status_code, response.ok, response.headers["CONTENT-TYPE"], "x-reply" in response.headers, response.content, response.text)
        \\print(response.raise_for_status())
        \\response.encoding = "ascii"
        \\print(response.text)
        \\form = requests.post("https://api.test/form", data={"a": "x y", "b": "/"})
        \\print(form.status_code, form.text)
        \\created = requests.post("https://api.test/json", json={"number": 12345678901234567890})
        \\print(created.json()["number"])
        \\raw = requests.post("https://api.test/raw", data=b"raw")
        \\text = requests.post("https://api.test/text", data="text")
        \\print(raw.content, text.text)
        \\invalid = requests.get("https://api.test/invalid-json")
        \\try:
        \\    invalid.json()
        \\except ValueError as problem:
        \\    import json
        \\    print("json decode", type(problem) is json.JSONDecodeError)
        \\malformed_text = requests.get("https://api.test/malformed-text")
        \\print(malformed_text.text)
        \\large = requests.get("https://api.test/large-json")
        \\print(len(large.json()))
        \\try:
        \\    created.encoding = "unknown-codec"
        \\    print(created.text)
        \\except LookupError:
        \\    print("codec")
        \\try:
        \\    requests.get("https://api.test/x", stream=True)
        \\except TypeError:
        \\    print("unknown option")
        \\try:
        \\    requests.Session()
        \\except AttributeError:
        \\    print("unsupported Session")
        \\try:
        \\    requests.get("https://api.test/x", headers={"Bad Name": "value"})
        \\except ValueError:
        \\    print("bad header")
        \\try:
        \\    requests.post("https://api.test/x", data="x", json={})
        \\except TypeError:
        \\    print("conflicting body")
    );

    try std.testing.expectEqual(vm.RunStatus.host_request, try boundary(&runtime, 1));
    var get = try decodeRequest(&runtime, .http);
    try expectHttpRequest(&get, "GET", "https://api.test/items?q=x+y&page=2", "");
    try std.testing.expect(std.mem.indexOf(u8, get.sections[2].bytes, "X-Test: yes\r\n") != null);
    const latin1_body = [_]u8{ 'c', 'a', 'f', 0xe9 };
    try httpOk(&runtime, get.request_id, 200, "Content-Type: text/plain; charset=latin-1\r\nX-Reply: yes\r\n", &latin1_body);
    get.deinit(std.testing.allocator);

    try std.testing.expectEqual(vm.RunStatus.host_request, try boundary(&runtime, 1));
    var form = try decodeRequest(&runtime, .http);
    try expectHttpRequest(&form, "POST", "https://api.test/form", "a=x+y&b=%2F");
    try std.testing.expect(std.mem.indexOf(u8, form.sections[2].bytes, "Content-Type: application/x-www-form-urlencoded") != null);
    try httpOk(&runtime, form.request_id, 202, "Content-Type: text/plain\r\n", "accepted");
    form.deinit(std.testing.allocator);

    try std.testing.expectEqual(vm.RunStatus.host_request, try boundary(&runtime, 1));
    var json_request = try decodeRequest(&runtime, .http);
    try std.testing.expectEqualStrings("POST", json_request.sections[0].bytes);
    try std.testing.expectEqualStrings("https://api.test/json", json_request.sections[1].bytes);
    try std.testing.expect(std.mem.indexOf(u8, json_request.sections[2].bytes, "Content-Type: application/json") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_request.sections[3].bytes, "12345678901234567890") != null);
    try httpOk(&runtime, json_request.request_id, 201, "Content-Type: application/json; charset=utf-8\r\n", "{\"number\":12345678901234567890}");
    json_request.deinit(std.testing.allocator);

    try std.testing.expectEqual(vm.RunStatus.host_request, try boundary(&runtime, 1));
    var raw_request = try decodeRequest(&runtime, .http);
    try expectHttpRequest(&raw_request, "POST", "https://api.test/raw", "raw");
    try httpOk(&runtime, raw_request.request_id, 200, "Content-Type: application/octet-stream\r\n", "raw-ok");
    raw_request.deinit(std.testing.allocator);

    try std.testing.expectEqual(vm.RunStatus.host_request, try boundary(&runtime, 1));
    var text_request = try decodeRequest(&runtime, .http);
    try expectHttpRequest(&text_request, "POST", "https://api.test/text", "text");
    try httpOk(&runtime, text_request.request_id, 200, "Content-Type: text/plain; charset=utf-8\r\n", "text-ok");
    text_request.deinit(std.testing.allocator);

    try std.testing.expectEqual(vm.RunStatus.host_request, try boundary(&runtime, 1));
    var invalid_json = try decodeRequest(&runtime, .http);
    try expectHttpRequest(&invalid_json, "GET", "https://api.test/invalid-json", "");
    try httpOk(&runtime, invalid_json.request_id, 200, "Content-Type: application/json\r\n", "{");
    invalid_json.deinit(std.testing.allocator);

    try std.testing.expectEqual(vm.RunStatus.host_request, try boundary(&runtime, 1));
    var malformed_text = try decodeRequest(&runtime, .http);
    try expectHttpRequest(&malformed_text, "GET", "https://api.test/malformed-text", "");
    const malformed_utf8 = [_]u8{ 'a', 0xff, 'b' };
    try httpOk(&runtime, malformed_text.request_id, 200, "Content-Type: text/plain\r\n", &malformed_utf8);
    malformed_text.deinit(std.testing.allocator);

    try std.testing.expectEqual(vm.RunStatus.host_request, try boundary(&runtime, 1));
    var large_request = try decodeRequest(&runtime, .http);
    try expectHttpRequest(&large_request, "GET", "https://api.test/large-json", "");
    const large_json = try makeIntegerArrayJson(std.testing.allocator, 20_000);
    defer std.testing.allocator.free(large_json);
    try httpOk(&runtime, large_request.request_id, 200, "Content-Type: application/json\r\n", large_json);
    large_request.deinit(std.testing.allocator);
    var saw_json_task = false;
    for (0..10_000) |_| {
        const status = runtime.run(1);
        if (runtime.currentNativeTask()) |task| if (task.owner == .json) {
            saw_json_task = true;
            break;
        };
        try std.testing.expect(status == .timeslice or status == .output_event);
    }
    try std.testing.expect(saw_json_task);
    const work_before_json = runtime.workCount();
    try std.testing.expectEqual(vm.RunStatus.timeslice, runtime.run(1));
    try std.testing.expect(runtime.workCount() > work_before_json);

    const result = try boundary(&runtime, 1);
    if (result != .completed) std.debug.print("requests result={s}: {s}\n", .{ @tagName(result), runtime.errorText() });
    try std.testing.expectEqual(vm.RunStatus.completed, result);
    try std.testing.expectEqualStrings(
        "True\nTrue\n200 True text/plain; charset=latin-1 True b'caf\\xe9' caf\u{00e9}\nNone\ncaf\u{fffd}\n202 accepted\n12345678901234567890\nb'raw-ok' text-ok\njson decode True\na\u{fffd}b\n20000\ncodec\nunknown option\nunsupported Session\nbad header\nconflicting body\n",
        runtime.stdout(),
    );

    try ready(&runtime, "import requests\nresponse = requests.get('https://api.test/cancel-json')\nresponse.json()\nprint('late')\n");
    try std.testing.expectEqual(vm.RunStatus.host_request, try boundary(&runtime, 1));
    var cancel_request = try decodeRequest(&runtime, .http);
    try httpOk(&runtime, cancel_request.request_id, 200, "Content-Type: application/json\r\n", large_json);
    cancel_request.deinit(std.testing.allocator);
    var cancel_task_ready = false;
    for (0..10_000) |_| {
        const status = runtime.run(1);
        if (runtime.currentNativeTask()) |task| if (task.owner == .json) {
            cancel_task_ready = true;
            break;
        };
        try std.testing.expect(status == .timeslice or status == .output_event);
    }
    try std.testing.expect(cancel_task_ready);
    runtime.cancel();
    try std.testing.expectEqual(vm.RunStatus.cancelled, runtime.run(1));
    try std.testing.expect(runtime.currentNativeTask() == null);
}

pub fn testRequestsStatusAndTransportExceptions() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 12 * 1024 * 1024);
    defer runtime.deinit();
    try ready(&runtime,
        \\import requests
        \\response = requests.get("https://api.test/fail")
        \\print(response.status_code, response.ok)
        \\try:
        \\    response.raise_for_status()
        \\except requests.HTTPError as problem:
        \\    print(isinstance(problem, requests.RequestException))
        \\try:
        \\    requests.get("https://api.test/slow", timeout=0.01)
        \\except requests.Timeout as problem:
        \\    print(isinstance(problem, requests.RequestException))
        \\try:
        \\    requests.get("https://api.test/offline")
        \\except requests.ConnectionError as problem:
        \\    print(isinstance(problem, requests.RequestException))
    );
    try std.testing.expectEqual(vm.RunStatus.host_request, try boundary(&runtime, 1));
    var failed = try decodeRequest(&runtime, .http);
    try httpOk(&runtime, failed.request_id, 500, "Content-Type: text/plain\r\n", "failure");
    failed.deinit(std.testing.allocator);
    try std.testing.expectEqual(vm.RunStatus.host_request, try boundary(&runtime, 1));
    var slow = try decodeRequest(&runtime, .http);
    var error_sections = [_]host.Section{
        .{ .kind = .utf8, .bytes = "timeout" },
        .{ .kind = .utf8, .bytes = "deadline exceeded" },
    };
    try resumePacket(&runtime, .http, slow.request_id, .host_error, &error_sections);
    slow.deinit(std.testing.allocator);
    try std.testing.expectEqual(vm.RunStatus.host_request, try boundary(&runtime, 1));
    var offline = try decodeRequest(&runtime, .http);
    var connection_sections = [_]host.Section{
        .{ .kind = .utf8, .bytes = "connection" },
        .{ .kind = .utf8, .bytes = "offline" },
    };
    try resumePacket(&runtime, .http, offline.request_id, .host_error, &connection_sections);
    offline.deinit(std.testing.allocator);
    const result = try boundary(&runtime, 1);
    try std.testing.expectEqual(vm.RunStatus.completed, result);
    try std.testing.expectEqualStrings("500 False\nTrue\nTrue\nTrue\n", runtime.stdout());
}

pub fn testTimeClockSleepValidationAndCancellation() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 8 * 1024 * 1024);
    defer runtime.deinit();
    try ready(&runtime,
        \\import time
        \\import math
        \\print(time.time())
        \\print(time.monotonic())
        \\print(time.sleep(0))
        \\for bad in [-1, math.inf, math.nan]:
        \\    try:
        \\        time.sleep(bad)
        \\    except ValueError:
        \\        print("bad sleep")
    );

    try std.testing.expectEqual(vm.RunStatus.host_request, try boundary(&runtime, 1));
    var wall = try decodeRequest(&runtime, .clock);
    try std.testing.expectEqual(@as(usize, 1), wall.sections.len);
    try std.testing.expectEqualStrings("wall", wall.sections[0].bytes);
    var wall_bytes: [8]u8 = undefined;
    putFloat(&wall_bytes, 123.5);
    var wall_sections = [_]host.Section{.{ .kind = .binary, .bytes = &wall_bytes }};
    try resumePacket(&runtime, .clock, wall.request_id, .ok, &wall_sections);
    wall.deinit(std.testing.allocator);

    try std.testing.expectEqual(vm.RunStatus.host_request, try boundary(&runtime, 1));
    var monotonic = try decodeRequest(&runtime, .clock);
    try std.testing.expectEqualStrings("monotonic", monotonic.sections[0].bytes);
    var monotonic_bytes: [8]u8 = undefined;
    putFloat(&monotonic_bytes, 9.25);
    var monotonic_sections = [_]host.Section{.{ .kind = .binary, .bytes = &monotonic_bytes }};
    try resumePacket(&runtime, .clock, monotonic.request_id, .ok, &monotonic_sections);
    monotonic.deinit(std.testing.allocator);

    try std.testing.expectEqual(vm.RunStatus.host_request, try boundary(&runtime, 1));
    var sleep = try decodeRequest(&runtime, .sleep);
    try std.testing.expectEqual(@as(usize, 1), sleep.sections.len);
    try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, sleep.sections[0].bytes[0..8], .little));
    var empty: [0]host.Section = .{};
    try resumePacket(&runtime, .sleep, sleep.request_id, .ok, &empty);
    sleep.deinit(std.testing.allocator);

    const result = try boundary(&runtime, 1);
    if (result != .completed) std.debug.print("time result={s}: {s}\n", .{ @tagName(result), runtime.errorText() });
    try std.testing.expectEqual(vm.RunStatus.completed, result);
    try std.testing.expectEqualStrings("123.5\n9.25\nNone\nbad sleep\nbad sleep\nbad sleep\n", runtime.stdout());

    try ready(&runtime,
        \\import time
        \\try:
        \\    time.time()
        \\except OSError:
        \\    print("clock error")
    );
    try std.testing.expectEqual(vm.RunStatus.host_request, try boundary(&runtime, 1));
    var failed_clock = try decodeRequest(&runtime, .clock);
    var unknown_clock_sections = [_]host.Section{
        .{ .kind = .utf8, .bytes = "invented" },
        .{ .kind = .utf8, .bytes = "bad classification" },
    };
    var unknown_clock = host.DecodedPacket{ .kind = .clock, .request_id = failed_clock.request_id, .status = .host_error, .flags = 0, .sections = &unknown_clock_sections, .storage = &.{} };
    try std.testing.expect(!runtime.resumeHost(&unknown_clock));
    var clock_error_sections = [_]host.Section{
        .{ .kind = .utf8, .bytes = "clock" },
        .{ .kind = .utf8, .bytes = "clock unavailable" },
    };
    try resumePacket(&runtime, .clock, failed_clock.request_id, .host_error, &clock_error_sections);
    failed_clock.deinit(std.testing.allocator);
    try std.testing.expectEqual(vm.RunStatus.completed, try boundary(&runtime, 1));
    try std.testing.expectEqualStrings("clock error\n", runtime.stdout());

    try ready(&runtime, "import time\ntime.sleep(30)\nprint('late')\n");
    try std.testing.expectEqual(vm.RunStatus.host_request, try boundary(&runtime, 1));
    var pending = try decodeRequest(&runtime, .sleep);
    runtime.cancel();
    try std.testing.expectEqual(vm.RunStatus.cancelled, runtime.run(1));
    var no_sections: [0]host.Section = .{};
    var late = host.DecodedPacket{ .kind = .sleep, .request_id = pending.request_id, .status = .ok, .flags = 0, .sections = &no_sections, .storage = &.{} };
    try std.testing.expect(!runtime.resumeHost(&late));
    pending.deinit(std.testing.allocator);
}

pub fn testHostReplyIdentitySchemaAndSizeDoNotConsumePendingRequest() !void {
    var runtime: vm.Runtime = undefined;
    try runtime.init(std.testing.allocator, 4 * 1024 * 1024);
    defer runtime.deinit();
    try ready(&runtime, "import requests\nprint(requests.get('https://api.test/ok').text)\n");
    try std.testing.expectEqual(vm.RunStatus.host_request, try boundary(&runtime, 1));
    var request = try decodeRequest(&runtime, .http);
    defer request.deinit(std.testing.allocator);
    const saved = try std.testing.allocator.dupe(u8, runtime.eventBytes());
    defer std.testing.allocator.free(saved);

    var no_sections: [0]host.Section = .{};
    var wrong_id = host.DecodedPacket{ .kind = .http, .request_id = request.request_id + 1, .status = .ok, .flags = 0, .sections = &no_sections, .storage = &.{} };
    try std.testing.expect(!runtime.resumeHost(&wrong_id));
    try std.testing.expectEqualSlices(u8, saved, runtime.eventBytes());
    var wrong_kind = host.DecodedPacket{ .kind = .clock, .request_id = request.request_id, .status = .ok, .flags = 0, .sections = &no_sections, .storage = &.{} };
    try std.testing.expect(!runtime.resumeHost(&wrong_kind));
    try std.testing.expectEqualSlices(u8, saved, runtime.eventBytes());

    var bad_status = [1]u8{0};
    var malformed_sections = [_]host.Section{
        .{ .kind = .binary, .bytes = &bad_status },
        .{ .kind = .utf8, .bytes = "Content-Type: text/plain\r\n" },
        .{ .kind = .binary, .bytes = "ok" },
    };
    var malformed = host.DecodedPacket{ .kind = .http, .request_id = request.request_id, .status = .ok, .flags = 0, .sections = &malformed_sections, .storage = &.{} };
    try std.testing.expect(!runtime.resumeHost(&malformed));
    try std.testing.expectEqualSlices(u8, saved, runtime.eventBytes());

    var invalid_status_bytes: [2]u8 = .{ 99, 0 };
    var invalid_header_utf8 = [_]u8{0xff};
    var invalid_utf8_sections = [_]host.Section{
        .{ .kind = .binary, .bytes = &invalid_status_bytes },
        .{ .kind = .utf8, .bytes = &invalid_header_utf8 },
        .{ .kind = .binary, .bytes = "ok" },
    };
    var invalid_utf8 = host.DecodedPacket{ .kind = .http, .request_id = request.request_id, .status = .ok, .flags = 0, .sections = &invalid_utf8_sections, .storage = &.{} };
    try std.testing.expect(!runtime.resumeHost(&invalid_utf8));
    try std.testing.expectEqualSlices(u8, saved, runtime.eventBytes());

    var invalid_status_sections = [_]host.Section{
        .{ .kind = .binary, .bytes = &invalid_status_bytes },
        .{ .kind = .utf8, .bytes = "Content-Type: text/plain\r\n" },
        .{ .kind = .binary, .bytes = "ok" },
    };
    var invalid_status = host.DecodedPacket{ .kind = .http, .request_id = request.request_id, .status = .ok, .flags = 0, .sections = &invalid_status_sections, .storage = &.{} };
    try std.testing.expect(!runtime.resumeHost(&invalid_status));
    try std.testing.expectEqualSlices(u8, saved, runtime.eventBytes());

    var valid_status_bytes: [2]u8 = .{ 200, 0 };
    var invalid_header_sections = [_]host.Section{
        .{ .kind = .binary, .bytes = &valid_status_bytes },
        .{ .kind = .utf8, .bytes = "Bad Name: value\r\n" },
        .{ .kind = .binary, .bytes = "ok" },
    };
    var invalid_header = host.DecodedPacket{ .kind = .http, .request_id = request.request_id, .status = .ok, .flags = 0, .sections = &invalid_header_sections, .storage = &.{} };
    try std.testing.expect(!runtime.resumeHost(&invalid_header));
    try std.testing.expectEqualSlices(u8, saved, runtime.eventBytes());

    var unknown_error_sections = [_]host.Section{
        .{ .kind = .utf8, .bytes = "invented" },
        .{ .kind = .utf8, .bytes = "unsupported host classification" },
    };
    var unknown_error = host.DecodedPacket{ .kind = .http, .request_id = request.request_id, .status = .host_error, .flags = 0, .sections = &unknown_error_sections, .storage = &.{} };
    try std.testing.expect(!runtime.resumeHost(&unknown_error));
    try std.testing.expectEqualSlices(u8, saved, runtime.eventBytes());

    const oversized = try std.testing.allocator.alloc(u8, host.max_packet_bytes);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 0);
    var status_bytes: [2]u8 = .{ 200, 0 };
    var oversized_sections = [_]host.Section{
        .{ .kind = .binary, .bytes = &status_bytes },
        .{ .kind = .utf8, .bytes = "" },
        .{ .kind = .binary, .bytes = oversized },
    };
    var oversized_response = host.DecodedPacket{ .kind = .http, .request_id = request.request_id, .status = .ok, .flags = 0, .sections = &oversized_sections, .storage = &.{} };
    try std.testing.expect(!runtime.resumeHost(&oversized_response));
    try std.testing.expectEqualSlices(u8, saved, runtime.eventBytes());

    try httpOk(&runtime, request.request_id, 200, "Content-Type: text/plain\r\n", "ok");
    try std.testing.expectEqual(vm.RunStatus.completed, try boundary(&runtime, 1));
    try std.testing.expectEqualStrings("ok\n", runtime.stdout());

    try ready(&runtime, "import requests\nrequests.get('https://api.test/reset')\nprint('late')\n");
    try std.testing.expectEqual(vm.RunStatus.host_request, try boundary(&runtime, 1));
    var reset_request = try decodeRequest(&runtime, .http);
    runtime.reset();
    var reset_status: [2]u8 = .{ 200, 0 };
    var reset_sections = [_]host.Section{
        .{ .kind = .binary, .bytes = &reset_status },
        .{ .kind = .utf8, .bytes = "Content-Type: text/plain\r\n" },
        .{ .kind = .binary, .bytes = "late" },
    };
    var late = host.DecodedPacket{ .kind = .http, .request_id = reset_request.request_id, .status = .ok, .flags = 0, .sections = &reset_sections, .storage = &.{} };
    try std.testing.expect(!runtime.resumeHost(&late));
    reset_request.deinit(std.testing.allocator);
}
