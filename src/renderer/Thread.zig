//! Represents the renderer thread logic. The renderer thread is able to
//! be woken up to render.
pub const Thread = @This();

const std = @import("std");
const builtin = @import("builtin");
const global = @import("../global.zig");
const xev = global.xev;
const crash = @import("../crash/main.zig");
const internal_os = @import("../os/main.zig");
const rendererpkg = @import("../renderer.zig");
const apprt = @import("../apprt.zig");
const configpkg = @import("../config.zig");
const terminalpkg = @import("../terminal/main.zig");
const BlockingQueue = @import("../datastruct/main.zig").BlockingQueue;

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.renderer_thread);

const CURSOR_BLINK_INTERVAL = 600;

/// Whether calls to `drawFrame` must be done from the app thread.
///
/// The type used for sending messages to the IO thread. For now this is
/// hardcoded with a capacity. We can make this a comptime parameter in
/// the future if we want it configurable.
pub const Mailbox = BlockingQueue(rendererpkg.Message, 64);

/// Allocator used for some state
alloc: std.mem.Allocator,

/// The main event loop for the application. The user data of this loop
/// is always the allocator used to create the loop. This is a convenience
/// so that users of the loop always have an allocator.
loop: xev.Loop,

/// This can be used to wake up the renderer and force a render safely from
/// any thread.
wakeup: xev.Async,
wakeup_c: xev.Completion = .{},

/// This can be used to stop the renderer on the next loop iteration.
stop: xev.Async,
stop_c: xev.Completion = .{},

/// The timer used for animations (custom shaders, Kitty graphics).
/// Normal rendering is driven by wakeup messages instead.
render_h: xev.Timer,
render_c: xev.Completion = .{},
render_c_cancel: xev.Completion = .{},

/// The kind of work the currently scheduled animation wake needs,
/// stored when the timer is armed.
animation_wake: rendererpkg.Renderer.AnimationWake.Kind = .draw,

/// This async is used to force a draw immediately. This does not
/// coalesce like the wakeup does.
draw_now: xev.Async,
draw_now_c: xev.Completion = .{},

/// CNDF: display refresh ticks recorded by the display link callback. See
/// `DisplayTick`.
display_tick: DisplayTick = .{},

/// CNDF: render coalescing policy state (`cndf-render-coalesce`). Owned by
/// this thread.
coalescer: Coalescer = .{},

/// CNDF: one-shot watchdog for a coalesced frame, in case the display link
/// tick it waits for never arrives. Separate from the animation timer.
coalesce_h: xev.Timer,
coalesce_c: xev.Completion = .{},
coalesce_c_cancel: xev.Completion = .{},

/// The timer used for cursor blinking
cursor_h: xev.Timer,
cursor_c: xev.Completion = .{},
cursor_c_cancel: xev.Completion = .{},

/// Incremental scrollback compression scheduling.
compression: Compression = undefined,

/// The surface we're rendering to.
surface: *apprt.Surface,

/// The underlying renderer implementation.
renderer: *rendererpkg.Renderer,

/// Pointer to the shared state that is used to generate the final render.
state: *rendererpkg.State,

/// The mailbox that can be used to send this thread messages. Note
/// this is a blocking queue so if it is full you will get errors (or block).
mailbox: *Mailbox,

/// Configuration we need derived from the main config.
config: DerivedConfig,

flags: packed struct {
    /// This is true when a blinking cursor should be visible and false
    /// when it should not be visible. This is toggled on a timer by the
    /// thread automatically.
    cursor_blink_visible: bool = false,

    /// This is true when the inspector is active.
    has_inspector: bool = false,

    /// This is true when the view is visible. This is used to determine
    /// if we should be rendering or not.
    visible: bool = true,

    /// This is true when the view is focused. This defaults to true
    /// and it is up to the apprt to set the correct value.
    focused: bool = true,
} = .{},

pub const DerivedConfig = struct {
    scrollback_compression: bool,
    render_coalesce: bool,

    pub fn init(config: *const configpkg.Config) DerivedConfig {
        return .{
            .scrollback_compression = config.@"scrollback-compression",
            .render_coalesce = config.@"cndf-render-coalesce",
        };
    }
};

/// Initialize the thread. This does not START the thread. This only sets
/// up all the internal state necessary prior to starting the thread. It
/// is up to the caller to start the thread with the threadMain entrypoint.
pub fn init(
    alloc: Allocator,
    config: *const configpkg.Config,
    surface: *apprt.Surface,
    renderer_impl: *rendererpkg.Renderer,
    state: *rendererpkg.State,
) !Thread {
    // Create our event loop.
    var loop = try xev.Loop.init(.{});
    errdefer loop.deinit();

    // This async handle is used to "wake up" the renderer and force a render.
    var wakeup_h = try xev.Async.init();
    errdefer wakeup_h.deinit();

    // This async handle is used to stop the loop and force the thread to end.
    var stop_h = try xev.Async.init();
    errdefer stop_h.deinit();

    // The primary timer for rendering.
    var render_h = try xev.Timer.init();
    errdefer render_h.deinit();

    // Draw now async, see comments.
    var draw_now = try xev.Async.init();
    errdefer draw_now.deinit();

    // CNDF: coalesced frame watchdog.
    var coalesce_h = try xev.Timer.init();
    errdefer coalesce_h.deinit();

    // Setup a timer for blinking the cursor
    var cursor_timer = try xev.Timer.init();
    errdefer cursor_timer.deinit();

    // The mailbox for messaging this thread
    var mailbox = try Mailbox.create(alloc);
    errdefer mailbox.destroy(alloc);

    const derived: DerivedConfig = .init(config);
    var result: Thread = .{
        .alloc = alloc,
        .config = derived,
        .coalescer = .{ .enabled = derived.render_coalesce },
        .loop = loop,
        .wakeup = wakeup_h,
        .stop = stop_h,
        .render_h = render_h,
        .draw_now = draw_now,
        .coalesce_h = coalesce_h,
        .cursor_h = cursor_timer,
        .surface = surface,
        .renderer = renderer_impl,
        .state = state,
        .mailbox = mailbox,
    };

    // Only enable compression if we have it enabled... save some
    // minor resources.
    if (comptime terminalpkg.compression_enabled) {
        result.compression = try .init();
    }

    return result;
}

