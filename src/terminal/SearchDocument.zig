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
//! The row map is sparse: one `Row` per physical row holding the byte
//! range it produced and a pin to its first cell. The ranges tile `text`
//! exactly (`rows[i].end == rows[i + 1].start`), and a hard row's range
//! includes its trailing "\n". There is no per-byte pin array; to find the
//! column of a byte inside a row, re-walk that row's cells with the same
//! rules; `cellsForRange` does exactly that for a byte range.
//!
//! OSC 8 hyperlinks are captured as byte spans over `text`. A span covers
//! exactly the cells that carry the link, in order: a blank cell is part of
//! a span only if it carries that same link itself (and only if it is
//! emitted, i.e. text follows it on the line). A cell without the link, an
//! unlinked blank gap or a hard line end closes the span, so two runs of
//! the same link separated by such a gap are two spans, and a span never
//! contains a "\n".
//!
//! LIFETIME: `text`, `rows` and `links` are owned by the document and
//! independent of the terminal, so they stay valid after the terminal is
//! destroyed. The `Pin`s in `rows` are NOT tracked: they point into the
//! terminal's pages and are only dereferenceable while the caller has
//! established that the same screen is alive and unchanged. `epoch` is
//! opaque and supplied by the caller for exactly that comparison.
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
epoch: u64,
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

/// Capture the retained text of `screen` (all scrollback and the active
/// area). The caller must hold whatever lock protects the screen for the
/// duration of the call and supplies `epoch` read under that same lock.
pub fn capture(
    alloc: Allocator,
    screen: *const Screen,
    epoch: u64,
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
        const row_start = text.items.len;

        for (cells) |*cell| {
            switch (cell.wide) {
                .narrow, .wide => {},
                .spacer_head, .spacer_tail => continue,
            }

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
            if (cell.content_tag == .codepoint_grapheme) {
                if (page.lookupGrapheme(cell)) |cps| {
                    for (cps) |cp| try appendCodepoint(alloc, &text, cp);
                }
            }
            try trackLink(alloc, &links, &open, link, start, text.items.len);
        }

        if (!row.wrap) {
            // Hard line end: pending blanks are trimmed and no link
            // continues over the newline.
            pending.clearRetainingCapacity();
            if (open) |o| {
                try appendLink(alloc, &links, o);
                open = null;
            }
            try text.append(alloc, '\n');
        }

        try rows.append(alloc, .{
            .start = row_start,
            .end = text.items.len,
            .pin = pin,
        });
    }

    if (open) |o| try appendLink(alloc, &links, o);

    const text_owned = try text.toOwnedSlice(alloc);
    errdefer alloc.free(text_owned);
    const rows_owned = try rows.toOwnedSlice(alloc);
    errdefer alloc.free(rows_owned);
    const links_owned = try links.toOwnedSlice(alloc);

    return .{
        .alloc = alloc,
        .epoch = epoch,
        .text = text_owned,
        .rows = rows_owned,
        .links = links_owned,
    };
}

/// What a physical row leaves pending at its end (see `cellsForRange`).
const RowTail = enum { text, blank, empty };

/// What a physical row leaves pending at its end: `blank` if its last
/// counted cell is blank (those blanks carry into the next row of a
/// soft-wrapped line), `text` if it ends in text, `empty` if it has no
/// counted cells at all (spacers only).
fn rowTail(pin: Pin) RowTail {
    const page = &pin.node.data;
    const cells = page.getCells(page.getRow(pin.y));
    var i = cells.len;
    while (i > 0) {
        i -= 1;
        const cell = &cells[i];
        switch (cell.wide) {
            .narrow, .wide => {},
            .spacer_head, .spacer_tail => continue,
        }

        return if (isBlankCell(cell)) .blank else .text;
    }

    return .empty;
}

