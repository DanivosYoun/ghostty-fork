//! SearchDocument is an immutable UTF-8 snapshot of a screen's retained
//! text (scrollback + active area) for searching outside the terminal
//! (external search UIs, bridges, etc).
//!
//! Text rules:
//!
//!   - Every physical row without the soft-wrap flag ends in a single "\n".
//!   - Rows with the soft-wrap flag are joined to the next row with no
//!     separator, so a wrapped logical line is contiguous in `text`.
//!   - Trailing blank cells of a hard line are trimmed; blank cells in the
//!     middle of a line become spaces. Wide-character spacers are skipped.
//!     What a blank cell is is defined by `isBlankCell`; notably a space
//!     that carries combining marks is text, not blank.
//!   - Grapheme clusters are emitted whole (base codepoint + extensions).
//!
//! The row map records physical identity and row-local byte ranges. Pins are
//! untracked: after capture their node pointers may only be compared, never
//! dereferenced. Content and serial are copied while the terminal lock is held.
//! The same Walker supplies capture, hashing, and byte-to-column conversion.
const SearchDocument = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const hyperlink = @import("hyperlink.zig");
const Cell = @import("page.zig").Cell;
const Page = @import("page.zig").Page;
const PageList = @import("PageList.zig");
const Pin = PageList.Pin;
const Screen = @import("Screen.zig");
const Terminal = @import("Terminal.zig");

/// One physical row of the screen.
pub const Row = struct {
    /// Byte range of `text` produced by this row: [start, end). Includes
    /// the trailing "\n" if the row is not soft-wrapped.
    start: usize,
    end: usize,

    /// First cell of the row. Untracked; see the lifetime note above.
    pin: Pin,
    serial: u64,
    hash: u64,
    byte_len: usize,
};

/// A hyperlink span over `text`: [start, end).
pub const Link = struct {
    start: usize,
    end: usize,
    uri: []const u8,

    /// The explicit OSC 8 id, if one was provided.
    id: ?[]const u8,
};

alloc: Allocator,
text: []const u8,
rows: []const Row,
links: []const Link,

/// A hyperlink span still being extended during capture. The link data
/// is borrowed from page memory and only valid during `capture`.
const Open = struct {
    start: usize,
    end: usize,
    link: hyperlink.Hyperlink,
};

/// A half-open byte range [start, end) of `text`.
pub const Range = struct {
    start: usize,
    end: usize,
};

/// A run of equal pending blank cells (see `capture`).
const BlankRun = struct {
    link: ?hyperlink.Hyperlink,
    count: usize,
};

/// Whether a cell is blank in the document's terms: it produces a space
/// only when text follows it on the same logical line, and is trimmed
/// otherwise. A cell with no text or whose only codepoint is U+0020 is
/// blank. A U+0020 base that carries grapheme extensions (combining marks)
/// is text: dropping it would lose the marks.
///
/// This is the single definition of the rule, shared by `capture` and by
/// anything that maps document bytes back to cells by re-walking rows
/// (the walk must apply exactly the emitter's rules).
pub fn isBlankCell(cell: *const Cell) bool {
    if (!cell.hasText()) return true;
    return cell.codepoint() == ' ' and cell.content_tag != .codepoint_grapheme;
}

/// The number of UTF-8 bytes `capture` emits for a codepoint (invalid
/// codepoints are replaced by U+FFFD, three bytes). Shared with row
/// re-walks for the same reason as `isBlankCell`.
pub fn codepointBytes(cp: u21) usize {
    var buf: [4]u8 = undefined;
    return encodeCodepoint(cp, &buf);
}

/// A cell view borrowed while the renderer mutex is held.
pub const LiveView = struct {
    page: *const Page,
    cells: []const Cell,
    pub fn len(self: LiveView) usize {
        return self.cells.len;
    }
    pub fn raw(self: LiveView, x: usize) *const Cell {
        return &self.cells[x];
    }
    pub fn grapheme(self: LiveView, x: usize) []const u21 {
        return self.page.lookupGrapheme(&self.cells[x]) orelse &.{};
    }
};

/// A view over render-state copies; safe outside the terminal lock.
pub const RenderView = struct {
    cells: std.MultiArrayList(@import("render.zig").RenderState.Cell).Slice,
    pub fn len(self: RenderView) usize {
        return self.cells.len;
    }
    pub fn raw(self: RenderView, x: usize) *const Cell {
        return &self.cells.items(.raw)[x];
    }
    pub fn grapheme(self: RenderView, x: usize) []const u21 {
        return self.cells.items(.grapheme)[x];
    }
};

