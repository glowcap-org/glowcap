//! Ban rows: transport vocabulary across the docs, and the dependency
//! directions between the transport archives, the driver, and the bindings.

const bans = @import("../bans.zig");
const Ban = bans.Ban;
const Where = bans.Where;

/// Docs the transport-vocabulary rows scan.
pub const transport_vocabulary_paths: []const []const u8 = &.{
    ".agents/rules/architecture.md",
    "AGENTS.md",
    "CONTRIBUTING.md",
    "README.md",
    "docs/architecture.md",
    "docs/boundaries.md",
    "docs/ladder.md",
    "docs/shipped.md",
    "docs/roadmap.md",
    "docs/capabilities.md",
    "docs/vision.md",
    "bindings/README.md",
    "bindings/DEVELOPING.md",
    "bindings/python/README.md",
    "bindings/rust/README.md",
    "bindings/racket/README.md",
    "bindings/ts/README.md",
    "examples/README.md",
    "apps/accountability-on-glowcap/README.md",
    "site/content/transports.smd",
    "site/content/modules.smd",
    "site/content/examples.smd",
};

/// CapTP is transport-agnostic. Only netlayers name transports. Docs that
/// equate glowcap/OCapN with TCP fail here.
pub const transport_vocabulary: []const Ban = &.{
    .{
        .where = .{ .files = transport_vocabulary_paths },
        .kind = .forbid,
        .needles = &.{"binds the TCP socket"},
        .check = "transport-vocabulary",
        .why = "`net` realizes netlayer residents over byte streams; CapTP never names a transport",
    },
    .{
        .where = .{ .files = transport_vocabulary_paths },
        .kind = .forbid,
        .needles = &.{"glowcap has two channels"},
        .check = "transport-vocabulary",
        .why = "name netlayer symbols and confidentiality postures; CapTP is identical across them",
    },
    .{
        .where = .{ .files = transport_vocabulary_paths },
        .kind = .forbid,
        .needles = &.{"OCapN/TCP"},
        .check = "transport-vocabulary",
        .why = "say an OCapN session on the `tcp` netlayer — CapTP is not TCP-based",
    },
    .{
        .where = .{ .files = transport_vocabulary_paths },
        .kind = .forbid,
        .needles = &.{"A byte-stream netlayer ships in `net`"},
        .check = "transport-vocabulary",
        .why = "`net` is the adapter + netlayer contract; CapTP stays above it",
    },
    .{
        .where = .{ .files = transport_vocabulary_paths },
        .kind = .forbid,
        .needles = &.{"Sessions above the socket"},
        .check = "transport-vocabulary",
        .why = "sessions live above I/O / the netlayer, not specifically TCP sockets",
    },
    .{
        .where = .{ .files = transport_vocabulary_paths },
        .kind = .forbid,
        .needles = &.{"pure asyncio over TCP"},
        .check = "transport-vocabulary",
        .why = "binding core is the byte-fed host; transport is chosen by locator",
    },
};

