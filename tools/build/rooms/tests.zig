//! Rooms' self-contained Deno test inventory and build steps. The application
//! build composes this subject; this module owns how the suite is cached,
//! divided into bounded processes, and attached to `check`.

const std = @import("std");
const common = @import("../common.zig");

pub const Context = struct {
    b: *std.Build,
    check_step: *std.Build.Step,
    ocapn_install: *std.Build.Step,
    host_install: *std.Build.Step,
    driver_install: *std.Build.Step,
    tcp_install: *std.Build.Step,
    relay_install: *std.Build.Step,
};

const command: []const []const u8 = &.{
    "deno",
    "test",
    "--cert=test/net/fixtures/tls_root.pem",
    "--allow-ffi",
    "--unstable-ffi",
    "--allow-read",
    "--allow-net",
    "--allow-run",
    "--allow-env",
    "--allow-write",
};

const batches: []const []const []const u8 = &.{
    &.{
        "apps/rooms/test/server/ephemeral_state_test.ts",
        "apps/rooms/test/server/files_test.ts",
        "apps/rooms/test/server/names_test.ts",
        "apps/rooms/test/server/signaling_test.ts",
        "apps/rooms/test/server/rooms_test.ts",
        "apps/rooms/test/server/directory_atomicity_test.ts",
        "apps/rooms/test/server/room_arguments_test.ts",
    },
    &.{
        "apps/rooms/test/server/peering_test.ts",
        "apps/rooms/test/peering_client_test.ts",
        "apps/rooms/test/server/lines_test.ts",
    },
    &.{
        "apps/rooms/test/server/history_test.ts",
        "apps/rooms/test/server/irc_gateway_test.ts",
        "apps/rooms/test/server/irc_authority_test.ts",
        "apps/rooms/test/server/irc_multi_channel_test.ts",
        "apps/rooms/test/server/irc_gateway/custody_test.ts",
        "apps/rooms/test/server/irc_gateway/arguments_test.ts",
        "apps/rooms/test/server/capabilities_test.ts",
        "apps/rooms/test/irc/reader_test.ts",
    },
    &.{
        "apps/rooms/test/server/links_test.ts",
        "apps/rooms/test/server/inspect_test.ts",
        "apps/rooms/test/server/topic_state_test.ts",
        "apps/rooms/test/server/operations_state_test.ts",
        "apps/rooms/test/server/private_links_test.ts",
        "apps/rooms/test/session/join_peer_test.ts",
        "apps/rooms/test/session/peer_test.ts",
        "apps/rooms/test/session/reconnect_peer_test.ts",
        "apps/rooms/test/session/peer_unnamed_test.ts",
        "apps/rooms/test/session/grant_peer_test.ts",
        "apps/rooms/test/session/private_room_test.ts",
        "apps/rooms/test/session/dm_peer_test.ts",
        "apps/rooms/test/session/mixed_dm_peer_test.ts",
        "apps/rooms/test/session/archive_test.ts",
        "apps/rooms/test/session/archive_shares_test.ts",
        "apps/rooms/test/session/history_policy_test.ts",
    },
    &.{
        "apps/rooms/test/server/steward_test.ts",
        "apps/rooms/test/enter_room_test.ts",
        "apps/rooms/test/bridge/prefix_test.ts",
        "apps/rooms/test/bridge/form_test.ts",
        "apps/rooms/test/server/invitation_test.ts",
        "apps/rooms/test/server/operator_test.ts",
        "apps/rooms/test/server/registration_release_test.ts",
        "apps/rooms/test/operator/watch_test.ts",
        "apps/rooms/test/operator/references_test.ts",
        "apps/rooms/test/server/sessions_test.ts",
        "apps/rooms/test/server/listeners_test.ts",
        "apps/rooms/test/registry_test.ts",
        "apps/rooms/test/routes_test.ts",
    },
    &.{
        "apps/rooms/test/text_test.ts",
        "apps/rooms/test/argument_custody_test.ts",
        "apps/rooms/test/member_identity_test.ts",
        "apps/rooms/test/prefs_test.ts",
        "apps/rooms/test/complete_test.ts",
        "apps/rooms/test/media_test.ts",
        "apps/rooms/test/store/attachments_test.ts",
        "apps/rooms/test/store/directory_test.ts",
        "apps/rooms/test/directory_conversation_test.ts",
        "apps/rooms/test/composer_commit_test.ts",
        "apps/rooms/test/store/typing_test.ts",
        "apps/rooms/test/store/roster_test.ts",
        "apps/rooms/test/store/app_shell_test.ts",
        "apps/rooms/test/page_projection_test.ts",
        "apps/rooms/test/session/setup_projection_test.ts",
        "apps/rooms/test/store/room_access_test.ts",
        "apps/rooms/test/store/irc_test.ts",
        "apps/rooms/test/store/line_identity_test.ts",
        "apps/rooms/test/store/room_identity_test.ts",
        "apps/rooms/test/attached/session_drafts_test.ts",
        "apps/rooms/test/irc/identity_form_test.ts",
        "apps/rooms/test/workspace_state_test.ts",
        "apps/rooms/test/workspace_persistence_test.ts",
        "apps/rooms/test/workspace_fanout_test.ts",
        "apps/rooms/test/ops_bundle_test.ts",
        "apps/rooms/test/ops_invalidation_test.ts",
        "apps/rooms/test/operator/refresh_test.ts",
        "apps/rooms/test/operator/parser_test.ts",
        "apps/rooms/test/session/state_test.ts",
        "apps/rooms/test/session/room_authority_test.ts",
        "apps/rooms/test/session/state_sync_test.ts",
        "apps/rooms/test/session/conversation_command_test.ts",
        "apps/rooms/test/session/adoption_test.ts",
        "apps/rooms/test/session/transition_test.ts",
        "apps/rooms/test/session/local_remote_test.ts",
        "apps/rooms/test/session/hosted_hold_test.ts",
        "apps/rooms/test/session/grants_test.ts",
        "apps/rooms/test/session/documents_test.ts",
        "apps/rooms/test/session/facet_view_test.ts",
        "apps/rooms/test/session/facet_pair_test.ts",
        "apps/rooms/test/session/topology_test.ts",
        "apps/rooms/test/session/realization_test.ts",
        "apps/rooms/test/session/runtime_cleanup_test.ts",
        "apps/rooms/test/session/webrtc_answer_test.ts",
        "apps/rooms/test/session/attached_failure_test.ts",
        "apps/rooms/test/runtime_directory_reconcile_test.ts",
        "apps/rooms/test/session/standing_test.ts",
        "apps/rooms/test/session/file_custody_test.ts",
        "apps/rooms/test/session/attachment_admission_test.ts",
        "apps/rooms/test/session/directory_view_test.ts",
        "apps/rooms/test/session/room_view_test.ts",
        "apps/rooms/test/local_peering_state_test.ts",
        "apps/rooms/test/local_archive_shares_test.ts",
        "apps/rooms/test/local_line_custody_test.ts",
        "apps/rooms/test/held_capability_test.ts",
        "apps/rooms/test/direct_files_test.ts",
        "apps/rooms/test/directory_signal_test.ts",
        "apps/rooms/test/directory_connection_lifecycle_test.ts",
        "apps/rooms/test/invitation_admission_test.ts",
        "apps/rooms/test/session/result_test.ts",
        "apps/rooms/test/session/invitation_test.ts",
        "apps/rooms/test/session/irc_command_test.ts",
        "apps/rooms/test/session/registration_command_test.ts",
        "apps/rooms/test/session/viz_test.ts",
        "apps/rooms/test/session/peering_test.ts",
        "apps/rooms/test/standalone_peer_test.ts",
        "apps/rooms/test/attached/feed_test.ts",
        "apps/rooms/test/attached/view_delivery_test.ts",
        "apps/rooms/test/attached/directory_reach_test.ts",
        "apps/rooms/test/attached/session_test.ts",
        "apps/rooms/test/attached/state_test.ts",
        "apps/rooms/test/attached/session_semantics_test.ts",
        "apps/rooms/test/attached/viz_publisher_test.ts",
        "apps/rooms/test/attached/authority_projection_test.ts",
        "apps/rooms/test/attached/identity_projection_test.ts",
        "apps/rooms/test/attached/line_custody_test.ts",
        "apps/rooms/test/attached/line_projection_custody_test.ts",
        "apps/rooms/test/attached/projection_test.ts",
        "apps/rooms/test/attached/direct_projection_test.ts",
        "apps/rooms/test/attached/handed_room_projection_test.ts",
        "apps/rooms/test/attached/presence_projection_test.ts",
        "apps/rooms/test/mixed_dm_projection_test.ts",
        "apps/rooms/test/attached/archive_projection_test.ts",
        "apps/rooms/test/session/wire_messages_test.ts",
        "apps/rooms/test/session/wire_client_custody_test.ts",
        "apps/rooms/test/session/room_realization_test.ts",
        "apps/rooms/test/room/membership_test.ts",
        "apps/rooms/test/toast_test.ts",
        "apps/rooms/test/richtext_test.ts",
        "apps/rooms/test/room/facts_test.ts",
        "apps/rooms/test/room/client_custody_test.ts",
        "apps/rooms/test/room/message_stream_test.ts",
        "apps/rooms/test/commands_test.ts",
        "apps/rooms/test/error_detail_test.ts",
        "apps/rooms/test/log_test.ts",
        "apps/rooms/test/name_voucher_test.ts",
        "apps/rooms/test/dir_address_test.ts",
        "apps/rooms/test/host_rendezvous_test.ts",
        "apps/rooms/test/locator_dial_test.ts",
        "apps/rooms/test/attach_signaling_test.ts",
        "apps/rooms/test/webrtc_route_test.ts",
        "apps/rooms/test/host_reach_test.ts",
        "apps/rooms/test/held_directories_test.ts",
        "apps/rooms/test/directory_adopt_test.ts",
        "apps/rooms/test/bind_host_test.ts",
        "apps/rooms/test/intent_test.ts",
        "apps/rooms/test/rail_filter_test.ts",
        "apps/rooms/test/scroll_memory_test.ts",
    },
    &.{
        "apps/rooms/test/deadline_test.ts",
        "apps/rooms/test/dm_inbox_test.ts",
        "apps/rooms/test/upload_stop_test.ts",
        "apps/rooms/test/ice_test.ts",
        "apps/rooms/test/direct_message_test.ts",
        "apps/rooms/test/direct_offers_test.ts",
        "apps/rooms/test/redeem_routes_test.ts",
    },
    &.{
        "apps/rooms/test/web/serve_test.ts",
    },
    &.{
        "apps/rooms/test/viz/records_test.ts",
        "apps/rooms/test/viz/endpoint_test.ts",
        "apps/rooms/test/viz/cap_test.ts",
        "apps/rooms/test/viz/containment_test.ts",
        "apps/rooms/test/web/viz_proxy_test.ts",
    },
    &.{
        "apps/rooms/test/history_order_test.ts",
        "apps/rooms/test/storage/composer_test.ts",
        "apps/rooms/test/storage/postgres_wire_test.ts",
        "apps/rooms/test/storage/postgres_test.ts",
        "apps/rooms/test/storage/postgres_live_test.ts",
        "apps/rooms/test/browser_bundle_test.ts",
        "apps/rooms/test/deploy_compose_test.ts",
    },
    &.{
        "apps/rooms/test/irc/protocol_test.ts",
        "apps/rooms/test/irc/config_test.ts",
        "apps/rooms/test/irc/front_config_test.ts",
        "apps/rooms/test/irc/front_inbox_test.ts",
        "apps/rooms/test/irc/socket_writer_test.ts",
        "apps/rooms/test/irc/outbound_test.ts",
        "apps/rooms/test/irc/bridge_test.ts",
        "apps/rooms/test/irc/front_test.ts",
    },
};

