//! Ban rows for Racket binding ownership and runtime policy.

const bans = @import("../bans.zig");
const Ban = bans.Ban;

/// A vow's release ticket, weak Host registration, and finalizer are one
/// adoption transaction. Callers consume that owner rather than constructing a
/// partial `session-vow` whose explicit release silently does nothing.
pub const vow_adoption_rows: []const Ban = &.{
    .{
        .where = .{ .tree = .{
            .dir = "bindings/racket",
            .suffixes = &.{".rkt"},
            .exclude = &.{"bindings/racket/private/promise.rkt"},
        } },
        .kind = .forbid,
        .needles = &.{"(session-vow "},
        .check = "racket-vow-adoption",
        .why = "Racket vow construction belongs to adopt-minted-vow!, which installs the exact release ticket and Host ownership row",
    },
};

/// The byte-transparent relay accepts only binary WebSocket messages. Text is
/// a typed payload, not opaque CapTP bytes, so the binding must not reinterpret
/// it through UTF-8.
pub const relay_binary_rows: []const Ban = &.{
    .{
        .where = .{ .file = "bindings/racket/relay.rkt" },
        .kind = .require,
        .needles = &.{"(define msg (recv conn #:payload-type 'binary))"},
        .check = "racket-relay-binary",
        .why = "the Racket relay must request binary WebSocket payloads for byte transparency",
    },
    .{
        .where = .{ .file = "bindings/racket/relay.rkt" },
        .kind = .forbid,
        .needles = &.{ "#:payload-type 'auto", "string->bytes/utf-8 msg" },
        .check = "racket-relay-binary",
        .why = "the Racket relay must reject text WebSocket messages instead of converting them to bytes",
    },
    .{
        .where = .{ .file = "bindings/racket/test/zig-smoke/diagnostics.rkt" },
        .kind = .require,
        .needles = &.{"relay refuses text WebSocket messages instead of reinterpreting them"},
        .check = "racket-relay-binary",
        .why = "Racket smoke diagnostics pin the byte relay's text-message refusal",
    },
};

/// A Racket script that starts another Racket process passes `-y`, as the
/// build does for the script itself. Without it the child keeps a module's
/// compiled `.zo` when that module's own source is unchanged, along with any
/// constant it inlined from a module that did change, such as a binding's
/// archive fingerprint.
pub const child_compile_rows: []const Ban = &.{
    childCompileRow("bench"),
    childCompileRow("interop"),
};

fn childCompileRow(comptime dir: []const u8) Ban {
    return .{
        .where = .{ .tree = .{ .dir = dir, .suffixes = &.{".rkt"} } },
        .kind = .forbid,
        .needles = &.{"(find-executable-path \"racket\")"},
        .unless_contains = "\"-y\"",
        .check = "racket-child-compile",
        .why = "a Racket child process must run with -y so it recompiles modules whose dependencies changed",
    };
}
