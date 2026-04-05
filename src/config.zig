const std = @import("std");
const httpz = @import("httpz.zig");
const request = @import("request.zig");
const response = @import("response.zig");

const posix = std.posix;

pub const Address = extern union {
    any: posix.sockaddr,
    in: posix.sockaddr.in,
    in6: posix.sockaddr.in6,
    un: posix.sockaddr.un,

    pub fn initIp4(addr: [4]u8, port: u16) Address {
        return .{ .in = .{
            .port = std.mem.nativeToBig(u16, port),
            .addr = @bitCast(addr),
        } };
    }

    pub fn initIp6(addr: [16]u8, port: u16) Address {
        return .{ .in6 = .{
            .port = std.mem.nativeToBig(u16, port),
            .flowinfo = 0,
            .addr = addr,
            .scope_id = 0,
        } };
    }

    pub fn parseIp(text: []const u8, port: u16) !Address {
        return parseIp4(text, port) catch parseIp6(text, port);
    }

    fn parseIp4(text: []const u8, port: u16) !Address {
        var addr: [4]u8 = undefined;
        var octet: u16 = 0;
        var octet_count: u8 = 0;
        var saw_digit = false;
        for (text) |c| {
            if (c == '.') {
                if (!saw_digit or octet_count >= 3) return error.InvalidAddress;
                addr[octet_count] = @intCast(octet);
                octet_count += 1;
                octet = 0;
                saw_digit = false;
            } else if (c >= '0' and c <= '9') {
                octet = octet * 10 + (c - '0');
                if (octet > 255) return error.InvalidAddress;
                saw_digit = true;
            } else {
                return error.InvalidAddress;
            }
        }
        if (!saw_digit or octet_count != 3) return error.InvalidAddress;
        addr[3] = @intCast(octet);
        return initIp4(addr, port);
    }

    fn parseIp6(_: []const u8, _: u16) !Address {
        return error.InvalidAddress;
    }

    pub fn initUnix(path: []const u8) !Address {
        var addr: Address = .{ .un = undefined };
        addr.un.family = posix.AF.UNIX;
        if (path.len >= addr.un.path.len) return error.NameTooLong;
        @memcpy(addr.un.path[0..path.len], path);
        if (path.len < addr.un.path.len) {
            addr.un.path[path.len] = 0;
        }
        return addr;
    }

    pub fn getOsSockLen(self: Address) posix.socklen_t {
        return switch (self.any.family) {
            posix.AF.INET => @sizeOf(posix.sockaddr.in),
            posix.AF.INET6 => @sizeOf(posix.sockaddr.in6),
            posix.AF.UNIX => @sizeOf(posix.sockaddr.un),
            else => @sizeOf(posix.sockaddr.storage),
        };
    }
};

pub const Config = struct {
    address: AddressConfig = .localhost(5882),
    workers: Worker = .{},
    request: Request = .{},
    response: Response = .{},
    timeout: Timeout = .{},
    thread_pool: ThreadPool = .{},
    websocket: Websocket = .{},

    pub const AddressConfig = union(enum) {
        ip: IpAddress,
        unix: []const u8,
        addr: Address,

        pub fn localhost(port: u16) AddressConfig {
            return .{ .addr = .initIp4(.{ 127, 0, 0, 1 }, port) };
        }

        pub fn all(port: u16) AddressConfig {
            return .{ .addr = .initIp4(.{ 0, 0, 0, 0 }, port) };
        }
    };

    pub const IpAddress = struct {
        host: []const u8,
        port: u16,
    };

    pub const ThreadPool = struct {
        count: ?u16 = null,
        backlog: ?u32 = null,
        buffer_size: ?usize = null,
    };

    pub const Worker = struct {
        count: ?u16 = null,
        max_conn: ?u16 = null,
        min_conn: ?u16 = null,
        large_buffer_count: ?u16 = null,
        large_buffer_size: ?u32 = null,
        retain_allocated_bytes: ?usize = null,
    };

    pub const Request = struct {
        lazy_read_size: ?usize = null,
        max_body_size: ?usize = null,
        buffer_size: ?usize = null,
        max_header_count: ?usize = null,
        max_param_count: ?usize = null,
        max_query_count: ?usize = null,
        max_form_count: ?usize = null,
        max_multiform_count: ?usize = null,
    };

    pub const Response = struct {
        max_header_count: ?usize = null,
    };

    pub const Timeout = struct {
        request: ?u32 = null,
        keepalive: ?u32 = null,
        request_count: ?usize = null,
    };

    pub const Websocket = struct {
        max_message_size: ?usize = null,
        small_buffer_size: ?usize = null,
        small_buffer_pool: ?usize = null,
        large_buffer_size: ?usize = null,
        large_buffer_pool: ?u16 = null,
        compression: bool = false,
        compression_retain_writer: bool = true,
        compression_write_treshold: ?usize = null,
    };

    pub fn parseAddress(self: *const Config) !Address {
        return switch (self.address) {
            .ip => |i| try .parseIp(i.host, i.port),
            .unix => |unix_path| b: {
                if (comptime std.Io.net.has_unix_sockets == false) {
                    break :b error.UnixPathNotSupported;
                }
                // Best-effort cleanup of existing socket file
                var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                if (unix_path.len < path_buf.len) {
                    @memcpy(path_buf[0..unix_path.len], unix_path);
                    path_buf[unix_path.len] = 0;
                    _ = posix.system.unlink(@ptrCast(path_buf[0..unix_path.len :0]));
                }
                break :b try .initUnix(unix_path);
            },
            .addr => |a| a,
        };
    }

    pub fn isUnixAddress(config: *const Config) bool {
        return switch (config.address) {
            .unix => true,
            .ip => false,
            .addr => |a| a.any.family == std.posix.AF.UNIX,
        };
    }

    pub fn threadPoolCount(self: *const Config) u32 {
        return self.thread_pool.count orelse 32;
    }

    pub fn workerCount(self: *const Config) u32 {
        if (httpz.blockingMode()) {
            return 1;
        }
        return self.workers.count orelse 1;
    }
};
