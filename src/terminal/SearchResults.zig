//! Immutable, reference-counted search anchors. Node pointers are opaque keys:
//! none of the functions here dereference them. Live views must be constructed
//! from a node found in the current page list under the renderer lock.
const SearchResults = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const Doc = @import("SearchDocument.zig");
const ScreenSet = @import("ScreenSet.zig");
const RenderState = @import("render.zig").RenderState;

pub const Key = struct { node: usize, serial: u64, y: usize };
pub const Anchor = struct {
    key: Key,
    hash: u64,
    byte_len: usize,
    range: Doc.Range,
    index: usize,
    link: bool,
};
pub const Visible = extern struct {
    index: usize,
    row: u32,
    x0: u32,
    x1: u32,
    tag: u32,
};
pub const Tag = enum(u8) { normal, selected, link };
const Bound = struct { byte: usize, slot: usize, end: bool };
pub const RowIndex = struct {
    anchors: std.ArrayListUnmanaged(usize) = .empty,
    bounds: std.ArrayListUnmanaged(Bound) = .empty,
    fn deinit(self: *RowIndex, alloc: Allocator) void {
        self.anchors.deinit(alloc);
        self.bounds.deinit(alloc);
    }
};

alloc: Allocator,
refs: std.atomic.Value(usize) = .init(1),
id: u64,
screen: ScreenSet.Key,
anchors: []const Anchor,
match_starts: []const usize,
rows: std.AutoHashMapUnmanaged(Key, RowIndex),

pub fn create(alloc: Allocator, id: u64, screen: ScreenSet.Key, doc: *const Doc, ranges: []const Doc.Range) !*SearchResults {
    // Validate the whole request before building any anchors.
    var previous: usize = 0;
    for (ranges, 0..) |range, i| {
        if (range.start >= range.end or range.end > doc.text.len or
            (i > 0 and range.start < previous) or
            (doc.text[range.start] & 0xc0) == 0x80 or
            (range.end < doc.text.len and (doc.text[range.end] & 0xc0) == 0x80) or
            std.mem.indexOfScalar(u8, doc.text[range.start..range.end], '\n') != null)
            return error.InvalidRange;
        previous = range.start;
    }
    var anchors: std.ArrayList(Anchor) = .empty;
    defer anchors.deinit(alloc);
    const starts = try alloc.alloc(usize, ranges.len + 1);
    errdefer alloc.free(starts);
    var rows: std.AutoHashMapUnmanaged(Key, RowIndex) = .empty;
    errdefer {
        var it = rows.valueIterator();
        while (it.next()) |list| list.deinit(alloc);
        rows.deinit(alloc);
    }
    for (ranges, 0..) |range, index| {
        starts[index] = anchors.items.len;
        // Binary-search the first physical row contributing bytes.
        var lo: usize = 0;
        var hi = doc.rows.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (doc.rows[mid].end <= range.start) lo = mid + 1 else hi = mid;
        }
        var link_lo: usize = 0;
        var link_hi = doc.links.len;
        while (link_lo < link_hi) {
            const mid = link_lo + (link_hi - link_lo) / 2;
            if (doc.links[mid].end <= range.start) link_lo = mid + 1 else link_hi = mid;
        }
        const link = link_lo < doc.links.len and doc.links[link_lo].start < range.end;
        for (doc.rows[lo..]) |row| {
            if (row.start >= range.end) break;
            const start = @max(row.start, range.start);
            const end = @min(row.start + row.byte_len, range.end);
            if (start >= end) continue;
            const key: Key = .{ .node = @intFromPtr(row.pin.node), .serial = row.serial, .y = row.pin.y };
            const entry = try rows.getOrPut(alloc, key);
            if (!entry.found_existing) entry.value_ptr.* = .{};
            const slot = entry.value_ptr.anchors.items.len;
            try entry.value_ptr.anchors.append(alloc, anchors.items.len);
            try entry.value_ptr.bounds.append(alloc, .{ .byte = start - row.start, .slot = slot, .end = false });
            try entry.value_ptr.bounds.append(alloc, .{ .byte = end - row.start, .slot = slot, .end = true });
            try anchors.append(alloc, .{
                .key = key,
                .hash = row.hash,
                .byte_len = row.byte_len,
                .range = .{ .start = start - row.start, .end = end - row.start },
                .index = index,
                .link = link,
            });
        }
    }
    starts[ranges.len] = anchors.items.len;
    var row_it = rows.valueIterator();
    while (row_it.next()) |row| std.mem.sort(Bound, row.bounds.items, {}, struct {
        fn less(_: void, a: Bound, b: Bound) bool {
            return a.byte < b.byte or (a.byte == b.byte and a.end and !b.end);
        }
    }.less);
    const self = try alloc.create(SearchResults);
    errdefer alloc.destroy(self);
    self.* = .{ .alloc = alloc, .id = id, .screen = screen, .anchors = try anchors.toOwnedSlice(alloc), .match_starts = starts, .rows = rows };
    return self;
}

