//! Malformed input against the Cap'n Proto codec: invalid
//! UTF-8, duplicate keys and elements, descending key order, byte-shaped,
//! truncated, multi-segment, and over-long frames, single-byte corruption
//! staying total, nesting-depth bounds, aliasing traversal budgets, and
//! duplicated locator hints, every arm a typed refusal, never a panic.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const capnp = glowcap.ocapn.codec.capnp;
const wire = capnp.wire;

test "a promise reference with derived data is refused instead of flattened" {
    const allocator = std.testing.allocator;
    const marker: u64 = 0xfedc_ba98_7654_3210;
    var frame = try capnp.encodeMessage(allocator, .{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(marker) } },
        .args = &.{},
    } });
    defer frame.deinit();

    const bytes = try allocator.dupe(u8, frame.bytes());
    defer allocator.free(bytes);
    const words = bytes.len / @sizeOf(u64);
    var reference_word: ?usize = null;
    for (1..words - 3) |i| {
        const data0 = std.mem.readInt(u64, bytes[i * 8 ..][0..8], .little);
        const data1 = std.mem.readInt(u64, bytes[(i + 1) * 8 ..][0..8], .little);
        if (data0 == 2 and data1 == marker) {
            reference_word = i;
            break;
        }
    }
    const start = reference_word orelse return error.TestUnexpectedResult;
    // Reference pointer slot 0 is the word after its two data words. Any
    // non-null value is unsupported for the promise arm; a zero-length list
    // pointer is sufficient to prove the decoder checks presence, not payload.
    std.mem.writeInt(u64, bytes[(start + 2) * 8 ..][0..8], 1, .little);
    const malformed = glowcap.foundation.FrameView{ .bytes = bytes, .shape = .word };
    try std.testing.expectError(error.UnsupportedReference, capnp.decodeBody(malformed));
    try std.testing.expectError(error.UnsupportedReference, capnp.decodeOwned(allocator, malformed));
}

test "Cap'n Proto refuses invalid UTF-8 String and Symbol values where it writes them" {
    const invalid = &.{@as(u8, 0xff)};
    const invalid_arguments = [_]model.Argument{
        .{ .string = invalid },
        .{ .symbol = invalid },
    };

    // The text is validated as it is written, one pass over it, and the
    // refusal commits nothing: the builder is the only effect and the testing
    // allocator would report it if it leaked.
    for (invalid_arguments) |argument| {
        const args = [_]model.Argument{argument};
        try std.testing.expectError(capnp.Error.UnsupportedArgument, capnp.encodeMessage(std.testing.allocator, .{
            .deliver = .{
                .target = .{ .far = model.FarRef.object(7) },
                .args = &args,
            },
        }));
    }

    const valid_args = [_]model.Argument{
        .{ .string = "\xc3\xa9" },
        .{ .symbol = "\xf0\x9f\x98\x80" },
        .{ .bytes = invalid },
    };
    var frame = try capnp.encodeMessage(std.testing.allocator, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &valid_args,
    } });
    defer frame.deinit();

    const valid_body = try capnp.decodeBody(frame.view());
    try std.testing.expectEqualSlices(u8, "\xc3\xa9", (try valid_body.deliver.args.at(0)).string);
    try std.testing.expectEqualSlices(u8, "\xf0\x9f\x98\x80", (try valid_body.deliver.args.at(1)).symbol);
    try std.testing.expectEqualSlices(u8, invalid, (try valid_body.deliver.args.at(2)).bytes);

    for ([_][]const u8{ "\xc3\xa9", "\xf0\x9f\x98\x80" }) |needle| {
        const bytes = try std.testing.allocator.dupe(u8, frame.bytes());
        defer std.testing.allocator.free(bytes);
        const offset = std.mem.indexOf(u8, bytes, needle) orelse return error.TestUnexpectedResult;
        bytes[offset] = 0xff;
        const view = glowcap.foundation.FrameView{ .bytes = bytes, .shape = .word };
        try std.testing.expectError(capnp.Error.MalformedFrame, capnp.decodeBody(view));
        try std.testing.expectError(capnp.Error.MalformedFrame, capnp.decodeOwned(std.testing.allocator, view));
    }
}

