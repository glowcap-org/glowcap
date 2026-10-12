//! Ban rows: layer purity, the clock seam, the actors layer, the README's C
//! verb names, binding policy mirrors, Goblins runtime portability, and
//! signature-arm reads.

const bans = @import("../bans.zig");
const Ban = bans.Ban;
const Where = bans.Where;

/// The monotonic clock is consolidated onto one seam, `src/net/clock.zig`, so a
/// component that reads wall-clock or monotonic time goes through it rather than
/// calling the OS clock by hand. A stray `clock_gettime` anywhere else in the
/// core silently reopens the drift the consolidation closed.
pub const clock_seam: []const Ban = &.{
    .{
        .where = .{ .tree = .{ .dir = "src", .suffixes = &.{".zig"}, .exclude = &.{"src/net/clock.zig"} } },
        .kind = .forbid,
        .needles = &.{"clock_gettime"},
        .check = "clock-seam",
        .why = "read monotonic time through src/net/clock.zig's seam (nowMonotonicMs/nowMs), never a hand-rolled clock_gettime",
    },
};

/// The V1.0 resolver descriptor (`resolve_me_desc`) is CapTP wire knowledge:
/// mapping a resolver-only deliver to the virtual answer the engine installed
/// is the engine's job, reached through `Peer.answerForDeliver`. The actor
/// layer must never decode it, because `actors` adds no CapTP semantics the
/// engine lacks (architecture rule). This holds the boundary the
/// `answerForDeliver` seam established, so the vat's old inline descriptor
/// walk cannot creep back.
pub const actors_layer_purity: []const Ban = &.{
    .{
        .where = .{ .tree = .{ .dir = "src/actors", .suffixes = &.{".zig"} } },
        .kind = .forbid,
        .needles = &.{"resolve_me_desc"},
        .check = "actors-layer-purity",
        .why = "the V1.0 resolver descriptor is CapTP wire knowledge; route a resolver-only deliver's answer through `Peer.answerForDeliver`, never by decoding resolve_me_desc in the actor layer (architecture: actors adds no CapTP semantics the engine lacks)",
    },
};

/// Outbound answer positions are minted only by the Session answer-consequence
/// owner. Callers reserve one answer or a contiguous span there. They never
/// advance the cursor by hand and risk wraparound aliasing.
pub const outbound_answer_cursor_rows: []const Ban = &.{
    .{
        .where = .{ .file = "src/ocapn/session/answers/pipeline.zig" },
        .kind = .require,
        .needles = &.{ "OutboundAnswerSpaceExhausted", "reserveOutboundAnswers" },
        .check = "outbound-answer-cursor-owner",
        .why = "session answer-consequence ownership includes fail-closed outbound-answer allocation and span reservation",
    },
    .{
        .where = .{ .tree = .{
            .dir = "src",
            .suffixes = &.{".zig"},
            .exclude = &.{"src/ocapn/session/answers/pipeline.zig"},
        } },
        .kind = .forbid,
        .needles = &.{"next_outbound_answer +="},
        .check = "outbound-answer-cursor-owner",
        .why = "advance outbound answer positions through Session.allocateOutboundAnswer/reserveOutboundAnswers",
    },
};

