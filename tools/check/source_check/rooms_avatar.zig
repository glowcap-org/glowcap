//! The avatar tint ramp: `--avatar-N` slot count parity between `member_identity.ts`
//! and the stylesheet, and the WCAG 4.5:1 contrast promise every tint makes
//! to the white initials drawn on it. Split from `rooms_ui.zig`, whose
//! shared stylesheet loader this leans on.

const std = @import("std");
const util = @import("util.zig");
const rooms_ui = @import("rooms_ui.zig");

const appendViolation = util.appendViolation;
const loadRoomsCss = rooms_ui.loadRoomsCss;
const ui_dir = rooms_ui.ui_dir;

/// The avatar ramp: one slot count in two homes, and a contrast floor the
/// tints owe the chip's white initials.
///
/// `hueOf` in `member_identity.ts` picks `var(--avatar-N)` with N in
/// `1..AVATAR_SLOTS`,
/// and the stylesheet defines the tints. A count that drifts in either
/// direction fails quietly at run time: a picked slot with no definition draws
/// white initials on no background at all. And every tint carries the same
/// promise, stated where the ramp is written: it clears WCAG 4.5:1 against the
/// white initials on it. Both claims are arithmetic, so the build holds them.
pub fn checkAvatarRamp(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const identity_ts = root.readFileAlloc(io, ui_dir ++ "/member_identity.ts", gpa, .limited(1 << 20)) catch {
        try appendViolation(gpa, violations, "{s}/member_identity.ts: could not be read for the avatar-ramp check", .{ui_dir});
        return;
    };
    defer gpa.free(identity_ts);
    const slots_decl = "const AVATAR_SLOTS = ";
    const at = std.mem.indexOf(u8, identity_ts, slots_decl) orelse {
        try appendViolation(gpa, violations, "{s}/member_identity.ts: `const AVATAR_SLOTS = ` is gone; hueOf's slot count is the half of the avatar ramp this check reads", .{ui_dir});
        return;
    };
    const slots = util.firstIntIn(identity_ts[at + slots_decl.len ..]) orelse {
        try appendViolation(gpa, violations, "{s}/member_identity.ts: AVATAR_SLOTS is not a literal count", .{ui_dir});
        return;
    };

    const sheet = (try loadRoomsCss(io, gpa, root, violations)) orelse return;
    defer gpa.free(sheet);
    var n: i64 = 0;
    while (n < slots) : (n += 1) {
        var name_buf: [32]u8 = undefined;
        const needle = std.fmt.bufPrint(&name_buf, "--avatar-{d}: #", .{n + 1}) catch unreachable;
        const def = std.mem.indexOf(u8, sheet, needle) orelse {
            try appendViolation(gpa, violations, "the rooms stylesheets define no `--avatar-{d}` while member_identity.ts's AVATAR_SLOTS is {d}; a picked slot with no tint draws white initials on nothing", .{ n + 1, slots });
            continue;
        };
        const hex = sheet[def + needle.len ..];
        if (hex.len < 6) continue;
        const rgb = std.fmt.parseInt(u24, hex[0..6], 16) catch {
            try appendViolation(gpa, violations, "`--avatar-{d}` is not a six-digit hex colour; the contrast floor cannot be checked", .{n + 1});
            continue;
        };
        const ratio = contrastVsWhite(rgb);
        if (ratio < 4.5) {
            try appendViolation(gpa, violations, "`--avatar-{d}` has {d:.2}:1 contrast against the chip's white initials; the ramp's own comment promises 4.5:1", .{ n + 1, ratio });
        }
    }
    {
        var name_buf: [32]u8 = undefined;
        const extra = std.fmt.bufPrint(&name_buf, "--avatar-{d}: #", .{slots + 1}) catch unreachable;
        if (std.mem.indexOf(u8, sheet, extra) != null) {
            try appendViolation(gpa, violations, "the rooms stylesheets define `--avatar-{d}` but member_identity.ts's AVATAR_SLOTS is {d}; hueOf can never pick it", .{ slots + 1, slots });
        }
    }
}

/// WCAG relative-luminance contrast of white text over an opaque sRGB tint.
fn contrastVsWhite(rgb: u24) f64 {
    const chans = [3]f64{
        @as(f64, @floatFromInt((rgb >> 16) & 0xff)) / 255.0,
        @as(f64, @floatFromInt((rgb >> 8) & 0xff)) / 255.0,
        @as(f64, @floatFromInt(rgb & 0xff)) / 255.0,
    };
    var lin: [3]f64 = undefined;
    for (chans, 0..) |c, i| {
        lin[i] = if (c <= 0.03928) c / 12.92 else std.math.pow(f64, (c + 0.055) / 1.055, 2.4);
    }
    const lum = 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2];
    return (1.0 + 0.05) / (lum + 0.05);
}
