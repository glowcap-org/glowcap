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
        "apps/rooms/test/server_files_test.ts",
        "apps/rooms/test/server_names_test.ts",
        "apps/rooms/test/server_signaling_test.ts",
        "apps/rooms/test/server_rooms_test.ts",
        "apps/rooms/test/server_room_arguments_test.ts",
    },
    &.{
        "apps/rooms/test/server_peering_test.ts",
        "apps/rooms/test/peering_client_test.ts",
        "apps/rooms/test/server_lines_test.ts",
    },
    &.{
        "apps/rooms/test/server_history_test.ts",
        "apps/rooms/test/server_irc_gateway_test.ts",
        "apps/rooms/test/irc_gateway/custody_test.ts",
        "apps/rooms/test/irc_gateway/arguments_test.ts",
        "apps/rooms/test/server_capabilities_test.ts",
        "apps/rooms/test/irc_reader_test.ts",
    },
    &.{
        "apps/rooms/test/server_links_test.ts",
        "apps/rooms/test/server_topic_state_test.ts",
        "apps/rooms/test/server_operations_state_test.ts",
        "apps/rooms/test/server_private_links_test.ts",
        "apps/rooms/test/session_join_peer_test.ts",
        "apps/rooms/test/session_peer_test.ts",
        "apps/rooms/test/session_peer_unnamed_test.ts",
        "apps/rooms/test/session_grant_peer_test.ts",
        "apps/rooms/test/session_private_room_test.ts",
        "apps/rooms/test/session_dm_peer_test.ts",
        "apps/rooms/test/session_mixed_dm_peer_test.ts",
        "apps/rooms/test/session_archive_test.ts",
        "apps/rooms/test/session_archive_shares_test.ts",
        "apps/rooms/test/session_history_policy_test.ts",
    },
    &.{
        "apps/rooms/test/server_steward_test.ts",
        "apps/rooms/test/server_operator_test.ts",
        "apps/rooms/test/operator_watch_test.ts",
        "apps/rooms/test/operator_references_test.ts",
        "apps/rooms/test/server_listeners_test.ts",
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
        "apps/rooms/test/store_test.ts",
        "apps/rooms/test/workspace_state_test.ts",
        "apps/rooms/test/ops_bundle_test.ts",
        "apps/rooms/test/ops_invalidation_test.ts",
        "apps/rooms/test/operator_parser_test.ts",
        "apps/rooms/test/session_state_test.ts",
        "apps/rooms/test/session_conversation_command_test.ts",
        "apps/rooms/test/session_adoption_test.ts",
        "apps/rooms/test/session_transition_test.ts",
        "apps/rooms/test/session_grants_test.ts",
        "apps/rooms/test/session_facet_pair_test.ts",
        "apps/rooms/test/session_topology_test.ts",
        "apps/rooms/test/session_realization_test.ts",
        "apps/rooms/test/session_runtime_cleanup_test.ts",
        "apps/rooms/test/session_standing_test.ts",
        "apps/rooms/test/session_file_custody_test.ts",
        "apps/rooms/test/session_attachment_admission_test.ts",
        "apps/rooms/test/session_directory_view_test.ts",
        "apps/rooms/test/local_peering_state_test.ts",
        "apps/rooms/test/local_archive_shares_test.ts",
        "apps/rooms/test/local_line_custody_test.ts",
        "apps/rooms/test/held_capability_test.ts",
        "apps/rooms/test/direct_files_test.ts",
        "apps/rooms/test/directory_signal_test.ts",
        "apps/rooms/test/directory_connection_lifecycle_test.ts",
        "apps/rooms/test/invitation_admission_test.ts",
        "apps/rooms/test/session_result_test.ts",
        "apps/rooms/test/session_invitation_test.ts",
        "apps/rooms/test/session_irc_command_test.ts",
        "apps/rooms/test/session_viz_test.ts",
        "apps/rooms/test/session_peering_test.ts",
        "apps/rooms/test/standalone_peer_test.ts",
        "apps/rooms/test/attached_feed_test.ts",
        "apps/rooms/test/attached_view_delivery_test.ts",
        "apps/rooms/test/attached_session_test.ts",
        "apps/rooms/test/attached_state_test.ts",
        "apps/rooms/test/attached_session_semantics_test.ts",
        "apps/rooms/test/attached_authority_projection_test.ts",
        "apps/rooms/test/attached_identity_projection_test.ts",
        "apps/rooms/test/attached_line_custody_test.ts",
        "apps/rooms/test/attached_line_projection_custody_test.ts",
        "apps/rooms/test/attached_projection_test.ts",
        "apps/rooms/test/attached_presence_projection_test.ts",
        "apps/rooms/test/mixed_dm_projection_test.ts",
        "apps/rooms/test/attached_archive_projection_test.ts",
        "apps/rooms/test/rooms_session_messages_test.ts",
        "apps/rooms/test/rooms_session_client_custody_test.ts",
        "apps/rooms/test/room_realization_test.ts",
        "apps/rooms/test/toast_test.ts",
        "apps/rooms/test/richtext_test.ts",
        "apps/rooms/test/room_facts_test.ts",
        "apps/rooms/test/room_client_custody_test.ts",
        "apps/rooms/test/room_message_stream_test.ts",
        "apps/rooms/test/commands_test.ts",
        "apps/rooms/test/error_detail_test.ts",
        "apps/rooms/test/log_test.ts",
        "apps/rooms/test/name_voucher_test.ts",
        "apps/rooms/test/dir_address_test.ts",
        "apps/rooms/test/intent_test.ts",
        "apps/rooms/test/rail_filter_test.ts",
    },
    &.{
        "apps/rooms/test/deadline_test.ts",
        "apps/rooms/test/dm_inbox_test.ts",
        "apps/rooms/test/upload_stop_test.ts",
        "apps/rooms/test/ice_test.ts",
        "apps/rooms/test/direct_message_test.ts",
    },
    &.{
        "apps/rooms/test/web_test.ts",
    },
    &.{
        "apps/rooms/test/viz_records_test.ts",
        "apps/rooms/test/viz_test.ts",
        "apps/rooms/test/viz_cap_test.ts",
        "apps/rooms/test/viz_containment_test.ts",
        "apps/rooms/test/web_viz_proxy_test.ts",
    },
    &.{
        "apps/rooms/test/history_order_test.ts",
        "apps/rooms/test/storage_test.ts",
        "apps/rooms/test/storage_postgres_wire_test.ts",
        "apps/rooms/test/storage_postgres_test.ts",
        "apps/rooms/test/storage_postgres_live_test.ts",
        "apps/rooms/test/deploy_compose_test.ts",
    },
    &.{
        "apps/rooms/test/irc_protocol_test.ts",
        "apps/rooms/test/irc_config_test.ts",
        "apps/rooms/test/irc_front_config_test.ts",
        "apps/rooms/test/irc_front_inbox_test.ts",
        "apps/rooms/test/irc_socket_writer_test.ts",
        "apps/rooms/test/irc_outbound_test.ts",
        "apps/rooms/test/irc_bridge_test.ts",
        "apps/rooms/test/irc_front_test.ts",
    },
};

const archive_files: []const []const u8 = &.{
    "apps/rooms/test/archive_test.ts",
    "apps/rooms/test/archive_storage_test.ts",
    "apps/rooms/test/archive_target_test.ts",
    "apps/rooms/test/archive_wire_test.ts",
    "apps/rooms/test/archive_peer_test.ts",
};

fn dependOnRuntimeArchives(step: *std.Build.Step, ctx: Context, relay: bool) void {
    step.dependOn(ctx.ocapn_install);
    step.dependOn(ctx.host_install);
    step.dependOn(ctx.driver_install);
    step.dependOn(ctx.tcp_install);
    if (relay) step.dependOn(ctx.relay_install);
}

pub fn register(ctx: Context) *std.Build.Step {
    const cache = common.addRootedSystemCommand(ctx.b, .build_tool, &.{ "deno", "test", "--no-run" });
    cache.addArgs(command[2..]);
    for (batches) |files| cache.addArgs(files);
    cache.addArgs(archive_files);

    const server_step = ctx.b.step("rooms-server-test", "Run the hermetic Rooms server and UI contract tests (needs deno)");
    const archive = common.addRootedSystemCommand(ctx.b, .{ .deterministic = 30 }, command);
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
