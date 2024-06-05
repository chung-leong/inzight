const std = @import("std");

const ServerContent = @import("./content.zig").ServerContent;

pub const ServerThread = struct {
    address: std.net.Address,
    listen_options: std.net.Address.ListenOptions,
    thread: ?std.Thread = null,
    server: ?*std.net.Server = null,
    connection: ?*std.net.Server.Connection = null,
    last_error: ?(std.net.Address.ListenError || std.net.Server.AcceptError) = null,
    content: *ServerContent,
    request_count: u64 = 0,

    pub fn init(
        address: std.net.Address,
        listen_options: std.net.Address.ListenOptions,
        content: *ServerContent,
    ) @This() {
        return .{
            .address = address,
            .listen_options = listen_options,
            .content = content,
        };
    }

    pub fn spawn(self: *@This()) !void {
        var futex_val = std.atomic.Value(u32).init(0);
        self.thread = try std.Thread.spawn(.{}, run, .{ self, &futex_val });
        std.Thread.Futex.wait(&futex_val, 0);
        if (self.last_error) |err| {
            return err;
        }
    }

    fn run(self: *@This(), futex_ptr: *std.atomic.Value(u32)) void {
        var listen_result = self.address.listen(self.listen_options);
        if (listen_result) |*server| {
            self.server = server;
        } else |err| {
            self.last_error = err;
        }
        futex_ptr.store(1, .release);
        std.Thread.Futex.wake(futex_ptr, 1);
        const server = self.server orelse return;
        while (true) {
            var connection = server.accept() catch |err| {
                self.last_error = switch (err) {
                    std.net.Server.AcceptError.SocketNotListening => null,
                    else => err,
                };
                break;
            };
            self.handleConnection(&connection);
        }
        self.server = null;
    }

    pub fn stop(self: *@This()) void {
        if (self.connection) |c| {
            std.posix.shutdown(c.stream.handle, .both) catch {};
        }
        if (self.server) |s| {
            std.posix.shutdown(s.stream.handle, .both) catch {};
        }
    }

    pub fn join(self: *@This()) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    fn handleConnection(self: *@This(), connection: *std.net.Server.Connection) void {
        var read_buffer: [4096]u8 = undefined;
        var http = std.http.Server.init(connection.*, &read_buffer);
        self.connection = connection;
        while (true) {
            var request = http.receiveHead() catch {
                break;
            };
            self.handleRequest(&request) catch |err| {
                std.debug.print("{any}\n", .{err});
            };
        }
        self.connection = null;
    }

    fn handleRequest(self: *@This(), request: *std.http.Server.Request) !void {
        _ = self;
        _ = request;
    }
};