/// Clean up the thread. This is only safe to call once the thread
/// completes executing; the caller must join prior to this.
pub fn deinit(self: *Thread) void {
    // Stop has joined the producer/consumer threads. Release any undelivered
    // embedded-search message reference without touching its opaque node keys.
    while (self.mailbox.pop(global.io())) |message| {
        switch (message) {
            .search_results => |v| if (v.set) |set| set.release(),
            else => {},
        }
    }
    self.stop.deinit();
    self.wakeup.deinit();
    self.render_h.deinit();
    self.draw_now.deinit();
    self.coalesce_h.deinit();
    self.cursor_h.deinit();
    if (comptime terminalpkg.compression_enabled)
        self.compression.deinit();
    self.loop.deinit();

    // Nothing can possibly access the mailbox anymore, destroy it.
    self.mailbox.destroy(self.alloc);
}

/// The main entrypoint for the thread.
pub fn threadMain(self: *Thread) void {
    // Call child function so we can use errors...
    self.threadMain_() catch |err| {
        // In the future, we should expose this on the thread struct.
        log.warn("error in renderer err={}", .{err});
    };
}

fn threadMain_(self: *Thread) !void {
    defer log.debug("renderer thread exited", .{});

    // Right now, on Darwin, `std.Thread.setName` can only name the current
    // thread, and we have no way to get the current thread from within it,
    // so instead we use this code to name the thread instead.
    if (builtin.target.os.tag.isDarwin()) {
        internal_os.macos.pthread_setname_np(&"renderer".*);
    }

    // Setup our crash metadata
    crash.sentry.thread_state = .{
        .type = .renderer,
        .surface = self.renderer.surface_mailbox.surface,
    };
    defer crash.sentry.thread_state = null;

    // Setup our thread QoS
    self.setQosClass();

    // CNDF: the display link callback reaches draw_now through the tick
    // record, which needs our final address.
    self.display_tick.draw_now = &self.draw_now;

    // Run our loop start/end callbacks if the renderer cares.
    const has_loop = @hasDecl(rendererpkg.Renderer, "loopEnter");
    if (has_loop) try self.renderer.loopEnter(self);
    defer if (has_loop) self.renderer.loopExit();

    // Run our thread start/end callbacks. This is important because some
    // renderers have to do per-thread setup. For example, OpenGL has to set
    // some thread-local state since that is how it works.
    try self.renderer.threadEnter(self.surface);
    defer self.renderer.threadExit();

    // Start the async handlers
    self.wakeup.wait(&self.loop, &self.wakeup_c, Thread, self, wakeupCallback);
    self.stop.wait(&self.loop, &self.stop_c, Thread, self, stopCallback);
    self.draw_now.wait(&self.loop, &self.draw_now_c, Thread, self, drawNowCallback);

    // Send an initial wakeup message so that we render right away.
    try self.wakeup.notify();

    // Start blinking the cursor.
    self.cursor_h.run(
        &self.loop,
        &self.cursor_c,
        cursorBlinkInterval(),
        Thread,
        self,
        cursorTimerCallback,
    );

    // Arm the animation timer in case the renderer already needs
    // animation wakes (e.g. custom shaders loaded at startup).
    self.armAnimationTimer();

    // Run
    log.debug("starting renderer thread", .{});
    defer log.debug("starting renderer thread shutdown", .{});
    defer if (self.config.render_coalesce) log.info(
        "render coalesce counters {f}",
        .{self.coalescer.counters},
    );
    _ = try self.loop.run(.until_done);
}

fn setQosClass(self: *const Thread) void {
    // Thread QoS classes are only relevant on macOS.
    if (comptime !builtin.target.os.tag.isDarwin()) return;

    const class: internal_os.macos.QosClass = class: {
        // If we aren't visible (our view is fully occluded) then we
        // always drop our rendering priority down because it's just
        // mostly wasted work.
        //
        // The renderer itself should be doing this as well (for example
        // Metal will stop our DisplayLink) but this also helps with
        // general forced updates and CPU usage i.e. a rebuild cells call.
        if (!self.flags.visible) break :class .utility;

        // If we're not focused, but we're visible, then we set a higher
        // than default priority because framerates still matter but it isn't
        // as important as when we're focused.
        if (!self.flags.focused) break :class .user_initiated;

        // We are focused and visible, we are the definition of user interactive.
        break :class .user_interactive;
    };

    if (internal_os.macos.setQosClass(class)) {
        log.debug("thread QoS class set class={}", .{class});
    } else |err| {
        log.warn("error setting QoS class err={}", .{err});
    }
}

