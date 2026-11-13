import AppKit
import GhosttyKit

// Embedded environment lifetime: the embedder may setenv/unsetenv after
// ghostty_init. Ghostty must keep reading its own copy, never the libc vector
// it was handed (1.4 regression: environMap() in Surface.init read a stale
// slice and crashed with exit 139 / "start index > end index").

private func stubWakeup(_ userdata: UnsafeMutableRawPointer?) {}
private func stubAction(_ app: ghostty_app_t?, _ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool { true }
private func stubReadClipboard(_ userdata: UnsafeMutableRawPointer?, _ kind: ghostty_clipboard_e,
                               _ state: UnsafeMutableRawPointer?, _ mimes: UnsafePointer<UnsafePointer<CChar>?>?,
                               _ count: Int, _ confirm: Bool) -> ghostty_clipboard_read_result_e {
    GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
}
private func stubConfirmReadClipboard(_ userdata: UnsafeMutableRawPointer?,
                                      _ request: UnsafePointer<ghostty_clipboard_confirm_s>?,
                                      _ state: UnsafeMutableRawPointer?, _ req: ghostty_clipboard_request_e) {}
private func stubReadPTY(_ userdata: UnsafeMutableRawPointer?, _ bytes: UnsafePointer<CChar>?, _ len: Int) {}
private func stubWriteClipboard(_ userdata: UnsafeMutableRawPointer?, _ kind: ghostty_clipboard_e,
                                _ content: UnsafePointer<ghostty_clipboard_content_s>?, _ count: Int,
                                _ confirm: Bool) {}
private func stubCloseSurface(_ userdata: UnsafeMutableRawPointer?, _ processAlive: Bool) {}
private func stubWriteInput(_ userdata: UnsafeMutableRawPointer?, _ bytes: UnsafePointer<CChar>?, _ len: Int) {}
private func stubResize(_ userdata: UnsafeMutableRawPointer?, _ cols: UInt16, _ rows: UInt16) {}

/// Shifts, grows and rewrites the libc environment the way an embedder (or
/// another test in the same process) does after ghostty_init.
private func mutateEnvironment(round: Int) {
    for i in 0..<8 { unsetenv("ENVIRON_LIFETIME_\(round)_\(i)") }
    for i in 0..<64 { setenv("ENVIRON_LIFETIME_GROW_\(round)_\(i)", String(repeating: "x", count: i), 1) }
    setenv("ENVIRON_LIFETIME_REWRITE", String(repeating: "y", count: 4096 + round), 1)
}

@main struct EnvironLifetimeFixture {
    @MainActor static func main() {
        _ = NSApplication.shared
        for round in 0..<3 {
            for i in 0..<8 { setenv("ENVIRON_LIFETIME_\(round)_\(i)", "initial", 1) }
        }
        setenv("ENVIRON_LIFETIME_REWRITE", "initial", 1)
        precondition(ghostty_init(0, nil) == 0)
        mutateEnvironment(round: 0)

        guard let config = ghostty_config_new() else { fatalError("config") }
        ghostty_config_load_default_files(config)   // environMap() via config/file_load.zig
        let path = NSTemporaryDirectory() + "environ-lifetime-\(UUID().uuidString).ghostty"
        try! "window-vsync = false\n".write(toFile: path, atomically: true, encoding: .utf8)
        ghostty_config_load_file(config, path)
        try? FileManager.default.removeItem(atPath: path)
        ghostty_config_finalize(config)
        mutateEnvironment(round: 1)

        var runtime = ghostty_runtime_config_s(
            userdata: nil, supports_selection_clipboard: false, wakeup_cb: stubWakeup,
            action_cb: stubAction, read_clipboard_cb: stubReadClipboard,
            confirm_read_clipboard_cb: stubConfirmReadClipboard, read_pty_cb: stubReadPTY,
            write_clipboard_cb: stubWriteClipboard, close_surface_cb: stubCloseSurface,
            write_input_cb: stubWriteInput, resize_cb: stubResize)
        guard let app = ghostty_app_new(&runtime, config) else { fatalError("app") }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 480),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false

        var surfaces: [ghostty_surface_t] = []
        for round in 1...2 {
            mutateEnvironment(round: round)
            let view = NSView(frame: window.contentRect(forFrameRect: window.frame))
            view.wantsLayer = true
            var surfaceConfig = ghostty_surface_config_new()
            surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
            surfaceConfig.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
                nsview: Unmanaged.passUnretained(view).toOpaque()))
            surfaceConfig.scale_factor = 2.0
            surfaceConfig.font_size = 14
            surfaceConfig.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
            surfaceConfig.external_io = true
            // Per-surface variables keep travelling through env_vars.
            let surface: ghostty_surface_t? = "ENVIRON_LIFETIME_SURFACE".withCString { key in
                "surface-\(round)".withCString { value in
                    var env = [ghostty_env_var_s(key: key, value: value)]
                    return env.withUnsafeMutableBufferPointer { buffer in
                        surfaceConfig.env_vars = buffer.baseAddress
                        surfaceConfig.env_var_count = buffer.count
                        return ghostty_surface_new(app, &surfaceConfig)
                    }
                }
            }
            guard let surface else { fatalError("surface \(round)") }
            surfaces.append(surface)
            let bytes = Array("round \(round)\r\n".utf8)
            bytes.withUnsafeBufferPointer { ghostty_surface_inject_output(surface, $0.baseAddress!, $0.count) }
            ghostty_surface_set_size(surface, 1600, 900)
            for _ in 0..<10 {
                ghostty_app_tick(app)
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
            }
        }
        for surface in surfaces { ghostty_surface_free(surface) }
        ghostty_app_free(app)
        ghostty_config_free(config)
        print("ENVIRON_LIFETIME PASS surfaces=\(surfaces.count)")
    }
}