/// Maps the bytes [range.start, range.end) of `text` to the terminal cells
/// that produced them, in document order, appending one Pin per cell (the
/// head cell of a wide cell) to `cells`. Newline bytes have no cell, so a
/// newline-only range appends nothing. A byte range touching only a
/// combining mark yields the whole cell that holds it.
///
/// This re-walks the rows covering the range with exactly the rules of
/// `capture` instead of keeping a per-byte pin map. The walk starts at the
/// row containing range.start, moved back over soft-wrapped rows that end
/// in blank cells, because those blanks are emitted as spaces at the start
/// of the following row and must map back to their own cells.
///
/// Collection stops early once `limit` cells are resolved (more than
/// `limit` may be appended when blanks were pending). The row byte ranges
/// are cross-checked against the walk and any disagreement, or a range
/// that starts beyond the text, fails with error.Inconsistent rather than
/// returning guessed cells. `cells` may be left partially filled on error.
///
/// The caller must have established that the pins in `rows` are still
/// live (same screen, unchanged since `epoch`), and holds the lock that
/// protects the screen. The range is not validated for UTF-8 boundaries.
pub fn cellsForRange(
    self: *const SearchDocument,
    alloc: Allocator,
    range: Range,
    limit: usize,
    cells: *std.ArrayList(Pin),
) (Allocator.Error || error{Inconsistent})!void {
    const rows = self.rows;

    // The first row whose byte range contains range.start. Rows tile
    // the text, so this is a partition point.
    var lo: usize = 0;
    var hi: usize = rows.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (rows[mid].end > range.start) hi = mid else lo = mid + 1;
    }
    if (lo >= rows.len) return error.Inconsistent;

    // Move back over rows whose pending blanks carry into this one.
    var first = lo;
    while (first > 0) {
        const prev = rows[first - 1].pin;
        if (!prev.rowAndCell().row.wrap) break;
        if (rowTail(prev) == .text) break;
        first -= 1;
    }

    // `pos` is the byte offset of the next byte the capture would emit.
    // Blank cells are pending until text follows them; their cells are
    // collected tentatively and dropped again if a hard line end discards
    // them.
    var pos: usize = rows[first].start;
    var pending: usize = 0;
    var mark: usize = cells.items.len;

    for (rows[first..]) |row| {
        const pin = row.pin;
        const page = &pin.node.data;
        const prow = page.getRow(pin.y);

        for (page.getCells(prow), 0..) |*cell, x| {
            switch (cell.wide) {
                .narrow, .wide => {},
                .spacer_head, .spacer_tail => continue,
            }

            const cell_pin: Pin = .{
                .node = pin.node,
                .y = pin.y,
                .x = @intCast(x),
            };

            if (isBlankCell(cell)) {
                if (pending == 0) mark = cells.items.len;
                const at = pos + pending;
                if (at >= range.start and at < range.end) {
                    try cells.append(alloc, cell_pin);
                }
                pending += 1;
                continue;
            }

            // Text: the pending blanks are emitted as spaces first.
            pos += pending;
            pending = 0;

            var n = codepointBytes(cell.codepoint());
            if (cell.content_tag == .codepoint_grapheme) {
                if (page.lookupGrapheme(cell)) |cps| {
                    for (cps) |cp| n += codepointBytes(cp);
                }
            }

            if (pos < range.end and pos + n > range.start) {
                try cells.append(alloc, cell_pin);
            }
            pos += n;

            // Nothing is pending here, so everything collected is final.
            if (pos >= range.end or cells.items.len >= limit) return;
        }

        if (!row.pin.rowAndCell().row.wrap) {
            // Hard line end: pending blanks are trimmed, and the newline
            // byte has no cell.
            if (pending > 0) cells.shrinkRetainingCapacity(mark);
            pending = 0;
            pos += 1;
            if (pos >= range.end or cells.items.len >= limit) return;
        }

        if (pos != row.end) return error.Inconsistent;
    }

    // The screen ended with blanks still pending: never emitted.
    if (pending > 0) cells.shrinkRetainingCapacity(mark);
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

    var doc = try SearchDocument.capture(alloc, t.screens.active, 7);
    defer doc.deinit();

    try testing.expectEqual(@as(u64, 7), doc.epoch);

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

    var doc = try SearchDocument.capture(alloc, t.screens.active, 0);
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

    var doc = try SearchDocument.capture(alloc, t.screens.active, 0);
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

    var doc = try SearchDocument.capture(alloc, t.screens.active, 0);
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

    var doc = try SearchDocument.capture(alloc, t.screens.active, 0);
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

    var doc = try SearchDocument.capture(alloc, t.screens.active, 0);
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

    var doc = try SearchDocument.capture(alloc, t.screens.active, 0);
    defer doc.deinit();

    try testing.expect(std.mem.startsWith(u8, doc.text, "A B C\n"));
    try testing.expectEqual(@as(usize, 1), doc.links.len);
    try testing.expectEqual(@as(usize, 0), doc.links[0].start);
    try testing.expectEqual(@as(usize, 4), doc.links[0].end);
}