/// Drain the mailbox.
fn drainMailbox(self: *Thread) !void {
    // There's probably a more elegant way to do this...
    //
    // This is effectively an @autoreleasepool{} block, which we need in
    // order to ensure that autoreleased objects are properly released.
    const pool = if (builtin.target.os.tag.isDarwin())
        @import("objc").AutoreleasePool.init()
    else
        void;
    defer if (builtin.target.os.tag.isDarwin()) pool.deinit();

    while (self.mailbox.pop(global.io())) |message| {
        log.debug("mailbox message={}", .{message});

        // CNDF: everything but the periodic cursor blink reset and
        // presentation health is a UI change whose frame must not wait for
        // a coalesced tick. `.reset_cursor_blink` is deliberately not an
        // input signal: termio sends it about every 500ms during output.
        switch (message) {
            .reset_cursor_blink, .presentation_health => {},
            else => self.coalescer.mailbox_immediate = true,
        }

        switch (message) {
            .crash => @panic("crash request, crashing intentionally"),

            .visible => |v| visible: {
                // If our state didn't change we do nothing.
                if (self.flags.visible == v) break :visible;

                // Set our visible state
                self.flags.visible = v;

                // CNDF: the display link restarts with a new cadence.
                self.coalescer.resetCadence();

                // Visibility affects our QoS class
                self.setQosClass();

                // If we became visible then we immediately rebuild cells
                // (renderCallback skips updateFrame while invisible) and
                // draw. Going through renderCallback also reschedules
                // any Kitty graphics animation wakeup that lapsed
                // while we were invisible.
                if (v) _ = renderCallback(self, undefined, undefined, {});

                // Notify the renderer so it can update any state.
                self.renderer.setVisible(v);

                // Note that we're explicitly today not stopping any
                // cursor timers, draw timers, etc. These things have very
                // little resource cost and properly maintaining their active
                // state across different transitions is going to be bug-prone,
                // so its easier to just let them keep firing and have them
                // check the visible state themselves to control their behavior.
            },

            .focus => |v| focus: {
                // If our state didn't change we do nothing.
                if (self.flags.focused == v) break :focus;

                // Set our state
                self.flags.focused = v;

                // Focus affects our QoS class
                self.setQosClass();

                // Set it on the renderer
                try self.renderer.setFocus(v);

                // Focus gates custom shader animation, so re-arm
                // the animation timer for the new state.
                self.armAnimationTimer();

                if (!v) {
                    // If we're not focused, then we stop the cursor blink
                    if (self.cursor_c.state() == .active and
                        self.cursor_c_cancel.state() == .dead)
                    {
                        self.cursor_h.cancel(
                            &self.loop,
                            &self.cursor_c,
                            &self.cursor_c_cancel,
                            void,
                            null,
                            cursorCancelCallback,
                        );
                    }
                } else {
                    // If we're focused, we immediately show the cursor again
                    // and then restart the timer.
                    if (self.cursor_c.state() != .active) {
                        self.flags.cursor_blink_visible = true;
                        self.cursor_h.run(
                            &self.loop,
                            &self.cursor_c,
                            cursorBlinkInterval(),
                            Thread,
                            self,
                            cursorTimerCallback,
                        );
                    }
                }
            },

            .reset_cursor_blink => {
                self.flags.cursor_blink_visible = true;
                if (self.cursor_c.state() == .active) {
                    self.cursor_h.reset(
                        &self.loop,
                        &self.cursor_c,
                        &self.cursor_c_cancel,
                        cursorBlinkInterval(),
                        Thread,
                        self,
                        cursorTimerCallback,
                    );
                }
            },

            .font_grid => |grid| {
                self.renderer.setFontGrid(grid.grid);
                grid.set.deref(grid.old_key);
            },

            .presentation_health => |v| self.renderer.setPresentationHealth(v),

            .resize => |v| self.renderer.setScreenSize(v),

            .change_config => |config| {
                defer config.alloc.destroy(config.thread);
                defer config.alloc.destroy(config.impl);
                try self.changeConfig(config.thread);
                try self.renderer.changeConfig(config.impl);

                // The config affects what animation wakes the
                // renderer needs (custom shaders, animation mode).
                self.armAnimationTimer();
            },

            .search_viewport_matches => |v| {
                // Note we don't free the new value because we expect our
                // allocators to match.
                if (self.renderer.search_matches) |*m| m.arena.deinit();
                self.renderer.search_matches = v;
                self.renderer.search_matches_dirty = true;
            },

            .search_selected_match => |v| {
                // Note we don't free the new value because we expect our
                // allocators to match.
                if (self.renderer.search_selected_match) |*m| m.arena.deinit();
                self.renderer.search_selected_match = v;
                self.renderer.search_matches_dirty = true;
            },

            .search_results => |v| {
                if (self.renderer.search_results) |set| set.release();
                self.renderer.search_results = v.set;
                self.renderer.search_result_selected = v.selected;
                self.renderer.search_matches_dirty = true;
            },

            .inspector => |v| {
                self.flags.has_inspector = v;
            },

            .macos_display_id => |v| {
                if (@hasDecl(rendererpkg.Renderer, "setMacOSDisplayID")) {
                    try self.renderer.setMacOSDisplayID(v, &self.display_tick);
                }

                // CNDF: a new display has its own refresh period.
                self.coalescer.resetCadence();
            },
        }
    }
}

fn changeConfig(self: *Thread, config: *const DerivedConfig) !void {
    // A newly enabled scheduler must reconsider existing history even when no
    // terminal activity occurred while compression was disabled.
    if (comptime terminalpkg.compression_enabled) {
        if (!self.config.scrollback_compression and
            config.scrollback_compression)
        {
            self.compression.activity = null;
        }
    }

    self.config = config.*;

    // CNDF: disabling drops any pending coalesced frame. The config change
    // already forces an immediate update for this wake (mailbox), which
    // reflects the final state; from then on the upstream path is used.
    self.coalescer.enabled = config.render_coalesce;
}

/// Trigger a draw. This will not update frame data or anything, it will
/// just trigger a draw/paint.
fn drawFrame(self: *Thread, now: bool) void {
    // If we're invisible, we do not draw.
    if (!self.flags.visible) return;

    // If the renderer is managing a vsync on its own, we only draw
    // when we're forced to via `now`.
    if (!now and self.renderer.hasVsync()) return;

    self.renderer.drawFrame(false) catch |err|
        log.warn("error drawing err={}", .{err});
}

fn wakeupCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch |err| {
        log.err("error in wakeup err={}", .{err});
        return .rearm;
    };

    const t = self_.?;

    // When we wake up, we check the mailbox. Mailbox producers should
    // wake up our thread after publishing.
    t.drainMailbox() catch |err|
        log.err("error draining mailbox err={}", .{err});

    // CNDF: render immediately unless this wake is bulk native output that
    // can join the next display refresh (see `Coalescer`).
    switch (t.coalesceDecide()) {
        .update => _ = renderCallback(t, undefined, undefined, {}),
        .wait => {},
        .wait_new => t.startCoalescePending(),
    }

    // PageList mutations maintain their own compression dirty state. Checking
    // it here covers output, resize, and viewport scrolling uniformly.
    t.compression.wake(t);

    // The below is not used anymore but if we ever want to introduce
    // a configuration to introduce a delay to coalesce renders, we can
    // use this.
    //
    // // If the timer is already active then we don't have to do anything.
    // if (t.render_c.state() == .active) return .rearm;
    //
    // // Timer is not active, let's start it
    // t.render_h.run(
    //     &t.loop,
    //     &t.render_c,
    //     10,
    //     Thread,
    //     t,
    //     renderCallback,
    // );

    return .rearm;
}