test "a Struct with duplicate keys is refused on the live view path" {
    const allocator = std.testing.allocator;

    // Encode a well-formed two-key struct, then patch the second key's bytes to
    // repeat the first, the duplicate-key frame an untrusted peer would send,
    // word-shaped like every Cap'n Proto frame. Each key must be non-Equal to
    // every other within a Struct (ADR-0046 / Model.md § Struct), so the codec
    // refuses the frame at the parse boundary, on the same projection the
    // engine dispatches (`decodeBody`), not only in an owned re-walk.
    const entries = [_]model.StructEntry{
        .{ .key = "k1", .value = .{ .integer = 1 } },
        .{ .key = "k2", .value = .{ .integer = 2 } },
    };
    const args = [_]model.Argument{.{ .@"struct" = entries[0..] }};
    var frame = try capnp.encodeMessage(allocator, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &args,
        .answer = .from(3),
        .resolve_me_desc = null,
    } });
    defer frame.deinit();

    const buf = try allocator.dupe(u8, frame.bytes());
    defer allocator.free(buf);
    const second_key = std.mem.indexOf(u8, buf, "k2") orelse return error.TestUnexpectedResult;
    @memcpy(buf[second_key .. second_key + 2], "k1");
    const view = glowcap.foundation.FrameView{ .bytes = buf, .shape = .word };

    // `decodeBody` is one metered walk over every argument (the remote-DoS
    // bound), and that walk reads each struct through the same
    // `neutralStructBacking` the lazy path uses, so the ascending-key rule is
    // enforced at the parse boundary. A duplicate key is thus refused the
    // instant the frame decodes, before any borrowed view escapes, not only
    // on a later owned re-walk.
    try std.testing.expectError(error.MalformedFrame, capnp.decodeBody(view));
    try std.testing.expectError(error.MalformedFrame, capnp.decodeOwned(allocator, view));
}

test "the Cap'n Proto encoder refuses a Set carrying a duplicate element" {
    // Symmetric with the Syrup codec and the duplicate-key struct: a set's
    // elements are unique, so a model with two equal elements is refused at
    // encode with UnsupportedArgument rather than emitted.
    const allocator = std.testing.allocator;
    const dup = [_]model.Argument{ .{ .integer = 1 }, .{ .integer = 1 } };
    const args = [_]model.Argument{.{ .set = dup[0..] }};
    try std.testing.expectError(capnp.Error.UnsupportedArgument, capnp.encodeMessage(allocator, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &args,
        .answer = .from(3),
        .resolve_me_desc = null,
    } }));
}

test "the Cap'n Proto encoder refuses a Struct carrying a duplicate key" {
    // Symmetric refusal (ADR-0003): the decoder rejects a duplicate-key struct,
    // so the encoder must not emit one. A model built with two "a" entries is
    // refused at encode with UnsupportedArgument rather than shipped as a frame
    // the partner would reject remotely.
    const allocator = std.testing.allocator;
    const entries = [_]model.StructEntry{
        .{ .key = "a", .value = .{ .integer = 1 } },
        .{ .key = "a", .value = .{ .integer = 2 } },
    };
    const args = [_]model.Argument{.{ .@"struct" = entries[0..] }};
    try std.testing.expectError(capnp.Error.UnsupportedArgument, capnp.encodeMessage(allocator, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &args,
        .answer = .from(3),
        .resolve_me_desc = null,
    } }));
}