test "SearchDocument cellsForRange maps blanks carried over a soft wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    // Row 0 is "ab" plus eight blanks and soft-wraps into row 1, so the
    // eight spaces are emitted at the start of row 1's byte range even
    // though their cells are on row 0.
    try s.nextSlice("ab        cd");

    var doc = try SearchDocument.capture(alloc, t.screens.active, 0);
    defer doc.deinit();
    try testing.expect(std.mem.startsWith(u8, doc.text, "ab        cd\n"));
    try testing.expectEqual(@as(usize, 2), doc.rows[0].end);
    try testing.expectEqual(@as(usize, 2), doc.rows[1].start);

    var cells: std.ArrayList(Pin) = .empty;
    defer cells.deinit(alloc);

    // All of the carried blanks: row 0, columns 2..9.
    try doc.cellsForRange(alloc, .{ .start = 2, .end = 10 }, std.math.maxInt(usize), &cells);
    try testing.expectEqual(@as(usize, 8), cells.items.len);
    for (cells.items, 2..) |pin, x| {
        try testing.expectEqual(@as(usize, 0), pin.y);
        try testing.expectEqual(x, pin.x);
    }

    // A range that starts inside the carried blanks (but whose first row
    // by byte offset is row 1).
    cells.clearRetainingCapacity();
    try doc.cellsForRange(alloc, .{ .start = 5, .end = 8 }, std.math.maxInt(usize), &cells);
    try testing.expectEqual(@as(usize, 3), cells.items.len);
    for (cells.items, 5..) |pin, x| {
        try testing.expectEqual(@as(usize, 0), pin.y);
        try testing.expectEqual(x, pin.x);
    }

    // A range crossing from the carried blanks into the continuation.
    cells.clearRetainingCapacity();
    try doc.cellsForRange(alloc, .{ .start = 8, .end = 12 }, std.math.maxInt(usize), &cells);
    try testing.expectEqual(@as(usize, 4), cells.items.len);
    try testing.expectEqual(@as(usize, 0), cells.items[0].y);
    try testing.expectEqual(@as(usize, 8), cells.items[0].x);
    try testing.expectEqual(@as(usize, 0), cells.items[1].y);
    try testing.expectEqual(@as(usize, 9), cells.items[1].x);
    try testing.expectEqual(@as(usize, 1), cells.items[2].y);
    try testing.expectEqual(@as(usize, 0), cells.items[2].x);
    try testing.expectEqual(@as(usize, 1), cells.items[3].y);
    try testing.expectEqual(@as(usize, 1), cells.items[3].x);
}

