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

pub const attached_session_authority = [_]Ban{
    .{
        .where = .{ .file = "apps/rooms/web/ui/session/managed/controller.ts" },
        .kind = .forbid,
        .needles = &.{ "...browser", "createLocalRoomsSession", "RoomsBrowserController &" },
        .check = "attached Rooms authority",
        .why = "an attached session may call its explicit browser dependencies, never absorb browser or local-session authority",
    },
    .{
        .where = .{ .file = "apps/rooms/web/ui/session/managed/controller.ts" },
        .kind = .require,
        .needles = &.{"browser: Pick<RoomsBrowserController"},
        .check = "attached Rooms authority",
        .why = "the attached session adapter must name the exact browser actions its command surface needs",
    },
    .{
        .where = .{ .file = "apps/rooms/web/ui/controller/browser.ts" },
        .kind = .require,
        .needles = &.{"RoomsBrowserContext = createContext<RoomsBrowserController | null>"},
        .check = "attached Rooms authority",
        .why = "browser presentation and establishment authority must have its own stable React context",
    },
    .{
        .where = .{ .file = "apps/rooms/web/ui/controller/session.ts" },
        .kind = .require,
        .needles = &.{"RoomsSessionContext = createContext<RoomsSessionController | null>"},
        .check = "attached Rooms authority",
        .why = "Rooms commands must be unavailable until an established session context exists",
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

pub const rows =
    nullish_absence ++
    neutral_alerts ++
    readable_loops ++
    attached_session_authority ++
    service_reporting ++
    runtime_error_vocabulary ++
    application_hex_writer ++
    browser_trouble_reporting;
