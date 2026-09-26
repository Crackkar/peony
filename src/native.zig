const std = @import("std");
const host = @import("runtime_host");
const runtime_vm = @import("runtime_vm");

const Runtime = runtime_vm.Runtime;
const max_source_bytes = 16 * 1024 * 1024;
const max_http_response_bytes = host.max_packet_bytes - 16 * 1024;

const Mount = struct {
    host_path: []const u8,
    virtual_path: []const u8,
};

const Options = struct {
    config: host.Config = host.Config.defaults(),
    script_path: ?[]const u8 = null,
    display_filename: ?[]const u8 = null,
    metrics_path: ?[]const u8 = null,
    program_args: []const []const u8 = &.{},
    mounts: std.ArrayList(Mount) = .empty,
};

const TerminalStatus = enum {
    completed,
    python_exception,
    unsupported,
    cancelled,
    limit,
    engine_error,
    host_error,
};

const Metrics = struct {
    status: TerminalStatus,
    elapsed_ns: u64,
    instructions: u64,
    work: u64,
    peak_session_bytes: u64,
};

const TracebackFrame = struct {
    filename: []const u8,
    name: []const u8,
    line: u32,
    column: u32,
    source_line: []const u8,
};

const NativeHost = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    http_client: std.http.Client,
    stdin_reader: std.Io.File.Reader,
    stdin_buffer: []u8,

    fn init(allocator: std.mem.Allocator, io: std.Io) !NativeHost {
        const input_buffer = try allocator.alloc(u8, host.max_packet_bytes);
        return .{
            .allocator = allocator,
            .io = io,
            .http_client = .{ .allocator = allocator, .io = io },
            .stdin_reader = std.Io.File.stdin().readerStreaming(io, input_buffer),
            .stdin_buffer = input_buffer,
        };
    }

    fn deinit(self: *NativeHost) void {
        self.http_client.deinit();
        self.allocator.free(self.stdin_buffer);
        self.* = undefined;
    }

    fn handle(self: *NativeHost, runtime: *Runtime, request: *const host.DecodedPacket) !void {
        switch (request.kind) {
            .input => try self.handleInput(runtime, request),
            .clock => try self.handleClock(runtime, request),
            .sleep => try self.handleSleep(runtime, request),
            .http => try self.handleHttp(runtime, request),
            .output => return error.InvalidHostRequest,
        }
    }

    fn handleInput(self: *NativeHost, runtime: *Runtime, request: *const host.DecodedPacket) !void {
        if (request.sections.len != 1 or request.sections[0].kind != .utf8) return error.InvalidHostRequest;
        const line = self.stdin_reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return self.resumeInputFailure(runtime, request, "failed to read standard input"),
            error.StreamTooLong => return self.resumeInputFailure(runtime, request, "input line exceeds 1 MiB"),
        };
        if (line) |bytes| {
            if (!std.unicode.utf8ValidateSlice(bytes)) return self.resumeInputFailure(runtime, request, "standard input is not valid UTF-8");
            const sections = [_]host.Section{.{ .kind = .utf8, .bytes = bytes }};
            try resumeRuntime(runtime, request.kind, request.request_id, .ok, &sections);
        } else {
            try resumeRuntime(runtime, request.kind, request.request_id, .eof, &.{});
        }
    }

    fn handleClock(self: *NativeHost, runtime: *Runtime, request: *const host.DecodedPacket) !void {
        if (request.sections.len != 1 or request.sections[0].kind != .utf8) return error.InvalidHostRequest;
        const clock: std.Io.Clock = if (std.mem.eql(u8, request.sections[0].bytes, "wall"))
            .real
        else if (std.mem.eql(u8, request.sections[0].bytes, "monotonic"))
            .awake
        else
            return error.InvalidHostRequest;
        const timestamp = clock.now(self.io);
        const seconds = @as(f64, @floatFromInt(timestamp.nanoseconds)) / @as(f64, std.time.ns_per_s);
        var encoded: [8]u8 = undefined;
        std.mem.writeInt(u64, &encoded, @bitCast(seconds), .little);
        const sections = [_]host.Section{.{ .kind = .binary, .bytes = &encoded }};
        try resumeRuntime(runtime, request.kind, request.request_id, .ok, &sections);
    }

    fn handleSleep(self: *NativeHost, runtime: *Runtime, request: *const host.DecodedPacket) !void {
        if (request.sections.len != 1 or request.sections[0].kind != .binary or request.sections[0].bytes.len != 8) return error.InvalidHostRequest;
        const seconds: f64 = @bitCast(std.mem.readInt(u64, request.sections[0].bytes[0..8], .little));
        if (!std.math.isFinite(seconds) or seconds < 0) return error.InvalidHostRequest;
        const nanoseconds_float = seconds * @as(f64, std.time.ns_per_s);
        if (nanoseconds_float > @as(f64, @floatFromInt(std.math.maxInt(i64)))) {
            return self.resumeFailure(runtime, request, "sleep", "sleep duration is too large");
        }
        const nanoseconds: i64 = @intFromFloat(@round(nanoseconds_float));
        std.Io.sleep(self.io, .fromNanoseconds(nanoseconds), .awake) catch {
            return self.resumeFailure(runtime, request, "sleep", "native sleep was cancelled");
        };
        try resumeRuntime(runtime, request.kind, request.request_id, .ok, &.{});
    }

    fn handleHttp(self: *NativeHost, runtime: *Runtime, request: *const host.DecodedPacket) !void {
        const response = self.performHttpWithTimeout(request) catch |err| {
            const classification: []const u8 = switch (err) {
                error.RequestTimedOut => "timeout",
                error.RedirectRejected, error.InvalidHttpRequest, error.ResponseTooLarge => "policy",
                else => "connection",
            };
            return self.resumeFailure(runtime, request, classification, @errorName(err));
        };
        defer response.deinit(self.allocator);
        var status_bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &status_bytes, response.status, .little);
        const sections = [_]host.Section{
            .{ .kind = .binary, .bytes = &status_bytes },
            .{ .kind = .utf8, .bytes = response.headers },
            .{ .kind = .binary, .bytes = response.body },
        };
        try resumeRuntime(runtime, request.kind, request.request_id, .ok, &sections);
    }

    const HttpResponse = struct {
        status: u16,
        headers: []u8,
        body: []u8,

        fn deinit(self: HttpResponse, allocator: std.mem.Allocator) void {
            allocator.free(self.headers);
            allocator.free(self.body);
        }
    };

    const HttpEvent = union(enum) {
        response: anyerror!HttpResponse,
        timeout,
    };

    fn performHttpWithTimeout(self: *NativeHost, request: *const host.DecodedPacket) !HttpResponse {
        if (request.sections.len != 5) return self.performHttp(request);
        if (request.sections[4].kind != .binary or request.sections[4].bytes.len != 8) return error.InvalidHttpRequest;
        const seconds: f64 = @bitCast(std.mem.readInt(u64, request.sections[4].bytes[0..8], .little));
        if (!std.math.isFinite(seconds) or seconds < 0) return error.InvalidHttpRequest;
        const nanoseconds_float = seconds * @as(f64, std.time.ns_per_s);
        if (nanoseconds_float > @as(f64, @floatFromInt(std.math.maxInt(i64)))) return error.InvalidHttpRequest;
        const duration = std.Io.Duration.fromNanoseconds(@as(i64, @intFromFloat(@round(nanoseconds_float))));

        var event_buffer: [2]HttpEvent = undefined;
        var select = std.Io.Select(HttpEvent).init(self.io, &event_buffer);
        try select.concurrent(.response, performHttpConcurrent, .{ self, request });
        select.concurrent(.timeout, waitForHttpTimeout, .{ self.io, duration }) catch {
            while (select.cancel()) |event| discardHttpEvent(self.allocator, event);
            return error.ConcurrencyUnavailable;
        };
        const first = try select.await();
        defer while (select.cancel()) |event| discardHttpEvent(self.allocator, event);
        return switch (first) {
            .response => |result| result,
            .timeout => error.RequestTimedOut,
        };
    }

    fn performHttpConcurrent(self: *NativeHost, request: *const host.DecodedPacket) anyerror!HttpResponse {
        return self.performHttp(request);
    }

    fn waitForHttpTimeout(io: std.Io, duration: std.Io.Duration) void {
        std.Io.sleep(io, duration, .awake) catch {};
    }

    fn discardHttpEvent(allocator: std.mem.Allocator, event: HttpEvent) void {
        switch (event) {
            .response => |result| if (result) |response| response.deinit(allocator) else |_| {},
            .timeout => {},
        }
    }

    fn performHttp(self: *NativeHost, request: *const host.DecodedPacket) !HttpResponse {
        if (request.sections.len < 4 or request.sections.len > 5) return error.InvalidHttpRequest;
        if (request.sections[0].kind != .utf8 or request.sections[1].kind != .utf8 or request.sections[2].kind != .utf8 or request.sections[3].kind != .binary) return error.InvalidHttpRequest;
        if (request.sections.len == 5) {
            if (request.sections[4].kind != .binary or request.sections[4].bytes.len != 8) return error.InvalidHttpRequest;
        }

        const method: std.http.Method = if (std.mem.eql(u8, request.sections[0].bytes, "GET"))
            .GET
        else if (std.mem.eql(u8, request.sections[0].bytes, "POST"))
            .POST
        else
            return error.InvalidHttpRequest;
        const uri = try std.Uri.parse(request.sections[1].bytes);
        if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) return error.InvalidHttpRequest;

        var extra_headers: std.ArrayList(std.http.Header) = .empty;
        defer extra_headers.deinit(self.allocator);
        var lines = std.mem.splitSequence(u8, request.sections[2].bytes, "\r\n");
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHttpRequest;
            const name = std.mem.trim(u8, line[0..colon], " \t");
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (name.len == 0 or shouldManageHeader(name)) continue;
            try extra_headers.append(self.allocator, .{ .name = name, .value = value });
        }

        var http_request = try self.http_client.request(method, uri, .{
            .redirect_behavior = .not_allowed,
            .extra_headers = extra_headers.items,
            .keep_alive = true,
        });
        defer http_request.deinit();
        if (method.requestHasBody()) {
            try http_request.sendBodyComplete(@constCast(request.sections[3].bytes));
        } else {
            if (request.sections[3].bytes.len != 0) return error.InvalidHttpRequest;
            try http_request.sendBodiless();
        }

        var response = http_request.receiveHead(&.{}) catch |err| switch (err) {
            error.TooManyHttpRedirects => return error.RedirectRejected,
            else => |other| return other,
        };
        var header_output: std.Io.Writer.Allocating = .init(self.allocator);
        defer header_output.deinit();
        var iterator = response.head.iterateHeaders();
        while (iterator.next()) |header_field| {
            if (!std.unicode.utf8ValidateSlice(header_field.name) or !std.unicode.utf8ValidateSlice(header_field.value)) return error.InvalidResponseHeaders;
            try header_output.writer.writeAll(header_field.name);
            try header_output.writer.writeAll(": ");
            try header_output.writer.writeAll(header_field.value);
            try header_output.writer.writeAll("\r\n");
        }
        const response_headers = try header_output.toOwnedSlice();
        errdefer self.allocator.free(response_headers);

        const decompress_size: usize = switch (response.head.content_encoding) {
            .identity => 0,
            .zstd => std.compress.zstd.default_window_len,
            .deflate, .gzip => std.compress.flate.max_window_len,
            .compress => return error.UnsupportedCompressionMethod,
        };
        const decompress_buffer = try self.allocator.alloc(u8, decompress_size);
        defer self.allocator.free(decompress_buffer);
        var transfer_buffer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const body_reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
        const response_body = body_reader.allocRemaining(self.allocator, .limited(max_http_response_bytes)) catch |err| switch (err) {
            error.StreamTooLong => return error.ResponseTooLarge,
            error.ReadFailed => return response.bodyErr() orelse error.HttpBodyReadFailed,
            else => |other| return other,
        };
        return .{ .status = @intFromEnum(response.head.status), .headers = response_headers, .body = response_body };
    }

    fn resumeFailure(self: *NativeHost, runtime: *Runtime, request: *const host.DecodedPacket, classification: []const u8, message: []const u8) !void {
        _ = self;
        const sections = [_]host.Section{
            .{ .kind = .utf8, .bytes = classification },
            .{ .kind = .utf8, .bytes = message },
        };
        try resumeRuntime(runtime, request.kind, request.request_id, .host_error, &sections);
    }

    fn resumeInputFailure(self: *NativeHost, runtime: *Runtime, request: *const host.DecodedPacket, message: []const u8) !void {
        _ = self;
        const sections = [_]host.Section{.{ .kind = .utf8, .bytes = message }};
        try resumeRuntime(runtime, request.kind, request.request_id, .host_error, &sections);
    }
};