const archive_files: []const []const u8 = &.{
    "apps/rooms/test/archive/protocol_test.ts",
    "apps/rooms/test/archive/storage_test.ts",
    "apps/rooms/test/archive/shares_ledger_test.ts",
    "apps/rooms/test/archive/target_test.ts",
    "apps/rooms/test/archive/wire_test.ts",
    "apps/rooms/test/archive/peer_test.ts",
};

fn dependOnRuntimeArchives(step: *std.Build.Step, ctx: Context, relay: bool) void {
    step.dependOn(ctx.ocapn_install);
    step.dependOn(ctx.host_install);
    step.dependOn(ctx.driver_install);
    step.dependOn(ctx.tcp_install);
    if (relay) step.dependOn(ctx.relay_install);
}

pub fn register(ctx: Context) *std.Build.Step {
    const lib_dir = common.rootPath(ctx.b, "zig-out/lib");
    const cache = common.addRootedSystemCommand(ctx.b, .build_tool, &.{ "deno", "test", "--no-run" });
    cache.addArgs(command[2..]);
    for (batches) |files| cache.addArgs(files);
    cache.addArgs(archive_files);

    const server_step = ctx.b.step("rooms-server-test", "Run the hermetic Rooms server and UI contract tests (needs deno)");
    const archive = common.addRootedSystemCommand(ctx.b, .{ .deterministic = 30 }, command);
    archive.setEnvironmentVariable("GLOWCAP_LIB_DIR", lib_dir);
    archive.addArgs(archive_files);
    archive.step.dependOn(&cache.step);
    dependOnRuntimeArchives(&archive.step, ctx, false);
    archive.has_side_effects = true;
    const archive_step = ctx.b.step("rooms-archive-test", "Prove the member-owned archive contract, durable store, wire floor, and peer restart (needs deno)");
    archive_step.dependOn(&archive.step);
    server_step.dependOn(archive_step);

    var previous: ?*std.Build.Step = null;
    for (batches) |files| {
        const batch = common.addRootedSystemCommand(ctx.b, .{ .deterministic = 30 }, command);
        batch.setEnvironmentVariable("GLOWCAP_LIB_DIR", lib_dir);
        batch.addArgs(files);
        batch.step.dependOn(&cache.step);
        if (previous) |prior| batch.step.dependOn(prior);
        previous = &batch.step;
        batch.has_side_effects = true;
        // Depend on exactly the archives this suite opens. The global install
        // would pull the cargo-built iroh sidecar into self-contained `check`.
        dependOnRuntimeArchives(&batch.step, ctx, true);
        server_step.dependOn(&batch.step);
    }

    // Each deterministic Deno process owns a bounded subject rather than the
    // whole application suite, while the complete family rides `check`.
    ctx.check_step.dependOn(server_step);
    return server_step;
}