fn drawNowCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch |err| {
        log.err("error in draw now err={}", .{err});
        return .rearm;
    };

    const t = self_.?;

    // CNDF: record the display cadence, then fold a coalesced frame into
    // this tick. The frame data is updated BEFORE the draw so it is shown
    // on this refresh, not the next one.
    t.coalescer.onTick(t.display_tick.load());
    if (t.coalescer.pending) {
        t.coalescer.counters.tick_flush += 1;
        _ = renderCallback(t, undefined, undefined, {});
    }

    // Draw immediately
    t.drawFrame(true);

    return .rearm;
}

/// CNDF: decide how to handle a renderer wake. Called after the mailbox
/// is drained.
fn coalesceDecide(t: *Thread) Coalescer.Decision {
    const shared = &t.state.coalesce;

    // Consume the immediate request even when disabled so a stale request
    // never leaks into a later enable.
    const requested = shared.immediate.swap(false, .acq_rel);
    const mailbox = t.coalescer.mailbox_immediate;
    t.coalescer.mailbox_immediate = false;

    if (!t.coalescer.enabled) return .update;

    return t.coalescer.onWake(.{
        .now_ns = rendererpkg.State.coalesceNowNs(global.io()),
        .generation = shared.output_generation.load(.acquire),
        .idle_through = shared.idle_through_generation.load(.acquire),
        .input_ns = shared.input_ns.load(.acquire),
        .immediate = requested or mailbox or t.flags.has_inspector,
        .vsync = t.flags.visible and
            t.renderer.display_realized and
            t.renderer.hasVsync(),
    });
}

/// CNDF: a coalesced frame just became pending. Keep the display link
/// running for it and arm the one-shot watchdog at first pending + P. The
/// deadline is never extended by later output.
fn startCoalescePending(t: *Thread) void {
    t.renderer.setCoalescePending(true);
    t.coalesce_h.reset(
        &t.loop,
        &t.coalesce_c,
        &t.coalesce_c_cancel,
        t.coalescer.watchdogDelayMs(),
        Thread,
        t,
        coalesceWatchdogCallback,
    );
}

/// CNDF: the display link tick a coalesced frame waited for did not come
/// within one period. Update and draw now, and re-learn the cadence.
fn coalesceWatchdogCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        // Superseded by a newer pending frame's deadline.
        error.Canceled => return .disarm,
        else => {
            log.warn("error in coalesce watchdog err={}", .{err});
            return .disarm;
        },
    };
    const t = self_ orelse return .disarm;

    // Already reflected by a tick, input, idle flush or animation.
    if (!t.coalescer.pending) return .disarm;

    t.coalescer.counters.watchdog += 1;
    t.coalescer.resetCadence();
    _ = renderCallback(t, undefined, undefined, {});

    // renderCallback only draws on its own without vsync.
    if (t.renderer.hasVsync()) t.drawFrame(true);
    return .disarm;
}

fn renderCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        // Sent when a scheduled animation wakeup is superseded by a
        // newer one (Timer.reset cancels the pending run). Nothing to
        // do; the replacement timer carries on.
        error.Canceled => return .disarm,
        else => unreachable,
    };
    const t: *Thread = self_ orelse {
        // This shouldn't happen so we log it.
        log.warn("render callback fired without data set", .{});
        return .disarm;
    };

    // CNDF: whatever happens below resolves a pending coalesced frame:
    // it is updated, or there is nothing to show (hidden, unrealized,
    // synchronized output, error). A later output wake decides again, so
    // a frame that could not be reflected never turns into a retry loop.
    t.clearCoalescePending();

    // If the display is now unrealized, release GPU resources now
    // we're on the render thread, and do not try to update and draw
    // this frame.
    if (!t.renderer.display_realized) {
        t.renderer.draw_mutex.lockUncancelable(global.io());
        defer t.renderer.draw_mutex.unlock(global.io());

        t.renderer.releaseGpuResources();
        return .disarm;
    }

    // If we're not visible there's no point spending CPU rebuilding cells —
    // we'll catch up when the .visible mailbox message flips us back on.
    // Kitty graphics animations pause with us and resume on visibility.
    if (!t.flags.visible) return .disarm;

    // Update our frame data
    t.coalescer.counters.update += 1;
    t.renderer.snapshot_output_generation = null;
    if (t.renderer.updateFrame(
        t.state,
        t.flags.cursor_blink_visible,
    )) {
        // CNDF: only a snapshot that actually happened counts, with the
        // generation read under the snapshot's own lock. Synchronized
        // output leaves it null.
        if (t.renderer.snapshot_output_generation) |gen| t.coalescer.reflect(gen);
    } else |err| log.warn("error rendering err={}", .{err});

    // Draw
    t.drawFrame(false);

    // Schedule the next animation wake, if the renderer needs one.
    t.armAnimationTimer();

    return .disarm;
}

/// CNDF: forget a pending coalesced frame and release its display link
/// keepalive. The watchdog may still fire; it does nothing then.
fn clearCoalescePending(t: *Thread) void {
    if (!t.coalescer.pending) return;
    t.coalescer.pending = false;
    t.renderer.setCoalescePending(false);
}

/// Schedule the animation timer for the renderer's next animation
/// wake, if it needs one.
///
/// This is called after every frame update or animation draw and
/// whenever the wake inputs change (focus, config, visibility
/// regain). Resetting a pending timer is always safe: every call
/// recomputes the wake, so the deadline only ever moves toward the
/// actual next wake.
fn armAnimationTimer(self: *Thread) void {
    const wake = self.renderer.animationWake() orelse return;
    self.animation_wake = wake.kind;
    self.render_h.reset(
        &self.loop,
        &self.render_c,
        &self.render_c_cancel,
        wake.delay_ms,
        Thread,
        self,
        animationTimerCallback,
    );
}