pub fn retain(self: *SearchResults) *SearchResults {
    _ = self.refs.fetchAdd(1, .monotonic);
    return self;
}
pub fn release(self: *SearchResults) void {
    if (self.refs.fetchSub(1, .acq_rel) != 1) return;
    var it = self.rows.valueIterator();
    while (it.next()) |list| list.deinit(self.alloc);
    self.rows.deinit(self.alloc);
    self.alloc.free(self.anchors);
    self.alloc.free(self.match_starts);
    self.alloc.destroy(self);
}
pub fn count(self: *const SearchResults) usize {
    return self.match_starts.len - 1;
}
pub fn match(self: *const SearchResults, index: usize) []const Anchor {
    return self.anchors[self.match_starts[index]..self.match_starts[index + 1]];
}

pub fn inheritedSelection(self: *const SearchResults, previous: *const SearchResults, index: usize) ?usize {
    if (self.screen != previous.screen or index >= previous.count()) return null;
    const old = previous.match(index);
    if (old.len == 0) return null;
    // Look up just the candidate anchors of the previously selected row.
    const candidates = self.rows.get(old[0].key) orelse return null;
    for (candidates.anchors.items) |at| {
        const candidate = self.match(self.anchors[at].index);
        if (candidate.len != old.len) continue;
        for (old, candidate) |a, b| {
            if (!std.meta.eql(a.key, b.key) or a.hash != b.hash or
                a.range.start != b.range.start or a.range.end != b.range.end or
                a.byte_len != b.byte_len) break;
        } else return self.anchors[at].index;
    }
    return null;
}

/// Shared by renderer, select and diagnostics. No pointer dereferences.
pub fn validatedColumns(comptime View: type, view: View, wrap: bool, hash: u64, anchor: Anchor) ?[2]usize {
    _ = wrap;
    if (hash != anchor.hash) return null;
    return Doc.columns(View, view, anchor.byte_len, anchor.range);
}

pub fn tag(anchor: Anchor, selected: ?usize) Tag {
    if (selected == anchor.index) return .selected;
    return if (anchor.link) .link else .normal;
}

/// One row walk resolves all sorted byte boundaries. Cost is columns plus
/// visible anchors, including overlapping ranges and grapheme interior hits.
pub fn validateRow(self: *const SearchResults, comptime View: type, view: View, wrap: bool, candidates: RowIndex, alloc: Allocator) ![]?[2]usize {
    const result = try alloc.alloc(?[2]usize, candidates.anchors.items.len);
    @memset(result, null);
    const hash = Doc.rowHash(View, view, wrap);
    var walker = Doc.Walker(View).init(view);
    var at: usize = 0;
    while (walker.next()) |token| {
        while (at < candidates.bounds.items.len) {
            const bound = candidates.bounds.items[at];
            if (bound.byte > token.end or (bound.byte == token.end and !bound.end)) break;
            const anchor = self.anchors[candidates.anchors.items[bound.slot]];
            if (anchor.hash == hash) {
                if (!bound.end) {
                    result[bound.slot] = .{ token.x, token.x };
                } else if (result[bound.slot]) |*cols| {
                    cols[1] = token.x + token.width;
                }
            }
            at += 1;
        }
        if (at == candidates.bounds.items.len) break;
    }
    for (result) |*cols| if (cols.*) |value| {
        if (value[0] >= value[1]) cols.* = null;
    };
    return result;
}

