//! The per-binding WebRTC dial and listen rows under their `bindings-*`
//! aggregates. The parent module registers them.
const BindingClientRow = @import("../binding_families.zig").BindingClientRow;

// Each binding dials the Zig WebRTC answerer (`interop/webrtc_browser_peer/
// answerer.zig`) through the C provider, carrying the offer, answer, and
// candidates itself over the answerer's stdio, then makes one call (ADR-0035).
// Each also listens and accepts the Zig offerer
// (`interop/webrtc_driver_provider/offerer.zig`) the same way (ADR-0035).
pub const webrtc_driver_provider_clients = [_]BindingClientRow{
    .{
        .step_name = "deno-webrtc-driver-provider",
        .description = "Live Deno WebRTC: the Deno binding dials the Zig answerer (ADR-0035) and accepts the Zig offerer (ADR-0035), both through the C provider with its own signaling (needs cargo + deno)",
        .argv = &.{ "deno", "run", "-A", "--unstable-ffi", "interop/webrtc_driver_provider/deno_client.ts" },
        .posture = .{ .deterministic = 30 },
    },
    .{
        .step_name = "python-webrtc-driver-provider",
        .description = "Live Python WebRTC: the Python binding dials the Zig answerer (ADR-0035) and accepts the Zig offerer (ADR-0035), both through the C provider with its own signaling (needs cargo + python3)",
        .argv = &.{ "python3", "interop/webrtc_driver_provider/python_client.py" },
        .posture = .{ .deterministic = 30 },
    },
    .{
        .step_name = "rust-webrtc-driver-provider",
        .description = "Live Rust WebRTC: the Rust binding dials the Zig answerer (ADR-0035), accepts the Zig offerer, and dials from a listening Host (ADR-0035), all through the C provider with its own signaling, after its hermetic adapter tests (needs cargo)",
        .argv = &.{ "cargo", "test", "--manifest-path", "bindings/rust/Cargo.toml", "--features", "webrtc", "webrtc::tests", "--", "--include-ignored", "--nocapture" },
        .posture = .{ .deterministic = 30 },
    },
    .{
        .step_name = "racket-webrtc-driver-provider",
        .description = "Live Racket WebRTC: the Racket binding dials the Zig answerer (ADR-0035) and accepts the Zig offerer (ADR-0035), both through the C provider with its own signaling (needs cargo + racket)",
        .argv = &.{ "racket", "-y", "interop/webrtc_driver_provider/racket_client.rkt" },
        .posture = .{ .deterministic = 30 },
    },
};
