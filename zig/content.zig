const std = @import("std");
const assert = std.debug.assert;

pub const Directory = struct {
    path: []const u8,
    filter: ContentFilter,
    source: ContentSource,
};

pub const ContentFilter = struct {
    host: ?[]const u8 = null,
    language: ?[]const u8 = null,
};

pub const ContentSource = union(enum) {
    static: StaticSource,
    dynamic: DynamicSource,
};

pub const StaticSource = struct {
    fs_path: []const u8,
};

pub const DynamicSource = struct {
    fs_path: ?[]const u8,
    fallback: Fallback,
};

pub const Fallback = union(enum) {
    location: ServerLocation,
};

pub const ServerLocation = struct {
    name: []const u8,
    port: u16 = 80,
};

pub const ContentError = error{
    invalid_path,
    duplicate_mapping,
    no_such_directory,
    not_found,
};

const Node = struct {
    name: []const u8,
    last_child: ?*Node = null,
    prev_sibling: ?*Node = null,
    source: ?*ContentSource = null,
};

const ParsedUri = struct {
    path: []const u8,
    query: []const u8,

    fn init(allocator: std.mem.Allocator, uri: []const u8) !ParsedUri {
        if (std.mem.indexOfScalar(u8, uri, '?')) |index| {
            return .{ .path = uri[0..index], .query = try normalize(allocator, uri[index..]) };
        } else {
            return .{ .path = uri, .query = "" };
        }
    }

    fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        if (self.query.len != 0) {
            allocator.free(self.query);
        }
    }

    fn normalize(allocator: std.mem.Allocator, query: []const u8) ![]const u8 {
        // found the value pairs and sort them
        const amp_count = count: {
            var n: usize = 0;
            for (query) |c| {
                if (c == '&') n += 1;
            }
            break :count n;
        };
        const pairs = try allocator.alloc([]const u8, amp_count + 1);
        defer allocator.free(pairs);
        var it = std.mem.splitScalar(u8, query[1..], '&');
        pairs[0] = it.first();
        var i: usize = 1;
        while (it.next()) |p| : (i += 1) pairs[i] = p;
        const string_sorter = struct {
            fn compare(_: void, lhs: []const u8, rhs: []const u8) bool {
                return std.mem.order(u8, lhs, rhs) == .lt;
            }
        };
        std.mem.sort([]const u8, pairs, {}, string_sorter.compare);
        // reconstruct the query, replacing initial ? with &
        const normalized = try allocator.alloc(u8, query.len);
        i = 0;
        for (pairs) |p| {
            normalized[i] = '&';
            const si = i + 1;
            const ei = si + p.len;
            std.mem.copyForwards(u8, normalized[si..ei], p);
            i = ei;
        }
        return normalized;
    }
};

