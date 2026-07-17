//! First-class intents: keys/mouse → Intent → systems.
const std = @import("std");
const vaxis = @import("vaxis");
const Mode = @import("resources.zig").Mode;

pub const Intent = union(enum) {
    quit,
    redraw,
    scroll: i32,
    scroll_page: i32,
    jump_top,
    jump_live,
    jump_user_turn: i32,
    submit_line,
    toggle_mode: Mode,
    exit_overlay,
    complete_tab: enum { forward, backward },
    complete_accept,
    complete_cycle: i8,
    focus_next_panel,
    copy_selection,
    history_prev,
    history_next,
    /// Cancel the active CapTP wait (Esc at the prompt while a turn is pending).
    cancel_pending,
};

pub const Queue = struct {
    items: [32]Intent = undefined,
    len: usize = 0,

    pub fn push(self: *Queue, intent: Intent) void {
        if (self.len >= self.items.len) return;
        self.items[self.len] = intent;
        self.len += 1;
    }

    pub fn clear(self: *Queue) void {
        self.len = 0;
    }

    pub fn slice(self: *const Queue) []const Intent {
        return self.items[0..self.len];
    }
};

/// Map a key to an intent given mode. Returns null → fall through to TextInput.
pub fn fromKey(key: vaxis.Key, mode: Mode, menu_open: bool) ?Intent {
    if (key.matches('c', .{ .ctrl = true })) return .quit;
    if (key.matches('l', .{ .ctrl = true })) return .redraw;
    if (key.matches('o', .{ .ctrl = true })) {
        return .{ .toggle_mode = if (mode == .transcript) .prompt else .transcript };
    }
    // Ctrl-` is often swallowed by terminals; Ctrl-t / Ctrl-p are reliable.
    if (key.matches('`', .{ .ctrl = true }) or
        key.matches('t', .{ .ctrl = true }) or
        key.matches('p', .{ .ctrl = true }))
    {
        return .focus_next_panel;
    }

    switch (mode) {
        .transcript => {
            if (key.matches('q', .{}) or key.matches(vaxis.Key.escape, .{})) return .exit_overlay;
            if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) return .{ .scroll = -1 };
            if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) return .{ .scroll = 1 };
            if (key.matches(vaxis.Key.page_up, .{})) return .{ .scroll_page = 1 };
            if (key.matches(vaxis.Key.page_down, .{})) return .{ .scroll_page = -1 };
            if (key.matches('g', .{}) or key.matches(vaxis.Key.home, .{})) return .jump_top;
            if (key.matches('G', .{}) or key.matches(vaxis.Key.end, .{})) return .jump_live;
            if (key.matches('{', .{})) return .{ .jump_user_turn = -1 };
            if (key.matches('}', .{})) return .{ .jump_user_turn = 1 };
            // Browse-mode help; prompt `?` is a tip line via submit.
            if (key.matches('?', .{})) return .{ .toggle_mode = .help };
            return null;
        },
        .help => {
            if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{})) return .exit_overlay;
            return null;
        },
        .quiet => {
            if (key.matches(vaxis.Key.escape, .{})) return .exit_overlay;
        },
        .complete => {
            if (key.matches(vaxis.Key.escape, .{})) return .exit_overlay;
            if (key.matches(vaxis.Key.enter, .{})) return .complete_accept;
            if (key.matches(vaxis.Key.up, .{}) or key.matches(vaxis.Key.tab, .{ .shift = true }))
                return .{ .complete_cycle = -1 };
            if (key.matches(vaxis.Key.down, .{}) or key.matches(vaxis.Key.tab, .{}))
                return .{ .complete_cycle = 1 };
        },
        .prompt => {},
    }

    if (!menu_open) {
        if (key.matches(vaxis.Key.page_up, .{})) return .{ .scroll_page = 1 };
        if (key.matches(vaxis.Key.page_down, .{})) return .{ .scroll_page = -1 };
        // Plain Up/Down = command history at the prompt (readline-shaped).
        // Shift/Ctrl+arrows still scroll the transcript.
        if (mode == .prompt or mode == .quiet) {
            if (key.matches(vaxis.Key.up, .{})) return .history_prev;
            if (key.matches(vaxis.Key.down, .{})) return .history_next;
        }
        if (key.matches(vaxis.Key.up, .{ .shift = true }) or key.matches(vaxis.Key.up, .{ .ctrl = true }))
            return .{ .scroll = 1 };
        if (key.matches(vaxis.Key.down, .{ .shift = true }) or key.matches(vaxis.Key.down, .{ .ctrl = true }))
            return .{ .scroll = -1 };
        if (key.matches(vaxis.Key.home, .{ .ctrl = true })) return .jump_top;
        if (key.matches(vaxis.Key.end, .{ .ctrl = true })) return .jump_live;
    }

    if (key.matches(vaxis.Key.tab, .{ .shift = true })) return .{ .complete_tab = .backward };
    if (key.matches(vaxis.Key.tab, .{})) return .{ .complete_tab = .forward };
    if (key.matches(vaxis.Key.enter, .{})) return .submit_line;
    // Re-copy last in-app selection (Ctrl-C is quit).
    if (key.matches('y', .{ .ctrl = true }) or key.matches('c', .{ .ctrl = true, .shift = true }))
        return .copy_selection;
    if (key.matches(vaxis.Key.f1, .{})) return .{ .toggle_mode = .help };
    if (key.matches(vaxis.Key.escape, .{})) {
        if (mode == .prompt or mode == .quiet) return .cancel_pending;
        return .exit_overlay;
    }

    return null; // TextInput
}

test "Queue push" {
    var q: Queue = .{};
    q.push(.quit);
    q.push(.redraw);
    try std.testing.expectEqual(@as(usize, 2), q.len);
}
