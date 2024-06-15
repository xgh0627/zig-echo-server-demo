const std = @import("std");
const net = std.net;
const builtin = @import("builtin");
const windows = std.os.windows;

const port = 8080;

/// windows context 定义
const windows_context = struct {
    const POLLIN: i16 = 0x0100;
    const POLLERR: i16 = 0x0001;
    const POLLHUP: i16 = 0x0002;
    const POLLNVAL: i16 = 0x0004;
    const INVALID_SOCKET = windows.ws2_32.INVALID_SOCKET;
};

/// linux context 定义
const linux_context = struct {
    const POLLIN: i16 = 0x0001;
    const POLLERR: i16 = 0x0008;
    const POLLHUP: i16 = 0x0010;
    const POLLNVAL: i16 = 0x0020;
    const INVALID_SOCKET = -1;
};

/// macOS context 定义
const macos_context = struct {
    const POLLIN: i16 = 0x0001;
    const POLLERR: i16 = 0x0008;
    const POLLHUP: i16 = 0x0010;
    const POLLNVAL: i16 = 0x0020;
    const INVALID_SOCKET = -1;
};

const context = switch (builtin.os.tag) {
    .windows => windows_context,
    .linux => linux_context,
    .macos => macos_context,
    else => @compileError("umsupported os"),
};

pub fn main() !void {
    const address = try net.Address.parseIp4("127.0.0.1", port);
    var server = try address.listen(.{ .reuse_port = true });
    defer server.deinit();

    //定义最大连接数
    const max_sockets = 1000;
    var buf: [1024]u8 = std.mem.zeroes([1024]u8);
    var connections: [max_sockets]?net.Server.Connection = undefined;
    var sockfds: [max_sockets]if (builtin.os.tag == .windows) windows.ws2_32.pollfd else std.posix.pollfd = undefined;

    for (1..max_sockets) |i| {
        sockfds[i].fd = context.INVALID_SOCKET;
        sockfds[i].events = context.POLLIN;
        connections[i] = null;
    }

    sockfds[0].fd = server.stream.handle;

    std.log.info("start listening as {d}...", .{port});

    while (true) {
        var nums = if (builtin.os.tag == .windows) windows.poll(&sockfds, max_sockets, -1) else try std.posix.poll(&sockfds, -1);
        if (nums == 0) {
            continue;
        }
        if (nums < 0) {
            @panic("An eror occrred in poll");
        }
        for (1..max_sockets) |i| {
            if (nums == 0) {
                break;
            }
            const sockfd = sockfds[i];
            if (sockfd.fd == context.INVALID_SOCKET) {
                continue;
            }
            defer if (sockfd.revents != 0) {
                nums -= 1;
            };
            if (sockfd.revents & (context.POLLIN) != 0) {
                const client = connections[i];
                if (client) |connection| {
                    const len = try connection.stream.read(&buf);
                    if (len == 0) {
                        // 但为了保险起见，我们还是调用 close
                        // 因为有可能是连接没有断开，但是出现了错误
                        connection.stream.close();
                        // 将 pollfd 和 connection 置为无效
                        sockfds[i].fd = context.INVALID_SOCKET;
                        std.log.info("client from {any} close!", .{
                            connection.address,
                        });
                        connections[i] = null;
                    } else {
                        // 如果读取到了数据，那么将数据写回去
                        // 但仅仅这样写一次并不安全
                        // 最优解应该是使用for循环检测写入的数据大小是否等于buf长度
                        // 如果不等于就继续写入
                        // 这是因为 TCP 是一个面向流的协议，它并不保证一次 write 调用能够发送所有的数据
                        // 作为示例，我们不检查是否全部写入
                        _ = try connection.stream.write(buf[0..len]);
                    }
                }
            } // 检查是否是 POLLNVAL | POLLERR | POLLHUP 事件，即是否有错误发生，或者连接断开
            else if (sockfd.revents & (context.POLLNVAL | context.POLLERR | context.POLLHUP) != 0) {
                // 将 pollfd 和 connection 置为无效
                sockfds[i].fd = context.INVALID_SOCKET;
                connections[i] = null;
                std.log.info("client {} close", .{i});
            }
        }
        if (sockfds[0].revents & context.POLLIN != 0 and nums > 0) {
            std.log.info("new client", .{});
            // 如果有新的连接，那么调用 accept
            const client = try server.accept();
            for (1..max_sockets) |i| {
                // 找到一个空的 pollfd，将新的连接放进去
                if (sockfds[i].fd == context.INVALID_SOCKET) {
                    sockfds[i].fd = client.stream.handle;
                    connections[i] = client;
                    std.log.info("new client {} comes", .{i});
                    break;
                }
                // 如果没有找到空的 pollfd，那么说明连接数已经达到了最大值
                if (i == max_sockets - 1) {
                    @panic("too many clients");
                }
            }
        }
    }
    if (builtin.os.tag == .windows) {
        try windows.ws2_32.WSACleanup();
    }
}