/// Codec decode nesting has one numeric owner. Syrup and Cap'n Proto keep their
/// historical public names as aliases, not as separate policy facts.
pub const codec_decode_nesting_rows: []const Ban = &.{
    .{
        .where = .{ .file = "src/ocapn/codec/limits.zig" },
        .kind = .require,
        .needles = &.{"pub const max_decode_nesting: usize = 512;"},
        .check = "codec-decode-nesting",
        .why = "codec/limits.zig owns the shared native recursion ceiling for codec decode walks",
    },
    .{
        .where = .{ .file = "src/ocapn/codec/syrup/decode/syntax.zig" },
        .kind = .require,
        .needles = &.{ "@import(\"codec_limits\")", "pub const max_decode_nesting: usize = limits.max_decode_nesting;" },
        .check = "codec-decode-nesting",
        .why = "the Syrup decoder aliases the shared codec decode recursion ceiling instead of restating it",
    },
    .{
        .where = .{ .file = "src/ocapn/codec/capnp/decode.zig" },
        .kind = .require,
        .needles = &.{ "@import(\"codec_limits\")", "pub const max_charge_depth: usize = limits.max_decode_nesting;" },
        .check = "codec-decode-nesting",
        .why = "the Cap'n Proto charge pass aliases the shared codec decode recursion ceiling instead of restating it",
    },
    .{
        .where = .{ .files = &.{
            "src/ocapn/codec/syrup/decode/syntax.zig",
            "src/ocapn/codec/capnp/decode.zig",
            "src/ocapn/codec/mod.zig",
        } },
        .kind = .forbid,
        .needles = &.{ ": usize = 512", "== capnp.decode.max_charge_depth" },
        .check = "codec-decode-nesting",
        .why = "codec decode recursion policy lives in codec/limits.zig; siblings project it",
    },
};

/// The host-session and host-turn C verbs are `glowcap_host_session_*` and
/// `glowcap_host_turn_*`. ADR-0079 retired the binding `Connection` concept, so
/// no `conn_*` export exists. A backticked `conn_` shorthand in the bindings
/// README names a symbol a C consumer cannot grep, so the drift fails here.
pub const readme_c_verb_names: []const Ban = &.{
    .{
        .where = .{ .file = "bindings/DEVELOPING.md" },
        .kind = .forbid,
        .needles = &.{"`conn_"},
        .check = "readme-c-verb-names",
        .why = "no `conn_*` C export exists (ADR-0079 retired the binding Connection concept); name the real `glowcap_host_session_*` or `glowcap_iroh_conn_*` verb a consumer can grep",
    },
};

/// Discovery-posture dial defaults are shared by native `driver.DialRetry` and
/// byte-fed binding connectors that see them through the Host C ABI. The values
/// live in `driver_core`, `driver` owns retry execution and `c_abi_host` only
/// projects the defaults.
pub const discovery_dial_budget_rows: []const Ban = &.{
    .{
        .where = .{ .file = "src/driver/core/vocab.zig" },
        .kind = .require,
        .needles = &.{"pub const discovery_retry_ms: u64 = 3_000;"},
        .check = "discovery-dial-budget",
        .why = "driver_core owns the shared discovery-posture retry interval consumed by driver.DialRetry and the Host C ABI",
    },
    .{
        .where = .{ .file = "src/driver/core/vocab.zig" },
        .kind = .require,
        .needles = &.{"pub const discovery_max_attempts: u32 = 24;"},
        .check = "discovery-dial-budget",
        .why = "driver_core owns the shared discovery-posture attempt budget consumed by driver.DialRetry and the Host C ABI",
    },
    .{
        .where = .{ .file = "src/driver/dial_retry.zig" },
        .kind = .require,
        .needles = &.{"pub const discovery_retry_ms: u64 = driver_core.discovery_retry_ms;"},
        .check = "discovery-dial-budget",
        .why = "driver.DialRetry projects the shared discovery retry interval instead of restating the value",
    },
    .{
        .where = .{ .file = "src/driver/dial_retry.zig" },
        .kind = .require,
        .needles = &.{"pub const discovery_max_attempts: u32 = driver_core.discovery_max_attempts;"},
        .check = "discovery-dial-budget",
        .why = "driver.DialRetry projects the shared discovery attempt budget instead of restating the value",
    },
    .{
        .where = .{ .file = "src/c_abi/host/mod.zig" },
        .kind = .require,
        .needles = &.{"GLOWCAP_DISCOVERY_DIAL_RETRY_MS: u64 = driver_core.discovery_retry_ms"},
        .check = "discovery-dial-budget",
        .why = "the Host C ABI projects the shared discovery retry interval instead of restating the value",
    },
    .{
        .where = .{ .file = "src/c_abi/host/mod.zig" },
        .kind = .require,
        .needles = &.{"GLOWCAP_DISCOVERY_DIAL_MAX_ATTEMPTS: u32 = driver_core.discovery_max_attempts"},
        .check = "discovery-dial-budget",
        .why = "the Host C ABI projects the shared discovery attempt budget instead of restating the value",
    },
    .{
        .where = .{ .files = &.{ "src/driver/dial_retry.zig", "src/c_abi/host/mod.zig" } },
        .kind = .forbid,
        .needles = &.{
            "pub const discovery_retry_ms: u64 = 3_000;",
            "pub const discovery_max_attempts: u32 = 24;",
            "GLOWCAP_DISCOVERY_DIAL_RETRY_MS: u64 = 3_000",
            "GLOWCAP_DISCOVERY_DIAL_MAX_ATTEMPTS: u32 = 24",
        },
        .check = "discovery-dial-budget",
        .why = "discovery dial defaults live in driver_core; driver and the Host C ABI project them",
    },
};

