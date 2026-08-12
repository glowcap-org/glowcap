comptime {
    _ = @import("api_surface_test.zig");
    // Oracle protocol tests run under `zig build oracle-check` only.
    _ = @import("foundation/frame_test.zig");
    _ = @import("foundation/id_test.zig");
    _ = @import("foundation/crypto_test.zig");
    _ = @import("foundation/noise_test.zig");
    _ = @import("foundation/spill_test.zig");
    _ = @import("codec/syrup_test.zig");
    _ = @import("codec/capnp_test.zig");
    _ = @import("codec/capnp_golden_test.zig");
    _ = @import("codec/prefix_decode_test.zig");
    _ = @import("codec/registry_test.zig");
    _ = @import("codec/encode_budget_test.zig");
    _ = @import("codec/fuzz_test.zig");
    _ = @import("engine/fuzz_test.zig");
    _ = @import("driver/fuzz_test.zig");
    _ = @import("model/fuzz_test.zig");
    _ = @import("net/fuzz_test.zig");
    _ = @import("actors/fuzz_test.zig");
    _ = @import("persistent/fuzz_test.zig");
    _ = @import("codec/codec_equivalence_test.zig");
    _ = @import("model/model_test.zig");
    _ = @import("model/equality_test.zig");
    _ = @import("model/view_test.zig");
    _ = @import("model/uri_test.zig");
    _ = @import("actors/vat_test.zig");
    _ = @import("actors/actor_roots_test.zig");
    _ = @import("actors/vat_alloc_budget_test.zig");
    _ = @import("actors/vat_footprint_budget_test.zig");
    _ = @import("actors/ocap_test.zig");
    _ = @import("actors/host_test.zig");
    _ = @import("persistent/persistent_map_test.zig");
    _ = @import("c_abi/header_parity_test.zig");
    _ = @import("c_abi/locator_adapter_test.zig");
    _ = @import("c_abi/uri_test.zig");
    _ = @import("c_abi/host_test.zig");
    _ = @import("c_abi/foreign_call_barrier_test.zig");
    _ = @import("c_abi/inproc_loopback_test.zig");
    _ = @import("c_abi/onion_loopback_test.zig");
    _ = @import("net/connection_test.zig");
    _ = @import("net/frame_stream_test.zig");
    _ = @import("net/netlayer_test.zig");
    _ = @import("net/onion_control_test.zig");
    _ = @import("net/onion_completion_test.zig");
    _ = @import("net/onion_resident_test.zig");
    _ = @import("net/onion_socks5_test.zig");
    _ = @import("net/tcp_parse_test.zig");
    _ = @import("net/tcp_test.zig");
    _ = @import("net/tcp_keepalive_test.zig");
    _ = @import("actors/resolver_vow_test.zig");
    _ = @import("driver/off_turn_settle_test.zig");
    _ = @import("net/keyed_relay_test.zig");
    _ = @import("net/keyed_tcp_test.zig");
    _ = @import("net/noise_tcp_test.zig");
    _ = @import("net/noise_relay_test.zig");
    if (@import("builtin").os.tag == .linux or @import("builtin").os.tag.isDarwin())
        _ = @import("net/completion_loop_test.zig");
    if (@import("builtin").os.tag == .linux or @import("builtin").os.tag.isDarwin())
        _ = @import("net/completion_dialer_test.zig");
    if (@import("builtin").os.tag == .linux or @import("builtin").os.tag.isDarwin())
        _ = @import("net/completion_cross_arm_test.zig");
    if (@import("builtin").os.tag == .linux or @import("builtin").os.tag.isDarwin())
        _ = @import("net/readiness_test.zig");
    if (@import("builtin").os.tag == .linux)
        _ = @import("net/uring_test.zig");
    if (@import("builtin").os.tag == .linux)
        _ = @import("driver/host_runtime_multiplexed_test.zig");
    if (@import("builtin").os.tag == .linux or @import("builtin").os.tag.isDarwin())
        _ = @import("driver/host_runtime_step_test.zig");
    if (@import("builtin").os.tag == .linux or @import("builtin").os.tag.isDarwin())
        _ = @import("c_abi/driver_loop_test.zig");
    if (@import("builtin").os.tag.isDarwin())
        _ = @import("net/kqueue_test.zig");
    if (@import("builtin").os.tag == .linux or @import("builtin").os.tag.isDarwin())
        _ = @import("driver/bridge_test.zig");
    _ = @import("session/session_test.zig");
    _ = @import("session/slot_test.zig");
    _ = @import("session/answers_slot_test.zig");
    _ = @import("session/bootstrap_test.zig");
    _ = @import("session/inspect_test.zig");
    _ = @import("engine/peer_test.zig");
    _ = @import("engine/relay_resolution_test.zig");
    _ = @import("engine/resolver_export_test.zig");
    _ = @import("engine/alloc_budget_test.zig");
    _ = @import("engine/cross_codec_budget_test.zig");
    _ = @import("engine/resolve_alloc_budget_test.zig");
    _ = @import("engine/listener_fire_budget_test.zig");
    _ = @import("engine/deliver_set_scratch_budget_test.zig");
    _ = @import("engine/footprint_budget_test.zig");
    _ = @import("engine/gc_churn_test.zig");
    _ = @import("engine/completion_seam_test.zig");
    _ = @import("engine/negotiation_test.zig");
    _ = @import("engine/abort_projection_test.zig");
    _ = @import("engine/error_taxonomy_test.zig");
    _ = @import("engine/pipeline_test.zig");
    _ = @import("engine/projection_test.zig");
    _ = @import("engine/resolve_window_test.zig");
    _ = @import("engine/fetch_test.zig");
    _ = @import("engine/bootstrap_test.zig");
    _ = @import("engine/sturdyref_test.zig");
    _ = @import("engine/gift_registry_test.zig");
    _ = @import("engine/cross_peer_test.zig");
    _ = @import("engine/pairing_test.zig");
    _ = @import("engine/node_test.zig");
    _ = @import("driver/blocking_session_test.zig");
    _ = @import("driver/host_runtime_handoff_test.zig");
    _ = @import("driver/relayed_promise_test.zig");
    _ = @import("driver/core_host_test.zig");
    _ = @import("driver/sealed_channel_test.zig");
    _ = @import("driver/noise_tcp_live_test.zig");
    _ = @import("driver/capability_registry_test.zig");
    _ = @import("driver/actor_reclaim_test.zig");
    _ = @import("driver/durable_publication_test.zig");
    _ = @import("driver/dial_plan_test.zig");
    _ = @import("driver/dial_retry_test.zig");
    _ = @import("driver/host_limits_test.zig");
    _ = @import("driver/served_budget_test.zig");
    _ = @import("driver/core_host_budget_test.zig");
    _ = @import("driver/core_host_adopt_test.zig");
    _ = @import("driver/crossed_hellos_test.zig");
    _ = @import("driver/gc_stateless_test.zig");
    _ = @import("driver/pluggability_test.zig");
    _ = @import("driver/inproc_netlayer_test.zig");
    _ = @import("driver/onion_host_test.zig");
    _ = @import("driver/session_target_test.zig");
    _ = @import("driver/keyed_tcp_restart_test.zig");
    _ = @import("c_abi/context_test.zig");
    _ = @import("c_abi/frame_test.zig");
}