test "SearchDocument cellsForRange trims blanks at hard line ends" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("ab   \r\ncd");

    var doc = try SearchDocument.capture(alloc, t.screens.active, 0);
    defer doc.deinit();
    try testing.expect(std.mem.startsWith(u8, doc.text, "ab\ncd\n"));

    var cells: std.ArrayList(Pin) = .empty;
    defer cells.deinit(alloc);

    // Everything: only the four text cells, never the trimmed blanks.
    try doc.cellsForRange(alloc, .{ .start = 0, .end = 6 }, std.math.maxInt(usize), &cells);
    try testing.expectEqual(@as(usize, 4), cells.items.len);
    try testing.expectEqual(@as(usize, 0), cells.items[0].y);
    try testing.expectEqual(@as(usize, 0), cells.items[0].x);
    try testing.expectEqual(@as(usize, 0), cells.items[1].y);
    try testing.expectEqual(@as(usize, 1), cells.items[1].x);
    try testing.expectEqual(@as(usize, 1), cells.items[2].y);
    try testing.expectEqual(@as(usize, 0), cells.items[2].x);
    try testing.expectEqual(@as(usize, 1), cells.items[3].y);
    try testing.expectEqual(@as(usize, 1), cells.items[3].x);

    // A newline-only range maps to no cell, and is not an error.
    cells.clearRetainingCapacity();
    try doc.cellsForRange(alloc, .{ .start = 2, .end = 3 }, std.math.maxInt(usize), &cells);
    try testing.expectEqual(@as(usize, 0), cells.items.len);

    // A range that starts beyond the text is rejected, not clamped.
    try testing.expectError(
        error.Inconsistent,
        doc.cellsForRange(
            alloc,
            .{ .start = doc.text.len, .end = doc.text.len + 1 },
            std.math.maxInt(usize),
            &cells,
        ),
    );
}

test "SearchDocument cellsForRange maps grapheme and wide cells" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    // e + U+0301 (bytes 0..3, column 0), a wide cell (bytes 3..6, column
    // 1, its spacer at column 2), x (byte 6, column 3).
    try s.nextSlice("e\u{301}中x");

    var doc = try SearchDocument.capture(alloc, t.screens.active, 0);
    defer doc.deinit();
    try testing.expect(std.mem.startsWith(u8, doc.text, "e\u{301}中x\n"));

    var cells: std.ArrayList(Pin) = .empty;
    defer cells.deinit(alloc);

    // The combining mark alone yields the whole cell that holds it.
    try doc.cellsForRange(alloc, .{ .start = 1, .end = 3 }, std.math.maxInt(usize), &cells);
    try testing.expectEqual(@as(usize, 1), cells.items.len);
    try testing.expectEqual(@as(usize, 0), cells.items[0].x);

    // The wide character is one cell, its head.
    cells.clearRetainingCapacity();
    try doc.cellsForRange(alloc, .{ .start = 3, .end = 6 }, std.math.maxInt(usize), &cells);
    try testing.expectEqual(@as(usize, 1), cells.items.len);
    try testing.expectEqual(@as(usize, 1), cells.items[0].x);

    // The whole line skips the spacer.
    cells.clearRetainingCapacity();
    try doc.cellsForRange(alloc, .{ .start = 0, .end = 7 }, std.math.maxInt(usize), &cells);
    try testing.expectEqual(@as(usize, 3), cells.items.len);
    try testing.expectEqual(@as(usize, 0), cells.items[0].x);
    try testing.expectEqual(@as(usize, 1), cells.items[1].x);
    try testing.expectEqual(@as(usize, 3), cells.items[2].x);
}

test "SearchDocument cellsForRange stops at limit" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("ab\r\ncd");

    var doc = try SearchDocument.capture(alloc, t.screens.active, 0);
    defer doc.deinit();

    var cells: std.ArrayList(Pin) = .empty;
    defer cells.deinit(alloc);

    // Whole document, but only the first cell is wanted.
    try doc.cellsForRange(alloc, .{ .start = 0, .end = 6 }, 1, &cells);
    try testing.expectEqual(@as(usize, 1), cells.items.len);
    try testing.expectEqual(@as(usize, 0), cells.items[0].y);
    try testing.expectEqual(@as(usize, 0), cells.items[0].x);
}
