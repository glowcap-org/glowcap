//! Rooms' self-contained Deno test inventory and build steps. The application
//! build composes this subject; this module owns how the suite is cached,
//! divided into bounded processes, and attached to `runtime-check`.

const std = @import("std");
const common = @import("../common.zig");
const execution = @import("../execution.zig");

pub const Context = struct {
    b: *std.Build,
    runtime_gate: *execution.RuntimeGate,
    ocapn_install: *std.Build.Step,
    host_install: *std.Build.Step,
    driver_install: *std.Build.Step,
    tcp_install: *std.Build.Step,
    relay_install: *std.Build.Step,
    archive_install: *std.Build.Step,
    wasm_install: *std.Build.Step,
};

const command: []const []const u8 = &.{
    "deno",
    "test",
    "--preload=apps/rooms/test/support/browser_application.ts",
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
        "apps/rooms/test/peering_client_test.ts",
    },
    &.{
        "apps/rooms/test/session/join_peer_test.ts",
        "apps/rooms/test/session/reconnect_peer_test.ts",
        "apps/rooms/test/session/peer_unnamed_test.ts",
        "apps/rooms/test/session/grant_peer_test.ts",
        "apps/rooms/test/session/private_room_test.ts",
        "apps/rooms/test/session/dm_peer_test.ts",
    },
    &.{
        "apps/rooms/test/bridge/prefix_test.ts",
        "apps/rooms/test/bridge/form_test.ts",
        "apps/rooms/test/routes_test.ts",
    },
    &.{
        "apps/rooms/test/text_test.ts",
        "apps/rooms/test/member_identity_test.ts",
        "apps/rooms/test/prefs_test.ts",
        "apps/rooms/test/complete_test.ts",
        "apps/rooms/test/media_test.ts",
        "apps/rooms/test/store/attachments_test.ts",
        "apps/rooms/test/store/link_preview_test.ts",
        "apps/rooms/test/store/directory_test.ts",
        "apps/rooms/test/directory_conversation_test.ts",
        "apps/rooms/test/composer_commit_test.ts",
        "apps/rooms/test/store/typing_test.ts",
        "apps/rooms/test/store/roster_test.ts",
        "apps/rooms/test/store/app_shell_test.ts",
        "apps/rooms/test/page_projection_test.ts",
        "apps/rooms/test/session/setup_projection_test.ts",
        "apps/rooms/test/session/snapshot_reader_test.ts",
        "apps/rooms/test/store/room_access_test.ts",
        "apps/rooms/test/store/irc_test.ts",
        "apps/rooms/test/store/line_identity_test.ts",
        "apps/rooms/test/store/line_change_recording_test.ts",
        "apps/rooms/test/store/archive_sections_test.ts",
        "apps/rooms/test/store/room_identity_test.ts",
        "apps/rooms/test/attached/session_drafts_test.ts",
        "apps/rooms/test/attached/shared_state_identity_test.ts",
        "apps/rooms/test/workspace_state_test.ts",
        "apps/rooms/test/checkpoint_redaction_test.ts",
        "apps/rooms/test/workspace_fanout_test.ts",
        "apps/rooms/test/ops_bundle_test.ts",
        "apps/rooms/test/operator/refresh_test.ts",
        "apps/rooms/test/operator/parser_test.ts",
        "apps/rooms/test/session/hosted_hold_test.ts",
        "apps/rooms/test/directory_signal_test.ts",
        "apps/rooms/test/standalone_peer_test.ts",
        "apps/rooms/test/attached/join_admission_test.ts",
        "apps/rooms/test/attached/state_test.ts",
        "apps/rooms/test/attached/session_semantics_test.ts",
        "apps/rooms/test/attached/authority_projection_test.ts",
        "apps/rooms/test/attached/identity_projection_test.ts",
        "apps/rooms/test/attached/line_custody_test.ts",
        "apps/rooms/test/attached/line_projection_custody_test.ts",
        "apps/rooms/test/attached/projection_test.ts",
        "apps/rooms/test/attached/projection_media_test.ts",
        "apps/rooms/test/attached/draft_projection_test.ts",
        "apps/rooms/test/attached/archive_target_projection_test.ts",
        "apps/rooms/test/attached/direct_projection_test.ts",
        "apps/rooms/test/attached/handed_room_projection_test.ts",
        "apps/rooms/test/attached/presence_projection_test.ts",
        "apps/rooms/test/mixed_dm_projection_test.ts",
        "apps/rooms/test/attached/archive_projection_test.ts",
        "apps/rooms/test/attached/archive_share_projection_test.ts",
        "apps/rooms/test/attached/history_invalidation_test.ts",
        "apps/rooms/test/session/wire_client_custody_test.ts",
        "apps/rooms/test/toast_test.ts",
        "apps/rooms/test/richtext_test.ts",
        "apps/rooms/test/writing_test.ts",
        "apps/rooms/test/room/facts_test.ts",
        "apps/rooms/test/room/client_custody_test.ts",
        "apps/rooms/test/room/message_stream_test.ts",
        "apps/rooms/test/commands_test.ts",
        "apps/rooms/test/error_detail_test.ts",
        "apps/rooms/test/log_test.ts",
        "apps/rooms/test/name_voucher_test.ts",
        "apps/rooms/test/locator_dial_test.ts",
        "apps/rooms/test/bind_host_test.ts",
        "apps/rooms/test/intent_test.ts",
        "apps/rooms/test/rail_filter_test.ts",
        "apps/rooms/test/scroll_memory_test.ts",
    },
    &.{
        "apps/rooms/test/deadline_test.ts",
        "apps/rooms/test/protocol_gen_test.ts",
        "apps/rooms/test/dm_inbox_test.ts",
        "apps/rooms/test/upload_stop_test.ts",
        "apps/rooms/test/ice_test.ts",
        "apps/rooms/test/listener_wire_test.ts",
        "apps/rooms/test/redeem_routes_test.ts",
    },
    &.{
        "apps/rooms/test/web/serve_test.ts",
    },
    &.{
        "apps/rooms/test/web/serve_supervision_test.ts",
    },
    &.{
        "apps/rooms/test/web/trace_proxy_test.ts",
    },
    &.{
        "apps/rooms/test/browser_bundle_test.ts",
    },
    &.{
        "apps/rooms/test/irc/protocol_test.ts",
        "apps/rooms/test/irc/bridge_process_test.ts",
        "apps/rooms/test/irc/front_test.ts",
    },
};