test "a Struct with descending keys is refused: decode requires the encoder's ascending order" {
    const allocator = std.testing.allocator;

    // glowcap's capnp encoder emits struct keys sorted ascending by raw bytes
    // (`canonicalStructOrder`), so decode requires strictly ascending keys,
    // one comparison per key, not an all-pairs scan a peer could drive to
    // n². A distinct-but-descending pair is non-canonical and refused, exactly
    // as a duplicate is (equal is also not strictly ascending). Here the
    // encoder produces [k1, k2]; patching k1 -> k3 leaves [k3, k2], descending.
    const entries = [_]model.StructEntry{
        .{ .key = "k1", .value = .{ .integer = 1 } },
        .{ .key = "k2", .value = .{ .integer = 2 } },
    };
    const args = [_]model.Argument{.{ .@"struct" = entries[0..] }};
    var frame = try capnp.encodeMessage(allocator, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &args,
        .answer = .from(3),
        .resolve_me_desc = null,
    } });
    defer frame.deinit();

    const buf = try allocator.dupe(u8, frame.bytes());
    defer allocator.free(buf);
    const first_key = std.mem.indexOf(u8, buf, "k1") orelse return error.TestUnexpectedResult;
    @memcpy(buf[first_key .. first_key + 2], "k3");
    const view = glowcap.foundation.FrameView{ .bytes = buf, .shape = .word };

    // As with the duplicate-key case, the metered walk in `decodeBody`
    // enforces the strictly-ascending-key rule at the parse boundary, so a
    // descending pair is refused the moment the frame decodes.
    try std.testing.expectError(error.MalformedFrame, capnp.decodeBody(view));
    try std.testing.expectError(error.MalformedFrame, capnp.decodeOwned(allocator, view));
}

test "decode rejects a byte-shaped frame" {
    const allocator = std.testing.allocator;
    const view = glowcap.foundation.FrameView{ .bytes = "not capnp", .shape = .byte };
    try std.testing.expectError(error.InvalidFrameShape, capnp.decodeOwned(allocator, view));
}

test "decode rejects a truncated frame" {
    const allocator = std.testing.allocator;
    // Header claims a 4-word segment, but no segment words follow.
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @as(u64, 4) << 32, .little);
    const view = glowcap.foundation.FrameView{ .bytes = &bytes, .shape = .word };
    try std.testing.expectError(error.Truncated, capnp.decodeOwned(allocator, view));
}

test "decode rejects a multi-segment frame" {
    const allocator = std.testing.allocator;
    // segment-count − 1 = 1 (i.e. two segments) in the low u32.
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, 1, .little);
    const view = glowcap.foundation.FrameView{ .bytes = &bytes, .shape = .word };
    try std.testing.expectError(error.UnsupportedSegmentCount, capnp.decodeOwned(allocator, view));
}

