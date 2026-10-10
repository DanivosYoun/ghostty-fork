import AppKit
import GhosttyKit

// MARK: - Runtime stubs (C callbacks cannot capture; none of these matter here)

private func stubWakeup(_ userdata: UnsafeMutableRawPointer?) {}
private func stubAction(_ app: ghostty_app_t?, _ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool { true }
private func stubReadClipboard(_ userdata: UnsafeMutableRawPointer?, _ kind: ghostty_clipboard_e,
                               _ state: UnsafeMutableRawPointer?) -> Bool { false }
private func stubConfirmReadClipboard(_ userdata: UnsafeMutableRawPointer?, _ text: UnsafePointer<CChar>?,
                                      _ state: UnsafeMutableRawPointer?, _ req: ghostty_clipboard_request_e) {}
private func stubReadPTY(_ userdata: UnsafeMutableRawPointer?, _ bytes: UnsafePointer<CChar>?, _ len: Int) {}
private func stubWriteClipboard(_ userdata: UnsafeMutableRawPointer?, _ kind: ghostty_clipboard_e,
                                _ content: UnsafePointer<ghostty_clipboard_content_s>?, _ count: Int,
                                _ confirm: Bool) {}
private func stubCloseSurface(_ userdata: UnsafeMutableRawPointer?, _ processAlive: Bool) {}
private func stubWriteInput(_ userdata: UnsafeMutableRawPointer?, _ bytes: UnsafePointer<CChar>?, _ len: Int) {}
private func stubResize(_ userdata: UnsafeMutableRawPointer?, _ cols: UInt16, _ rows: UInt16) {}

// MARK: - Fixture

/// One ghostty app, a hidden window, and any number of external_io surfaces.
@MainActor
private final class EngineFixture {
    struct Cell { let width: UInt32; let height: UInt32 }

    private var config: ghostty_config_t?
    private(set) var app: ghostty_app_t?
    private let window: NSWindow
    private var views: [NSView] = []
    private var liveSurfaces: [ghostty_surface_t] = []

    /// nil when the engine cannot run in this environment.
    init?() {
        _ = NSApplication.shared
        _ = ghostty_init(0, nil)

        // Test-only config: `window-vsync = false` so no display link is needed
        // for a window that is never shown.
        guard let config = ghostty_config_new() else { return nil }
        let path = NSTemporaryDirectory() + "search-viewport-\(UUID().uuidString).ghostty"
        guard (try? "window-vsync = false\nwindow-padding-x = 0\nwindow-padding-y = 0\n".write(toFile: path, atomically: true, encoding: .utf8)) != nil else {
            ghostty_config_free(config)
            return nil
        }
        ghostty_config_load_file(config, path)
        try? FileManager.default.removeItem(atPath: path)
        ghostty_config_finalize(config)
        self.config = config

        var runtime = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: stubWakeup,
            action_cb: stubAction,
            read_clipboard_cb: stubReadClipboard,
            confirm_read_clipboard_cb: stubConfirmReadClipboard,
            read_pty_cb: stubReadPTY,
            write_clipboard_cb: stubWriteClipboard,
            close_surface_cb: stubCloseSurface,
            write_input_cb: stubWriteInput,
            resize_cb: stubResize)
        guard let app = ghostty_app_new(&runtime, config) else {
            ghostty_config_free(config)
            return nil
        }
        self.app = app
        let frame = NSRect(x: 0, y: 0, width: 800, height: 480)
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
    }

    /// Frees whatever the test left (surfaces first, then app, then config).
    /// Explicit rather than `deinit`, which is nonisolated for a MainActor class.
    func shutdown() {
        for surface in liveSurfaces { ghostty_surface_free(surface) }
        liveSurfaces.removeAll()
        if let app { ghostty_app_free(app) }
        app = nil
        if let config { ghostty_config_free(config) }
        config = nil
    }

    /// A new 80x24 external_io surface, or nil if the engine refuses to create one.
    func makeSurface() -> ghostty_surface_t? {
        guard let app else { return nil }
        let view = NSView(frame: window.contentRect(forFrameRect: window.frame))
        view.wantsLayer = true
        views.append(view)

        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(view).toOpaque()))
        surfaceConfig.scale_factor = 2.0
        surfaceConfig.font_size = 14
        surfaceConfig.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        surfaceConfig.external_io = true   // no PTY: only injected bytes reach the terminal
        guard let surface = ghostty_surface_new(app, &surfaceConfig) else { return nil }
        liveSurfaces.append(surface)

        ghostty_surface_set_size(surface, 1600, 900)
        pump()
        let cell = cellSize(of: surface)
        ghostty_surface_set_size(surface, cell.width * 80, cell.height * 24)
        pump()
        return surface
    }

    func free(_ surface: ghostty_surface_t) {
        liveSurfaces.removeAll { $0 == surface }
        ghostty_surface_free(surface)
    }

    func cellSize(of surface: ghostty_surface_t) -> Cell {
        let cursor = ghostty_surface_cursor_position(surface)
        return Cell(width: cursor.cell_width_px, height: cursor.cell_height_px)
    }

    func pump(ticks: Int = 20) {
        guard let app else { return }
        for _ in 0..<ticks {
            ghostty_app_tick(app)
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
        }
    }

    /// Controlled output: chunks of at most 4096 bytes, one tick after each.
    func inject(_ text: String, into surface: ghostty_surface_t) {
        guard let app else { return }
        let bytes = Array(text.utf8)
        for start in stride(from: 0, to: bytes.count, by: 4096) {
            let count = min(4096, bytes.count - start)
            bytes.withUnsafeBufferPointer { buffer in
                ghostty_surface_inject_output(surface, buffer.baseAddress!.advanced(by: start), count)
            }
            ghostty_app_tick(app)
        }
        pump(ticks: 5)
    }
}