/// One walker for capture, hashing and range mapping. Wide spacers emit no
/// bytes; blanks emit a provisional space, bounded by the captured byte_len.
pub fn Walker(comptime View: type) type {
    return struct {
        view: View,
        x: usize = 0,
        pos: usize = 0,
        const Self = @This();
        pub const Token = struct {
            cell: *const Cell,
            grapheme: []const u21,
            blank: bool,
            x: usize,
            width: usize,
            start: usize,
            end: usize,
        };
        pub fn init(view: View) Self {
            return .{ .view = view };
        }
        pub fn next(self: *Self) ?Token {
            while (self.x < self.view.len()) {
                const x = self.x;
                self.x += 1;
                const cell = self.view.raw(x);
                switch (cell.wide) {
                    .spacer_head, .spacer_tail => continue,
                    else => {},
                }
                const blank = isBlankCell(cell);
                const grapheme = if (cell.content_tag == .codepoint_grapheme)
                    self.view.grapheme(x)
                else
                    &.{};
                const start = self.pos;
                self.pos += if (blank) 1 else codepointBytes(cell.codepoint());
                for (grapheme) |cp| self.pos += codepointBytes(cp);
                return .{ .cell = cell, .grapheme = grapheme, .blank = blank, .x = x, .width = if (cell.wide == .wide) 2 else 1, .start = start, .end = self.pos };
            }
            return null;
        }
    };
}

pub fn rowHash(comptime View: type, view: View, wrap: bool) u64 {
    var hash = std.hash.Wyhash.init(0);
    const cols: u64 = @intCast(view.len());
    hash.update(std.mem.asBytes(&cols));
    hash.update(&.{@intFromBool(wrap)});
    var walker = Walker(View).init(view);
    while (walker.next()) |token| {
        hash.update(&.{@intCast(token.width)});
        var buf: [4]u8 = undefined;
        const n = encodeCodepoint(if (token.blank) ' ' else token.cell.codepoint(), &buf);
        hash.update(buf[0..n]);
        for (token.grapheme) |cp| {
            const len = encodeCodepoint(cp, &buf);
            hash.update(buf[0..len]);
        }
    }
    return hash.final();
}

pub fn columns(comptime View: type, view: View, byte_len: usize, range: Range) ?[2]usize {
    var walker = Walker(View).init(view);
    var result: ?[2]usize = null;
    while (walker.next()) |token| {
        if (token.start >= byte_len or token.start >= range.end) break;
        if (token.end <= range.start) continue;
        if (result) |*r| {
            r[1] = token.x + token.width;
        } else {
            result = .{ token.x, token.x + token.width };
        }
    }
    return result;
}