// Every byte of an inbound frame is untrusted. Union discriminants,
// pointer words, and list tags decode through bounded helpers, so a corrupted
// frame must resolve to a typed `Error` (or a well-formed message) and never
// trip illegal behavior (an out-of-range `@enumFromInt`, an unchecked slice).
// This walks representative frames, every union arm, a promise reference, a handoff
// and flipping each byte to boundary values and asserting both decode paths stay
// total. A regression here (e.g. a raw `@enumFromInt` on a wire discriminant)
// surfaces as a panic that aborts the test binary.
test "corrupting any byte of a frame stays total: typed error or message, never a panic" {
    const allocator = std.testing.allocator;

    const call_args = [_]model.Argument{.{ .string = "ping" }};
    const give = model.HandoffGive{
        .recipient_key = &(@as([32]u8, @splat(0x01))),
        .exporter = .{ .transport = "tcp", .designator = "host" },
        .gifter_exporter_session = &(@as([32]u8, @splat(0x02))),
        .gifter_side = &(@as([32]u8, @splat(0x03))),
        .gift_id = &(@as([32]u8, @splat(0x04))),
        .signature = &(@as([64]u8, @splat(0x05))),
    };
    var handoff_arg = model.Handoff{ .give = give };
    // Cover every union arm and argument kind so each errdefer in the owned
    // decode path is actually unwound by some corruption: deliver (far + every
    // arg kind, including a nested reference/error/handoff/tagged), deliver
    // (promise target), deliver (sturdy target), resolve
    // (fulfill + break), gc-export (two parallel lists), abort, the get/index/
    // listen receiver-bearing ops, start-session, and both handoff arms.
    const messages = [_]model.Message{
        .{ .deliver = .{
            .target = .{ .far = model.FarRef.object(4) },
            .args = &.{
                .{ .bytes = &.{ 1, 2, 3 } },
                .{ .symbol = "run" },
                .{ .string = "hello" },
                .{ .keyword = "kw" },
                .{ .integer = -99 },
                .{ .boolean = true },
                .{ .float64 = 1.5 },
                .{ .void = {} },
                .{ .reference = .{ .far = model.FarRef.promise(2) } },
                .{ .@"error" = .{ .message = "bad" } },
                .{ .list = &call_args },
                .{ .set = &call_args },
                .{ .tagged = .{ .tag = "point", .value = &call_args } },
                .{ .handoff = &handoff_arg },
            },
            .answer = .from(7),
            .resolve_me_desc = .{ .near = model.NearRef.promise(3) },
        } },
        .{ .deliver = .{
            .target = .{ .promise = .{ .answer_position = .from(1) } },
            .args = &.{},
        } },
        .{ .deliver = .{
            .target = .{ .sturdy = &.{
                .peer = .{ .transport = "tcp", .designator = "host:9000" },
                .swissnum = &.{ 0xde, 0xad },
            } },
            .args = &.{},
        } },
        .{ .resolve = .{ .answer = .from(9), .resolution = .{ .@"break" = .{ .message = "boom" } } } },
        .{ .resolve = .{ .answer = .from(2), .resolution = .{ .fulfill = .{ .reference = .{ .far = model.FarRef.object(6) } } } } },
        .{ .gc_export = .{ .positions = &.{ 2, 5, 8 }, .deltas = &.{ 1, 1, 3 } } },
        .{ .abort = .{ .kind = .version_mismatch, .message = "expected ocapn-1.0" } },
        .{ .listen = .{
            .target = .{ .far = model.FarRef.promise(1) },
            .listener = .{ .near = model.NearRef.object(2) },
            .mode = .shortening_or_settling,
        } },
        .{ .get = .{ .receiver = .{ .far = model.FarRef.object(5) }, .field = "value", .answer = .from(8) } },
        .{ .index = .{ .receiver = .{ .far = model.FarRef.object(6) }, .index = .{ .integer = -3 }, .answer = .from(9) } },
        .{ .untag = .{ .receiver = .{ .far = model.FarRef.object(5) }, .tag = "cm", .answer = .from(8) } },
        .{ .start_session = .{
            .captp_version = .v1_0,
            .session_pubkey = .{ .bytes = &(@as([32]u8, @splat(0xab))) },
            .acceptable_location = .{ .transport = "tcp", .designator = "1.2.3.4:5" },
            .acceptable_location_sig = .{ .bytes = &(@as([64]u8, @splat(0xcd))) },
        } },
    };

    for (messages) |message| {
        var frame = try capnp.encodeMessage(allocator, message);
        defer frame.deinit();

        const original = try allocator.dupe(u8, frame.bytes());
        defer allocator.free(original);

        for (0..original.len) |i| {
            for ([_]u8{ 0xFF, 0x7F, 0x01 }) |corruption| {
                if (original[i] == corruption) continue;
                const buf = try allocator.dupe(u8, original);
                defer allocator.free(buf);
                buf[i] = corruption;
                const view = glowcap.foundation.FrameView{ .bytes = buf, .shape = .word };

                if (capnp.decodeOwned(allocator, view)) |decoded| {
                    model.freeMessage(allocator, decoded);
                } else |_| {}

                if (capnp.decodeMessageView(view)) |v| {
                    if (v.toOwned(allocator)) |owned| {
                        model.freeMessage(allocator, owned);
                    } else |_| {}
                } else |_| {}
            }
        }
    }
}