/// Local-turn amplification defaults belong to the driver-core serve loop. The
/// Vat owns queue admission and budgeted driving mechanics, but it does not own
/// the finite Host policy a multi-session loop opts into.
pub const local_turn_budget_rows: []const Ban = &.{
    .{
        .where = .{ .file = "src/driver/core/served.zig" },
        .kind = .require,
        .needles = &.{"pub const default_loop_local_turn_budget: usize = 4096;"},
        .check = "local-turn-budget-owner",
        .why = "driver_core.Served owns the shared finite local-turn amplification cap for multi-session loop hosts",
    },
    .{
        .where = .{ .file = "src/driver/core/mod.zig" },
        .kind = .require,
        .needles = &.{"pub const default_loop_local_turn_budget = served.default_loop_local_turn_budget;"},
        .check = "local-turn-budget-owner",
        .why = "driver.core projects the serve-loop budget owner instead of callers reaching into actors.Vat",
    },
    .{
        .where = .{ .tree = .{ .dir = "src", .suffixes = &.{".zig"} } },
        .kind = .forbid,
        .needles = &.{"max_batch_local_turns"},
        .check = "local-turn-budget-owner",
        .why = "actors.Vat does not own Host loop amplification policy; use driver.core.default_loop_local_turn_budget where a finite loop default is intended",
    },
    .{
        .where = .{ .tree = .{ .dir = "test", .suffixes = &.{".zig"} } },
        .kind = .forbid,
        .needles = &.{"max_batch_local_turns"},
        .check = "local-turn-budget-owner",
        .why = "tests must not restore the old actors.Vat policy name; use the driver-core owner or an explicit test budget",
    },
    .{
        .where = .{ .files = &.{
            "bench/iroh_bench.zig",
            "bench/peer_scaling_bench.zig",
            "interop/iroh_loop/driver.zig",
            "interop/tcp_loop/driver.zig",
            "interop/webrtc_loop/driver.zig",
        } },
        .kind = .forbid,
        .needles = &.{"max_batch_local_turns"},
        .check = "local-turn-budget-owner",
        .why = "loop demos and benches read their finite amplification cap from driver.core, not actors.Vat",
    },
};