/// Capture the retained text of `screen` (all scrollback and the active
/// area). The caller must hold whatever lock protects the screen for the
/// duration of the call.
pub fn capture(
    alloc: Allocator,
    screen: *const Screen,
) Allocator.Error!SearchDocument {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(alloc);
    var rows: std.ArrayList(Row) = .empty;
    errdefer rows.deinit(alloc);
    var links: std.ArrayList(Link) = .empty;
    errdefer {
        freeLinkStrings(alloc, links.items);
        links.deinit(alloc);
    }

    var open: ?Open = null;
    var line_base: usize = 0;
    var logical_bytes: usize = 0;
    var last_text_end: usize = 0;

    // Blank cells are only turned into spaces once text follows them, so
    // trailing blanks of a hard line are dropped. Blanks pending at a
    // soft-wrapped row end carry into the next row. They are kept as runs
    // of equal link so the spans over them can be decided when (if) they
    // are emitted; the link data is borrowed from page memory, which is
    // stable for the duration of this call.
    var pending: std.ArrayList(BlankRun) = .empty;
    defer pending.deinit(alloc);

    var it = screen.pages.rowIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |pin| {
        const page = &pin.node.data;
        const row = page.getRow(pin.y);
        const cells = page.getCells(row);
        const row_start = line_base + logical_bytes;
        var walker = Walker(LiveView).init(.{ .page = page, .cells = cells });
        while (walker.next()) |token| {
            const cell = token.cell;
            logical_bytes = row_start - line_base + token.end;
            if (!token.blank) last_text_end = logical_bytes;

            const link = cellLink(page, cell);

            if (isBlankCell(cell)) {
                if (pending.items.len > 0) {
                    const last = &pending.items[pending.items.len - 1];
                    if (sameOptionalLink(last.link, link)) {
                        last.count += 1;
                        continue;
                    }
                }

                try pending.append(alloc, .{ .link = link, .count = 1 });
                continue;
            }

            // Text follows: the pending blanks are emitted as spaces
            // first, and extend or close the link span like any cell.
            for (pending.items) |run| {
                const run_start = text.items.len;
                try text.appendNTimes(alloc, ' ', run.count);
                try trackLink(alloc, &links, &open, run.link, run_start, text.items.len);
            }
            pending.clearRetainingCapacity();

            const start = text.items.len;
            try appendCodepoint(alloc, &text, cell.codepoint());
            for (token.grapheme) |cp| try appendCodepoint(alloc, &text, cp);
            try trackLink(alloc, &links, &open, link, start, text.items.len);
        }

        try rows.append(alloc, .{
            .start = row_start,
            .end = line_base + logical_bytes,
            .pin = pin,
            .serial = pin.node.serial,
            .hash = rowHash(LiveView, .{ .page = page, .cells = cells }, row.wrap),
            .byte_len = walker.pos,
        });

        if (!row.wrap) {
            pending.clearRetainingCapacity();
            if (open) |o| {
                try appendLink(alloc, &links, o);
                open = null;
            }
            // Blank cells carried across a wrap belong to the physical row
            // they came from. Trim at the logical line end without consulting
            // the next row during renderer byte-to-column conversion.
            const end = line_base + last_text_end;
            var i = rows.items.len;
            while (i > 0) {
                i -= 1;
                const r = &rows.items[i];
                if (r.end <= end) break;
                r.start = @min(r.start, end);
                r.end = @min(r.end, end);
                r.byte_len = r.end - r.start;
            }
            try text.append(alloc, '\n');
            rows.items[rows.items.len - 1].end = text.items.len;
            line_base = text.items.len;
            logical_bytes = 0;
            last_text_end = 0;
        }
    }

    if (open) |o| try appendLink(alloc, &links, o);
    if (logical_bytes > last_text_end) {
        const end = line_base + last_text_end;
        var i = rows.items.len;
        while (i > 0) {
            i -= 1;
            const r = &rows.items[i];
            if (r.end <= end) break;
            r.start = @min(r.start, end);
            r.end = @min(r.end, end);
            r.byte_len = r.end - r.start;
        }
    }

    const text_owned = try text.toOwnedSlice(alloc);
    errdefer alloc.free(text_owned);
    const rows_owned = try rows.toOwnedSlice(alloc);
    errdefer alloc.free(rows_owned);
    const links_owned = try links.toOwnedSlice(alloc);

    return .{
        .alloc = alloc,
        .text = text_owned,
        .rows = rows_owned,
        .links = links_owned,
    };
}

pub fn deinit(self: *SearchDocument) void {
    freeLinkStrings(self.alloc, self.links);
    self.alloc.free(self.links);
    self.alloc.free(self.rows);
    self.alloc.free(self.text);
    self.* = undefined;
}

fn freeLinkStrings(alloc: Allocator, links: []const Link) void {
    for (links) |l| {
        alloc.free(l.uri);
        if (l.id) |id| alloc.free(id);
    }
}

fn appendLink(
    alloc: Allocator,
    links: *std.ArrayList(Link),
    open: Open,
) Allocator.Error!void {
    const uri = try alloc.dupe(u8, open.link.uri);
    errdefer alloc.free(uri);
    const id: ?[]const u8 = switch (open.link.id) {
        .explicit => |v| try alloc.dupe(u8, v),
        .implicit => null,
    };
    errdefer if (id) |v| alloc.free(v);

    try links.append(alloc, .{
        .start = open.start,
        .end = open.end,
        .uri = uri,
        .id = id,
    });
}

/// The hyperlink on a cell, borrowing from the page's memory.
fn cellLink(page: *const Page, cell: *const Cell) ?hyperlink.Hyperlink {
    if (!cell.hyperlink) return null;
    const id = page.lookupHyperlink(cell) orelse return null;
    const entry = page.hyperlink_set.get(page.memory, id);
    return .{
        .id = switch (entry.id) {
            .explicit => |v| .{ .explicit = v.slice(page.memory) },
            .implicit => |v| .{ .implicit = v },
        },
        .uri = entry.uri.slice(page.memory),
    };
}