test "decodeOwned bounds nesting depth: an over-deep frame fails loud, never overflows the stack" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Build one argument nested in single-element lists `depth` deep, the shape a
    // untrusted peer would craft to drive the decoder's recursion off the stack. The
    // encoder has no depth limit, so it produces exactly the over-deep frame the
    // decoder must reject. 260 sits just past the shared view materializer's bound
    // (`model.view.max_owned_depth`, 256), which is the one owned path now that
    // `decodeOwned` is `decodeBody` + `toOwned`.
    var arg: model.Argument = .{ .void = {} };
    var i: usize = 0;
    while (i < 260) : (i += 1) {
        const slice = try arena.alloc(model.Argument, 1);
        slice[0] = arg;
        arg = .{ .list = slice };
    }
    const args = [_]model.Argument{arg};
    const message = model.Message{ .deliver = .{
        .target = .{ .far = model.FarRef.object(0) },
        .args = &args,
    } };

    const frame = try capnp.encodeMessageForProfile(arena, .next, message);
    // The bound fires with a typed error; the testing allocator also proves the
    // rejection path freed every partial allocation (no leak on the error path).
    try std.testing.expectError(error.MalformedView, capnp.decodeOwned(allocator, frame.view()));
}

test "an aliasing composite DAG exhausts the traversal budget instead of amplifying" {
    const allocator = std.testing.allocator;

    // Hand-build the amplification shape the encoder can never emit: a chain of
    // D composite lists where BOTH elements of level i point at the ONE shared
    // level i+1 list. The frame holds only D+1 lists (~1.3 KB), but a naive
    // walk visits 2^i nodes at level i, 2^31 total for D=30, because Cap'n
    // Proto pointers may alias. The single-byte-flip corruption tests mutate
    // valid tree frames and can never synthesize these converging offsets, so
    // this construction is the only pressure on the traversal budget
    // (`shared.traversalBudget`, seeded from the segment word count), which
    // must refuse the frame in bounded time with the malformed-frame error.
    const levels_deep: usize = 30;
    const list_arg: u64 = @backingInt(capnp.shared.ArgKind.list);
    const void_arg: u64 = @backingInt(capnp.shared.ArgKind.void);
    // Each level: composite tag + 2 elements of stride 2 (1 data word for the
    // ArgKind discriminant, 1 pointer word to the next level).
    const list_body_words: u29 = 4;

    var b = try wire.Builder.init(allocator);
    defer b.deinit(allocator);

    // Pre-allocate every word so forward pointers (root -> envelope -> deliver
    // body, level i -> level i+1) target known indices.
    const root = try b.allocWords(allocator, 1);
    const env = try b.allocWords(allocator, 2); // Kind data word + body pointer
    const body = try b.allocWords(allocator, 3); // flags + target ptr + args ptr
    const target = try b.allocWords(allocator, 2); // RefTag + scalar
    var levels: [levels_deep + 1]usize = undefined;
    for (0..levels_deep + 1) |i| {
        levels[i] = try b.allocWords(allocator, 1 + list_body_words);
    }

    b.set(root, wire.encodeStructPointer(wire.Builder.offsetTo(root, env), 1, 1));
    b.set(env, @backingInt(capnp.shared.Kind.deliver));
    b.set(env + 1, wire.encodeStructPointer(wire.Builder.offsetTo(env + 1, body), 1, 2));
    b.set(body, 0); // flags: no answer, no resolve-me
    b.set(body + 1, wire.encodeStructPointer(wire.Builder.offsetTo(body + 1, target), 2, 0));
    b.set(body + 2, wire.encodeListPointer(wire.Builder.offsetTo(body + 2, levels[0]), .composite, list_body_words));
    b.set(target, @backingInt(capnp.shared.RefTag.far));
    b.set(target + 1, 0);

    for (0..levels_deep + 1) |i| {
        const tag = levels[i];
        b.set(tag, wire.Builder.compositeTag(2, 1, 1));
        const leaf = i == levels_deep;
        const disc: u64 = if (leaf) void_arg else list_arg;
        b.set(tag + 1, disc); // element 0 data
        b.set(tag + 3, disc); // element 1 data
        if (!leaf) {
            const child = levels[i + 1];
            // Both element pointers converge on the same child list: the DAG edge.
            b.set(tag + 2, wire.encodeListPointer(wire.Builder.offsetTo(tag + 2, child), .composite, list_body_words));
            b.set(tag + 4, wire.encodeListPointer(wire.Builder.offsetTo(tag + 4, child), .composite, list_body_words));
        }
    }

    var frame = try b.finishOwned(allocator);
    defer frame.deinit();

    // The test completing at all is the time bound: without the budget this
    // walk performs ~2^31 element resolutions.
    try std.testing.expectError(error.MalformedFrame, capnp.decodeBody(frame.view()));
    try std.testing.expectError(error.MalformedFrame, capnp.decodeOwned(allocator, frame.view()));

    // With room lent for views, the walk parses the first levels into the
    // slab and leaves the rest wire-backed once the room runs out. The same
    // budget bounds both halves, so the frame is refused the same way.
    var views: [128]model.view.Argument = undefined;
    var slab = model.view.ValueSlab.init(std.mem.sliceAsBytes(&views));
    var refused: model.view.Body = undefined;
    try std.testing.expectError(error.MalformedFrame, capnp.decodeBodyInto(.v1_0, frame.view(), &slab, &refused));
}