private let resetScreen = "\u{1b}[3J\u{1b}[2J\u{1b}[H"
private struct Captured {
    let handle: ghostty_search_document_t
    let text: String
    init(_ surface: ghostty_surface_t) {
        var info = ghostty_search_document_info_s()
        handle = ghostty_surface_search_capture(surface, &info)!
        text = String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(info.text!).assumingMemoryBound(to: UInt8.self), count: info.text_len), as: UTF8.self)
    }
    func ranges(_ query: String) -> [ghostty_search_range_s] {
        let bytes = Array(text.utf8), needle = Array(query.utf8)
        var result: [ghostty_search_range_s] = []
        var pos = 0
        while pos + needle.count <= bytes.count {
            if bytes[pos..<pos+needle.count].elementsEqual(needle) {
                result.append(.init(start: pos, end: pos + needle.count))
                pos += needle.count
            } else { pos += 1 }
        }
        return result
    }
    func free() { ghostty_search_document_free(handle) }
}
private func commit(_ surface: ghostty_surface_t, _ doc: Captured, _ ranges: [ghostty_search_range_s], keep: Bool = false) -> (UInt64, Int64) {
    var id: UInt64 = 0
    let selected = ranges.withUnsafeBufferPointer {
        ghostty_surface_search_set_results(surface, doc.handle, $0.baseAddress, $0.count, keep, &id)
    }
    return (id, selected)
}
private func visible(_ surface: ghostty_surface_t, _ id: UInt64) -> [ghostty_search_visible_s] {
    var buffer = [ghostty_search_visible_s](repeating: .init(), count: 4096)
    var count = 0
    let ok = buffer.withUnsafeMutableBufferPointer {
        ghostty_surface_search_visible(surface, id, $0.baseAddress, $0.count, &count)
    }
    precondition(ok, "visible capacity/rejection count=\(count)")
    return Array(buffer.prefix(count))
}
private func action(_ surface: ghostty_surface_t, _ name: String) {
    name.withCString { precondition(ghostty_surface_binding_action(surface, $0, UInt(name.utf8.count))) }
}
private var callbackCount = 0
private let countChange: ghostty_search_changed_cb = { _, document in
    precondition(document)
    callbackCount += 1
}
@main struct SearchResultsFixture {
    @MainActor static func main() {
        guard let fixture = EngineFixture(), let surface = fixture.makeSurface() else { fatalError("fixture unavailable") }
        defer { fixture.shutdown() }
        fixture.inject(resetScreen + String(repeating: "line\r\n", count: 30) + "NEEDLE", into: surface)
        let doc = Captured(surface); defer { doc.free() }
        let (id, selected) = commit(surface, doc, doc.ranges("NEEDLE"))
        precondition(selected == -1)
        var spans = visible(surface, id)
        precondition(spans.count == 1 && spans[0].row == 23 && spans[0].x0 == 0 && spans[0].x1 == 6)
        fixture.inject("\r\nhello\r\n", into: surface)
        spans = visible(surface, id)
        precondition(spans.count == 1 && spans[0].row == 21 && spans[0].x1 == 6, "append must retain anchor")
        precondition(ghostty_surface_search_select(surface, id, 0, true))
        precondition(visible(surface, id)[0].tag == 1)
        let fresh = Captured(surface); defer { fresh.free() }
        let (freshID, inherited) = commit(surface, fresh, fresh.ranges("NEEDLE"), keep: true)
        precondition(inherited == 0)
        fixture.inject("\u{1b}[?1049hALT", into: surface)
        precondition(visible(surface, freshID).isEmpty)
        fixture.inject("\u{1b}[?1049l", into: surface)
        precondition(visible(surface, freshID).count == 1)
        fixture.inject(String(repeating: "hello\r\n", count: 100), into: surface)
        precondition(ghostty_surface_search_select(surface, freshID, 0, true))
        let top = visible(surface, freshID)
        precondition(top.count == 1)
        fixture.inject(String(repeating: "hello\r\n", count: 1000), into: surface)
        let retained = visible(surface, freshID)
        precondition(top.map(\.row) == retained.map(\.row))
        precondition(ghostty_surface_search_select(surface, freshID, 0, true))
        precondition(visible(surface, freshID).count == 1)
        // Overwrite NEEDLE at the first viewport row after reveal; no refresh.
        fixture.inject("\u{1b}[1;1HXXXXXX", into: surface)
        // Cursor addressing is active-area relative, so test overwrite on a new surface below.
        let second = fixture.makeSurface()!
        var crossID: UInt64 = 0
        let range = doc.ranges("NEEDLE")
        precondition(range.withUnsafeBufferPointer { ghostty_surface_search_set_results(second, doc.handle, $0.baseAddress, $0.count, false, &crossID) } == -2)
        fixture.inject(resetScreen + "NEEDLE", into: second)
        let overwrite = Captured(second); defer { overwrite.free() }
        let (overwriteID, _) = commit(second, overwrite, overwrite.ranges("NEEDLE"))
        fixture.inject("\rXXXXXX", into: second)
        precondition(visible(second, overwriteID).isEmpty)
        precondition(!ghostty_surface_search_select(second, overwriteID, 0, true))
        let stale = commit(second, overwrite, overwrite.ranges("NEEDLE"))
        precondition(stale.1 == -1 && visible(second, stale.0).isEmpty)
        let badRanges: [[ghostty_search_range_s]] = [
            [.init(start: 0, end: 0)], [.init(start: 0, end: overwrite.text.utf8.count + 1)],
            [.init(start: 2, end: 3), .init(start: 0, end: 1)],
            [.init(start: 0, end: 7)]
        ]
        for bad in badRanges { precondition(commit(second, overwrite, bad).1 == -2) }
        ghostty_surface_search_clear_results(second)
        precondition(visible(second, stale.0).isEmpty)
        fixture.inject(resetScreen + "\u{1b}]8;;https://example.test\u{1b}\\e\u{301}中\u{1b}]8;;\u{1b}\\", into: second)
        let unicode = Captured(second); defer { unicode.free() }
        let (unicodeID, _) = commit(second, unicode, unicode.ranges("e\u{301}中"))
        let unicodeSpans = visible(second, unicodeID)
        precondition(unicodeSpans.count == 1 && unicodeSpans[0].x1 == 3 && unicodeSpans[0].tag == 2)
        precondition(commit(second, unicode, [.init(start: 2, end: 3)]).1 == -2)
        let cell = fixture.cellSize(of: second)
        ghostty_surface_set_size(second, cell.width * 40, cell.height * 24)
        fixture.pump()
        precondition(visible(second, unicodeID).isEmpty)
        // Window scrolling generates zero document callbacks and no search pull.
        ghostty_surface_search_set_callback(surface, countChange, nil)
        fixture.pump(); callbackCount = 0
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<200 { action(surface, "scroll_page_up"); action(surface, "scroll_page_down") }
        fixture.pump()
        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
        precondition(callbackCount == 0)
        ghostty_surface_search_set_callback(surface, nil, nil)
        print("ENGINE_FIXTURE PASS I1/I2/I7/I8/I9; scroll400_ms=\(elapsed); viewport_callbacks=\(callbackCount)")
    }
}