fn sameLink(a: hyperlink.Hyperlink, b: hyperlink.Hyperlink) bool {
    if (!std.mem.eql(u8, a.uri, b.uri)) return false;
    return switch (a.id) {
        .explicit => |x| switch (b.id) {
            .explicit => |y| std.mem.eql(u8, x, y),
            .implicit => false,
        },
        .implicit => |x| switch (b.id) {
            .explicit => false,
            .implicit => |y| x == y,
        },
    };
}

fn encodeCodepoint(cp: u21, buf: *[4]u8) usize {
    return std.unicode.utf8Encode(cp, buf) catch n: {
        // Surrogates or out of range: substitute U+FFFD.
        break :n std.unicode.utf8Encode(0xFFFD, buf) catch unreachable;
    };
}

fn appendCodepoint(
    alloc: Allocator,
    text: *std.ArrayList(u8),
    cp: u21,
) Allocator.Error!void {
    var buf: [4]u8 = undefined;
    const n = encodeCodepoint(cp, &buf);
    try text.appendSlice(alloc, buf[0..n]);
}

/// Account the emitted bytes [start, end) of one cell (or run of equal
/// blanks) carrying `link` against the open span: extend it if it is the
/// same link, otherwise close it and, if the cell is linked, open a new
/// one. An unlinked cell closes the span.
fn trackLink(
    alloc: Allocator,
    links: *std.ArrayList(Link),
    open: *?Open,
    link: ?hyperlink.Hyperlink,
    start: usize,
    end: usize,
) Allocator.Error!void {
    if (open.*) |*o| {
        if (link) |l| {
            if (sameLink(o.link, l)) {
                o.end = end;
                return;
            }
        }

        try appendLink(alloc, links, o.*);
        open.* = null;
    }

    if (link) |l| open.* = .{ .start = start, .end = end, .link = l };
}

fn sameOptionalLink(a: ?hyperlink.Hyperlink, b: ?hyperlink.Hyperlink) bool {
    if (a == null or b == null) return a == null and b == null;
    return sameLink(a.?, b.?);
}

test "SearchDocument captures scrollback and active screen" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{ .cols = 20, .rows = 5 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    for (0..30) |i| {
        var buf: [16]u8 = undefined;
        try s.nextSlice(try std.fmt.bufPrint(&buf, "line {d}\r\n", .{i}));
    }
    try s.nextSlice("NEEDLE");

    var doc = try SearchDocument.capture(alloc, t.screens.active);
    defer doc.deinit();

    // Scrolled-off lines are retained, in order, with hard newlines.
    try testing.expect(std.mem.startsWith(u8, doc.text, "line 0\nline 1\n"));
    const needle = std.mem.indexOf(u8, doc.text, "line 29\nNEEDLE\n").? + 8;

    // Rows tile the text exactly.
    try testing.expect(doc.rows.len >= 31);
    try testing.expectEqual(@as(usize, 0), doc.rows[0].start);
    for (doc.rows[0 .. doc.rows.len - 1], doc.rows[1..]) |a, b| {
        try testing.expectEqual(a.end, b.start);
    }
    try testing.expectEqual(doc.text.len, doc.rows[doc.rows.len - 1].end);

    // The row covering NEEDLE points at its first cell.
    for (doc.rows) |row| {
        if (needle < row.start or needle >= row.end) continue;
        try testing.expectEqual(needle, row.start);
        try testing.expectEqual(
            @as(u21, 'N'),
            row.pin.rowAndCell().cell.codepoint(),
        );
        break;
    } else return error.RowNotFound;
}

test "SearchDocument joins soft-wrapped rows" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    // 16 chars wrap after column 10, then a hard line.
    try s.nextSlice("0123456789abcdef\r\nnext");

    var doc = try SearchDocument.capture(alloc, t.screens.active);
    defer doc.deinit();

    try testing.expect(std.mem.startsWith(
        u8,
        doc.text,
        "0123456789abcdef\nnext\n",
    ));
    try testing.expectEqual(@as(usize, 5), doc.rows.len);

    // The wrapped row has no newline; the continuation owns it.
    try testing.expectEqual(@as(usize, 0), doc.rows[0].start);
    try testing.expectEqual(@as(usize, 10), doc.rows[0].end);
    try testing.expectEqual(@as(usize, 10), doc.rows[1].start);
    try testing.expectEqual(@as(usize, 17), doc.rows[1].end);
}