pub const transport_provider_architecture: []const Ban = &.{
    .{
        .where = .{ .tree = .{ .dir = "src/c_abi/net_transport", .suffixes = &.{".zig"} } },
        .kind = .forbid,
        .needles = &.{ "secondary_result =", "secondary_name =", "secondary_name_len =", "secondary_count =" },
        .check = "transport-provider-architecture",
        .why = "transport archives project FailureChain through c_abi/shared/transport_provider.zig; hand-assembling the ABI record duplicates the diagnostic authority and can flatten boundary-supplied names",
    },
    .{
        .where = .{ .file = "src/c_abi/shared/locator.zig" },
        .kind = .forbid,
        .needles = &.{ "@import(\"model\")", "clonePeerLocator", "fromView", "project(", "pub fn " },
        .check = "transport-provider-architecture",
        .why = "shared/locator.zig is archive-neutral POD vocabulary only; OCapN semantics and model projection live in their owning modules",
    },
    .{
        .where = .{ .tree = .{
            .dir = "src",
            .suffixes = &.{".zig"},
            .exclude = &.{"src/c_abi/shared/locator.zig"},
        } },
        .kind = .forbid,
        .needles = &.{"GLOWCAP_LOCATOR_VIEW_ABI_VERSION: u32 ="},
        .check = "transport-provider-architecture",
        .why = "the locator ABI version and layout have one physical authority in c_abi/shared/locator.zig; other modules may only re-export it",
    },
    .{
        .where = .{ .tree = .{ .dir = "src/c_abi/driver", .suffixes = &.{".zig"} } },
        .kind = .forbid,
        .needles = &.{ "net.tcp", "glowcap_tcp_", "c_abi_net_transport_tcp", "transport/tcp" },
        .check = "transport-provider-architecture",
        .why = "the generic driver consumes GlowcapTransportProvider and must not depend on a concrete TCP implementation",
    },
    .{
        .where = .{ .file = "src/c_abi/driver/loop.zig" },
        .kind = .forbid,
        .needles = &.{ "StreamAdapter", "MultiplexedAdapter", "decodeTransportProfile", "GlowcapStreamTransport", "GlowcapMultiplexedTransport" },
        .check = "transport-provider-architecture",
        .why = "the loop state/index stays provider-neutral; provider ABI adaptation belongs to the provider-registry package",
    },
    .{
        .where = .{ .tree = .{ .dir = "src/c_abi/driver/loop", .suffixes = &.{".zig"} } },
        .kind = .forbid,
        .needles = &.{ "StreamAdapter", "MultiplexedAdapter", "decodeTransportProfile", "GlowcapStreamTransport", "GlowcapMultiplexedTransport" },
        .check = "transport-provider-architecture",
        .why = "loop operation owners stay provider-neutral; provider ABI adaptation belongs to the provider-registry package",
    },
    .{
        .where = .{ .tree = .{
            .dir = "src/c_abi",
            .suffixes = &.{".zig"},
        } },
        .kind = .forbid,
        .needles = &.{
            "GlowcapStreamListenerLocatorFn",
            "GlowcapStreamListenerAdvertiseFn",
            "GlowcapMultiplexedListenerLocatorFn",
            "GlowcapMultiplexedListenerAdvertiseFn",
        },
        .check = "transport-provider-architecture",
        .why = "stream and multiplexed listeners share one locator projection and canonicalization ABI; only their I/O execution models differ",
    },
    .{
        .where = .{ .files = &.{ "include/glowcap_transport_provider.h", "tools/gen/header/transport_provider.zig" } },
        .kind = .forbid,
        .needles = &.{
            "GlowcapStreamListenerLocatorFn",
            "GlowcapStreamListenerAdvertiseFn",
            "GlowcapMultiplexedListenerLocatorFn",
            "GlowcapMultiplexedListenerAdvertiseFn",
        },
        .check = "transport-provider-architecture",
        .why = "the generated C authority must preserve the execution-model-neutral listener locator callback ABI",
    },
    .{
        .where = .{ .file = "src/c_abi/net_transport/tcp/runtime.zig" },
        .kind = .forbid,
        .needles = &.{ "parseKnown(", "IpAddress.connect(", ".server.accept(", "stream.reader(", "stream.writer(" },
        .check = "transport-provider-architecture",
        .why = "the TCP C ABI projects net.tcp's admitted profile/runtime; it must not reconstruct semantics or realize sockets independently",
    },
    .{
        .where = .{ .files = &.{ "include/glowcap_driver.h", "tools/gen/header/driver.zig" } },
        .kind = .forbid,
        .needles = &.{ "typedef struct GlowcapTransportProfile", "typedef struct GlowcapTransportProvider", "struct GlowcapTransportProvider {" },
        .check = "transport-provider-architecture",
        .why = "provider layouts belong only to the standalone glowcap_transport_provider.h authority",
    },
    .{
        .where = .{ .tree = .{ .dir = "src", .suffixes = &.{".zig"} } },
        .kind = .forbid,
        .needles = &.{ "glowcap_driver_new", "glowcap_driver_host", "glowcap_driver_add_resident", "glowcap_iroh_loop_resident" },
        .check = "transport-provider-architecture",
        .why = "drivers adopt Hosts and install archive-owned packages through the generic registration ABI; concrete provider entry points would create a second integration seam",
    },
    .{
        .where = .{ .tree = .{ .dir = "src/c_abi/net_transport", .suffixes = &.{".zig"} } },
        .kind = .forbid,
        .needles = &.{"Shim"},
        .check = "transport-provider-architecture",
        .why = "transport callbacks are the provider ABI implementation, not transitional shims",
    },
    .{
        .where = .{ .file = "src/net/socket.zig" },
        .kind = .forbid,
        .needles = &.{"pub const Shim = stream_shim.Shim;"},
        .check = "transport-provider-architecture",
        .why = "the stream adapter has one public authority at net.stream_shim; socket owns only OS socket and keepalive primitives",
    },
    .{
        .where = .{ .file = "src/c_abi/driver/symbols.zig" },
        .kind = .forbid,
        .needles = &.{".name = \"glowcap_host_"},
        .check = "transport-provider-architecture",
        .why = "the driver symbol inventory owns only glowcap_driver_*; Host keeps its own archive and inventory",
    },
    .{
        .where = .{ .tree = .{
            .dir = "bindings",
            .suffixes = &.{ ".py", ".rs", ".rkt", ".ts" },
            .skip_dirs = &.{ "target/", "node_modules/" },
        } },
        .kind = .forbid,
        .needles = &.{
            "_LoopIrohResident",        "_loop_iroh_residents", "_provider_owners",
            "provider_owners",          "providerOwners",       " _netlayer: IrohNetlayer",
            "._netlayer: IrohNetlayer",
        },
        .check = "transport-provider-architecture",
        .why = "the driver-held provider lease is the native callback-context owner; bindings retain only immutable provider state",
    },
    .{
        .where = .{ .tree = .{ .dir = "bindings/python/glowcap/_loop", .suffixes = &.{".py"} } },
        .kind = .forbid,
        .needles = &.{ "_ffi_tcp", "glowcap_tcp_", "ensure_tcp_provider" },
        .check = "transport-provider-architecture",
        .why = "the generic Python loop registers packages and drives events; transport modules own concrete provider composition",
    },
    .{
        .where = .{ .file = "bindings/rust/src/driver_loop.rs" },
        .kind = .forbid,
        .needles = &.{ "ensure_tcp_provider", "crate::dial::DialPlan", "crate::iroh::ensure_loop_provider" },
        .check = "transport-provider-architecture",
        .why = "the generic Rust loop registers packages and drives events; dial and transport modules own concrete provider composition",
    },
    .{
        .where = .{ .tree = .{ .dir = "bindings/rust/src/driver_loop", .suffixes = &.{".rs"} } },
        .kind = .forbid,
        .needles = &.{ "ensure_tcp_provider", "crate::dial::DialPlan", "crate::iroh::ensure_loop_provider" },
        .check = "transport-provider-architecture",
        .why = "the Rust loop package registers providers and drives events, while concrete transport composition remains in transport modules",
    },
    .{
        .where = .{ .tree = .{ .dir = "bindings/racket/private/loop", .suffixes = &.{".rkt"} } },
        .kind = .forbid,
        .needles = &.{ "\"ffi-tcp.rkt\"", "driver-loop-add-tcp!" },
        .check = "transport-provider-architecture",
        .why = "the generic Racket loop registers packages and drives events; transport modules own concrete provider composition",
    },
    .{
        .where = .{ .tree = .{ .dir = "bindings/ts/runtime/driver_loop", .suffixes = &.{".ts"} } },
        .kind = .forbid,
        .needles = &.{ "internal/ffi/tcp", "glowcap_tcp_", "ensureTcpProvider" },
        .check = "transport-provider-architecture",
        .why = "the generic TypeScript loop registers packages and drives events; transport modules own concrete provider composition",
    },
};