/// Iroh node ids are fixed-width designators reflected through generated mirrors.
pub const iroh_node_id_bytes_rows: []const Ban = &.{
    .{
        .where = .{ .file = "src/c_abi/net_transport/iroh/mod.zig" },
        .kind = .require,
        .needles = &.{"pub const GLOWCAP_IROH_NODE_ID_BYTES: usize = iroh.node_id_len;"},
        .check = "iroh-node-id-bytes",
        .why = "the iroh C ABI mirrors the resident-owned node id width",
    },
    .{
        .where = .{ .files = &.{
            "tools/gen/binding/constants.zig",
            "tools/gen/binding/ts_abi.zig",
            "tools/gen/header/iroh.zig",
        } },
        .kind = .require,
        .needles = &.{ "IROH_NODE_ID_BYTES", "GLOWCAP_IROH_NODE_ID_BYTES" },
        .check = "iroh-node-id-bytes",
        .why = "generated mirrors carry the iroh node id width",
    },
    .{
        .where = .{ .files = &.{
            "bindings/python/glowcap/_iroh_native.py",
            "bindings/rust/src/iroh.rs",
            "bindings/ts/iroh/native.ts",
            "bindings/racket/private/iroh/netlayer.rkt",
            "bindings/racket/private/iroh/runtime.rkt",
        } },
        .kind = .require,
        .needles = &.{ "IROH_NODE_ID_BYTES", "IROH-NODE-ID-BYTES" },
        .check = "iroh-node-id-bytes",
        .why = "bindings consume the generated iroh node id width",
    },
    .{
        .where = .{ .files = &.{
            "bindings/python/glowcap/_iroh_native.py",
            "bindings/rust/src/iroh.rs",
            "bindings/ts/iroh/native.ts",
            "bindings/racket/private/iroh/netlayer.rkt",
            "bindings/racket/private/iroh/runtime.rkt",
        } },
        .kind = .forbid,
        .needles = &.{ "cap = 64", "const cap = 64", "[0u8; 64]", "(make-bytes 64)", " buf 64", "buffer 64" },
        .check = "iroh-node-id-bytes",
        .why = "iroh node id buffers use IROH_NODE_ID_BYTES, not the old literal width",
    },
};

/// Iroh direct-address sizing is owned by the transport, not guessed by bindings.
pub const iroh_direct_address_rows: []const Ban = &.{
    .{
        .where = .{ .file = "src/net/transport/iroh/locators.zig" },
        .kind = .require,
        .needles = &.{"max_direct_address_bytes"},
        .check = "iroh-direct-address-sizing",
        .why = "iroh locator policy owns the direct-address publication cap",
    },
    .{
        .where = .{ .file = "src/net/transport/iroh/resident.zig" },
        .kind = .require,
        .needles = &.{ "too_small: usize", "directAddrsOwned" },
        .check = "iroh-direct-address-sizing",
        .why = "the resident preserves the sidecar-reported length and owns the bounded allocation loop",
    },
    .{
        .where = .{ .file = "src/net/transport/iroh/resident.zig" },
        .kind = .forbid,
        .needles = &.{"const direct_len = sidecar.glowcap_iroh_sidecar_endpoint_direct_addrs"},
        .check = "iroh-direct-address-sizing",
        .why = "listener locator publication must use the resident-owned bounded sizing helper",
    },
    .{
        .where = .{ .file = "src/c_abi/net_transport/iroh/mod.zig" },
        .kind = .require,
        .needles = &.{"GLOWCAP_IROH_MAX_DIRECT_ADDRESS_BYTES"},
        .check = "iroh-direct-address-sizing",
        .why = "the iroh C ABI names the direct-address cap it enforces",
    },
    .{
        .where = .{ .file = "src/c_abi/net_transport/iroh/mod.zig" },
        .kind = .require,
        .needles = &.{"len_slot.* = required"},
        .check = "iroh-direct-address-sizing",
        .why = "the iroh C ABI reports required capacity on BUFFER_TOO_SMALL",
    },
    .{
        .where = .{ .file = "bindings/python/glowcap/_iroh_native.py" },
        .kind = .require,
        .needles = &.{"raw,\n                None,\n                0,"},
        .check = "iroh-direct-address-sizing",
        .why = "Python queries direct-address size through the C ABI before allocating",
    },
    .{
        .where = .{ .file = "bindings/rust/src/iroh.rs" },
        .kind = .require,
        .needles = &.{"std::ptr::null_mut(), 0, &mut cap"},
        .check = "iroh-direct-address-sizing",
        .why = "Rust queries direct-address size through the C ABI before allocating",
    },
    .{
        .where = .{ .file = "bindings/ts/iroh/native.ts" },
        .kind = .require,
        .needles = &.{"this.#raw,\n\t\t\tnull,\n\t\t\t0n,"},
        .check = "iroh-direct-address-sizing",
        .why = "TypeScript queries direct-address size through the C ABI before allocating",
    },
    .{
        .where = .{ .file = "bindings/racket/private/iroh/netlayer.rkt" },
        .kind = .require,
        .needles = &.{"(iroh-netlayer-handle netlayer) #f 0"},
        .check = "iroh-direct-address-sizing",
        .why = "Racket queries direct-address size through the C ABI before allocating",
    },
    .{
        .where = .{ .file = "bindings/python/glowcap/_iroh_native.py" },
        .kind = .require,
        .needles = &.{"n.value > cap"},
        .check = "iroh-direct-address-sizing",
        .why = "Python retries direct-address reads from the C-reported size",
    },
    .{
        .where = .{ .file = "bindings/rust/src/iroh.rs" },
        .kind = .require,
        .needles = &.{"len > cap"},
        .check = "iroh-direct-address-sizing",
        .why = "Rust retries direct-address reads from the C-reported size",
    },
    .{
        .where = .{ .file = "bindings/ts/iroh/native.ts" },
        .kind = .require,
        .needles = &.{"required > cap"},
        .check = "iroh-direct-address-sizing",
        .why = "TypeScript retries direct-address reads from the C-reported size",
    },
    .{
        .where = .{ .file = "bindings/racket/private/iroh/netlayer.rkt" },
        .kind = .require,
        .needles = &.{"(> len capacity)"},
        .check = "iroh-direct-address-sizing",
        .why = "Racket retries direct-address reads from the C-reported size",
    },
    .{
        .where = .{ .files = &.{
            "bindings/python/glowcap/_iroh_native.py",
            "bindings/rust/src/iroh.rs",
            "bindings/ts/iroh/native.ts",
            "bindings/racket/private/iroh/netlayer.rkt",
        } },
        .kind = .forbid,
        .needles = &.{ "cap = 256", "let mut cap = 256usize", "let cap = 256", "[capacity 256]", "cap = 1024", "const cap = 1024", "64 * 1024", "(* 64 1024)" },
        .check = "iroh-direct-address-sizing",
        .why = "binding direct-address readers use C-reported sizes, not local guesses",
    },
};

