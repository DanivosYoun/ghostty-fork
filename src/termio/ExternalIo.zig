//! ExternalIo는 PTY/fork/read-thread 없이 외부가 PTY를 소유하는 backend 구현.
//!
//! 핵심 계약:
//!   - 입력 경로: ghostty 인코더(IME·preedit·kitty keyboard 포함)가 키를
//!     인코딩한 UTF-8/escape 시퀀스를 queueWrite 로 전달하면, PTY write
//!     대신 write_input_cb 콜백으로 외부 워커에게 전달한다.
//!   - 출력 경로: 외부 워커가 ghostty_surface_inject_output 으로 raw 바이트를
//!     주입하면 기존 inject 경로(VT parser → renderer)가 처리한다.
//!     이 파일은 해당 경로를 건드리지 않는다.
//!   - resize: 외부가 PTY를 소유하므로 ioctl TIOCSWINSZ 대신
//!     resize_cb 콜백으로 cols/rows 를 전달한다. 미구현이면 no-op.

const ExternalIo = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");

const log = std.log.scoped(.io_external);

/// 외부로 인코딩된 입력 바이트를 전달하는 콜백.
/// 서명은 ghostty_runtime_write_input_cb / App.Options.write_input_cb 와 동일.
pub const WriteInputCb = *const fn (
    userdata: ?*anyopaque,
    bytes: [*]const u8,
    len: usize,
) callconv(.c) void;

/// 외부 PTY 소유자에게 resize(cols, rows)를 알리는 콜백.
pub const ResizeCb = *const fn (
    userdata: ?*anyopaque,
    cols: u16,
    rows: u16,
) callconv(.c) void;

/// ExternalIo 초기화 설정.
pub const Config = struct {
    /// 외부 입력 export 콜백. null 이면 입력이 조용히 드롭된다(개발 시 경고).
    write_input_cb: ?WriteInputCb = null,
    /// resize 알림 콜백. null 이면 no-op.
    resize_cb: ?ResizeCb = null,
    /// 두 콜백에 전달되는 per-surface 유저데이터.
    userdata: ?*anyopaque = null,
};

/// ExternalIo 인스턴스 — 현재 콜백 포인터만 보관한다.
write_input_cb: ?WriteInputCb,
resize_cb: ?ResizeCb,
userdata: ?*anyopaque,

pub fn init(_: Allocator, cfg: Config) !ExternalIo {
    return .{
        .write_input_cb = cfg.write_input_cb,
        .resize_cb = cfg.resize_cb,
        .userdata = cfg.userdata,
    };
}

pub fn deinit(_: *ExternalIo) void {
    // 소유한 리소스가 없으므로 no-op.
}

/// initTerminal: exec 와 달리 PTY 가 없으므로 아무것도 하지 않는다.
pub fn initTerminal(_: *ExternalIo, _: *terminal.Terminal) void {}

/// threadEnter: PTY/fork/read-thread 전부 없음 — 최소 상태 설정만.
pub fn threadEnter(
    self: *ExternalIo,
    _: Allocator,
    _: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    // backend thread-data 를 external_io variant 로 설정한다.
    td.backend = .{ .external_io = .{
        .write_input_cb = self.write_input_cb,
        .resize_cb = self.resize_cb,
        .userdata = self.userdata,
    } };
    log.debug("external_io threadEnter: PTY-less surface ready", .{});
}

/// threadExit: no-op — 정리할 스레드/fd 가 없다.
pub fn threadExit(_: *ExternalIo, _: *termio.Termio.ThreadData) void {}

/// focusGained: termios timer 가 없으므로 no-op.
pub fn focusGained(
    _: *ExternalIo,
    _: *termio.Termio.ThreadData,
    _: bool,
) !void {}

/// resize: 외부 PTY 소유자에게 cols/rows 를 콜백으로 전달.
pub fn resize(
    self: *ExternalIo,
    grid_size: renderer.GridSize,
    _: renderer.ScreenSize,
) !void {
    // TODO(P3): resize_cb 를 td 에서 가져오는 것이 맞지만, resize 는
    // Termio.init 에서 backend.initTerminal 전에도 불릴 수 있으므로
    // self 에 저장된 콜백을 사용한다.
    if (self.resize_cb) |cb| {
        cb(self.userdata, grid_size.columns, grid_size.rows);
    } else {
        log.debug(
            "external_io resize: no resize_cb, cols={} rows={} (no-op)",
            .{ grid_size.columns, grid_size.rows },
        );
    }
}

/// queueWrite: PTY write 대신 write_input_cb 콜백으로 인코딩된 바이트 전달.
/// linefeed=true 이면 exec 와 동일하게 \r → \r\n 변환 후 전달한다.
pub fn queueWrite(
    _: *ExternalIo,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    const ext = &td.backend.external_io;

    const cb = ext.write_input_cb orelse {
        log.warn("external_io queueWrite: no write_input_cb, dropping {} bytes", .{data.len});
        return;
    };

    if (!linefeed) {
        // 변환 불필요 — 직접 전달.
        cb(ext.userdata, data.ptr, data.len);
        return;
    }

    // linefeed=true: \r → \r\n 변환이 필요. 임시 버퍼에 변환 후 전달.
    // 최대 2배 크기(모든 바이트가 \r인 경우)로 충분하다.
    const buf = try alloc.alloc(u8, data.len * 2);
    defer alloc.free(buf);

    var j: usize = 0;
    for (data) |ch| {
        if (ch == '\r') {
            buf[j] = '\r';
            buf[j + 1] = '\n';
            j += 2;
        } else {
            buf[j] = ch;
            j += 1;
        }
    }
    cb(ext.userdata, buf.ptr, j);
}

/// childExitedAbnormally: 외부가 프로세스를 소유하므로 no-op.
pub fn childExitedAbnormally(
    _: *ExternalIo,
    _: Allocator,
    _: *terminal.Terminal,
    _: u32,
    _: u64,
) !void {}

/// ThreadData: thread-local 상태. exec 와 달리 스트림·타이머 없음.
pub const ThreadData = struct {
    write_input_cb: ?WriteInputCb,
    resize_cb: ?ResizeCb,
    userdata: ?*anyopaque,

    pub fn deinit(_: *ThreadData, _: Allocator) void {}
};