fn animationTimerCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        // Sent when a scheduled animation wake is superseded by a
        // newer one (Timer.reset cancels the pending run). Nothing to
        // do; the replacement timer carries on.
        error.Canceled => return .disarm,
        else => unreachable,
    };
    const t: *Thread = self_ orelse {
        // This shouldn't happen so we log it.
        log.warn("animation callback fired without data set", .{});
        return .disarm;
    };

    // Animations pause entirely while we're invisible; the .visible
    // mailbox message re-arms us when we can be seen again.
    if (!t.flags.visible) return .disarm;

    switch (t.animation_wake) {
        // Frame data must be updated (a Kitty animation frame is
        // due). renderCallback updates, draws, and re-arms us.
        .update => return renderCallback(
            t,
            undefined,
            undefined,
            {},
        ),

        // A redraw alone suffices (custom shader time uniform).
        // Draw calls don't update from the terminal state so they
        // are much cheaper than a frame update.
        .draw => {
            t.drawFrame(false);
            t.armAnimationTimer();
            return .disarm;
        },
    }
}

fn cursorTimerCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        // This is sent when our timer is canceled. That's fine.
        error.Canceled => return .disarm,

        else => {
            log.warn("error in cursor timer callback err={}", .{err});
            unreachable;
        },
    };

    const t: *Thread = self_ orelse {
        // This shouldn't happen so we log it.
        log.warn("render callback fired without data set", .{});
        return .disarm;
    };

    t.flags.cursor_blink_visible = !t.flags.cursor_blink_visible;
    t.wakeup.notify() catch {};

    t.cursor_h.run(
        &t.loop,
        &t.cursor_c,
        cursorBlinkInterval(),
        Thread,
        t,
        cursorTimerCallback,
    );
    return .disarm;
}

fn cursorCancelCallback(
    _: ?*void,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.CancelError!void,
) xev.CallbackAction {
    // This makes it easier to work across platforms where different platforms
    // support different sets of errors, so we just unify it.
    const CancelError = xev.Timer.CancelError || error{
        Canceled,
        NotFound,
        Unexpected,
    };

    _ = r catch |err| switch (@as(CancelError, @errorCast(err))) {
        error.Canceled => {}, // success
        error.NotFound => {}, // completed before it could cancel
        else => {
            log.warn("error in cursor cancel callback err={}", .{err});
            unreachable;
        },
    };

    return .disarm;
}

// fn prepFrameCallback(h: *libuv.Prepare) void {
//     _ = h;
//
//     tracy.frameMark();
// }

fn stopCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch unreachable;
    self_.?.loop.stop();
    return .disarm;
}

/// Returns the interval for the blinking cursor in milliseconds.
fn cursorBlinkInterval() u64 {
    if (std.valgrind.runningOnValgrind() > 0) {
        // If we're running under Valgrind, the cursor blink adds enough
        // churn that it makes some stalls annoying unless you're on a
        // super powerful computer, so we delay it.
        //
        // This is a hack, we should change some of our cursor timer
        // logic to be more efficient:
        // https://github.com/ghostty-org/ghostty/issues/8003
        return CURSOR_BLINK_INTERVAL * 5;
    }

    return CURSOR_BLINK_INTERVAL;
}

/// CNDF: the most recent display link tick, written by the CoreVideo
/// callback thread and read by the renderer thread. The callback only
/// records and notifies `draw_now`; all decisions happen on the renderer
/// thread.
pub const DisplayTick = struct {
    /// Set by the renderer thread before the display link exists.
    draw_now: ?*xev.Async = null,

    /// Number of ticks recorded so far.
    seq: std.atomic.Value(u64) = .init(0),

    /// Awake clock nanoseconds of tick `seq`.
    ns: std.atomic.Value(u64) = .init(0),

    pub const Sample = struct { seq: u64, ns: u64 };

    /// Called on the display link thread once per refresh.
    pub fn record(self: *DisplayTick, now_ns: u64) void {
        self.ns.store(now_ns, .monotonic);
        _ = self.seq.fetchAdd(1, .release);
    }

    /// Called on the renderer thread. A tick racing with this may pair a
    /// new `ns` with an old `seq`; that only skews one interval sample,
    /// which the cadence filter tolerates.
    pub fn load(self: *const DisplayTick) Sample {
        const seq = self.seq.load(.acquire);
        return .{ .seq = seq, .ns = self.ns.load(.monotonic) };
    }
};

