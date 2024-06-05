const std = @import("std");

const ServerThread = @import("./thread.zig").ServerThread;
const ServerContent = @import("./content.zig").ServerContent;
const StaticDirectory = @import("./content.zig").StaticDirectory;
const DynamicDirectory = @import("./content.zig").DynamicDirectory;

const Server = struct {
    threads: []ServerThread,
    allocator: std.mem.Allocator,
    content: *ServerContent,

    pub fn init(allocator: std.mem.Allocator, options: ServerOptions) !Server {
        const address = try std.net.Address.resolveIp(options.ip, options.port);
        const threads = try allocator.alloc(ServerThread, options.thread_count);
        errdefer allocator.free(threads);
        const listen_options = .{ .reuse_address = true };
        const content = try allocator.create(ServerContent);
        content.* = ServerContent.init(allocator);
        for (threads) |*thread| {
            thread.* = ServerThread.init(address, listen_options, content);
        }
        return .{ .threads = threads, .content = content, .allocator = allocator };
    }

    pub fn deinit(self: @This()) void {
        self.allocator.free(self.threads);
        self.content.deinit();
        self.allocator.destroy(self.content);
    }

    pub fn start(self: *@This()) !void {
        errdefer self.stop();
        for (self.threads) |*thread| {
            try thread.spawn();
        }
    }

    pub fn stop(self: *@This()) void {
        for (self.threads) |*thread| {
            thread.stop();
        }
        for (self.threads) |*thread| {
            thread.join();
        }
    }
};

const ServerOpaque = opaque {};
const ServerOpaquePointer = *align(@alignOf(Server)) ServerOpaque;
const ServerOptions = struct {
    ip: []const u8,
    port: u16 = 80,
    thread_count: usize = 1,
};

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

pub fn startServer(options: ServerOptions) !ServerOpaquePointer {
    const allocator = gpa.allocator();
    const server = try allocator.create(Server);
    errdefer allocator.destroy(server);
    server.* = try Server.init(allocator, options);
    errdefer server.deinit();
    try server.start();
    return @ptrCast(server);
}

pub fn stopServer(opaque_ptr: ServerOpaquePointer) void {
    const allocator = gpa.allocator();
    const server: *Server = @ptrCast(opaque_ptr);
    server.stop();
    server.deinit();
    allocator.destroy(server);
}

pub fn addStaticDirectory(opaque_ptr: ServerOpaquePointer, dir: StaticDirectory) !void {
    const server: *Server = @ptrCast(opaque_ptr);
    server.content.addDirectory(dir);
}

pub fn addDynamicDirectory(opaque_ptr: ServerOpaquePointer, dir: DynamicDirectory) !void {
    const server: *Server = @ptrCast(opaque_ptr);
    server.content.addDirectory(dir);
}