test "an aliasing hint list is charged against the traversal budget" {
    const allocator = std.testing.allocator;

    // The hint list was once the one composite list the metered walk never
    // enumerated. The locator projector in `decode/values.zig` packs a lazy
    // view, so without the parent decoder's hint-list observer N entries cost
    // O(1) to charge; the later materializer then builds its own unmetered
    // reader and dupes a name and a value per entry. Every entry here aliases
    // one blob, which Cap'n Proto pointers permit and every individual read
    // bounds-checks cleanly, so nothing but a budget can refuse it.
    //
    // Every other field is valid and small, so the frame reaches
    // hint materialization rather than being turned away for an unrelated
    // reason, and so the hints are the only pressure on the budget.
    //
    // It rides an `op:start-session`, which is the worst placement: the
    // handshake materializes the locator hints to rebuild the signing domain,
    // so this runs before the partner signature is verified.
    const entry_count: usize = 1024;
    const blob_words: usize = 512; // 4 KiB, aliased by every entry, twice
    const data_words: u16 = 2;
    const ptr_words: u16 = 2;
    const stride: usize = data_words + ptr_words;

    var b = try wire.Builder.init(allocator);
    defer b.deinit(allocator);

    const root = try b.allocWords(allocator, 1);
    const env = try b.allocWords(allocator, 2);
    const body = try b.allocWords(allocator, 4); // start-session: 0 data, 4 ptrs
    const loc = try b.allocWords(allocator, 4); // locator: 1 data, 3 ptrs
    const ver = try b.allocWords(allocator, 1);
    const small = try b.allocWords(allocator, 4);
    const blob = try b.allocWords(allocator, blob_words);
    const tag = try b.allocWords(allocator, 1);
    const block = try b.allocWords(allocator, entry_count * stride);

    b.setBytes(ver, "1.0");
    b.setBytes(small, "aaaaaaaa");

    b.set(root, wire.encodeStructPointer(wire.Builder.offsetTo(root, env), 1, 1));
    b.set(env, @backingInt(capnp.shared.Kind.start_session));
    b.set(env + 1, wire.encodeStructPointer(wire.Builder.offsetTo(env + 1, body), 0, 4));

    b.set(body, wire.encodeListPointer(wire.Builder.offsetTo(body, ver), .byte, 3));
    b.set(body + 1, wire.encodeListPointer(wire.Builder.offsetTo(body + 1, small), .byte, 8));
    b.set(body + 2, wire.encodeStructPointer(wire.Builder.offsetTo(body + 2, loc), 1, 3));
    b.set(body + 3, wire.encodeListPointer(wire.Builder.offsetTo(body + 3, small), .byte, 8));

    b.set(loc, 0); // hints present, map form
    b.set(loc + 1, wire.encodeListPointer(wire.Builder.offsetTo(loc + 1, small), .byte, 8));
    b.set(loc + 2, wire.encodeListPointer(wire.Builder.offsetTo(loc + 2, small), .byte, 8));
    b.set(loc + 3, wire.encodeListPointer(wire.Builder.offsetTo(loc + 3, tag), .composite, @intCast(entry_count * stride)));

    b.set(tag, wire.Builder.compositeTag(@intCast(entry_count), data_words, ptr_words));
    for (0..entry_count) |i| {
        const e = block + i * stride;
        b.set(e, @backingInt(capnp.shared.HintValueKind.string));
        b.set(e + 1, 0);
        // Name and value both point at the one shared blob: the aliasing edge.
        b.set(e + 2, wire.encodeListPointer(wire.Builder.offsetTo(e + 2, blob), .byte, @intCast(blob_words * 8)));
        b.set(e + 3, wire.encodeListPointer(wire.Builder.offsetTo(e + 3, blob), .byte, @intCast(blob_words * 8)));
    }

    var frame = try b.finishOwned(allocator);
    defer frame.deinit();

    // Materializing this unbudgeted dupes entry_count * 2 * 4 KiB from a frame
    // a fraction of that size. The budget refuses it instead.
    try std.testing.expectError(error.MalformedFrame, capnp.decodeBody(frame.view()));
    try std.testing.expectError(error.MalformedFrame, capnp.decodeOwned(allocator, frame.view()));
}