pub fn main(init: std.process.Init) !u8 {
    return runMain(init) catch |err| {
        writeError(init.io, "peony: {s}\n", .{@errorName(err)});
        return 2;
    };
}

fn runMain(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var options = Options{};
    defer options.mounts.deinit(allocator);
    const parse_result = parseOptions(allocator, args, &options) catch |err| {
        writeError(io, "peony: {s}\n\n", .{@errorName(err)});
        writeUsage(io, .stderr);
        return 2;
    };
    switch (parse_result) {
        .help => {
            writeUsage(io, .stdout);
            return 0;
        },
        .version => {
            try std.Io.File.writeStreamingAll(.stdout(), io, "Peony 0.1.0 (Python 3.12 subset)\n");
            return 0;
        },
        .run => {},
    }

    const script_path = options.script_path orelse return error.MissingScript;
    const filename = options.display_filename orelse script_path;
    if (!std.unicode.utf8ValidateSlice(filename)) return error.FilenameNotUtf8;
    for (options.program_args) |argument| if (!std.unicode.utf8ValidateSlice(argument) or std.mem.indexOfScalar(u8, argument, 0) != null) return error.ArgumentNotUtf8;

    const source = std.Io.Dir.cwd().readFileAlloc(io, script_path, allocator, .limited(max_source_bytes)) catch |err| {
        writeError(io, "peony: cannot read script \"{s}\": {s}\n", .{ script_path, @errorName(err) });
        return 2;
    };
    defer allocator.free(source);

    var runtime: Runtime = undefined;
    runtime.initWithConfig(allocator, options.config) catch |err| {
        writeError(io, "peony: cannot initialize runtime: {s}\n", .{@errorName(err)});
        return 2;
    };
    defer runtime.deinit();
    for (options.mounts.items) |mount| installMount(io, allocator, &runtime, options.config, mount) catch |err| {
        writeError(io, "peony: cannot mount \"{s}\" at \"{s}\": {s}\n", .{ mount.host_path, mount.virtual_path, @errorName(err) });
        return 2;
    };

    var native_host = try NativeHost.init(allocator, io);
    defer native_host.deinit();

    const started = std.Io.Clock.awake.now(io);
    const outcome = runtime.compileAndStartArgs(source, filename, options.program_args);
    var terminal: TerminalStatus = .completed;
    var exit_code: u8 = 0;
    switch (outcome) {
        .ready => {
            terminal = execute(&runtime, &native_host) catch |err| blk: {
                writeError(io, "peony: native host failure: {s}\n", .{@errorName(err)});
                exit_code = 2;
                break :blk .host_error;
            };
            if (exit_code == 0) exit_code = terminalExitCode(terminal);
        },
        .unsupported => {
            terminal = .unsupported;
            exit_code = 1;
            renderDiagnostic(io, allocator, &runtime, false);
        },
        .syntax_error, .python_exception => {
            terminal = .python_exception;
            exit_code = 1;
            renderDiagnostic(io, allocator, &runtime, false);
        },
    }
    const finished = std.Io.Clock.awake.now(io);
    const duration = started.durationTo(finished).nanoseconds;
    const elapsed_ns: u64 = if (duration <= 0) 0 else @intCast(@min(duration, std.math.maxInt(u64)));
    if (options.metrics_path) |path| {
        const metrics = Metrics{
            .status = terminal,
            .elapsed_ns = elapsed_ns,
            .instructions = runtime.instructionCount(),
            .work = runtime.workCount(),
            .peak_session_bytes = runtime.session_allocator.peak_bytes,
        };
        try writeMetrics(io, allocator, path, metrics);
    }
    return exit_code;
}