/// CNDF: render coalescing policy. Pure state, owned by the renderer
/// thread, with time and generations passed in so it can be tested with
/// a fake clock.
///
/// A wake is folded into the next display refresh ("wait") only when all
/// of these hold; otherwise the frame is updated immediately, which is the
/// upstream behavior:
///   - coalescing is enabled
///   - no immediate request (input, UI change, injected output, mailbox)
///   - outside the input guard window after the last input
///   - the display link is running and its period P has been observed
///   - the native producer is not idle through the latest generation
///   - at least `threshold_bytes` were parsed within the last P
pub const Coalescer = struct {
    /// Bulk output threshold within one display period. Initial policy
    /// value to be validated, not tuned.
    pub const threshold_bytes: u64 = 16 * 1024;

    /// How long after user input coalescing stays bypassed.
    pub const input_guard_ns: u64 = 50 * std.time.ns_per_ms;

    /// Plausible display periods (240Hz .. 20Hz). Tick intervals outside
    /// this range are gaps (link paused) or noise and are not learned.
    const min_period_ns: u64 = 4 * std.time.ns_per_ms;
    const max_period_ns: u64 = 50 * std.time.ns_per_ms;

    /// Valid intervals needed before the period is trusted.
    const period_samples_needed = 3;

    const window_len = 32;

    pub const Decision = enum {
        /// Update the frame now (upstream path).
        update,
        /// A coalesced frame is already pending; nothing to do.
        wait,
        /// A coalesced frame just became pending: keep the display link
        /// alive and arm the watchdog.
        wait_new,
    };

    pub const Wake = struct {
        now_ns: u64,
        generation: u64,
        idle_through: u64,
        input_ns: u64,
        immediate: bool,
        vsync: bool,
    };

    const Sample = struct { ns: u64, generation: u64 };

    enabled: bool = false,

    /// Set while draining the mailbox, consumed by the next decision.
    mailbox_immediate: bool = false,

    /// A coalesced frame is waiting for the next tick (or the watchdog).
    pending: bool = false,

    /// The output generation contained in the last frame snapshot.
    reflected: u64 = 0,

    /// Display cadence.
    tick_seq: u64 = 0,
    tick_ns: u64 = 0,
    period_ns: u64 = 0,
    period_samples: u8 = 0,

    /// Recent (time, generation) samples, oldest first from `head`.
    window: [window_len]Sample = undefined,
    window_count: usize = 0,
    window_head: usize = 0,

    counters: Counters = .{},

    pub const Counters = struct {
        update: u64 = 0,
        coalesced: u64 = 0,
        tick: u64 = 0,
        tick_flush: u64 = 0,
        idle_flush: u64 = 0,
        input_flush: u64 = 0,
        watchdog: u64 = 0,

        pub fn format(self: Counters, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print(
                "update={} coalesced={} tick={} tick_flush={} idle_flush={} input_flush={} watchdog={}",
                .{
                    self.update,     self.coalesced,  self.tick,
                    self.tick_flush, self.idle_flush, self.input_flush,
                    self.watchdog,
                },
            );
        }
    };

    pub fn onWake(self: *Coalescer, w: Wake) Decision {
        self.record(w.now_ns, w.generation);

        if (!self.enabled) return .update;

        const update = update: {
            if (w.immediate) break :update true;

            if (w.input_ns != 0 and w.now_ns -| w.input_ns < input_guard_ns) {
                if (self.pending) self.counters.input_flush += 1;
                break :update true;
            }

            if (!w.vsync or !self.periodKnown(w.now_ns)) break :update true;

            // Producer idle through everything parsed: show it now. A stale
            // idle (older than the generation) does not count.
            if (w.idle_through >= w.generation) {
                if (self.pending) self.counters.idle_flush += 1;
                break :update true;
            }

            if (self.bytesInPeriod(w.now_ns, w.generation) < threshold_bytes)
                break :update true;

            break :update false;
        };
        if (update) return .update;

        self.counters.coalesced += 1;
        if (self.pending) return .wait;
        self.pending = true;
        return .wait_new;
    }

    /// A frame snapshot containing `generation` completed.
    pub fn reflect(self: *Coalescer, generation: u64) void {
        self.reflected = @max(self.reflected, generation);
    }

    /// Record a display link tick read from `DisplayTick`.
    pub fn onTick(self: *Coalescer, tick: DisplayTick.Sample) void {
        if (tick.seq == self.tick_seq) return;
        self.counters.tick += 1;
        if (self.tick_seq != 0 and
            tick.seq > self.tick_seq and
            tick.ns > self.tick_ns)
        {
            const interval = (tick.ns - self.tick_ns) / (tick.seq - self.tick_seq);
            if (interval >= min_period_ns and interval <= max_period_ns) {
                self.period_ns = if (self.period_samples == 0)
                    interval
                else
                    (self.period_ns * 3 + interval) / 4;
                self.period_samples +|= 1;
            }
        }
        self.tick_seq = tick.seq;
        self.tick_ns = tick.ns;
    }

    /// Forget the observed cadence (start, restore, display change,
    /// missed tick). Until it is learned again every wake updates
    /// immediately.
    pub fn resetCadence(self: *Coalescer) void {
        self.period_samples = 0;
        self.period_ns = 0;
        self.tick_seq = 0;
        self.tick_ns = 0;
    }

    /// The period is trusted and the link ticked recently enough that the
    /// next tick is expected within it.
    pub fn periodKnown(self: *const Coalescer, now_ns: u64) bool {
        if (self.period_samples < period_samples_needed) return false;
        return now_ns -| self.tick_ns <= 2 * self.period_ns;
    }

    /// Watchdog delay for a frame that just became pending: one period,
    /// rounded up to whole milliseconds.
    pub fn watchdogDelayMs(self: *const Coalescer) u64 {
        const ns = @max(self.period_ns, min_period_ns);
        return std.math.divCeil(u64, ns, std.time.ns_per_ms) catch unreachable;
    }

    /// Bytes parsed within the last period: from the newest sample at
    /// least one period old. If the window doesn't reach that far back,
    /// the oldest sample undercounts, which errs toward updating.
    fn bytesInPeriod(self: *const Coalescer, now_ns: u64, generation: u64) u64 {
        const cutoff = now_ns -| self.period_ns;
        var base: ?u64 = null;
        var i: usize = 0;
        while (i < self.window_count) : (i += 1) {
            const sample = self.window[(self.window_head + i) % window_len];
            if (base == null) base = sample.generation;
            if (sample.ns <= cutoff) base = sample.generation else break;
        }
        return generation -| (base orelse generation);
    }

    fn record(self: *Coalescer, now_ns: u64, generation: u64) void {
        const sample: Sample = .{ .ns = now_ns, .generation = generation };
        if (self.window_count < window_len) {
            self.window[(self.window_head + self.window_count) % window_len] = sample;
            self.window_count += 1;
        } else {
            self.window[self.window_head] = sample;
            self.window_head = (self.window_head + 1) % window_len;
        }
    }
};