test "a decoded frame must be exactly the length its header declares" {
    const allocator = std.testing.allocator;
    var frame = try capnp.encodeMessage(allocator, .{ .gc_answer = .{ .positions = &.{7} } });
    defer frame.deinit();

    // The frame itself decodes.
    _ = try capnp.decodeBody(frame.view());

    // The same bytes with anything appended do not. Syrup refuses trailing
    // bytes too; without the rule these two byte strings name one message, and
    // anything treating a frame's bytes as its identity sees two of it.
    const padded = try allocator.alloc(u8, frame.bytes().len + 8);
    defer allocator.free(padded);
    @memcpy(padded[0..frame.bytes().len], frame.bytes());
    @memset(padded[frame.bytes().len..], 0);
    const aligned = try allocator.alignedAlloc(u8, .@"8", padded.len);
    defer allocator.free(aligned);
    @memcpy(aligned, padded);
    try std.testing.expectError(
        error.MalformedFrame,
        capnp.decodeBody(.{ .bytes = aligned, .shape = .word }),
    );
}

test "a locator carrying the same hint name twice is refused" {
    const allocator = std.testing.allocator;
    const entries = [_]model.HintEntry{
        .{ .name = "direct-addresses1", .value = .{ .string = "10.0.0.1:9000" } },
        .{ .name = "direct-addresses2", .value = .{ .string = "10.0.0.2:9000" } },
    };
    var frame = try capnp.encodeMessage(allocator, .{ .start_session = .{
        .captp_version = .v1_0,
        .session_pubkey = .{ .bytes = &(@as([32]u8, @splat(0x11))) },
        .acceptable_location = .{
            .transport = "tcp",
            .designator = "127.0.0.1:9000",
            .hints = .{ .entries = entries[0..] },
        },
        .acceptable_location_sig = .{ .bytes = &(@as([64]u8, @splat(0x22))) },
    } });
    defer frame.deinit();

    const bytes = try allocator.dupe(u8, frame.bytes());
    defer allocator.free(bytes);
    const second = std.mem.indexOf(u8, bytes, "direct-addresses2") orelse
        return error.TestUnexpectedResult;
    bytes[second + "direct-addresses".len] = '1';
    const view = glowcap.foundation.FrameView{ .bytes = bytes, .shape = .word };
    try std.testing.expectError(error.MalformedView, capnp.decodeOwned(allocator, view));
}