test "ParsedUri.init" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const result1 = try ParsedUri.init(allocator, "/hello");
    assert(std.mem.eql(u8, result1.path, "/hello"));
    const result2 = try ParsedUri.init(allocator, "/hello?x=456&b=8&a=123");
    assert(std.mem.eql(u8, result2.path, "/hello"));
    assert(std.mem.eql(u8, result2.query, "&a=123&b=8&x=456"));
    result1.deinit(allocator);
    result2.deinit(allocator);
    assert(gpa.detectLeaks() == false);
}

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

    pub fn findContent(self: *const @This(), allocator: std.mem.Allocator, uri: []const u8) !void {
        const req = try ParsedUri.init(allocator, uri);
        defer req.deinit(allocator);
        const res = self.findContentSource(req.path) orelse return ContentError.not_found;
        switch (res.source) {
            .dynamic => |d| {
                if (d.fs_path) |fp| {
                    const cache_path = try std.fmt.allocPrint(allocator, "{s}/{s}{s}.http", .{ fp, req.path, req.query });
                }
            },
            .static => |s| {},
        }
    }

    fn loadCacheFile(path: []const u8) !std.fs.File {
        if (std.fs.openFileAbsolute(path, .{})) |file| {
            const header = extern struct {
                content_size: usize,
                response_size: usize,
            };
        } else |_| {}
    }

    // fn sendStaticContent(allocator: std.mem.Allocator, src: *const ContentSource, req: ParsedUri, stream: std.net.stream) !void {}

    const FindContentSourceResult = struct {
        source: *const ContentSource,
        path: []const u8,
    };

    fn findContentSource(self: *const @This(), path: []const u8) ?FindContentSourceResult {
        var parent: ?*Node = null;
        var si: usize = 0;
        var i: usize = 0;
        const ei = if (path[path.len - 1] == '/') path.len - 1 else path.len;
        while (i <= ei) : (i += 1) {
            if (i == ei or path[i] == '/') {
                const name = path[si..i];
                if (self.findChild(parent, name)) |child| {
                    parent = child;
                } else {
                    break;
                }
                si = i + 1;
            }
        }
        if (parent) |p| {
            if (p.source) |s| {
                return .{ .source = s, .path = path[si..] };
            }
        }
        return null;
    }

    pub fn addDirectory(self: *@This(), dir: Directory) !void {
        const path = dir.path;
        var parent: ?*Node = null;
        var si: usize = 0;
        var i: usize = 0;
        const ei = if (path[path.len - 1] == '/') path.len - 1 else path.len;
        while (i <= ei) : (i += 1) {
            if (i == ei or path[i] == '/') {
                const name = path[si..i];
                if (self.findChild(parent, name)) |child| {
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
            if (p.source) |_| {
                return ContentError.duplicate_mapping;
            } else {
                const src = try self.allocator.create(ContentSource);
                src.* = switch (dir.source) {
                    .static => |s| .{
                        .static = .{
                            .fs_path = try self.allocator.dupe(u8, s.fs_path),
                        },
                    },
                    .dynamic => |d| .{
                        .dynamic = .{
                            .fs_path = if (d.fs_path) |fp| try self.allocator.dupe(u8, fp) else null,
                            .fallback = switch (d.fallback) {
                                .location => |loc| .{
                                    .location = .{
                                        .name = try self.allocator.dupe(u8, loc.name),
                                        .port = loc.port,
                                    },
                                },
                            },
                        },
                    },
                };
                p.source = src;
            }
        } else {
            return ContentError.invalid_path;
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
            const prev_sibling = child.?.prev_sibling;
            self.freeNode(child.?);
            child = prev_sibling;
        }
        if (node.source) |src| {
            switch (src.*) {
                .static => |s| self.allocator.free(s.fs_path),
                .dynamic => |d| {
                    if (d.fs_path) |fp| self.allocator.free(fp);
                    switch (d.fallback) {
                        .location => |loc| self.allocator.free(loc.name),
                    }
                },
            }
            self.allocator.destroy(src);
        }
        self.allocator.destroy(node);
    }
};

test "ServerContent.addDirectory" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var content = try ServerContent.init(allocator);
    const s1: Directory = .{
        .path = "/hello/world",
        .source = .{
            .static = .{
                .fs_path = "/home/website/hello",
            },
        },
    };
    try content.addDirectory(s1);
    assert(content.root.last_child != null);
    const first = content.root.last_child.?;
    assert(std.mem.eql(u8, first.name, "hello"));
    assert(first.prev_sibling == null);
    assert(first.last_child != null);
    assert(first.source == null);
    const second = first.last_child.?;
    assert(second.prev_sibling == null);
    assert(second.last_child == null);
    assert(second.source != null);
    assert(std.mem.eql(u8, second.source.?.static.fs_path, "/home/website/hello"));
    const s2: Directory = .{
        .path = "/hello/kitty/",
        .source = .{
            .dynamic = .{
                .fs_path = "/tmp/cache",
                .fallback = .{
                    .location = .{ .name = "127.0.0.1", .port = 8000 },
                },
            },
        },
    };
    try content.addDirectory(s2);
    const third = first.last_child.?;
    assert(third != second);
    assert(third.prev_sibling.? == second);
    assert(third.last_child == null);
    assert(third.source != null);
    assert(std.mem.eql(u8, third.source.?.dynamic.fs_path.?, "/tmp/cache"));
    assert(third.source.?.dynamic.fs_path != null);
    assert(std.mem.eql(u8, third.source.?.dynamic.fallback.location.name, "127.0.0.1"));
    assert(third.source.?.dynamic.fallback.location.port == 8000);
    if (content.addDirectory(s1)) |_| assert(false) else |_| {}
    const s3: Directory = .{
        .path = "candies",
        .source = .{
            .static = .{
                .fs_path = "/home/website/hello",
            },
        },
    };
    if (content.addDirectory(s3)) |_| assert(false) else |_| {}
}

test "ServerContent.findContentSource" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var content = try ServerContent.init(allocator);
    const s1: Directory = .{
        .path = "/hello/world",
        .source = .{
            .static = .{
                .fs_path = "/home/website/hello",
            },
        },
    };
    try content.addDirectory(s1);
    const s2: Directory = .{
        .path = "/hello/kitty/",
        .source = .{
            .dynamic = .{
                .fs_path = "/tmp/cache",
                .fallback = .{
                    .location = .{ .name = "127.0.0.1", .port = 8000 },
                },
            },
        },
    };
    try content.addDirectory(s2);
    const result1 = content.findContentSource("/hello/world/chicken");
    assert(result1 != null);
    assert(std.mem.eql(u8, result1.?.source.static.fs_path, "/home/website/hello"));
    assert(std.mem.eql(u8, result1.?.path, "chicken"));
    const result2 = content.findContentSource("/hello/kitty/something/else/index");
    assert(result2 != null);
    assert(std.mem.eql(u8, result2.?.source.dynamic.fs_path.?, "/tmp/cache"));
    assert(std.mem.eql(u8, result2.?.path, "something/else/index"));
    const result3 = content.findContentSource("/hello");
    assert(result3 == null);
    const result4 = content.findContentSource("/hello/dingo");
    assert(result4 == null);
}

test "ServerContent.deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var content = try ServerContent.init(allocator);
    const s1: Directory = .{
        .path = "/hello/world",
        .source = .{
            .static = .{
                .fs_path = "/home/website/hello",
            },
        },
    };
    try content.addDirectory(s1);
    const s2: Directory = .{
        .path = "/hello/kitty/",
        .source = .{
            .dynamic = .{
                .fs_path = "/tmp/cache",
                .fallback = .{
                    .location = .{ .name = "127.0.0.1", .port = 8000 },
                },
            },
        },
    };
    try content.addDirectory(s2);
    content.deinit();
    assert(gpa.detectLeaks() == false);
}
