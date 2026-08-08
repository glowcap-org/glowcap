//! The seed corpus every hostile-bytes fuzz target starts from.
//!
//! One list, in one place. A target seeded from a couple of shapes spends its
//! budget rediscovering what a frame looks like instead of exploring what
//! happens past one, and the codec targets started from the whole checked-in
//! corpus while the stream-level ones started from two frames. The coverage
//! each reached showed the difference plainly, so they share this now.
//!
//! `zig build meta-check` holds the list against `test/oracle/corpus/`, so a new
//! corpus file cannot land without becoming a seed. The other direction needs no
//! check: a seed naming a file that is gone fails to compile, because the seeds
//! are embedded at build time.

const std = @import("std");

/// Every CapTP message in the checked-in Syrup corpus, wired as a seed.
///
/// The whole message subset, not a hand-picked spread: a message entry that is
/// not a seed is a shape the fuzzer never starts from. `zig build meta-check`
/// holds all seed lists against the directory, so a new corpus file cannot land
/// without becoming a seed.
pub const message_seeds = [_][]const u8{
    seed(@embedFile("../oracle/corpus/op_abort.bin")),
    seed(@embedFile("../oracle/corpus/op_abort_connection_lost.bin")),
    seed(@embedFile("../oracle/corpus/op_abort_crossed_hellos.bin")),
    seed(@embedFile("../oracle/corpus/op_abort_graceful_shutdown.bin")),
    seed(@embedFile("../oracle/corpus/op_abort_resource_exhausted.bin")),
    seed(@embedFile("../oracle/corpus/op_abort_typed.bin")),
    seed(@embedFile("../oracle/corpus/op_deliver.bin")),
    seed(@embedFile("../oracle/corpus/op_deliver_arg_big_integer.bin")),
    seed(@embedFile("../oracle/corpus/op_deliver_arg_float64.bin")),
    seed(@embedFile("../oracle/corpus/op_deliver_arg_keyword.bin")),
    seed(@embedFile("../oracle/corpus/op_deliver_arg_set.bin")),
    seed(@embedFile("../oracle/corpus/op_deliver_arg_tagged.bin")),
    seed(@embedFile("../oracle/corpus/op_deliver_arg_void.bin")),
    seed(@embedFile("../oracle/corpus/op_deliver_listen_break_notification.bin")),
    seed(@embedFile("../oracle/corpus/op_deliver_v1_0_with_resolve_me_desc.bin")),
    seed(@embedFile("../oracle/corpus/op_deliver_withdraw_gift.bin")),
    seed(@embedFile("../oracle/corpus/op_gc_answers.bin")),
    seed(@embedFile("../oracle/corpus/op_gc_exports.bin")),
    seed(@embedFile("../oracle/corpus/op_get.bin")),
    seed(@embedFile("../oracle/corpus/op_index.bin")),
    seed(@embedFile("../oracle/corpus/op_listen_export_target.bin")),
    seed(@embedFile("../oracle/corpus/op_listen_promise_target.bin")),
    seed(@embedFile("../oracle/corpus/op_listen_v1_0_wants_partial_false.bin")),
    seed(@embedFile("../oracle/corpus/op_listen_v1_0_wants_partial_true.bin")),
    seed(@embedFile("../oracle/corpus/op_resolve_break.bin")),
    seed(@embedFile("../oracle/corpus/op_resolve_fulfill_far.bin")),
    seed(@embedFile("../oracle/corpus/op_resolve_fulfill_import_promise.bin")),
    seed(@embedFile("../oracle/corpus/op_resolve_fulfill_near.bin")),
    seed(@embedFile("../oracle/corpus/op_resolve_fulfill_promise.bin")),
    seed(@embedFile("../oracle/corpus/op_start_session_v1_0.bin")),
    seed(@embedFile("../oracle/corpus/op_untag.bin")),
};

/// Passable CapTP descriptors that are valid nested values, not messages.
pub const descriptor_seeds = [_][]const u8{
    seed(@embedFile("../oracle/corpus/desc_handoff_give_signed.bin")),
    seed(@embedFile("../oracle/corpus/desc_handoff_receive_signed.bin")),
};

/// The corpus also holds bare Syrup values that are not CapTP messages: a
/// dictionary, integers at both ends of the small/big boundary, a list, a set, a
/// string. They seed the fuzzer with well-formed
/// Syrup that the message decoder must still refuse, which is a different and
/// useful starting shape, so they are seeds but not subject to
/// `ratifySyrupSeeds`.
pub const primitive_seeds = [_][]const u8{
    seed(@embedFile("../oracle/corpus/prim_dict_str_to_int.bin")),
    seed(@embedFile("../oracle/corpus/prim_integer_big_neg.bin")),
    seed(@embedFile("../oracle/corpus/prim_integer_neg_7.bin")),
    seed(@embedFile("../oracle/corpus/prim_integer_pos_42.bin")),
    seed(@embedFile("../oracle/corpus/prim_list_of_ints.bin")),
    seed(@embedFile("../oracle/corpus/prim_set_of_ints.bin")),
    seed(@embedFile("../oracle/corpus/prim_string_hello.bin")),
};

/// Every shape in the checked-in corpus, for a target that wants the whole set.
///
/// Deliberately not including anything the fuzzer found. A crash belongs to the
/// target that crashed on it: seeding it into the other eight is noise, and the
/// build check that holds a saved input against its replay looks for it in that
/// target's own file. Each target keeps its own `regression_seeds` and appends
/// it to this.
pub const all = message_seeds ++ descriptor_seeds ++ primitive_seeds;

/// `Smith.slice` replays a corpus entry by reading a little-endian u32 length
/// ahead of the slice bytes, so a seed is its frame prefixed with the frame's
/// length.
pub fn seed(comptime frame: []const u8) []const u8 {
    const entry: [4 + frame.len]u8 = comptime blk: {
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @as(u32, @intCast(frame.len)), .little);
        break :blk len_buf ++ frame[0..frame.len].*;
    };
    return &entry;
}

/// Runtime sibling of `seed`, for a seed an encoder produces inside a test.
pub fn runtimeSeed(buf: []u8, frame_bytes: []const u8) []const u8 {
    std.mem.writeInt(u32, buf[0..4], @intCast(frame_bytes.len), .little);
    @memcpy(buf[4..][0..frame_bytes.len], frame_bytes);
    return buf[0 .. 4 + frame_bytes.len];
}

/// One generator draw, in the shape it reads one: a little-endian u64.
fn drawBytes(v: u64) [8]u8 {
    var out: [8]u8 = undefined;
    std.mem.writeInt(u64, &out, v, .little);
    return out;
}

/// A seed for a target whose input is a program rather than a frame.
///
/// Each row is one step, holding that step's draws in the order the loop makes
/// them. A not-the-end byte goes in front of each row.
///
/// No length prefix. That framing belongs to a target whose first draw is a
/// slice, and putting it in front of a program means the first byte of the
/// length is read as the end-of-program check instead — which answers "stop"
/// for any seed whose length is not a multiple of 256.
///
/// Hand-writing these is how two targets ended up running programs their
/// comments did not describe: a step's arity changed, every later draw shifted
/// by eight bytes, and the out-of-range fallback quietly turned all of them into
/// the same operation. Spelling the draws out is what makes the arity impossible
/// to miscount.
pub fn program(comptime steps: []const []const u64) []const u8 {
    const bytes = comptime blk: {
        var out: []const u8 = &.{};
        for (steps) |step| {
            out = out ++ [_]u8{0}; // not the end
            for (step) |draw| out = out ++ drawBytes(draw);
        }
        break :blk out;
    };
    return bytes;
}
