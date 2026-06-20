const std = @import("std");

pub const MessageArm = struct {
    name: []const u8,
};

pub const message_arms = [_]MessageArm{
    .{ .name = "Deliver" },
    .{ .name = "Resolve" },
    .{ .name = "GcExport" },
    .{ .name = "GcAnswer" },
    .{ .name = "Handoff" },
    .{ .name = "StartSession" },
    .{ .name = "Abort" },
    .{ .name = "Listen" },
    .{ .name = "Get" },
    .{ .name = "Index" },
    .{ .name = "Untag" },
};

pub const OracleFixture = struct {
    name: []const u8,
    data: []const u8,

    pub fn bytes(self: OracleFixture) []const u8 {
        return self.data;
    }
};

const fixture_root = "corpus/";

pub const corpus = [_]OracleFixture{
    fixture("op_abort.bin"),
    fixture("op_abort_connection_lost.bin"),
    fixture("op_abort_crossed_hellos.bin"),
    fixture("op_abort_graceful_shutdown.bin"),
    fixture("op_abort_resource_exhausted.bin"),
    fixture("op_abort_typed.bin"),
    fixture("op_deliver.bin"),
    fixture("op_deliver_arg_big_integer.bin"),
    fixture("op_deliver_arg_float64.bin"),
    fixture("op_deliver_arg_keyword.bin"),
    fixture("op_deliver_arg_set.bin"),
    fixture("op_deliver_arg_tagged.bin"),
    fixture("op_deliver_arg_void.bin"),
    fixture("op_deliver_v1_0_with_resolve_me_desc.bin"),
    fixture("op_deliver_withdraw_gift.bin"),
    fixture("op_gc_answers.bin"),
    fixture("op_gc_exports.bin"),
    fixture("op_get.bin"),
    fixture("op_handoff_give.bin"),
    fixture("op_handoff_receive.bin"),
    fixture("op_index.bin"),
    fixture("op_listen_export_target.bin"),
    fixture("op_listen_promise_target.bin"),
    fixture("op_listen_v1_0_wants_partial_false.bin"),
    fixture("op_listen_v1_0_wants_partial_true.bin"),
    fixture("op_resolve_break.bin"),
    fixture("op_resolve_fulfill_far.bin"),
    fixture("op_resolve_fulfill_near.bin"),
    fixture("op_resolve_fulfill_promise.bin"),
    fixture("op_start_session_v1_0.bin"),
    fixture("op_untag.bin"),
    fixture("prim_dict_str_to_int.bin"),
    fixture("prim_integer_big_neg.bin"),
    fixture("prim_integer_neg_7.bin"),
    fixture("prim_integer_pos_42.bin"),
    fixture("prim_list_of_ints.bin"),
    fixture("prim_set_of_ints.bin"),
    fixture("prim_string_hello.bin"),
};

pub fn fixtureByName(name: []const u8) ?OracleFixture {
    for (corpus) |entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            return entry;
        }
    }
    return null;
}

fn fixture(comptime name: []const u8) OracleFixture {
    return .{
        .name = name,
        .data = @embedFile(fixture_root ++ name),
    };
}