pub fn updateHighlights(self: *const SearchResults, alloc: Allocator, state: *RenderState, selected: ?usize, tags: [3]u8) !void {
    if (state.screen != self.screen) return;
    const rows = state.row_data.slice();
    for (0..rows.len) |y| {
        const pin = rows.items(.pin)[y];
        const candidates = self.rows.get(.{ .node = @intFromPtr(pin.node), .serial = rows.items(.serial)[y], .y = pin.y }) orelse continue;
        const view: Doc.RenderView = .{ .cells = rows.items(.cells)[y].slice() };
        var arena = rows.items(.arena)[y].promote(alloc);
        defer rows.items(.arena)[y] = arena.state;
        const columns = try self.validateRow(Doc.RenderView, view, rows.items(.raw)[y].wrap, candidates, alloc);
        defer alloc.free(columns);
        // Renderer takes the first highlight covering a cell.
        for ([_]Tag{ .selected, .link, .normal }) |priority| {
            for (candidates.anchors.items, columns) |at, maybe_cols| {
                const anchor = self.anchors[at];
                if (tag(anchor, selected) != priority) continue;
                const cols = maybe_cols orelse continue;
                try rows.items(.highlights)[y].append(arena.allocator(), .{
                    .tag = tags[@intFromEnum(priority)],
                    .range = .{ @intCast(cols[0]), @intCast(cols[1] - 1) },
                });
                rows.items(.dirty)[y] = true;
                if (state.dirty == .false) state.dirty = .partial;
            }
        }
    }
}

test "SearchResults wrapped blanks and grapheme map identically from render copies" {
    const alloc = std.testing.allocator;
    var terminal = try @import("Terminal.zig").init(alloc, .{ .cols = 10, .rows = 5 });
    defer terminal.deinit(alloc);
    var stream = terminal.vtStream();
    defer stream.deinit();
    try stream.nextSlice("ab        cd\r\ne\u{301}中x");
    var doc = try Doc.capture(alloc, terminal.screens.active);
    defer doc.deinit();
    try std.testing.expect(std.mem.startsWith(u8, doc.text, "ab        cd\ne\u{301}中x\n"));
    try std.testing.expectEqual(@as(usize, 10), doc.rows[0].byte_len);
    const set = try create(alloc, 1, .primary, &doc, &.{ .{ .start = 8, .end = 12 }, .{ .start = 14, .end = 16 }, .{ .start = 16, .end = 19 } });
    defer set.release();
    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &terminal);
    try set.updateHighlights(alloc, &state, 0, .{ 0, 1, 2 });
    const hls = state.row_data.items(.highlights);
    try std.testing.expectEqual(@as(usize, 1), hls[0].items.len);
    try std.testing.expectEqual([2]@import("size.zig").CellCountInt{ 8, 9 }, hls[0].items[0].range);
    try std.testing.expectEqual([2]@import("size.zig").CellCountInt{ 0, 1 }, hls[1].items[0].range);
    try std.testing.expectEqual([2]@import("size.zig").CellCountInt{ 0, 0 }, hls[2].items[0].range);
    try std.testing.expectEqual([2]@import("size.zig").CellCountInt{ 1, 2 }, hls[2].items[1].range);
    // Clean rows retain grapheme copies and serial on the next update.
    try state.update(alloc, &terminal);
    const view: Doc.RenderView = .{ .cells = state.row_data.items(.cells)[2].slice() };
    try std.testing.expectEqual(doc.rows[2].hash, Doc.rowHash(Doc.RenderView, view, false));
}