/// URI formatting size is owned by the C ABI formatter, not guessed by bindings.
pub const uri_format_sizing_rows: []const Ban = &.{
    .{
        .where = .{ .file = "src/ocapn/model/uri.zig" },
        .kind = .require,
        .needles = &.{"pub fn writePeerBounded(locator: model.PeerLocator, out: []u8) Error!BoundedWrite"},
        .check = "uri-format-sizing",
        .why = "URI formatting probes and caller-buffer writes share the model formatter instead of a binding-local sizing guess",
    },
    .{
        .where = .{ .file = "src/ocapn/model/uri.zig" },
        .kind = .require,
        .needles = &.{"pub fn writeSturdyrefForProfileBounded"},
        .check = "uri-format-sizing",
        .why = "sturdyref URI formatting uses the same bounded model formatter as peer URI formatting",
    },
    .{
        .where = .{ .file = "src/ocapn/model/uri.zig" },
        .kind = .require,
        .needles = &.{"const CountSink = struct"},
        .check = "uri-format-sizing",
        .why = "URI formatting can count required bytes without allocating a rendered string",
    },
    .{
        .where = .{ .file = "src/c_abi/ocapn/uri/format.zig" },
        .kind = .require,
        .needles = &.{"model.uri.measurePeer(locator)"},
        .check = "uri-format-sizing",
        .why = "the URI C ABI reports rendered length for null/zero sizing probes without materializing the URI",
    },
    .{
        .where = .{ .file = "src/c_abi/ocapn/uri/format.zig" },
        .kind = .require,
        .needles = &.{"model.uri.measureSturdyrefForProfile(profile, value)"},
        .check = "uri-format-sizing",
        .why = "the sturdyref URI C ABI reports rendered length for null/zero sizing probes without materializing the URI",
    },
    .{
        .where = .{ .file = "src/c_abi/ocapn/uri/format.zig" },
        .kind = .require,
        .needles = &.{"model.uri.writePeerBounded(locator, dest[0..cap])"},
        .check = "uri-format-sizing",
        .why = "the URI C ABI writes directly into caller storage instead of allocating and copying a rendered URI",
    },
    .{
        .where = .{ .file = "src/c_abi/ocapn/uri/format.zig" },
        .kind = .require,
        .needles = &.{"model.uri.writeSturdyrefForProfileBounded(profile, value, dest[0..cap])"},
        .check = "uri-format-sizing",
        .why = "the sturdyref URI C ABI writes directly into caller storage instead of allocating and copying a rendered URI",
    },
    .{
        .where = .{ .file = "test/c_abi/uri_test.zig" },
        .kind = .require,
        .needles = &.{"format probes report the needed URI length without an output buffer"},
        .check = "uri-format-sizing",
        .why = "the C ABI test pins URI format sizing probes",
    },
    .{
        .where = .{ .file = "test/c_abi/uri_test.zig" },
        .kind = .require,
        .needles = &.{"var peer_buf: [expected_peer.len]u8 = undefined"},
        .check = "uri-format-sizing",
        .why = "the C ABI test proves exact-size URI buffers succeed with no NUL terminator room",
    },
    .{
        .where = .{ .file = "bindings/python/glowcap/_locator.py" },
        .kind = .require,
        .needles = &.{"rc = call_format(None, 0, out_len)"},
        .check = "uri-format-sizing",
        .why = "Python queries formatted URI size through the C ABI before allocating",
    },
    .{
        .where = .{ .file = "bindings/rust/src/uri/format.rs" },
        .kind = .require,
        .needles = &.{"core::ptr::null_mut(),\n\t\t\t\t0,\n\t\t\t\t&mut cap"},
        .check = "uri-format-sizing",
        .why = "Rust queries formatted URI size through the C ABI before allocating",
    },
    .{
        .where = .{ .file = "bindings/ts/runtime/locator.ts" },
        .kind = .require,
        .needles = &.{"const probeRc = callFormat(null, 0, ab(probeLen))"},
        .check = "uri-format-sizing",
        .why = "TypeScript queries formatted URI size through the C ABI before allocating",
    },
    .{
        .where = .{ .file = "bindings/racket/private/locator.rkt" },
        .kind = .require,
        .needles = &.{"(define-values (probe-rc probe-len) (call-format #f 0))"},
        .check = "uri-format-sizing",
        .why = "Racket queries formatted URI size through the C ABI before allocating",
    },
    .{
        .where = .{ .files = &.{
            "bindings/python/glowcap/_locator.py",
            "bindings/rust/src/uri/format.rs",
            "bindings/ts/runtime/locator.ts",
            "bindings/racket/private/locator.rkt",
        } },
        .kind = .forbid,
        .needles = &.{
            "cap = 256",
            "cap=256",
            "const cap = 256",
            "let mut cap = 256usize",
            "let cap = 256",
            "create_string_buffer(256)",
            "vec![0u8; 256]",
            "vec![0; 256]",
            "new Uint8Array(256)",
            "(make-bytes 256)",
            "[cap 256]",
        },
        .check = "uri-format-sizing",
        .why = "binding URI formatters use C-reported sizes, not local guesses",
    },
};