test "SearchDocument captures hyperlinks, graphemes and wide cells" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{ .cols = 20, .rows = 3 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("\x1b]8;id=a;http://x.test\x1b\\LINK\x1b]8;;\x1b\\ e\u{301}中x");

    var doc = try SearchDocument.capture(alloc, t.screens.active);
    defer doc.deinit();

    try testing.expect(std.mem.startsWith(u8, doc.text, "LINK e\u{301}中x\n"));
    try testing.expectEqual(@as(usize, 1), doc.links.len);
    try testing.expectEqual(@as(usize, 0), doc.links[0].start);
    try testing.expectEqual(@as(usize, 4), doc.links[0].end);
    try testing.expectEqualStrings("http://x.test", doc.links[0].uri);
    try testing.expectEqualStrings("a", doc.links[0].id.?);
}

test "SearchDocument isBlankCell: space with combining mark is text" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{ .cols = 20, .rows = 3 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    // A plain gap, then a space carrying U+0301, then more text.
    try s.nextSlice("a  b \u{301}c");

    // Direct check of the shared rule on the cells that were written.
    const page = &t.screens.active.pages.getTopLeft(.screen).node.data;
    const cells = page.getCells(page.getRow(0));
    try testing.expect(!isBlankCell(&cells[0])); // a
    try testing.expect(isBlankCell(&cells[1])); // plain space
    try testing.expect(isBlankCell(&cells[2])); // plain space
    try testing.expect(!isBlankCell(&cells[3])); // b
    try testing.expect(!isBlankCell(&cells[4])); // space + U+0301
    try testing.expect(isBlankCell(&cells[10])); // never written

    var doc = try SearchDocument.capture(alloc, t.screens.active);
    defer doc.deinit();

    // The mark survives, and its base space is neither trimmed nor merged.
    try testing.expect(std.mem.startsWith(u8, doc.text, "a  b \u{301}c\n"));
}

test "SearchDocument link spans end at unlinked gaps" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{ .cols = 20, .rows = 3 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    // The same link (same explicit id and URI) twice, separated by one
    // unlinked space.
    try s.nextSlice(
        "\x1b]8;id=a;http://x.test\x1b\\AB\x1b]8;;\x1b\\ " ++
            "\x1b]8;id=a;http://x.test\x1b\\CD\x1b]8;;\x1b\\",
    );

    var doc = try SearchDocument.capture(alloc, t.screens.active);
    defer doc.deinit();

    try testing.expect(std.mem.startsWith(u8, doc.text, "AB CD\n"));
    try testing.expectEqual(@as(usize, 2), doc.links.len);
    try testing.expectEqual(@as(usize, 0), doc.links[0].start);
    try testing.expectEqual(@as(usize, 2), doc.links[0].end);
    try testing.expectEqual(@as(usize, 3), doc.links[1].start);
    try testing.expectEqual(@as(usize, 5), doc.links[1].end);
    try testing.expectEqualStrings("http://x.test", doc.links[0].uri);
    try testing.expectEqualStrings("http://x.test", doc.links[1].uri);
}

test "SearchDocument link spans never contain a hard newline" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{ .cols = 20, .rows = 3 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    // The link stays active across the line break, so both lines' cells
    // carry the same link; they are still two spans.
    try s.nextSlice("\x1b]8;id=a;http://x.test\x1b\\AB\r\nCD\x1b]8;;\x1b\\");

    var doc = try SearchDocument.capture(alloc, t.screens.active);
    defer doc.deinit();

    try testing.expect(std.mem.startsWith(u8, doc.text, "AB\nCD\n"));
    try testing.expectEqual(@as(usize, 2), doc.links.len);
    try testing.expectEqual(@as(usize, 0), doc.links[0].start);
    try testing.expectEqual(@as(usize, 2), doc.links[0].end);
    try testing.expectEqual(@as(usize, 3), doc.links[1].start);
    try testing.expectEqual(@as(usize, 5), doc.links[1].end);
}

test "SearchDocument link spans include linked spaces only" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{ .cols = 20, .rows = 3 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    // "A", a linked space, "B", a linked space, then an unlinked "C".
    // Both spaces carry the link and are emitted (text follows), so they
    // belong to the span; the unlinked "C" does not.
    try s.nextSlice("\x1b]8;id=a;http://x.test\x1b\\A B \x1b]8;;\x1b\\C");

    var doc = try SearchDocument.capture(alloc, t.screens.active);
    defer doc.deinit();

    try testing.expect(std.mem.startsWith(u8, doc.text, "A B C\n"));
    try testing.expectEqual(@as(usize, 1), doc.links.len);
    try testing.expectEqual(@as(usize, 0), doc.links[0].start);
    try testing.expectEqual(@as(usize, 4), doc.links[0].end);
}