test "SearchResults rejects invalid whole sets and preserves anchor selection" {
    const alloc = std.testing.allocator;
    var terminal = try @import("Terminal.zig").init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 10_000 });
    defer terminal.deinit(alloc);
    var stream = terminal.vtStream();
    defer stream.deinit();
    try stream.nextSlice("NEEDLE\r\nhello\r\n");
    var doc = try Doc.capture(alloc, terminal.screens.active);
    defer doc.deinit();
    const set = try create(alloc, 1, .primary, &doc, &.{.{ .start = 0, .end = 6 }});
    defer set.release();
    try std.testing.expectError(error.InvalidRange, create(alloc, 2, .primary, &doc, &.{.{ .start = 0, .end = 7 }}));
    try std.testing.expectError(error.InvalidRange, create(alloc, 2, .primary, &doc, &.{.{ .start = 0, .end = 0 }}));
    try stream.nextSlice("hello\r\n");
    var fresh = try Doc.capture(alloc, terminal.screens.active);
    defer fresh.deinit();
    const refreshed = try create(alloc, 3, .primary, &fresh, &.{.{ .start = 0, .end = 6 }});
    defer refreshed.release();
    try std.testing.expectEqual(@as(?usize, 0), refreshed.inheritedSelection(set, 0));
    // Prune and serial reuse must not match old opaque node pointers.
    for (0..2000) |_| try stream.nextSlice("hello\r\n");
    var pruned = try Doc.capture(alloc, terminal.screens.active);
    defer pruned.deinit();
    try std.testing.expect(std.mem.indexOf(u8, pruned.text, "NEEDLE") == null);
    const replacement = try create(alloc, 4, .primary, &pruned, &.{.{ .start = 0, .end = 5 }});
    defer replacement.release();
    try std.testing.expectEqual(@as(?usize, null), replacement.inheritedSelection(set, 0));
    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &terminal);
    try set.updateHighlights(alloc, &state, 0, .{ 0, 1, 2 });
    for (state.row_data.items(.highlights)) |hls| try std.testing.expectEqual(@as(usize, 0), hls.items.len);
}

test "SearchResults frame budget at configured scrollback limit" {
    const alloc = std.heap.page_allocator;
    var terminal = try @import("Terminal.zig").init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 10_000_000 });
    defer terminal.deinit(alloc);
    var stream = terminal.vtStream();
    defer stream.deinit();
    for (1..200001) |i| {
        var buf: [32]u8 = undefined;
        try stream.nextSlice(try std.fmt.bufPrint(&buf, "{d}\r\n", .{i}));
    }
    var timer = try std.time.Timer.start();
    var doc = try Doc.capture(alloc, terminal.screens.active);
    defer doc.deinit();
    const capture_ns = timer.lap();
    var ranges: std.ArrayList(Doc.Range) = .empty;
    defer ranges.deinit(alloc);
    for (doc.text, 0..) |byte, at| if (byte == '1') {
        try ranges.append(alloc, .{ .start = at, .end = at + 1 });
    };
    const set = try create(alloc, 1, .primary, &doc, ranges.items);
    defer set.release();
    const commit_ns = timer.lap();
    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &terminal);
    const runs = 500;
    timer.reset();
    for (0..runs) |_| {
        for (state.row_data.items(.highlights)) |*hls| hls.clearRetainingCapacity();
    }
    const empty_ns = timer.lap() / runs;
    for (0..runs) |_| {
        for (state.row_data.items(.highlights)) |*hls| hls.clearRetainingCapacity();
        try set.updateHighlights(alloc, &state, null, .{ 0, 1, 2 });
    }
    const frame_ns = timer.lap() / runs;
    std.debug.print("SEARCH_COST mode={s} text_bytes={d} matches={d} capture_ms={d} commit_and_ranges_ms={d} frame_us={d} empty_us={d}\n", .{ @tagName(@import("builtin").mode), doc.text.len, ranges.items.len, capture_ns / 1_000_000, commit_ns / 1_000_000, frame_ns / 1000, empty_ns / 1000 });
    try std.testing.expect(frame_ns < 2_000_000);
}