test "a Cap'n Proto locator cannot carry false and non-empty hints" {
    const allocator = std.testing.allocator;
    const entries = [_]model.HintEntry{.{
        .name = "direct-addresses",
        .value = .{ .string = "10.0.0.1:9000" },
    }};
    var frame = try capnp.encodeMessage(allocator, .{ .start_session = .{
        .captp_version = .v1_0,
        .session_pubkey = .{ .bytes = &(@as([32]u8, @splat(0x11))) },
        .acceptable_location = .{
            .transport = "tcp",
            .designator = "127.0.0.1:9000",
            .hints = .{ .entries = &entries },
        },
        .acceptable_location_sig = .{ .bytes = &(@as([64]u8, @splat(0x22))) },
    } });
    defer frame.deinit();

    const bytes = try allocator.dupe(u8, frame.bytes());
    defer allocator.free(bytes);
    const mutable_view = glowcap.foundation.FrameView{ .bytes = bytes, .shape = .word };
    const message_view = try capnp.decodeMessageView(mutable_view);
    const locator = (try message_view.reader.followStruct(message_view.body, 2)) orelse
        return error.TestUnexpectedResult;
    const data_word = bytes[(locator.data_idx + 1) * wire.word_bytes ..][0..wire.word_bytes];
    std.mem.writeInt(u64, data_word, std.mem.readInt(u64, data_word, .little) | 1, .little);

    const body = try capnp.decodeBody(mutable_view);
    var s = glowcap.ocapn.session.Session.initNegotiating(allocator);
    defer s.deinit();
    try std.testing.expectError(
        glowcap.ocapn.session.Error.MalformedMessage,
        s.recordRecvView(body),
    );
    try std.testing.expectError(error.MalformedView, capnp.decodeOwned(allocator, mutable_view));
}

test "a composite tag wearing a non-struct pointer kind is refused" {
    const allocator = std.testing.allocator;
    const args = [_]model.Argument{.{ .integer = 0x1111_2222_3333_4444 }};
    var frame = try capnp.encodeMessage(allocator, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &args,
    } });
    defer frame.deinit();

    const bytes = try allocator.dupe(u8, frame.bytes());
    defer allocator.free(bytes);
    const mutable_view = glowcap.foundation.FrameView{ .bytes = bytes, .shape = .word };
    const message_view = try capnp.decodeMessageView(mutable_view);
    // The args list is deliver's pointer field 1; its content begins with the
    // struct-pointer-shaped tag word this test corrupts.
    const clist = (try capnp.shared.compositeList(message_view.reader, message_view.body, 1)) orelse
        return error.TestUnexpectedResult;
    const tag_bytes = bytes[(clist.tag_idx + 1) * wire.word_bytes ..][0..wire.word_bytes];
    const tag_word = std.mem.readInt(u64, tag_bytes, .little);
    std.mem.writeInt(u64, tag_bytes, tag_word | @backingInt(wire.PointerKind.capability), .little);

    // Every field bit still reads the same, so only the kind check can refuse
    // this word; a decoder that ignores it would accept two spellings of one
    // list.
    try std.testing.expectError(error.InvalidPointer, capnp.decodeBody(mutable_view));
    try std.testing.expectError(error.InvalidPointer, capnp.decodeOwned(allocator, mutable_view));
}
