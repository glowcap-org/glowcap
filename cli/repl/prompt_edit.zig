//! Prompt buffer edits for the CapTP lab TUI.
//!
//! `tui.zig` owns the frame loop. Completion and history only need to
//! replace the current editor line or its last token. This module is
//! that leaf so mouse clicks and key intents share one buffer walk.
const vaxis = @import("vaxis");

pub fn currentLine(text_input: *vaxis.widgets.TextInput, scratch: []u8) []const u8 {
    const first = text_input.buf.firstHalf();
    const second = text_input.buf.secondHalf();
    const total = first.len + second.len;
    if (total > scratch.len) {
        const n = scratch.len;
        if (first.len >= n) {
            @memcpy(scratch[0..n], first[0..n]);
            return scratch[0..n];
        }
        @memcpy(scratch[0..first.len], first);
        const rest = n - first.len;
        @memcpy(scratch[first.len..][0..rest], second[0..rest]);
        return scratch[0..n];
    }
    @memcpy(scratch[0..first.len], first);
    @memcpy(scratch[first.len .. first.len + second.len], second);
    return scratch[0..total];
}

pub fn replaceEditorLine(text_input: *vaxis.widgets.TextInput, line: []const u8) !void {
    text_input.clearRetainingCapacity();
    if (line.len > 0) try text_input.insertSliceAtCursor(line);
}

fn replaceLastToken(text_input: *vaxis.widgets.TextInput, scratch: []u8, token: []const u8, trailing_space: bool) !void {
    const line = currentLine(text_input, scratch);
    var cut: usize = line.len;
    while (cut > 0 and line[cut - 1] != ' ' and line[cut - 1] != '\t') cut -= 1;
    text_input.clearRetainingCapacity();
    if (cut > 0) try text_input.insertSliceAtCursor(line[0..cut]);
    try text_input.insertSliceAtCursor(token);
    if (trailing_space) try text_input.insertSliceAtCursor(" ");
}

pub fn previewCandidate(text_input: *vaxis.widgets.TextInput, scratch: []u8, token: []const u8) !void {
    try replaceLastToken(text_input, scratch, token, false);
}

pub fn acceptCandidate(text_input: *vaxis.widgets.TextInput, scratch: []u8, token: []const u8) !void {
    try replaceLastToken(text_input, scratch, token, true);
}
