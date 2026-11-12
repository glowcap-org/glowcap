//! Ban rows for Rooms application, service, and presentation ownership.

const Ban = @import("../bans.zig").Ban;

const nullish_absence = [_]Ban{.{
    .where = .{ .files = &.{
        "apps/rooms/lib/operator.ts",
        "apps/rooms/web/ui/ops/Operator.tsx",
    } },
    .kind = .forbid,
    .needles = &.{ "=== undefined", "!== undefined" },
    .check = "nullish absence",
    .why = "JavaScript and TypeScript use `== null` / `!= null` for ordinary optional-value checks",
}};

const neutral_alerts = [_]Ban{.{
    .where = .{ .tree = .{ .dir = "apps/rooms/web/ui", .suffixes = &.{".tsx"} } },
    .kind = .forbid,
    .needles = &.{ "className=\"hint\" role=\"alert\"", "role=\"alert\" className=\"hint\"" },
    .check = "Rooms failure presentation",
    .why = "an alert is not neutral hint text; render refusals through the shared `Said` failure treatment",
}};

const readable_loops = [_]Ban{.{
    .where = .{ .tree = .{ .dir = "apps/rooms", .suffixes = &.{ ".ts", ".tsx" } } },
    .kind = .forbid,
    .needles = &.{"for (;;)"},
    .check = "Rooms loop readability",
    .why = "a repeated Rooms operation names its continuation state or bound instead of using an unconditional C-style loop",
}};

pub const page_reloads = [_]Ban{.{
    .where = .{ .tree = .{
        .dir = "apps/rooms/web/ui",
        .suffixes = &.{ ".ts", ".tsx" },
        .exclude = &.{"apps/rooms/web/ui/page_base.ts"},
    } },
    .kind = .forbid,
    .needles = &.{"location.reload("},
    .check = "Rooms page reload",
    .why = "a static host answers only the page's own file, so the page reloads through reloadPage in page_base.ts, which asks for an address its host answers",
}};

pub const proof_child_environment = [_]Ban{.{
    .where = .{ .tree = .{
        .dir = "apps/rooms/test",
        .suffixes = &.{".ts"},
        .exclude = &.{"apps/rooms/test/support/children.ts"},
    } },
    .kind = .forbid,
    .needles = &.{"Deno.env.toObject()"},
    .check = "Rooms proof child environment",
    .why = "spawnOwned gives a child the shell's environment without its Rooms options, so a proof that passes the whole environment hands them back",
}};

pub const attached_session_authority = [_]Ban{
    .{
        .where = .{ .file = "apps/rooms/web/ui/session/managed/controller.ts" },
        .kind = .forbid,
        .needles = &.{ "...browser", "createLocalRoomsSession", "RoomsBrowserController &" },
        .check = "attached Rooms authority",
        .why = "an attached session may call its explicit browser dependencies, never absorb browser or local-session authority",
    },
};

const service_reporting = [_]Ban{.{
    .where = .{ .tree = .{
        .dir = "apps/rooms/rust/services/src",
        .suffixes = &.{".rs"},
        .skip_dirs = &.{"bin/"},
    } },
    .kind = .forbid,
    .needles = &.{"eprintln!"},
    .check = "Rooms service reporting ownership",
    .why = "service libraries emit typed notices through a caller-owned report callback; only executable fronts choose stderr",
}};

pub const runtime_error_vocabulary = [_]Ban{
    .{
        .where = .{ .tree = .{
            .dir = "apps/rooms/rust/runtime/src",
            .suffixes = &.{".rs"},
        } },
        .kind = .forbid,
        .needles = &.{ "Runtime(String)", "Error::runtime", "done: watch::Receiver<Option<Result<(), String>>>", "done: watch::Sender<Option<Result<(), String>>>" },
        .check = "Rooms runtime error vocabulary",
        .why = "runtime failures retain their typed class until a CapTP boundary renders them",
    },
};

const application_hex_writer = [_]Ban{.{
    .where = .{ .tree = .{
        .dir = "apps/rooms/rust/application/src",
        .suffixes = &.{".rs"},
        .exclude = &.{"apps/rooms/rust/application/src/fields/hex.rs"},
    } },
    .kind = .forbid,
    .needles = &.{ ":02x", "b\"0123456789abcdef\"" },
    .check = "Rooms lowercase hex authority",
    .why = "byte encoding belongs to fields::lower_hex so every production identifier uses one writer",
}};

pub const browser_trouble_reporting = [_]Ban{.{
    .where = .{ .files = &.{
        "apps/rooms/rust/browser/src/attached/managed/signaling.rs",
    } },
    .kind = .forbid,
    .needles = &.{"web_sys::console::error_1"},
    .check = "Rooms browser trouble reporting",
    .why = "WebRTC listener failures enter the page trouble journal through the application-owned reporter",
}};

/// Every Rooms peer is minted through `lib/locator.ts`. A `new Host()` or a
/// bare `listen()` anywhere else speaks the v1.0 Syrup floor, and the session
/// it opens refuses every frame as malformed instead of naming the profile
/// disagreement. The profile literals have one owner in `lib/profile.ts`.
const rooms_peer_minting = [_]Ban{
    .{
        .where = .{ .tree = .{
            .dir = "apps/rooms",
            .suffixes = &.{ ".ts", ".tsx" },
            .exclude = &.{"apps/rooms/lib/locator.ts"},
        } },
        .kind = .forbid,
        .needles = &.{"new Host("},
        .unless_contains = "rooms-profile-exempt:",
        .check = "Rooms peer minting",
        .why = "a Rooms peer comes from roomsHost in lib/locator.ts so it wears the fleet profile; a file that must hold a v1.0 peer says so with a rooms-profile-exempt: comment",
    },
    .{
        .where = .{ .tree = .{
            .dir = "apps/rooms",
            .suffixes = &.{ ".ts", ".tsx" },
            .exclude = &.{"apps/rooms/lib/locator.ts"},
        } },
        .kind = .forbid,
        .needles = &.{ " listen(", "(listen(" },
        .check = "Rooms peer minting",
        .why = "a Rooms listener is opened by roomsListen in lib/locator.ts, the accepting half of roomsHost",
    },
    .{
        .where = .{ .tree = .{
            .dir = "apps/rooms",
            .suffixes = &.{ ".ts", ".tsx" },
            .exclude = &.{ "apps/rooms/lib/locator.ts", "apps/rooms/lib/profile.ts" },
        } },
        .kind = .forbid,
        .needles = &.{ "codec: \"capnp\"", "captpVersion: \"next\"", "codec: CODEC", "captpVersion: CAPTP_VERSION" },
        .check = "Rooms peer minting",
        .why = "the Rooms wire profile is stated once in lib/profile.ts and reached through roomsHostOptions",
    },
};

pub const rows =
    nullish_absence ++
    rooms_peer_minting ++
    neutral_alerts ++
    page_reloads ++
    proof_child_environment ++
    readable_loops ++
    attached_session_authority ++
    service_reporting ++
    runtime_error_vocabulary ++
    application_hex_writer ++
    browser_trouble_reporting;
