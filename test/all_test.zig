//! Every test file the suite runs. `zig build test -Dtest-layer=engine,driver`
//! compiles only those layers' files while iterating. The bare step compiles
//! all layers. CI partitions the shipped-mode compile and checks full coverage.

const std = @import("std");
const selection = @import("test_layers");
const Layer = enum { loam, root, foundation, codec, engine, driver, model, net, session, actors, c_abi };
/// Which layers compile, resolved once so each `wanted` call is one lookup
/// and the selection's length never grows the comptime branch budget.
const wanted_layers = blk: {
    var mask = std.enums.EnumArray(Layer, bool).initFill(selection.layers.len == 0);
    for (selection.layers) |selected| {
        const layer = for (std.enums.values(Layer)) |layer| {
            if (std.mem.eql(u8, @tagName(layer), selected)) break layer;
        } else @compileError("unknown test layer: " ++ selected);
        mask.set(layer, true);
    }
    break :blk mask;
};

fn wanted(comptime layer: Layer) bool {
    return wanted_layers.get(layer);
}

comptime {
    if (wanted(.loam)) {
        _ = @import("loam/core/store_test.zig");
        _ = @import("loam/core/backend_test.zig");
        _ = @import("loam/core/engine_test.zig");
        _ = @import("loam/core/evaluation_test.zig");
        _ = @import("loam/core/names_test.zig");
        _ = @import("loam/core/cache_commit_test.zig");
        _ = @import("loam/core/read_ahead_test.zig");
        _ = @import("loam/core/collection_test.zig");
        _ = @import("loam/core/collection_resume_test.zig");
        _ = @import("loam/core/collection_custody_test.zig");
        _ = @import("loam/hosting/actors_test.zig");
        _ = @import("loam/hosting/reference_test.zig");
        _ = @import("loam/hosting/live_epoch_test.zig");
        _ = @import("loam/hosting/live_reference_test.zig");
        _ = @import("loam/hosting/reference_window_test.zig");
        _ = @import("loam/hosting/reference_metadata_test.zig");
        _ = @import("loam/hosting/reference_scratch_test.zig");
        _ = @import("loam/hosting/ingress_capacity_test.zig");
        _ = @import("loam/hosting/wire_test.zig");
        _ = @import("loam/hosting/arguments_test.zig");
        _ = @import("loam/hosting/continuation_test.zig");
        _ = @import("loam/hosting/read_scope_test.zig");
        _ = @import("loam/hosting/discovery_test.zig");
        _ = @import("loam/hosting/worker_test.zig");
        _ = @import("loam/access/hosting_test.zig");
        _ = @import("loam/access/registration_test.zig");
        _ = @import("loam/access/callback_context_test.zig");
        _ = @import("loam/access/content_graph_test.zig");
        _ = @import("loam/access/content_graph_hosted_test.zig");
        _ = @import("loam/access/continuation_hosted_test.zig");
        _ = @import("loam/access/read_scope_hosted_test.zig");
        _ = @import("loam/access/graph_read_scope_test.zig");
        _ = @import("loam/access/reference_test.zig");
        _ = @import("loam/access/hosting_wire_test.zig");
        _ = @import("loam/access/sharing_test.zig");
        _ = @import("loam/access/tree_hosted_test.zig");
        _ = @import("loam/access/mutation_test.zig");
        _ = @import("loam/access/management_test.zig");
        _ = @import("loam/access/value_record_test.zig");
        _ = @import("loam/access/resource_lifecycle_test.zig");
        _ = @import("loam/access/description_test.zig");
        _ = @import("loam/core/record_test.zig");
        _ = @import("loam/access/graph_test.zig");
        _ = @import("loam/access/scope_test.zig");
        _ = @import("loam/access/resource_view_test.zig");
        _ = @import("loam/access/resource_record_test.zig");
        _ = @import("loam/access/grant_view_test.zig");
        _ = @import("loam/access/grant_record_test.zig");
        _ = @import("loam/access/change_history_test.zig");
        _ = @import("loam/access/observation_test.zig");
        _ = @import("loam/access/observation_lifetime_test.zig");
        _ = @import("loam/access/identity_registry_test.zig");
        _ = @import("loam/access/maintenance_test.zig");
        _ = @import("loam/access/observation_hosted_test.zig");
        _ = @import("loam/access/owner_test.zig");
        _ = @import("loam/access/owner_composed_test.zig");
        _ = @import("loam/access/directory_edit_test.zig");
        _ = @import("loam/access/owner_index_test.zig");
        _ = @import("loam/access/stored_capability_test.zig");
        _ = @import("loam/access/stored_capability_memory_test.zig");
        _ = @import("loam/access/stored_capability_record_test.zig");
        _ = @import("loam/access/owner_records_test.zig");
        _ = @import("loam/access/policy_test.zig");
        _ = @import("loam/access/applicability_test.zig");
        _ = @import("loam/access/grants_test.zig");
        _ = @import("loam/access/grant_limits_test.zig");
        _ = @import("loam/access/grant_memory_test.zig");
        _ = @import("loam/access/grant_events_test.zig");
        _ = @import("loam/access/grant_transaction_test.zig");
        _ = @import("loam/access/grant_transaction_memory_test.zig");
        _ = @import("loam/access/graph_reservation_test.zig");
        _ = @import("loam/access/grant_capability_test.zig");
        _ = @import("loam/access/grant_capability_memory_test.zig");
        _ = @import("loam/collections/fuzz_test.zig");
        _ = @import("loam/collections/persistent_map_test.zig");
    }
    if (wanted(.root)) {
        _ = @import("api_surface_test.zig");
    }
    if (wanted(.foundation)) {
        _ = @import("foundation/utf8_test.zig");
        // Oracle protocol tests run under `zig build oracle-check` only.
        _ = @import("foundation/frame_test.zig");
        _ = @import("foundation/id_test.zig");
        _ = @import("foundation/id_issuer_test.zig");
        _ = @import("foundation/crypto_test.zig");
        _ = @import("foundation/noise_test.zig");
        _ = @import("foundation/sealed_test.zig");
        _ = @import("foundation/thread_affinity_test.zig");
        _ = @import("foundation/identity_hash_test.zig");
        _ = @import("foundation/handle_table_test.zig");
        _ = @import("foundation/bearer_table_test.zig");
        _ = @import("foundation/fuzz_test.zig");
        _ = @import("foundation/inline_rows_test.zig");
        _ = @import("foundation/spill_test.zig");
        _ = @import("foundation/failure_chain_test.zig");
        _ = @import("foundation/stream_framing_test.zig");
    }
    if (wanted(.codec)) {
        _ = @import("codec/syrup/encode_test.zig");
        _ = @import("codec/syrup/meter_test.zig");
        _ = @import("codec/syrup/render_test.zig");
        _ = @import("codec/syrup/struct_order_test.zig");
        _ = @import("codec/syrup/encode_view_test.zig");
        _ = @import("codec/syrup/decode_test.zig");
        _ = @import("codec/syrup/decode_records_test.zig");
        _ = @import("codec/syrup/decode_slab_test.zig");
        _ = @import("codec/syrup/decode_hints_test.zig");
        _ = @import("codec/syrup/decode/borrowed_test.zig");
        _ = @import("codec/syrup/argument_test.zig");
        _ = @import("codec/syrup/oracle_test.zig");
        _ = @import("codec/syrup/view_test.zig");
        _ = @import("codec/capnp_test.zig");
        _ = @import("codec/capnp_malformed_test.zig");
        _ = @import("codec/capnp_word_run_test.zig");
        _ = @import("codec/capnp_view_encode_test.zig");
        _ = @import("codec/sequence_length_test.zig");
        _ = @import("codec/struct_slab_test.zig");
        _ = @import("codec/capnp_golden_test.zig");
        _ = @import("codec/whole_frame_test.zig");
        _ = @import("codec/registry_test.zig");
        _ = @import("codec/encode_budget_test.zig");
        _ = @import("codec/fuzz_test.zig");
        _ = @import("codec/codec_equivalence_test.zig");
    }
    if (wanted(.engine)) {
        _ = @import("engine/fuzz_test.zig");
        _ = @import("engine/allocation_failure_test.zig");
        _ = @import("engine/parse_once_test.zig");
        _ = @import("engine/give_location_test.zig");
        _ = @import("engine/peer/ownership_test.zig");
        _ = @import("engine/peer/encoded_send_test.zig");
        _ = @import("engine/peer/freight_send_test.zig");
        _ = @import("engine/peer/answer_release_test.zig");
        _ = @import("engine/peer/v1_translation/gc_test.zig");
        _ = @import("engine/peer/v1_translation/oom_test.zig");
        _ = @import("engine/peer/v1_translation/resolver_test.zig");
        _ = @import("engine/peer/v1_translation/shared_resolver_test.zig");
        _ = @import("engine/peer/pipeline_test.zig");
        _ = @import("engine/peer/pipeline_undeliverable_test.zig");
        _ = @import("engine/peer/pipeline_reply_identity_test.zig");
        _ = @import("engine/peer/pipeline_remote_forward_test.zig");
        _ = @import("engine/peer/pipeline_local_promise_test.zig");
        _ = @import("engine/peer/pipeline_local_promise_drain_test.zig");
        _ = @import("engine/peer/pipeline/fail_closed_test.zig");
        _ = @import("engine/peer/abort_test.zig");
        _ = @import("engine/peer/shortening_test.zig");
        _ = @import("engine/peer/settling_test.zig");
        _ = @import("engine/peer/listener_discard_test.zig");
        _ = @import("engine/peer/listen_failure_test.zig");
        _ = @import("engine/relay_resolution_test.zig");
        _ = @import("engine/listen_on_far_test.zig");
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
        _ = @import("engine/gift_registry_budget_test.zig");
        _ = @import("engine/cross_peer/authority_test.zig");
        _ = @import("engine/cross_peer/withdraw_test.zig");
        _ = @import("engine/cross_peer/parked_test.zig");
        _ = @import("engine/cross_peer/parked_admission_test.zig");
        _ = @import("engine/cross_peer/capnp_test.zig");
        _ = @import("engine/pairing/handshake_test.zig");
        _ = @import("engine/pairing/route_vocabulary_test.zig");
        _ = @import("engine/pairing/offers_test.zig");
        _ = @import("engine/pairing/signature_test.zig");
        _ = @import("engine/pairing/resolver_test.zig");
        _ = @import("engine/node/tables_test.zig");
        _ = @import("engine/node/proxy_test.zig");
        _ = @import("engine/node/proxy/convergence_test.zig");
        _ = @import("engine/node/proxy/lifecycle_test.zig");
        _ = @import("engine/node/gift_test.zig");
        _ = @import("engine/node/staged_order_test.zig");
        _ = @import("engine/node/answer_settlement_test.zig");
        _ = @import("engine/node/gift_failure_test.zig");
        _ = @import("engine/node/relay_failure_test.zig");
        _ = @import("engine/node/staged_local_promise_test.zig");
        _ = @import("engine/node/dial_test.zig");
        _ = @import("engine/node/dial/allocation_test.zig");
        _ = @import("engine/node/dial/id_route_test.zig");
        _ = @import("engine/node/withdraw_test.zig");
        _ = @import("engine/node/enroll_test.zig");
        _ = @import("engine/node/relay_test.zig");
    }
    if (wanted(.driver)) {
        _ = @import("driver/fuzz_test.zig");
        _ = @import("driver/promise_argument_test.zig");
        _ = @import("driver/vow_capability_test.zig");
        _ = @import("driver/off_turn_settle_test.zig");
        if (@import("builtin").os.tag == .linux) {
            _ = @import("driver/host_runtime_multiplexed/lifecycle_test.zig");
            _ = @import("driver/host_runtime_multiplexed/park_test.zig");
            _ = @import("driver/host_runtime_multiplexed/zig_server_test.zig");
            _ = @import("driver/host_runtime_multiplexed/conversation_test.zig");
            _ = @import("driver/host_runtime_multiplexed/completion_resident_test.zig");
            _ = @import("driver/host_runtime_multiplexed/provider_test.zig");
            _ = @import("driver/session_wire_fault_test.zig");
            _ = @import("driver/host_runtime_step/dial_retry_test.zig");
        }
        if (@import("builtin").os.tag == .linux or @import("builtin").os.tag.isDarwin())
            _ = @import("driver/host_runtime_step/serve_test.zig");
        _ = @import("driver/host_runtime_step/flood_test.zig");
        _ = @import("driver/host_runtime_step/refused_partner_release_test.zig");
        _ = @import("driver/host_runtime_step/staged_dial_test.zig");
        _ = @import("driver/host_runtime_step/wake_test.zig");
        _ = @import("driver/host_runtime_multiplexed/external_resident_test.zig");
        _ = @import("driver/host_runtime_multiplexed/inproc_resident_test.zig");
        _ = @import("driver/host_runtime_multiplexed/relay_resident_test.zig");
        _ = @import("driver/host_runtime_multiplexed/noise_tcp_resident_test.zig");
        _ = @import("driver/host_runtime_multiplexed/onion_resident_test.zig");
        _ = @import("driver/host_runtime_multiplexed/stream_stack_test.zig");
        _ = @import("driver/session_loopback_test.zig");
        _ = @import("driver/session_fault_test.zig");
        _ = @import("driver/served_byte_fed_test.zig");
        _ = @import("driver/host_runtime_handoff_test.zig");
        _ = @import("driver/core_host/close_test.zig");
        _ = @import("driver/core_host/finish_test.zig");
        _ = @import("driver/core_host/pressure_test.zig");
        _ = @import("driver/core_host/give_test.zig");
        _ = @import("driver/core_host/give/staged_test.zig");
        _ = @import("driver/core_host/give/tell_retirement_test.zig");
        _ = @import("driver/core_host/give/projection_callback_test.zig");
        _ = @import("driver/core_host/give/cancel_pump_test.zig");
        _ = @import("driver/core_host/give/id_exhaustion_test.zig");
        _ = @import("driver/core_host/give/pending_cap_test.zig");
        _ = @import("driver/core_host/failure_taxonomy_test.zig");
        _ = @import("driver/core_host/capability_projection_test.zig");
        _ = @import("driver/core_host/routing_depth_test.zig");
        _ = @import("driver/core_host/give/relayed_test.zig");
        _ = @import("driver/core_host/locator_test.zig");
        _ = @import("driver/core_host/locator_budget_test.zig");
        _ = @import("driver/core_host/redeem_test.zig");
        _ = @import("driver/core_host/enliven_test.zig");
        _ = @import("driver/core_host/enliven/group_test.zig");
        _ = @import("driver/core_host/owned_call_test.zig");
        _ = @import("driver/core_host/local_delivery_test.zig");
        _ = @import("driver/core_host/local_foreign_forward_test.zig");
        _ = @import("driver/core_host/local_effects_test.zig");
        _ = @import("driver/core_host/completion_test.zig");
        _ = @import("driver/core_host/view_delivery_test.zig");
        _ = @import("driver/value_views_test.zig");
        _ = @import("driver/core_host/redeem/id_routes_test.zig");
        _ = @import("driver/core_host/redeem/route_completion_test.zig");
        _ = @import("driver/core_host/redeem/withdraw_test.zig");
        _ = @import("driver/core_host/redeem/batch_failure_test.zig");
        _ = @import("driver/core_host/actors_test.zig");
        _ = @import("driver/core_host/actors/swiss_test.zig");
        _ = @import("driver/core_host/actors/scope_test.zig");
        _ = @import("driver/core_host/publication_reservation_test.zig");
        _ = @import("driver/core_host/turn_lowering_test.zig");
        _ = @import("driver/core_host/turn_staging_test.zig");
        _ = @import("driver/core_host/gift_order_test.zig");
        _ = @import("driver/core_host/pairing_test.zig");
        _ = @import("driver/core_host/pairing/reentry_test.zig");
        _ = @import("driver/core_host/pairing/durable_peer_test.zig");
        _ = @import("driver/core_host/answer_release_test.zig");
        _ = @import("driver/core_host/vow_test.zig");
        _ = @import("driver/core_host/vow/allocation_test.zig");
        _ = @import("driver/core_host/admission_test.zig");
        _ = @import("driver/core_host/session_cap_test.zig");
        _ = @import("driver/core_host/range_test.zig");
        _ = @import("driver/core_host/identity_test.zig");
        _ = @import("driver/core_host/identity/provenance_test.zig");
        _ = @import("driver/core_host/defer_test.zig");
        _ = @import("driver/core_host/trace_test.zig");
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
        _ = @import("driver/inproc_netlayer_test.zig");
        _ = @import("driver/onion_host_test.zig");
        _ = @import("driver/session_target_test.zig");
        _ = @import("driver/keyed_tcp_restart_test.zig");
    }
    if (wanted(.model)) {
        _ = @import("model/fuzz_test.zig");
        _ = @import("model/model_test.zig");
        _ = @import("model/equality_test.zig");
        _ = @import("model/view_test.zig");
        _ = @import("model/uri_test.zig");
    }
    if (wanted(.net)) {
        _ = @import("net/inproc_completion_test.zig");
        _ = @import("net/completion_poll_test.zig");
        _ = @import("net/completion_listeners_test.zig");
        _ = @import("net/tcp_completion_policy_test.zig");
        _ = @import("net/completion_resident_test.zig");
        _ = @import("net/completion_resident_listener_test.zig");
        _ = @import("net/fuzz_test.zig");
        _ = @import("net/connection_test.zig");
        _ = @import("net/completion_contract_test.zig");
        _ = @import("net/frame_stream_test.zig");
        _ = @import("net/netlayer_test.zig");
        _ = @import("net/operation_owner_test.zig");
        _ = @import("net/onion_control_test.zig");
        _ = @import("net/onion_control_session_test.zig");
        _ = @import("net/onion_completion_test.zig");
        _ = @import("net/onion_resident_test.zig");
        _ = @import("net/onion_socks5_test.zig");
        _ = @import("net/tcp_parse_test.zig");
        _ = @import("net/tcp_test.zig");
        _ = @import("net/tcp_keepalive_test.zig");
        _ = @import("net/tls_engine_test.zig");
        _ = @import("net/tls_runtime_owner_test.zig");
        _ = @import("net/tls_pollable_stream_test.zig");
        _ = @import("net/tls_transform_test.zig");
        _ = @import("net/keyed_relay_failure_test.zig");
        _ = @import("net/keyed_relay_address_race_test.zig");
        _ = @import("net/keyed_relay_frame_test.zig");
        _ = @import("net/keyed_relay_url_test.zig");
        _ = @import("net/keyed_relay/listener_test.zig");
        _ = @import("net/keyed_relay/rendezvous_test.zig");
        _ = @import("net/keyed_relay/alias_test.zig");
        _ = @import("net/keyed_relay/loop_test.zig");
        _ = @import("net/keyed_relay/close_test.zig");
        _ = @import("net/keyed_relay/registration_test.zig");
        _ = @import("net/keyed_relay_completion_test.zig");
        _ = @import("net/keyed_relay_completion_dial_test.zig");
        _ = @import("net/keyed_relay_completion_bounds_test.zig");
        _ = @import("net/keyed_relay_bounds_test.zig");
        _ = @import("net/keyed_relay_registration_bounds_test.zig");
        _ = @import("net/keyed_relay_completion_dns_test.zig");
        _ = @import("net/keyed_relay_completion_tls_test.zig");
        _ = @import("net/keyed_relay_completion_wire_test.zig");
        _ = @import("net/keyed_tcp_test.zig");
        _ = @import("net/noise_tcp_test.zig");
        if (@import("builtin").os.tag == .linux or @import("builtin").os.tag.isDarwin())
            _ = @import("net/completion_loop_test.zig");
        if (@import("builtin").os.tag == .linux or @import("builtin").os.tag.isDarwin())
            _ = @import("net/completion_listener_test.zig");
        _ = @import("net/completion_loop_backpressure_test.zig");
        _ = @import("net/completion_loop_stream_test.zig");
        _ = @import("net/completion_loop_reclaim_test.zig");
        _ = @import("net/completion_loop_reclaim/fan_in_test.zig");
        if (@import("builtin").os.tag == .linux or @import("builtin").os.tag.isDarwin())
            _ = @import("net/completion_dialer_test.zig");
        if (@import("builtin").os.tag == .linux or @import("builtin").os.tag.isDarwin()) {
            _ = @import("net/completion/cross_arm_test.zig");
            _ = @import("net/completion/wake_test.zig");
            _ = @import("net/completion/close_slot_test.zig");
        }
        if (@import("builtin").os.tag == .linux or @import("builtin").os.tag.isDarwin())
            _ = @import("net/readiness_test.zig");
        if (@import("builtin").os.tag == .linux)
            _ = @import("net/uring_test.zig");
        if (@import("builtin").os.tag == .linux)
            _ = @import("net/linux_completion_test.zig");
        if (@import("builtin").os.tag.isDarwin())
            _ = @import("net/kqueue_test.zig");
    }
    if (wanted(.session)) {
        _ = @import("session/fuzz_test.zig");
        _ = @import("session/lifecycle_test.zig");
        _ = @import("session/traffic_test.zig");
        _ = @import("session/set_uniqueness_test.zig");
        _ = @import("session/answer_test.zig");
        _ = @import("session/answer_notification_test.zig");
        _ = @import("session/gc_test.zig");
        _ = @import("session/gc_prepared_test.zig");
        _ = @import("session/resolver_link_test.zig");
        _ = @import("session/grant_test.zig");
        _ = @import("session/handoff_test.zig");
        _ = @import("session/resolver_test.zig");
        _ = @import("session/listen_record_test.zig");
        _ = @import("session/imported_promise_test.zig");
        _ = @import("session/held_import_test.zig");
        _ = @import("session/slot_test.zig");
        _ = @import("session/answers_slot_test.zig");
        _ = @import("session/position_slab_test.zig");
        _ = @import("session/bootstrap_test.zig");
        _ = @import("session/inspect_test.zig");
        _ = @import("session/inventory_test.zig");
        _ = @import("session/freight_test.zig");
        _ = @import("session/integer_run_test.zig");
        _ = @import("session/freight_scratch_test.zig");
    }
    if (wanted(.actors)) {
        _ = @import("actors/fuzz_test.zig");
        _ = @import("actors/vat/turn_test.zig");
        _ = @import("actors/vat/turn_commit_test.zig");
        _ = @import("actors/vat/turn_far_test.zig");
        _ = @import("actors/vat/hosted_test.zig");
        _ = @import("actors/vat/ingress_test.zig");
        _ = @import("actors/vat/opaque_test.zig");
        _ = @import("actors/vat/far_test.zig");
        _ = @import("actors/vat/snapshot_test.zig");
        _ = @import("actors/vat/move_test.zig");
        _ = @import("actors/vat/become_test.zig");
        _ = @import("actors/vat/borrowed_reply_test.zig");
        _ = @import("actors/actor_roots_test.zig");
        _ = @import("actors/vat_alloc_budget_test.zig");
        _ = @import("actors/freight_send_test.zig");
        _ = @import("actors/invocation_shape_test.zig");
        _ = @import("actors/vat_footprint_budget_test.zig");
        _ = @import("actors/ocap_test.zig");
        _ = @import("actors/host_test.zig");
        _ = @import("actors/resolver_vow_test.zig");
    }
    if (wanted(.c_abi)) {
        _ = @import("c_abi/header_parity_test.zig");
        _ = @import("c_abi/archive_contract_test.zig");
        _ = @import("c_abi/locator_adapter_test.zig");
        _ = @import("c_abi/uri_test.zig");
        _ = @import("c_abi/designator_test.zig");
        _ = @import("c_abi/host/close_test.zig");
        _ = @import("c_abi/host/authority_test.zig");
        _ = @import("c_abi/host/verbs_test.zig");
        _ = @import("c_abi/host/values_test.zig");
        _ = @import("c_abi/host/turn_test.zig");
        _ = @import("c_abi/host/local_delivery_test.zig");
        _ = @import("c_abi/host/invocation_test.zig");
        _ = @import("c_abi/host/dial_plan_test.zig");
        _ = @import("c_abi/host/handoff_test.zig");
        _ = @import("c_abi/host/stream_test.zig");
        _ = @import("c_abi/host/frame_admission_test.zig");
        _ = @import("c_abi/host/callback_test.zig");
        _ = @import("c_abi/last_error_test.zig");
        _ = @import("c_abi/failure_diagnostics_test.zig");
        _ = @import("c_abi/foreign_call_barrier_test.zig");
        _ = @import("c_abi/inproc_loopback_test.zig");
        _ = @import("c_abi/onion_loopback/provider_test.zig");
        _ = @import("c_abi/onion_loopback/conversation_test.zig");
        _ = @import("c_abi/onion_loopback/refusal_test.zig");
        _ = @import("c_abi/relay_provider_test.zig");
        _ = @import("c_abi/relay_provider/buffered_accept_test.zig");
        _ = @import("c_abi/tcp_provider_options_test.zig");
        if (@import("builtin").os.tag == .linux or @import("builtin").os.tag.isDarwin())
            _ = @import("c_abi/driver_loop/close_test.zig");
        _ = @import("c_abi/driver_loop/adopt_test.zig");
        _ = @import("c_abi/driver_loop/provider_test.zig");
        _ = @import("c_abi/driver_loop/readiness_contract_test.zig");
        _ = @import("c_abi/driver_loop/teardown_contract_test.zig");
        _ = @import("c_abi/driver_loop/listener_test.zig");
        _ = @import("c_abi/driver_loop/archive_test.zig");
        _ = @import("c_abi/driver_loop/loopback_test.zig");
        _ = @import("c_abi/driver_loop/session_release_test.zig");
        _ = @import("c_abi/context_test.zig");
        _ = @import("c_abi/frame_test.zig");
    }
}