const archive_files: []const []const u8 = &.{
    "apps/rooms/test/archive/merge_test.ts",
    "apps/rooms/test/archive/protocol_test.ts",
    "apps/rooms/test/archive/record_document_test.ts",
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
    const b = ctx.b;
    const lib_dir = common.rootPath(ctx.b, "zig-out/lib");
    const cache = common.addRootedSystemCommand(ctx.b, .build_tool, &.{ "deno", "test", "--no-run" });
    cache.addArgs(command[2..]);
    for (batches) |files| cache.addArgs(files);
    cache.addArgs(archive_files);
    // UI imports include the generated production Rust application surface.
    cache.step.dependOn(ctx.wasm_install);

    const server_step = b.step("rooms-server-test", "Run the hermetic Rooms server and UI contract tests (needs cargo + deno)");
    const web_tooling = common.addRootedSystemCommand(ctx.b, .{ .deterministic = 30 }, &.{
        "deno", "task", "--config", "apps/rooms/web/deno.json", "check",
    });
    web_tooling.step.dependOn(ctx.wasm_install);
    web_tooling.has_side_effects = true;
    server_step.dependOn(&web_tooling.step);
    const archive = common.addRootedSystemCommand(ctx.b, .{ .deterministic = 30 }, &.{"env"});
    archive.addFileArg2(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-archive" } }, .{ .prefix = "GLOWCAP_ROOMS_ARCHIVE_TEST_BIN=", .make_absolute = true });
    archive.addArgs(command);
    archive.step.dependOn(ctx.archive_install);
    archive.setEnvironmentVariable("GLOWCAP_LIB_DIR", lib_dir);
    archive.addArgs(archive_files);
    archive.step.dependOn(&cache.step);
    dependOnRuntimeArchives(&archive.step, ctx, false);
    archive.has_side_effects = true;
    const archive_step = ctx.b.step("rooms-archive-test", "Prove the member-owned archive contract, durable store, wire floor, and peer restart (needs cargo + deno)");
    archive_step.dependOn(&archive.step);
    server_step.dependOn(archive_step);

    var previous: ?*std.Build.Step = &web_tooling.step;
    for (batches) |files| {
        const batch = common.addRootedSystemCommand(ctx.b, .{ .deterministic = 30 }, &.{"env"});
        batch.addFileArg2(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-server" } }, .{ .prefix = "GLOWCAP_ROOMS_SERVER_BIN=", .make_absolute = true });
        batch.addFileArg2(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-irc-bridge" } }, .{ .prefix = "GLOWCAP_ROOMS_IRC_BRIDGE_BIN=", .make_absolute = true });
        batch.addFileArg2(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-irc-front" } }, .{ .prefix = "GLOWCAP_ROOMS_IRC_FRONT_BIN=", .make_absolute = true });
        batch.step.dependOn(ctx.archive_install);
        batch.addFileArg2(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-web" } }, .{ .prefix = "GLOWCAP_ROOMS_WEB_BIN=", .make_absolute = true });
        for (files) |file| {
            if (std.mem.eql(u8, file, "apps/rooms/test/browser_bundle_test.ts")) batch.step.dependOn(ctx.wasm_install);
        }
        batch.addArgs(command);
        batch.setEnvironmentVariable("GLOWCAP_LIB_DIR", lib_dir);
        batch.addArgs(files);
        batch.step.dependOn(&cache.step);
        if (previous) |prior| batch.step.dependOn(prior);
        previous = &batch.step;
        batch.has_side_effects = true;
        // Depend on exactly the archives this suite opens. The global install
        // is not needed by the TypeScript-only batches.
        dependOnRuntimeArchives(&batch.step, ctx, true);
        server_step.dependOn(&batch.step);
    }

    // Each deterministic Deno process owns a bounded subject rather than the
    // whole application suite. The runtime gate gives side-effecting commands
    // exclusive execution without making focused checks depend on one another.
    ctx.runtime_gate.add(server_step);
    return server_step;
}