/// Schedules incremental terminal compression after renderer activity stops.
///
/// This owns all renderer-specific compression state. The terminal decides
/// when compression-relevant activity changes and performs the actual work;
/// the renderer only provides idle scheduling and avoids waiting for the
/// terminal lock.
const Compression = struct {
    const idle_interval = 250;
    const step_interval = 1;

    timer: xev.Timer,
    completion: xev.Completion = .{},
    reset_completion: xev.Completion = .{},
    activity: ?u64 = null,

    fn init() !Compression {
        return .{ .timer = try xev.Timer.init() };
    }

    fn deinit(self: *Compression) void {
        self.timer.deinit();
    }

    /// Start or postpone compression after a renderer wake.
    fn wake(self: *Compression, thread: *Thread) void {
        // If we have no compression then don't do anything.
        if (comptime !terminalpkg.compression_enabled) return;
        if (!thread.config.scrollback_compression) return;

        // PageList activity, rather than a generic renderer wake, restarts the
        // idle interval. In particular, the inspector wakes the renderer every
        // frame without changing terminal contents and must not starve this
        // timer indefinitely.
        if (thread.state.mutex.tryLock()) {
            defer thread.state.mutex.unlock(global.io());
            const activity = thread.state.terminal.compressionActivity();
            if (self.activity == activity) return;
            self.activity = activity;
        } else if (self.completion.state() == .active) {
            // Contention doesn't prove that compression-relevant activity
            // changed. Keep an existing deadline so frequent inspector frames
            // cannot postpone compression forever. The timer rechecks both the
            // activity token and lock availability before doing any work.
            return;
        }

        // Contention may mean parsing is active. Scheduling is a harmless
        // false positive when no compression work is actually pending, but is
        // necessary when no timer is already active.
        self.schedule(thread, idle_interval);
    }

    /// Start the one-shot timer, or move its deadline if it is already active.
    fn schedule(self: *Compression, thread: *Thread, delay_ms: u64) void {
        self.timer.reset(
            &thread.loop,
            &self.completion,
            &self.reset_completion,
            delay_ms,
            Thread,
            thread,
            timerCallback,
        );
    }

    fn timerCallback(
        thread_: ?*Thread,
        _: *xev.Loop,
        _: *xev.Completion,
        result: xev.Timer.RunError!void,
    ) xev.CallbackAction {
        _ = result catch |err| switch (err) {
            error.Canceled => return .disarm,
            else => {
                log.warn("error in compression timer err={}", .{err});
                return .disarm;
            },
        };

        const thread = thread_ orelse return .disarm;
        const self = &thread.compression;

        if (self.step(thread)) |delay| self.schedule(thread, delay);
        return .disarm;
    }

    /// Try one bounded step without waiting for the terminal lock. The return
    /// value is the delay before another attempt, or null when work is done.
    fn step(self: *Compression, thread: *Thread) ?u64 {
        if (!thread.config.scrollback_compression) return null;

        const state = thread.state;
        if (!state.mutex.tryLock()) return idle_interval;
        defer state.mutex.unlock(global.io());

        const activity = state.terminal.compressionActivity();
        if (self.activity != activity) {
            self.activity = activity;
            return idle_interval;
        }

        return switch (state.terminal.compress(.incremental)) {
            .pending => step_interval,
            .unsupported,
            .complete,
            => null,
        };
    }
};

const test_ms = std.time.ns_per_ms;

/// A coalescer that has learned a 60Hz-ish cadence (P = 16ms) with its
/// last tick at `t_ns`.
fn testCoalescer(t_ns: u64) Coalescer {
    var c: Coalescer = .{ .enabled = true };
    const p = 16 * test_ms;
    var seq: u64 = 1;
    while (seq <= 4) : (seq += 1) {
        c.onTick(.{ .seq = seq, .ns = t_ns - (4 - seq) * p });
    }
    return c;
}

fn testWake(now: u64, gen: u64) Coalescer.Wake {
    return .{
        .now_ns = now,
        .generation = gen,
        .idle_through = 0,
        .input_ns = 0,
        .immediate = false,
        .vsync = true,
    };
}

test "Coalescer: small output updates immediately, bulk output waits" {
    const testing = std.testing;
    const t0: u64 = 1000 * test_ms;
    var c = testCoalescer(t0);

    // A trickle within the period: immediate.
    try testing.expectEqual(.update, c.onWake(testWake(t0, 100)));
    try testing.expectEqual(.update, c.onWake(testWake(t0 + 2 * test_ms, 4000)));

    // Over the threshold within the last P: the first wake makes a frame
    // pending, the next ones just wait (no new deadline).
    try testing.expectEqual(.wait_new, c.onWake(testWake(t0 + 4 * test_ms, 20 * 1024)));
    try testing.expect(c.pending);
    try testing.expectEqual(.wait, c.onWake(testWake(t0 + 6 * test_ms, 40 * 1024)));
}

test "Coalescer: threshold is measured over the last period only" {
    const testing = std.testing;
    const t0: u64 = 1000 * test_ms;
    var c = testCoalescer(t0);

    _ = c.onWake(testWake(t0, 0));
    // 20 KiB spread over far more than P: the window base is the newest
    // sample at least P old, so only the recent bytes count.
    _ = c.onWake(testWake(t0 + 100 * test_ms, 15 * 1024));
    // The link kept ticking meanwhile.
    c.onTick(.{ .seq = 11, .ns = t0 + 112 * test_ms });
    try testing.expectEqual(.update, c.onWake(testWake(t0 + 117 * test_ms, 20 * 1024)));
    // Exactly at the threshold within P: waits.
    try testing.expectEqual(.wait_new, c.onWake(testWake(t0 + 118 * test_ms, 15 * 1024 + 16 * 1024)));
}

test "Coalescer: input guard boundary is exactly 50ms" {
    const testing = std.testing;
    const t0: u64 = 1000 * test_ms;
    var c = testCoalescer(t0);
    _ = c.onWake(testWake(t0, 0));

    var w = testWake(t0 + 10 * test_ms, 64 * 1024);
    w.input_ns = t0 + 10 * test_ms - Coalescer.input_guard_ns + 1;
    try testing.expectEqual(.update, c.onWake(w));

    w.input_ns = t0 + 10 * test_ms - Coalescer.input_guard_ns;
    w.generation = 128 * 1024;
    try testing.expectEqual(.wait_new, c.onWake(w));
}

