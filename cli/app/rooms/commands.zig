//! Public Rooms vocabulary. No shell passthrough: every option participates in
//! the same parser, help, and shell completion as the rest of glowcap.
const std = @import("std");
const types = @import("../../cmd/types.zig");
const run = @import("mod.zig").run;
const Flag = types.Flag;
const boot = @import("boot_capabilities.zig");
fn value(comptime name: []const u8, comptime help: []const u8) Flag {
    return .{ .long = name, .help = help, .kind = .string_flag };
}
fn many(comptime name: []const u8, comptime help: []const u8) Flag {
    var flag = value(name, help);
    flag.repeatable = true;
    return flag;
}
/// The same flags for another peer the command runs, under `prefix`, each
/// help led by `subject`. A help that named a sibling flag would point the
/// prefixed copy at the unprefixed flag, so a help holding `--` is refused.
fn prefixed(comptime prefix: []const u8, comptime subject: []const u8, comptime flags: []const Flag) [flags.len]Flag {
    var out: [flags.len]Flag = undefined;
    @setEvalBranchQuota(100_000);
    for (flags, 0..) |flag, index| {
        if (std.mem.find(u8, flag.help, "--") != null) @compileError("the help of --" ++ flag.long ++ " holds `--`, and a prefixed flag's help may name no flag");
        out[index] = flag;
        out[index].long = prefix ++ flag.long;
        out[index].help = subject ++ flag.help;
    }
    return out;
}
const state = value("state", "Durable service state directory");
/// The announced listener's help, as every Rooms peer's help names the transports.
pub const transport_help = "Announced listener: tcp, keyed-tcp, noise-tcp, iroh (default), keyed-relay, noise-relay, or onion";
pub const transport = [_]Flag{
    value("transport", transport_help),
    value("reachability", "iroh discovery (default) or direct"),
    value("bind", "TCP listener address (default loopback)"),
    value("port", "Room listener port (0 chooses an ephemeral port)"),
    value("announce-host", "Advertised TCP host"),
    value("relay", "WebSocket relay a keyed-relay or noise-relay listener registers at (or GLOWCAP_ROOMS_RELAY_URL)"),
    value("relay-public", "That relay as peers dial it, behind a port forward or proxy (or GLOWCAP_ROOMS_RELAY_PUBLIC_URL)"),
    value("onion-socks", "Running Tor SOCKS endpoint"),
    value("onion-control", "Running Tor control endpoint"),
    value("onion-forward", "Absolute Unix forwarding socket, used with the listener port left at 0"),
};
pub const admission = [_]Flag{
    value("admission-scale", "Scale default work allowances (1..100, default 1)"),
    value("admission-rates", "Absolute class=burst/per-minute overrides, separated by commas"),
    value("admission-rows", "Retained accounting rows (1..65536)"),
    value("admission-aggregate-scale", "Aggregate allowance multiplier (1..100)"),
};
const directory = transport ++ admission ++ [_]Flag{
    many("listen", "Also listen over <transport>[,<name>=<value>...] (repeat once per transport)"),
    state,
    .{ .long = "history", .help = "Retain listed-room history" },
    value("capabilities", "Operator capabilities to mint: all, or names from " ++ boot.names ++ ", separated by commas (or GLOWCAP_ROOMS_CAPABILITIES)"),
    value("trace-bind", "Trace listener interface (default 127.0.0.1, or GLOWCAP_ROOMS_TRACE_BIND)"),
    value("trace-port", "Trace port (default 9300, 0 chooses an ephemeral port)"),
    value("trace-connect", "Advertised trace CapTP WebSocket URL through a proxy (wss:// off loopback)"),
    value("trace-publish", "Advertised trace producer WebSocket URL through a proxy (wss:// off loopback)"),
};
const serve = directory ++ [_]Flag{
    value("http-admission-scale", "Scale HTTP work allowances (1..100)"),
    value("http-admission-rates", "HTTP class=burst/per-minute overrides"),
    value("http-admission-rows", "HTTP accounting row cap (1..65536)"),
    value("http-admission-aggregate-scale", "HTTP deployment allowance multiplier (1..100)"),
    value("http-admission-per-address", "Apply an additional actual socket source budget (true or false)"),
    value("http-trusted-proxies", "Proxy addresses or CIDR prefixes whose X-Forwarded-For client selects that budget"),
    value("browser-admission-scale", "Scale browser-local session work allowances (1..100)"),
    value("browser-admission-rates", "Browser-local class=burst/per-minute overrides"),
    value("browser-admission-rows", "Browser-local accounting row cap (1..65536)"),
    value("browser-admission-aggregate-scale", "Browser-local session allowance multiplier (1..100)"),
    value("session-state", "Also serve a shared session from this directory and print its use and management links"),
} ++ prefixed("session-", "Shared session: ", &@import("session_commands.zig").serve_options) ++ [_]Flag{
    value("allow-origin", "Rooms pages served elsewhere that may use this server, as origins or page addresses separated by commas (default: https://glowcap.org/rooms/app/, the page the website publishes, and an empty value allows none, or GLOWCAP_RELAY_ALLOW_ORIGINS). A page address also prints a link that opens it with this server, and with --session-state one that opens it ready to attach"),
    value("http-bind", "HTTP listener address (default 127.0.0.1, or GLOWCAP_ROOMS_HTTP_BIND)"),
    value("http-port", "HTTP listener port (default 8080, or GLOWCAP_ROOMS_HTTP_PORT)"),
    value("http-public", "The address browsers reach this server at, named by every link it prints (default http://localhost:<port>/, or GLOWCAP_ROOMS_HTTP_PUBLIC)"),
    value("assets", "Serve these prepared browser assets instead of the installed ones (never compiles source)"),
};
const status = [_]Flag{value("url", "Rooms HTTP base URL (default http://127.0.0.1:8080)")};
const irc = [_]types.Command{
    .{ .name = "bridge", .short_help = "Expose an IRC channel as a Rooms directory (read-only by default)", .flags = &(transport ++ [_]Flag{
        value("network", "IRC network label (default libera)"),
        value("channel", "IRC channel (default #ocapn)"),
        value("irc-host", "IRC server (default irc.libera.chat)"),
        value("irc-port", "IRC port (default 6697)"),
        value("irc-nick", "Bridge nickname (default glowcap-rooms)"),
        value("irc-realname", "Required public bot identity and reachable administrator"),
        value("tls", "true (default) or false (two-way requires TLS)"),
        value("mode", "read-only (default) or two-way"),
        value("sasl-account", "SASL account (the password comes only from GLOWCAP_ROOMS_IRC_SASL_PASSWORD)"),
    }), .run = run("rooms-irc-bridge", .service) },
    .{ .name = "serve", .short_help = "Let ordinary IRC clients participate in Rooms", .flags = &.{
        value("directory", "The address the Rooms server printed (required)"),
        value("bind", "IRC listener address (default 127.0.0.1)"),
        value("port", "IRC listener port (default 6667)"),
        value("server-name", "IRC server name (default rooms.local)"),
        value("tls-cert", "TLS certificate, required with --tls-key for a public bind"),
        value("tls-key", "TLS private key file"),
        value("dm-transport", "noise-tcp (default), iroh, or tcp (cleartext, loopback only)"),
        value("dm-bind", "Direct-message listener address"),
        value("dm-announce-host", "Advertised direct-message host"),
        value("dm-port", "Direct-message listener port (default 0)"),
        value("dial-transports", "Also dial members on these: noise-tcp, iroh, and the cleartext keyed-tcp and tcp"),
    }, .run = run("rooms-irc-server", .service) },
};
pub const commands = [_]types.Command{
    @import("deployment.zig").command,
    .{ .name = "serve", .short_help = "Run the browser app and its directory, keeping local state by default", .flags = &serve, .run = run("rooms-web", .serve) },
    .{ .name = "status", .short_help = "Check the running directory and browser assets", .flags = &status, .run = run("rooms-web", .status) },
    .{ .name = "locator", .short_help = "Print the running directory locator", .flags = &status, .run = run("rooms-web", .locator) },
    .{ .name = "revision", .short_help = "Print the served browser revision", .flags = &status, .run = run("rooms-web", .revision) },
    .{ .name = "page", .short_help = "Print the link that opens the Rooms page with the running directory", .flags = &status, .run = run("rooms-web", .page) },
    .{ .name = "capabilities", .short_help = "Print the kept operator capabilities as complete links, with the running directory's locators", .flags = &.{ state, status[0] }, .run = run("rooms-web", .capabilities) },
    .{ .name = "trace", .short_help = "Follow the live protocol trace, including replay", .flags = &.{ state, status[0], .{ .long = "json", .help = "Print complete records as JSON lines" }, .{ .long = "print-link", .help = "Print the full capability and exit" } }, .positionals = &.{.{ .name = "capability", .help = "Trace sturdyref (found from local HTTP and private --state when left out)", .required = false }}, .run = run("rooms-web", .trace) },
    .{ .name = "session", .short_help = "Join, converse, and keep listening through a durable session", .children = &@import("session.zig").commands },
    .{ .name = "team", .short_help = "Coordinate a roster through the same durable session lifecycle", .children = &@import("session_commands.zig").team_commands },
    .{ .name = "directory", .short_help = "Operate a standalone Rooms directory", .children = &.{
        .{ .name = "serve", .short_help = "Run a directory without HTTP or browser assets", .flags = &directory, .run = run("rooms-server", .service) },
    } },
    .{ .name = "chat", .short_help = "Chat interactively from the terminal", .positionals = &.{
        .{ .name = "locator", .help = "Directory locator" },
        .{ .name = "room", .help = "Room name" },
        .{ .name = "nick", .help = "Your nickname" },
    }, .run = run("rooms-chat", .service) },
    .{ .name = "archive", .short_help = "Operate a durable Rooms archive capability", .children = &.{
        .{ .name = "serve", .short_help = "Serve the archive capability", .flags = &(transport ++ .{state}), .run = run("rooms-archive", .service) },
    } },
    .{ .name = "irc", .short_help = "Bridge IRC channels or serve IRC clients", .children = &irc },
    .{ .name = "skills", .short_help = "Print the installed individual/team skill directory", .run = run("", .skills) },
};