/// The `rendezvous-relay` hint byte cap is relay route policy, owned by
/// `src/net/transport/keyed_relay/route.zig` and projected through the relay C
/// ABI. Bindings that validate a relay URL before I/O consume the generated
/// mirror. They do not carry their own cap.
pub const relay_route_hint_cap_rows: []const Ban = &.{
    .{
        .where = .{ .file = "src/net/transport/keyed_relay/route.zig" },
        .kind = .require,
        .needles = &.{"pub const max_rendezvous_relay_hint_bytes: usize = 4 * 1024;"},
        .check = "relay-route-hint-cap",
        .why = "the relay route parser owns the rendezvous-relay hint byte cap; change this owner, then regenerate C and binding mirrors",
    },
    .{
        .where = .{ .file = "src/c_abi/net_transport/relay/mod.zig" },
        .kind = .require,
        .needles = &.{"GLOWCAP_RELAY_MAX_RENDEZVOUS_RELAY_HINT_BYTES = net.relay.max_rendezvous_relay_hint_bytes"},
        .check = "relay-route-hint-cap",
        .why = "the relay C ABI must project the route-owned hint cap instead of restating the value",
    },
    .{
        .where = .{ .file = "tools/gen/binding/constants.zig" },
        .kind = .require,
        .needles = &.{"RELAY_MAX_RENDEZVOUS_RELAY_HINT_BYTES"},
        .check = "relay-route-hint-cap",
        .why = "generated binding constants mirror the relay C ABI's route hint cap",
    },
    .{
        .where = .{ .file = "bindings/ts/relay/route.ts" },
        .kind = .require,
        .needles = &.{"RELAY_MAX_RENDEZVOUS_RELAY_HINT_BYTES"},
        .check = "relay-route-hint-cap",
        .why = "TypeScript relay route validation must consume the generated route hint cap instead of carrying its own literal",
    },
    .{
        .where = .{ .file = "bindings/python/glowcap/relay.py" },
        .kind = .require,
        .needles = &.{"_MAX_RENDEZVOUS_RELAY_HINT_BYTES = _c.RELAY_MAX_RENDEZVOUS_RELAY_HINT_BYTES"},
        .check = "relay-route-hint-cap",
        .why = "Python relay route validation must consume the generated route hint cap instead of carrying its own literal",
    },
    .{
        .where = .{ .file = "bindings/racket/private/relay-provider.rkt" },
        .kind = .require,
        .needles = &.{"MAX-RENDEZVOUS-RELAY-HINT-BYTES RELAY-MAX-RENDEZVOUS-RELAY-HINT-BYTES"},
        .check = "relay-route-hint-cap",
        .why = "Racket relay route validation must consume the generated route hint cap instead of carrying its own literal",
    },
};

