//! User-facing CapTP lab strings (content design). No CapTP authority.
const std = @import("std");
const meta = @import("meta.zig");

/// One-line workbench greeting (default). Not a walkthrough dump.
pub const workbench_ready =
    \\Workbench ready. CapTP verbs at the prompt · help · guide (optional walkthrough).
;

/// Full coach body, shown only after `guide` (or `?` while guided).
pub const coach_guide =
    \\CapTP walkthrough — dial an ocapn:// locator (listen --publish greeter is argv-only).
    \\Then: fetch greeter → call greeter greet world
    \\Or deliver to a held capability: call #<n> greet world  (n from a fetch's `cap` id).
    \\tour exports|imports|answers · guide exit returns to the workbench · ? reprints this.
;

pub const next_identity = "next: mint identity (glowcap init) or set GLOWCAP_IDENTITY";
pub const next_connect = "next: dial ocapn://…";
pub const next_session = "next: wait for the session to open, then fetch a name";
pub const next_fetch = "next: fetch greeter";
pub const next_deliver = "next: call greeter greet world   or   call #<cap> greet world";
pub const next_tables = "next: tour exports · tour imports · tour answers";
pub const next_done = "walkthrough complete — guide exit, or keep calling";

/// Prompt footer when not in guide mode.
pub const workbench_footer = "guide — optional CapTP walkthrough";

pub const repl_title = "REPL";
pub const captp_title = "CapTP";

pub const stage_identity = "identity";
pub const stage_connect = "connect";
pub const stage_session = "session";
pub const stage_fetch = "fetch";
pub const stage_deliver = "deliver";
pub const stage_tables = "tables";

pub const empty_exports = "No exports yet. publish a builtin, or wait for a partner deliver.";
pub const empty_imports = "No imports yet. fetch a published name from the peer.";
pub const empty_answers = "No answers yet. call creates an answered deliver.";

pub const tip_quoted_uri = "Inside the REPL, paste the locator without quotes.";
pub const tip_missing_verb = "call needs name|#N, verb, then args: call greeter greet world  or  call #1 greet world";
pub const tip_no_session = "No open session. dial an ocapn:// locator (or run listen on argv).";

pub const help_captp_map =
    \\CapTP noun map:
    \\  bootstrap  ask the peer for a published name (fetch)
    \\  export     a capability you offer on this session
    \\  import     a wire position the peer offered (fetch prints the cap id #N takes)
    \\  answer     a promise for an answered deliver
    \\  deliver    call / tell by published name or #<cap>
    \\  dial       open a session to a peer (listen is argv-only)
    \\  close      end the session (no table-reset API — close + redial)
;

pub fn gloss(verb: []const u8) []const u8 {
    if (std.mem.eql(u8, verb, "call")) return "Answered deliver: name or #<cap>, then verb. Watch Answers.";
    if (std.mem.eql(u8, verb, "tell")) return "Fire-and-forget: name or #<cap>, then verb. No answer row.";
    if (std.mem.eql(u8, verb, "fetch")) return "Bootstrap fetch → import N. Then: call greeter … or call #N …";
    if (std.mem.eql(u8, verb, "publish")) return "Export a builtin on this session for the partner to fetch.";
    if (std.mem.eql(u8, verb, "dial")) return "Open a CapTP session to a peer locator.";
    if (std.mem.eql(u8, verb, "probe")) return "Handshake only, then close. Does not keep a session.";
    if (std.mem.eql(u8, verb, "close")) return "Close the open session (there is no table-reset; close + redial).";
    if (std.mem.eql(u8, verb, "info")) return "Show identity and session summary.";
    if (meta.glossOf(verb)) |g| return g;
    return "CapTP lab command.";
}

pub fn tipForErrorDetail(detail: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, detail, "UriParseError") != null) return tip_quoted_uri;
    if (std.mem.indexOf(u8, detail, "needs <name> <verb>") != null) return tip_missing_verb;
    if (std.mem.indexOf(u8, detail, "needs a session") != null) return tip_no_session;
    if (std.mem.indexOf(u8, detail, "NoSuchMethod") != null) return tip_missing_verb;
    return null;
}

pub fn tourBlurb(pane: []const u8) []const u8 {
    if (std.mem.eql(u8, pane, "exports")) return "Exports are capabilities you offer on this session.";
    if (std.mem.eql(u8, pane, "imports")) return "Imports are capabilities the peer offered you.";
    if (std.mem.eql(u8, pane, "answers")) return "Answers are promises for answered delivers.";
    return "Unknown pane. Try tour exports, tour imports, or tour answers.";
}