const ParseResult = enum { run, help, version };

fn parseOptions(allocator: std.mem.Allocator, args: []const [:0]const u8, options: *Options) !ParseResult {
    var index: usize = 1;
    while (index < args.len) {
        const argument: []const u8 = args[index];
        if (std.mem.eql(u8, argument, "--help") or std.mem.eql(u8, argument, "-h")) return .help;
        if (std.mem.eql(u8, argument, "--version") or std.mem.eql(u8, argument, "-V")) return .version;
        if (std.mem.eql(u8, argument, "--")) {
            index += 1;
            break;
        }
        if (!std.mem.startsWith(u8, argument, "-")) break;
        if (std.mem.eql(u8, argument, "--filename")) {
            options.display_filename = try optionValue(args, &index);
        } else if (std.mem.eql(u8, argument, "--metrics")) {
            options.metrics_path = try optionValue(args, &index);
        } else if (std.mem.eql(u8, argument, "--mount")) {
            const host_path = try optionValue(args, &index);
            const virtual_path = try optionValue(args, &index);
            try options.mounts.append(allocator, .{ .host_path = host_path, .virtual_path = virtual_path });
        } else if (std.mem.eql(u8, argument, "--max-memory")) {
            options.config.max_memory_bytes = try parsePositive(u32, try optionValue(args, &index));
        } else if (std.mem.eql(u8, argument, "--max-work")) {
            options.config.max_instructions = try parsePositive(u64, try optionValue(args, &index));
        } else if (std.mem.eql(u8, argument, "--quantum")) {
            options.config.quantum = try parsePositive(u32, try optionValue(args, &index));
        } else if (std.mem.eql(u8, argument, "--max-vfs")) {
            options.config.max_vfs_bytes = try parsePositive(u32, try optionValue(args, &index));
        } else if (std.mem.eql(u8, argument, "--max-file")) {
            options.config.max_file_bytes = try parsePositive(u32, try optionValue(args, &index));
        } else if (std.mem.eql(u8, argument, "--seed")) {
            options.config.seed = try optionValue(args, &index);
            if (options.config.seed.len > host.max_seed_length) return error.SeedTooLong;
            if (!std.unicode.utf8ValidateSlice(options.config.seed)) return error.SeedNotUtf8;
        } else return error.UnknownOption;
        index += 1;
    }
    if (options.config.max_file_bytes > options.config.max_vfs_bytes) return error.InvalidVfsLimits;
    if (index >= args.len) return error.MissingScript;
    options.script_path = args[index];
    options.program_args = args[index + 1 ..];
    return .run;
}

