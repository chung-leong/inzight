const std = @import("std");
const assert = std.debug.assert;

pub const StaticDirectory = struct {
    path: []const u8,
    fs_path: []const u8,
};

pub const ServerLocation = struct {
    ip: []const u8,
    port: u16 = 80,
};

pub const Fallback = union(enum) {
    location: ServerLocation,
};

pub const DynamicDirectory = struct {
    path: []const u8,
    fs_path: ?[]const u8,
    fallback: Fallback,
};

pub const VFSError = error{
    invalid_path,
    duplicate_mapping,
};

const FallbackImpl = union(enum) {
    address: std.net.Address,
};

const Directory = struct {
    is_dynamic: bool,
    fs_path: ?[]const u8 = null,
    fallback: ?FallbackImpl = null,
};

const Node = struct {
    name: []const u8,
    active: bool = true,
    last_child: ?*Node = null,
    prev_sibling: ?*Node = null,
    directory: ?*Directory = null,
};

const FindDirectoryResult = struct {
    directory: *const Directory,
    path: []const u8,
};

pub const ServerContent = struct {
    allocator: std.mem.Allocator,
    root: *Node,

    pub fn init(allocator: std.mem.Allocator) !@This() {
        const root = try allocator.create(Node);
        root.* = .{
            .name = try allocator.dupe(u8, ""),
        };
        return .{
            .allocator = allocator,
            .root = root,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.freeNode(self.root);
    }

    pub fn findDirectory(self: *const @This(), path: []const u8) ?FindDirectoryResult {
        var parent: ?*Node = null;
        var si: usize = 0;
        var i: usize = 0;
        const ei = if (path[path.len - 1] == '/') path.len - 1 else path.len;
        while (i <= ei) : (i += 1) {
            if (i == ei or path[i] == '/') {
                const name = path[si..i];
                if (self.findChild(parent, name)) |child| {
                    if (child.active) {
                        parent = child;
                    } else {
                        break;
                    }
                } else {
                    break;
                }
                si = i + 1;
            }
        }
        if (parent) |p| {
            if (p.directory) |d| {
                return .{ .directory = d, .path = path[si..] };
            }
        }
        return null;
    }

    pub fn addDirectory(self: *@This(), arg: anytype) !void {
        const path = arg.path;
        var parent: ?*Node = null;
        var si: usize = 0;
        var i: usize = 0;
        const ei = if (path[path.len - 1] == '/') path.len - 1 else path.len;
        while (i <= ei) : (i += 1) {
            if (i == ei or path[i] == '/') {
                const name = path[si..i];
                if (self.findChild(parent, name)) |child| {
                    child.active = true;
                    parent = child;
                } else {
                    if (parent) |p| {
                        const child = try self.allocator.create(Node);
                        child.* = .{ .name = try self.allocator.dupe(u8, name), .prev_sibling = p.last_child };
                        p.last_child = child;
                        parent = child;
                    } else {
                        break;
                    }
                }
                si = i + 1;
            }
        }
        if (parent) |p| {
            if (p.directory) |_| {
                return VFSError.duplicate_mapping;
            } else {
                const directory = try self.allocator.create(Directory);
                directory.* = .{ .is_dynamic = @TypeOf(arg) == DynamicDirectory };
                const fs_path: ?[]const u8 = arg.fs_path;
                if (fs_path) |fp| {
                    directory.fs_path = try self.allocator.dupe(u8, fp);
                }
                if (@TypeOf(arg) == DynamicDirectory) {
                    directory.fallback = switch (arg.fallback) {
                        .location => |loc| .{
                            .address = try std.net.Address.resolveIp(loc.ip, loc.port),
                        },
                    };
                }
                p.directory = directory;
            }
        } else {
            return VFSError.invalid_path;
        }
    }

    fn findChild(self: *const @This(), parent: ?*Node, name: []const u8) ?*Node {
        if (parent) |p| {
            var child = p.last_child;
            return while (child != null) : (child = child.?.prev_sibling) {
                if (std.mem.eql(u8, child.?.name, name)) {
                    break child;
                }
            } else null;
        } else {
            return if (name.len == 0) self.root else null;
        }
    }

    fn freeNode(self: *@This(), node: *Node) void {
        var child = node.last_child;
        self.allocator.free(node.name);
        while (child != null) {
            const prev_sibling = child.prev_sibling;
            self.freeNode(child.?);
            child = prev_sibling;
        }
        if (node.directory) |d| {
            self.allocator.free(d.fs_path);
            self.allocator.destroy(d);
        }
        self.allocator.destroy(node);
    }
};

test "ServerContent.addDirectory" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var content = try ServerContent.init(allocator);
    const s1: StaticDirectory = .{
        .path = "/hello/world",
        .fs_path = "/home/website/hello",
    };
    try content.addDirectory(s1);
    assert(content.root.last_child != null);
    const first = content.root.last_child.?;
    assert(std.mem.eql(u8, first.name, "hello"));
    assert(first.prev_sibling == null);
    assert(first.last_child != null);
    assert(first.directory == null);
    assert(first.active == true);
    const second = first.last_child.?;
    assert(second.prev_sibling == null);
    assert(second.last_child == null);
    assert(second.directory != null);
    assert(second.active == true);
    assert(std.mem.eql(u8, second.directory.?.fs_path.?, "/home/website/hello"));
    assert(second.directory.?.is_dynamic == false);
    const s2: DynamicDirectory = .{
        .path = "/hello/kitty/",
        .fs_path = "/tmp/cache",
        .fallback = .{
            .location = .{ .ip = "127.0.0.1", .port = 8000 },
        },
    };
    try content.addDirectory(s2);
    const third = first.last_child.?;
    assert(third != second);
    assert(third.prev_sibling.? == second);
    assert(third.last_child == null);
    assert(third.directory != null);
    assert(third.active == true);
    assert(std.mem.eql(u8, third.directory.?.fs_path.?, "/tmp/cache"));
    assert(third.directory.?.is_dynamic == true);
    assert(third.directory.?.fallback != null);
    assert(third.directory.?.fallback.?.address.getPort() == 8000);
    if (content.addDirectory(s1)) |_| assert(false) else |_| {}
    const s3: StaticDirectory = .{
        .path = "candies",
        .fs_path = "/home/website/hello",
    };
    if (content.addDirectory(s3)) |_| assert(false) else |_| {}
}

test "ServerContent.findDirectory" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var content = try ServerContent.init(allocator);
    const s1: StaticDirectory = .{
        .path = "/hello/world",
        .fs_path = "/home/website/hello",
    };
    try content.addDirectory(s1);
    const s2: DynamicDirectory = .{
        .path = "/hello/kitty/",
        .fs_path = "/tmp/cache",
        .fallback = .{
            .location = .{ .ip = "127.0.0.1", .port = 8000 },
        },
    };
    try content.addDirectory(s2);
    const result1 = content.findDirectory("/hello/world/chicken");
    assert(result1 != null);
    assert(std.mem.eql(u8, result1.?.directory.fs_path.?, "/home/website/hello"));
    assert(std.mem.eql(u8, result1.?.path, "chicken"));
}