pub const goblins_runtime_portability: []const Ban = &.{
    .{
        .where = .{ .tree = .{
            .dir = "interop/goblins_interop",
            .suffixes = &.{ ".zig", ".py", ".rs", ".ts", ".rkt" },
        } },
        .kind = .forbid,
        // The class, not one spelling: /usr/bin, /usr/local/bin, and
        // /opt/homebrew/bin all end this way.
        .needles = &.{"/bin/racket"},
        .check = "Goblins runtime portability",
        .why = "live interop resolves `racket` through PATH; an absolute path pins one machine's layout",
    },
};

/// Every migrated table, run once per gate invocation.
/// A borrowed `Signature` is two arms because two codecs spell one value two
/// ways: Syrup carries the halves, Cap'n Proto the concatenation. Reading
/// either arm by name outside the type's own file is therefore a claim about
/// which codec decoded the frame, which no consumer of a codec-neutral view is
/// entitled to make, and the arm that is not active panics. `Signature.eql`
/// answers across arms without allocating. Every comparison goes through it.
pub const signature_arm_reads: []const Ban = &.{
    .{
        .where = .{ .tree = .{
            .dir = "src",
            .suffixes = &.{".zig"},
            .exclude = &.{"src/ocapn/model/view_records.zig"},
        } },
        .kind = .forbid,
        .needles = &.{ "signature.raw", "signature.halves" },
        .check = "signature-arm-reads",
        .why = "compare borrowed signatures through `Signature.eql`, which is total across arms; naming an arm assumes a codec and panics on the other",
    },
};

/// The rooms app's shared contract (`apps/rooms/lib/`) is consumed by the
/// server, the web supervisor, the browser page, and the terminal clients
/// alike, so it may import none of them: a lib module reaching up drags a
/// whole process graph into every consumer (a server import in a module the
/// page touches rides into the browser bundle). Demo orchestration that
/// needs the server belongs in `apps/rooms/demos/`.
pub const rooms_lib_layer: []const Ban = &.{
    .{
        .where = .{ .tree = .{
            .dir = "apps/rooms/lib",
            .suffixes = &.{".ts"},
        } },
        .kind = .forbid,
        .needles = &.{ "from \"../server/", "from \"../web/", "from \"../demos/" },
        .check = "rooms-lib-layer",
        .why = "apps/rooms/lib is the shared contract every rooms consumer imports; it imports no server, web, or demo module",
    },
};