fn optionValue(args: []const [:0]const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return error.MissingOptionValue;
    return args[index.*];
}

fn parsePositive(comptime T: type, bytes: []const u8) !T {
    const value = try std.fmt.parseUnsigned(T, bytes, 10);
    if (value == 0) return error.ValueMustBePositive;
    return value;
}

fn installMount(io: std.Io, allocator: std.mem.Allocator, runtime: *Runtime, config: host.Config, mount: Mount) !void {
    if (!std.unicode.utf8ValidateSlice(mount.virtual_path) or mount.virtual_path.len < 2 or mount.virtual_path[0] != '/') return error.InvalidMountPath;
    const contents = try std.Io.Dir.cwd().readFileAlloc(io, mount.host_path, allocator, .limited(config.max_file_bytes));
    defer allocator.free(contents);
    if (std.mem.startsWith(u8, mount.virtual_path, "/course/")) {
        try runtime.mountCourseFile(mount.virtual_path, contents);
        return;
    }
    if (!std.mem.startsWith(u8, mount.virtual_path, "/home/")) return error.InvalidMountPath;
    if (std.mem.lastIndexOfScalar(u8, mount.virtual_path, '/')) |separator| {
        const parent = mount.virtual_path[0..separator];
        if (parent.len != 0 and !std.mem.eql(u8, parent, "/home")) try runtime.mkdirVfsDirectory(parent);
    }
    try runtime.writeVfsFile(mount.virtual_path, contents);
}