test "Coalescer: pending frame is resolved by input, immediate and idle" {
    const testing = std.testing;
    const t0: u64 = 1000 * test_ms;

    // Input while pending.
    {
        var c = testCoalescer(t0);
        _ = c.onWake(testWake(t0, 0));
        try testing.expectEqual(.wait_new, c.onWake(testWake(t0 + 1 * test_ms, 64 * 1024)));
        var w = testWake(t0 + 2 * test_ms, 65 * 1024);
        w.input_ns = t0 + 2 * test_ms;
        try testing.expectEqual(.update, c.onWake(w));
        try testing.expectEqual(@as(u64, 1), c.counters.input_flush);
    }

    // UI change (resize, config, focus...) while pending.
    {
        var c = testCoalescer(t0);
        _ = c.onWake(testWake(t0, 0));
        _ = c.onWake(testWake(t0 + 1 * test_ms, 64 * 1024));
        var w = testWake(t0 + 2 * test_ms, 65 * 1024);
        w.immediate = true;
        try testing.expectEqual(.update, c.onWake(w));
    }

    // Producer idle through the latest generation while pending.
    {
        var c = testCoalescer(t0);
        _ = c.onWake(testWake(t0, 0));
        _ = c.onWake(testWake(t0 + 1 * test_ms, 64 * 1024));
        var w = testWake(t0 + 2 * test_ms, 80 * 1024);
        w.idle_through = 80 * 1024;
        try testing.expectEqual(.update, c.onWake(w));
        try testing.expectEqual(@as(u64, 1), c.counters.idle_flush);
    }
}

test "Coalescer: stale idle does not release new output" {
    const testing = std.testing;
    const t0: u64 = 1000 * test_ms;
    var c = testCoalescer(t0);
    _ = c.onWake(testWake(t0, 0));

    // Idle was published at 10 KiB, then a burst started.
    var w = testWake(t0 + 2 * test_ms, 64 * 1024);
    w.idle_through = 10 * 1024;
    try testing.expectEqual(.wait_new, c.onWake(w));
}

test "Coalescer: disabled and no vsync always update" {
    const testing = std.testing;
    const t0: u64 = 1000 * test_ms;

    var c = testCoalescer(t0);
    c.enabled = false;
    _ = c.onWake(testWake(t0, 0));
    try testing.expectEqual(.update, c.onWake(testWake(t0 + 1 * test_ms, 64 * 1024)));

    var d = testCoalescer(t0);
    _ = d.onWake(testWake(t0, 0));
    var w = testWake(t0 + 1 * test_ms, 64 * 1024);
    w.vsync = false;
    try testing.expectEqual(.update, d.onWake(w));
}

test "Coalescer: cadence must be learned and recent" {
    const testing = std.testing;
    const t0: u64 = 1000 * test_ms;

    // Fewer than three valid intervals: unknown.
    var c: Coalescer = .{ .enabled = true };
    c.onTick(.{ .seq = 1, .ns = t0 });
    c.onTick(.{ .seq = 2, .ns = t0 + 16 * test_ms });
    c.onTick(.{ .seq = 3, .ns = t0 + 32 * test_ms });
    try testing.expect(!c.periodKnown(t0 + 33 * test_ms));
    c.onTick(.{ .seq = 4, .ns = t0 + 48 * test_ms });
    try testing.expect(c.periodKnown(t0 + 49 * test_ms));
    try testing.expectEqual(@as(u64, 16 * test_ms), c.period_ns);

    // Ticks stopped for more than two periods: unknown again.
    try testing.expect(c.periodKnown(t0 + 80 * test_ms));
    try testing.expect(!c.periodKnown(t0 + 81 * test_ms));
    _ = c.onWake(testWake(t0 + 81 * test_ms, 0));
    try testing.expectEqual(.update, c.onWake(testWake(t0 + 82 * test_ms, 64 * 1024)));

    // A pause gap is not learned as a period, but the link resuming
    // makes the learned period usable again.
    c.onTick(.{ .seq = 5, .ns = t0 + 500 * test_ms });
    try testing.expectEqual(@as(u64, 16 * test_ms), c.period_ns);
    try testing.expect(c.periodKnown(t0 + 501 * test_ms));

    // Coalesced draw_now notifications skip ticks: averaged per tick.
    c.onTick(.{ .seq = 7, .ns = t0 + 516 * test_ms });
    try testing.expectEqual(@as(u64, 14 * test_ms), c.period_ns);

    // Display change or watchdog: forget it.
    c.resetCadence();
    try testing.expect(!c.periodKnown(t0 + 517 * test_ms));
}

test "Coalescer: 120Hz cadence and watchdog delay" {
    const testing = std.testing;
    const t0: u64 = 1000 * test_ms;
    var c: Coalescer = .{ .enabled = true };
    const p: u64 = 8_333_333;
    var seq: u64 = 1;
    while (seq <= 5) : (seq += 1) c.onTick(.{ .seq = seq, .ns = t0 + seq * p });
    try testing.expectEqual(p, c.period_ns);
    try testing.expectEqual(@as(u64, 9), c.watchdogDelayMs());

    var d = testCoalescer(t0);
    try testing.expectEqual(@as(u64, 16), d.watchdogDelayMs());
    d.resetCadence();
    // Never zero, even without a period.
    try testing.expect(d.watchdogDelayMs() > 0);
}

test "Coalescer: reflect keeps the newest snapshot generation" {
    const testing = std.testing;
    var c: Coalescer = .{ .enabled = true };
    c.reflect(100);
    c.reflect(50);
    try testing.expectEqual(@as(u64, 100), c.reflected);
    c.reflect(300);
    try testing.expectEqual(@as(u64, 300), c.reflected);
}

test "Coalescer: repeated tick reads count once" {
    const testing = std.testing;
    var c = testCoalescer(1000 * test_ms);
    const before = c.counters.tick;
    c.onTick(.{ .seq = 4, .ns = 1000 * test_ms });
    try testing.expectEqual(before, c.counters.tick);
}
