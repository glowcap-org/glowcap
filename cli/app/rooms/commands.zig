//! Public Rooms vocabulary. No shell passthrough: every option participates in
//! the same parser, help, and shell completion as the rest of glowcap.
const types = @import("../../cmd/types.zig");
const run = @import("mod.zig").run;
const Flag = types.Flag;
fn value(comptime name: []const u8, comptime help: []const u8) Flag {
    return .{ .long = name, .help = help, .kind = .string_flag };
}
const state = value("state", "Durable service state directory");
pub const transport = [_]Flag{
    value("transport", "iroh (default), tcp (cleartext), or onion (requires Tor)"),
    value("reachability", "iroh discovery (default) or direct"),
    value("bind", "TCP listener address (default loopback)"),
    value("port", "Room listener port; 0 chooses an ephemeral port"),
    value("announce-host", "Advertised TCP host"),
    value("onion-socks", "Running Tor SOCKS endpoint"),
    value("onion-control", "Running Tor control endpoint"),
    value("onion-forward", "Absolute Unix forwarding socket; requires --port=0"),
};
const directory = transport ++ [_]Flag{
    state,
    .{ .long = "history", .help = "Retain listed-room history" },
    value("storage", "History directory or PostgreSQL URL (database is optional)"),
    value("storage-password-file", "Read database password from this file"),
    .{ .long = "admin-listeners", .help = "Mint listener administration capability" },
    .{ .long = "diagnostics", .help = "Mint diagnostics capability" },
    .{ .long = "operator", .help = "Mint operator capability" },
    .{ .long = "peering", .help = "Mint directory peering capability" },
    .{ .long = "irc", .help = "Mint IRC administration capability" },
    .{ .long = "trace", .help = "Mint trace capability and start its loopback endpoint" },
    value("trace-port", "Trace port (default 9300; 0 chooses an ephemeral port)"),
};
const serve = directory ++ [_]Flag{
    value("http-bind", "HTTP listener address (default 127.0.0.1; public exposure is explicit)"),
    value("http-port", "HTTP listener port (default 8080)"),
    value("assets", "Override the installed prepared browser generation; never compiles source"),
};
const status = [_]Flag{value("url", "Rooms HTTP base URL (default http://127.0.0.1:8080)")};
const irc = [_]types.Command{
    .{ .name = "bridge", .short_help = "Expose an IRC channel as a Rooms directory (read-only by default)", .flags = &.{
        value("network", "IRC network label (default libera)"),
        value("channel", "IRC channel (default #ocapn)"),
        value("irc-host", "IRC server (default irc.libera.chat)"),
        value("irc-port", "IRC port (default 6697)"),
        value("irc-nick", "Bridge nickname (default glowcap-rooms)"),
        value("irc-realname", "Required public bot identity and reachable administrator"),
        value("tls", "true (default) or false; two-way requires TLS"),
        value("mode", "read-only (default) or two-way"),
        value("sasl-account", "SASL account; password comes only from GLOWCAP_ROOMS_IRC_SASL_PASSWORD"),
        value("bind", "Rooms TCP listener address (default 127.0.0.1)"),
        value("announce-host", "Advertised Rooms TCP host"),
        value("port", "Rooms TCP port (default 0)"),
    }, .run = run("rooms-irc-bridge", .service) },
    .{ .name = "front", .short_help = "Let ordinary IRC clients participate in Rooms", .flags = &.{
        value("directory", "Rooms locator or TCP address (default 127.0.0.1:9099)"),
        value("bind", "IRC listener address (default 127.0.0.1)"),
        value("port", "IRC listener port (default 6667)"),
        value("server-name", "IRC server name (default rooms.local)"),
        value("tls-cert", "TLS certificate; required with --tls-key for a public bind"),
        value("tls-key", "TLS private key file"),
        value("dm-transport", "noise (default), tcp (loopback only), or iroh"),
        value("dm-bind", "Direct-message listener address"),
        value("dm-announce-host", "Advertised direct-message host"),
        value("dm-port", "Direct-message listener port (default 0)"),
    }, .run = run("rooms-irc-front", .service) },
};
pub const commands = [_]types.Command{
    @import("deployment.zig").command,
    .{ .name = "serve", .short_help = "Run the browser app and its directory; durable local state by default", .flags = &serve, .run = run("rooms-web", .serve) },
    .{ .name = "status", .short_help = "Check the running directory and browser assets", .flags = &status, .run = run("rooms-web", .status) },
    .{ .name = "locator", .short_help = "Print the running directory locator", .flags = &status, .run = run("rooms-web", .locator) },
    .{ .name = "revision", .short_help = "Print the served browser revision", .flags = &status, .run = run("rooms-web", .revision) },
    .{ .name = "session", .short_help = "Join, converse, and keep listening through a durable session", .children = &@import("session.zig").commands },
    .{ .name = "team", .short_help = "Coordinate a roster through the same durable session lifecycle", .children = &@import("session_commands.zig").team_commands },
    .{ .name = "directory", .short_help = "Operate a standalone Rooms directory", .children = &.{
        .{ .name = "serve", .short_help = "Run a directory without HTTP or browser assets", .flags = &directory, .run = run("rooms-server", .service) },
        .{ .name = "capabilities", .short_help = "Read kept operator capabilities without starting a server", .flags = &.{state}, .run = run("rooms-server", .capabilities) },
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