fn execute(runtime: *Runtime, native_host: *NativeHost) !TerminalStatus {
    while (true) {
        const status = runtime.run(0);
        if (status == .host_request) {
            var request = try host.decode(native_host.allocator, runtime.eventBytes());
            defer request.deinit(native_host.allocator);
            try drainOutput(native_host.io, runtime);
            try native_host.handle(runtime, &request);
            continue;
        }
        try drainOutput(native_host.io, runtime);
        switch (status) {
            .timeslice, .output_event => continue,
            .host_request => unreachable,
            .completed => return .completed,
            .python_exception => {
                renderDiagnostic(native_host.io, native_host.allocator, runtime, true);
                return .python_exception;
            },
            .cancelled => return .cancelled,
            .limit => {
                writeError(native_host.io, "peony: execution work limit reached\n", .{});
                return .limit;
            },
            .engine_error => {
                writeError(native_host.io, "peony: internal runtime error\n", .{});
                return .engine_error;
            },
        }
    }
}

fn drainOutput(io: std.Io, runtime: *Runtime) !void {
    const stdout = runtime.stdout();
    if (stdout.len != 0) {
        try std.Io.File.writeStreamingAll(.stdout(), io, stdout);
        if (!runtime.consumeStdout(stdout.len)) return error.InvalidRuntimeOutput;
    }
    const stderr = runtime.stderr();
    if (stderr.len != 0) {
        try std.Io.File.writeStreamingAll(.stderr(), io, stderr);
        if (!runtime.consumeStderr(stderr.len)) return error.InvalidRuntimeOutput;
    }
}

fn resumeRuntime(runtime: *Runtime, kind: host.Kind, request_id: u32, status: host.Status, sections: []const host.Section) !void {
    const packet = host.DecodedPacket{
        .kind = kind,
        .request_id = request_id,
        .status = status,
        .flags = 0,
        .sections = @constCast(sections),
        .storage = &.{},
    };
    if (!runtime.resumeHost(&packet)) return error.InvalidHostResponse;
}

fn shouldManageHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "host") or
        std.ascii.eqlIgnoreCase(name, "connection") or
        std.ascii.eqlIgnoreCase(name, "content-length") or
        std.ascii.eqlIgnoreCase(name, "transfer-encoding") or
        std.ascii.eqlIgnoreCase(name, "accept-encoding");
}

fn terminalExitCode(status: TerminalStatus) u8 {
    return switch (status) {
        .completed => 0,
        .python_exception, .unsupported => 1,
        .cancelled, .limit, .engine_error, .host_error => 2,
    };
}

fn renderDiagnostic(io: std.Io, allocator: std.mem.Allocator, runtime: *Runtime, traceback: bool) void {
    const json = runtime.tracebackJson();
    if (json.len != 0) {
        var parsed = std.json.parseFromSlice([]TracebackFrame, allocator, json, .{}) catch null;
        if (parsed) |*frames| {
            defer frames.deinit();
            if (traceback and frames.value.len != 0) writeError(io, "Traceback (most recent call last):\n", .{});
            for (frames.value) |frame| {
                writeError(io, "  File \"{s}\", line {d}, in {s}\n", .{ frame.filename, frame.line, frame.name });
                if (frame.source_line.len != 0) writeError(io, "    {s}\n", .{frame.source_line});
            }
        }
    }
    const message = runtime.errorText();
    if (message.len != 0) writeError(io, "{s}\n", .{message});
}

fn writeMetrics(io: std.Io, allocator: std.mem.Allocator, path: []const u8, metrics: Metrics) !void {
    const bytes = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":1,\"status\":\"{s}\",\"elapsed_ns\":{d},\"instructions\":{d},\"work\":{d},\"peak_session_bytes\":{d}}}\n",
        .{ @tagName(metrics.status), metrics.elapsed_ns, metrics.instructions, metrics.work, metrics.peak_session_bytes },
    );
    defer allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

const Output = enum { stdout, stderr };

fn writeUsage(io: std.Io, output: Output) void {
    const text =
        \\Usage: peony [options] SCRIPT [ARG ...]
        \\
        \\Run a Python 3.12 subset program with the native Peony runtime.
        \\
        \\Options:
        \\  -h, --help                 show this help
        \\  -V, --version              show the runtime version
        \\  --filename NAME            override sys.argv[0] and diagnostic filename
        \\  --mount HOST_PATH VFS_PATH copy one host file into /home or /course
        \\  --metrics PATH              write JSON execution metrics after the run
        \\  --max-memory BYTES          session allocation limit
        \\  --max-work COUNT            bytecode and native-work limit
        \\  --quantum COUNT             execution scheduling quantum
        \\  --max-vfs BYTES             total virtual filesystem content limit
        \\  --max-file BYTES            single virtual file content limit
        \\  --seed TEXT                 deterministic session hash seed
        \\
    ;
    const file: std.Io.File = if (output == .stdout) .stdout() else .stderr();
    std.Io.File.writeStreamingAll(file, io, text) catch {};
}

fn writeError(io: std.Io, comptime format: []const u8, values: anytype) void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);
    writer.interface.print(format, values) catch return;
    writer.interface.flush() catch {};
}
