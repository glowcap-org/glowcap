const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;

test "far references are equal on import id and wire kind" {
    const a: model.Reference = .{ .far = .{ .import_position = .from(7), .kind = .object } };
    try std.testing.expect(model.referencesStructurallyEqual(a, .{ .far = .{ .import_position = .from(7), .kind = .object } }));
    // Positions are session-local representation, not global target identity.
    try std.testing.expect(!model.referencesStructurallyEqual(a, .{ .far = .{ .import_position = .from(8), .kind = .object } }));
    // The wire-kind discriminator participates (ADR-0010 § Decision 5).
    try std.testing.expect(!model.referencesStructurallyEqual(a, .{ .far = .{ .import_position = .from(7), .kind = .promise } }));
}

test "references of differing variants are never equal" {
    const far: model.Reference = .{ .far = .{ .import_position = .from(1) } };
    const near: model.Reference = .{ .near = .{ .export_position = .from(1) } };
    try std.testing.expect(!model.referencesStructurallyEqual(far, near));
}

test "near references compare on export id and kind" {
    const a: model.Reference = .{ .near = .{ .export_position = .from(3), .kind = .promise } };
    try std.testing.expect(model.referencesStructurallyEqual(a, .{ .near = .{ .export_position = .from(3), .kind = .promise } }));
    try std.testing.expect(!model.referencesStructurallyEqual(a, .{ .near = .{ .export_position = .from(3), .kind = .object } }));
}

test "broken references compare on message" {
    const a: model.Reference = .{ .broken = .{ .message = "gone" } };
    try std.testing.expect(model.referencesStructurallyEqual(a, .{ .broken = .{ .message = "gone" } }));
    try std.testing.expect(!model.referencesStructurallyEqual(a, .{ .broken = .{ .message = "other" } }));
}

test "sturdy references compare structurally on (peer, swissnum)" {
    const a: model.Reference = .{ .sturdy = &.{
        .peer = .{ .transport = "memory", .designator = "host" },
        .swissnum = "abc",
    } };
    try std.testing.expect(model.referencesStructurallyEqual(a, .{ .sturdy = &.{
        .peer = .{ .transport = "memory", .designator = "host" },
        .swissnum = "abc",
    } }));
    try std.testing.expect(!model.referencesStructurallyEqual(a, .{ .sturdy = &.{
        .peer = .{ .transport = "memory", .designator = "host" },
        .swissnum = "xyz",
    } }));
    try std.testing.expect(!model.referencesStructurallyEqual(a, .{ .sturdy = &.{
        .peer = .{ .transport = "memory", .designator = "other" },
        .swissnum = "abc",
    } }));
}

test "peer-locator equality ignores the hint-encoding marker" {
    // The hint wire-form marker is a wire-shape artifact, not a semantic value.
    const a: model.PeerLocator = .{ .transport = "tcp", .designator = "h", .hints = model.Hints.emptyMap() };
    const b: model.PeerLocator = .{ .transport = "tcp", .designator = "h", .hints = model.Hints.emptyFalse() };
    try std.testing.expect(model.peerLocatorsEqual(a, b));
}

test "peer locators differing only in hints are the same peer" {
    // Locators.md: "the designator and transport are the only pieces of
    // information which need to match". Hints are connection advice, not
    // identity.
    const entries = [_]model.HintEntry{
        .{ .name = "host", .value = .{ .string = "127.0.0.1" } },
    };
    const hinted: model.PeerLocator = .{
        .transport = "tcp",
        .designator = "h",
        .hints = .{ .entries = &entries },
    };
    const bare: model.PeerLocator = .{ .transport = "tcp", .designator = "h" };
    try std.testing.expect(model.peerLocatorsEqual(hinted, bare));

    // Designator and transport still discriminate.
    const other: model.PeerLocator = .{ .transport = "onion", .designator = "h" };
    try std.testing.expect(!model.peerLocatorsEqual(hinted, other));
}

test "sturdy references differing only in peer hints are equal" {
    const entries = [_]model.HintEntry{
        .{ .name = "port", .value = .{ .integer = 22055 } },
    };
    const hinted: model.Reference = .{ .sturdy = &.{
        .peer = .{ .transport = "tcp", .designator = "host", .hints = .{ .entries = &entries } },
        .swissnum = "abc",
    } };
    const bare: model.Reference = .{ .sturdy = &.{
        .peer = .{ .transport = "tcp", .designator = "host" },
        .swissnum = "abc",
    } };
    try std.testing.expect(model.referencesStructurallyEqual(hinted, bare));
}

test "handoff gives differing only in a hint entry value are unequal" {
    // Locator identity ignores hints; give payload equality deep-compares them.
    const entries_a = [_]model.HintEntry{
        .{ .name = "direct-addresses", .value = .{ .string = "127.0.0.1:1" } },
    };
    const entries_b = [_]model.HintEntry{
        .{ .name = "direct-addresses", .value = .{ .string = "127.0.0.1:2" } },
    };
    var give_a = model.Handoff{ .give = .{
        .recipient_key = &([_]u8{0x11} ** 32),
        .exporter = .{
            .transport = "tcp",
            .designator = "exporter",
            .hints = .{ .entries = &entries_a },
        },
        .gifter_exporter_session = &([_]u8{0x22} ** 32),
        .gifter_side = &([_]u8{0x33} ** 32),
        .gift_id = &([_]u8{0x44} ** 32),
        .signature = &([_]u8{0xaa} ** 64),
    } };
    var give_b = model.Handoff{ .give = .{
        .recipient_key = &([_]u8{0x11} ** 32),
        .exporter = .{
            .transport = "tcp",
            .designator = "exporter",
            .hints = .{ .entries = &entries_b },
        },
        .gifter_exporter_session = &([_]u8{0x22} ** 32),
        .gifter_side = &([_]u8{0x33} ** 32),
        .gift_id = &([_]u8{0x44} ** 32),
        .signature = &([_]u8{0xaa} ** 64),
    } };
    try std.testing.expect(!model.argumentsEqual(.{ .handoff = &give_a }, .{ .handoff = &give_b }));
    try std.testing.expect(model.peerLocatorsEqual(give_a.give.exporter, give_b.give.exporter));
}

test "promise references compare on answer id and pipeline path" {
    const ops = [_]model.PipelineOp{.{ .field = "method" }};
    const a: model.Reference = .{ .promise = .{ .answer_position = .from(5), .path = .{ .ops = &ops } } };
    try std.testing.expect(model.referencesStructurallyEqual(a, .{ .promise = .{ .answer_position = .from(5), .path = .{ .ops = &ops } } }));
    // Same answer, empty path ≠ non-empty path.
    try std.testing.expect(!model.referencesStructurallyEqual(a, .{ .promise = .{ .answer_position = .from(5) } }));
    try std.testing.expect(!model.referencesStructurallyEqual(a, .{ .promise = .{ .answer_position = .from(6), .path = .{ .ops = &ops } } }));
}

test "argument equality recurses through lists and nested references" {
    const inner_a = [_]model.Argument{
        .{ .integer = 1 },
        .{ .reference = .{ .far = .{ .import_position = .from(9) } } },
    };
    const inner_b = [_]model.Argument{
        .{ .integer = 1 },
        .{ .reference = .{ .far = .{ .import_position = .from(9) } } },
    };
    try std.testing.expect(model.argumentsEqual(.{ .list = &inner_a }, .{ .list = &inner_b }));

    const inner_c = [_]model.Argument{
        .{ .integer = 1 },
        .{ .reference = .{ .far = .{ .import_position = .from(10) } } },
    };
    try std.testing.expect(!model.argumentsEqual(.{ .list = &inner_a }, .{ .list = &inner_c }));

    // Differing arity is unequal.
    const shorter = [_]model.Argument{.{ .integer = 1 }};
    try std.testing.expect(!model.argumentsEqual(.{ .list = &inner_a }, .{ .list = &shorter }));
}

test "big integer equality is bytewise over sign and canonical digits" {
    // Canonical digits (enforced at decode, ADR-0049) make bytewise comparison
    // arithmetic equality (Model.md § Integer: every Integer value is only
    // equal to Integer values representing the same arithmetic integer).
    const two_pow_100 = "1267650600228229401496703205376";
    const a = model.Argument{ .big_integer = .{ .negative = false, .digits = two_pow_100 } };
    const same = model.Argument{ .big_integer = .{ .negative = false, .digits = two_pow_100 } };
    try std.testing.expect(model.argumentsEqual(a, same));

    // Sign distinguishes.
    const negated = model.Argument{ .big_integer = .{ .negative = true, .digits = two_pow_100 } };
    try std.testing.expect(!model.argumentsEqual(a, negated));

    // Digits distinguish.
    const other = model.Argument{ .big_integer = .{ .negative = false, .digits = "1267650600228229401496703205377" } };
    try std.testing.expect(!model.argumentsEqual(a, other));

    // The two integer arms never compare equal; decode keeps every i64-range
    // value on the `integer` arm, so cross-arm aliasing cannot arise.
    try std.testing.expect(!model.argumentsEqual(a, .{ .integer = 42 }));

    // The canonical-form invariant the codecs enforce, at its boundaries.
    try std.testing.expect((model.BigInteger{ .negative = false, .digits = "9223372036854775808" }).isCanonical());
    try std.testing.expect(!(model.BigInteger{ .negative = true, .digits = "9223372036854775808" }).isCanonical()); // minInt(i64)'s magnitude
    try std.testing.expect((model.BigInteger{ .negative = true, .digits = "9223372036854775809" }).isCanonical());
    try std.testing.expect(!(model.BigInteger{ .negative = false, .digits = "042" }).isCanonical());
    try std.testing.expect(!(model.BigInteger{ .negative = false, .digits = "" }).isCanonical());
    try std.testing.expect(!(model.BigInteger{ .negative = false, .digits = "12a4" }).isCanonical());
}

test "set equality is order-agnostic (multiset), per Pass Invariant Equality" {
    // A set is unordered. The two codecs emit its elements in different orders
    // (Syrup canonical-sorts, Cap'n Proto keeps insertion order), so the same set
    // decoded from each must still compare Equal.
    const a = [_]model.Argument{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } };
    const reordered = [_]model.Argument{ .{ .integer = 3 }, .{ .integer = 1 }, .{ .integer = 2 } };
    try std.testing.expect(model.argumentsEqual(.{ .set = &a }, .{ .set = &reordered }));

    // The same elements as a list in a different order are NOT equal; lists are
    // ordered, only sets are not. This is the line that keeps the two arms honest.
    try std.testing.expect(!model.argumentsEqual(.{ .list = &a }, .{ .list = &reordered }));

    // Same length, different elements is unequal.
    const different = [_]model.Argument{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 4 } };
    try std.testing.expect(!model.argumentsEqual(.{ .set = &a }, .{ .set = &different }));

    // Multiplicity matters: {1, 1, 2} is not the {1, 2, 2} multiset, even though
    // they share the same distinct elements and length.
    const ones = [_]model.Argument{ .{ .integer = 1 }, .{ .integer = 1 }, .{ .integer = 2 } };
    const twos = [_]model.Argument{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 2 } };
    try std.testing.expect(!model.argumentsEqual(.{ .set = &ones }, .{ .set = &twos }));

    // Differing arity is unequal.
    const shorter_set = [_]model.Argument{.{ .integer = 1 }};
    try std.testing.expect(!model.argumentsEqual(.{ .set = &a }, .{ .set = &shorter_set }));
}

test "nested set equality stays order-agnostic at depth" {
    // A set of sets, with both the outer and the inner orderings shuffled. The
    // value is the same, so it compares Equal all the way down.
    const inner1 = [_]model.Argument{ .{ .integer = 1 }, .{ .integer = 2 } };
    const inner2 = [_]model.Argument{ .{ .integer = 3 }, .{ .integer = 4 } };
    const outer_a = [_]model.Argument{ .{ .set = &inner1 }, .{ .set = &inner2 } };

    const inner1_r = [_]model.Argument{ .{ .integer = 2 }, .{ .integer = 1 } };
    const inner2_r = [_]model.Argument{ .{ .integer = 4 }, .{ .integer = 3 } };
    const outer_b = [_]model.Argument{ .{ .set = &inner2_r }, .{ .set = &inner1_r } };

    try std.testing.expect(model.argumentsEqual(.{ .set = &outer_a }, .{ .set = &outer_b }));
}

test "scalar arguments compare by value and reject variant mismatch" {
    try std.testing.expect(model.argumentsEqual(.{ .boolean = true }, .{ .boolean = true }));
    try std.testing.expect(!model.argumentsEqual(.{ .boolean = true }, .{ .boolean = false }));
    try std.testing.expect(model.argumentsEqual(.{ .void = {} }, .{ .void = {} }));
    // A symbol and a string with identical bytes are different argument shapes.
    try std.testing.expect(!model.argumentsEqual(.{ .symbol = "x" }, .{ .string = "x" }));
}

test "float64 equality follows Object.is, not IEEE: NaN equals NaN" {
    // Model.md § Pass Invariant Equality: every NaN is Equal to every other NaN,
    // so a NaN-bearing value that round-trips the network stays Equal to itself,
    // unlike IEEE `==`, under which `NaN == NaN` is false.
    const nan = std.math.nan(f64);
    try std.testing.expect(model.argumentsEqual(.{ .float64 = nan }, .{ .float64 = nan }));

    // A different NaN bit-pattern (e.g. a signalling NaN payload) is still Equal.
    const other_nan: f64 = @bitCast(@as(u64, 0x7ff8_0000_dead_beef));
    try std.testing.expect(std.math.isNan(other_nan));
    try std.testing.expect(model.argumentsEqual(.{ .float64 = nan }, .{ .float64 = other_nan }));

    // A NaN is never Equal to a finite value.
    try std.testing.expect(!model.argumentsEqual(.{ .float64 = nan }, .{ .float64 = 1.0 }));
}

test "float64 equality follows Object.is: +0.0 is distinct from -0.0" {
    // Object.is(+0, -0) is false; preserving the sign-zero distinction keeps the
    // JSON round-trip invariant (Model.md). IEEE `==` would wrongly call these
    // Equal.
    const pos_zero: f64 = 0.0;
    const neg_zero: f64 = -0.0;
    try std.testing.expect(!model.argumentsEqual(.{ .float64 = pos_zero }, .{ .float64 = neg_zero }));
    try std.testing.expect(model.argumentsEqual(.{ .float64 = pos_zero }, .{ .float64 = 0.0 }));
}

test "float64 equality compares ordinary values by magnitude" {
    try std.testing.expect(model.argumentsEqual(.{ .float64 = 3.5 }, .{ .float64 = 3.5 }));
    try std.testing.expect(!model.argumentsEqual(.{ .float64 = 3.5 }, .{ .float64 = 3.6 }));
}

test "equality bails at the depth cap on a promise/call tower instead of overflowing" {
    // The recursion cycle under test: a promise reference carries a pipeline
    // path, a `call` step carries arguments, and an argument can be another
    // promise reference. The depth counter must thread through that whole
    // cycle, dropping it at the reference arm or restarting it at the path
    // would let a tall enough tower recurse off the native stack.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const buildTower = struct {
        fn build(a: std.mem.Allocator, levels: usize) !model.Reference {
            var reference: model.Reference = .{ .promise = .{ .answer_position = .from(0) } };
            var level: usize = 0;
            while (level < levels) : (level += 1) {
                const args = try a.alloc(model.Argument, 1);
                args[0] = .{ .reference = reference };
                const ops = try a.alloc(model.PipelineOp, 1);
                ops[0] = .{ .call = args };
                reference = .{ .promise = .{ .answer_position = .from(0), .path = .{ .ops = ops } } };
            }
            return reference;
        }
    }.build;

    // A shallow tower is well inside the cap and compares equal to itself.
    const shallow = try buildTower(allocator, 8);
    try std.testing.expect(model.referencesStructurallyEqual(shallow, shallow));

    // A tower past `max_equality_depth` (256) bails out as unequal — even
    // against itself — rather than recursing one native frame per level.
    const deep = try buildTower(allocator, 100_000);
    try std.testing.expect(!model.referencesStructurallyEqual(deep, deep));
    try std.testing.expect(!model.argumentsEqual(.{ .reference = deep }, .{ .reference = deep }));
}

// The borrowed-view equality and hash spine (`viewArgument*`) mirrors the owned
// spine (`argument*`) arm for arm, because a view iterator is fallible where an
// owned slice is not, so the two cannot be merged without forcing error handling
// onto every owned caller. Two mirrored spines can silently drift. This gate
// closes that: `model.view.Body.fromOwned` projects a borrowed view over the
// exact owned values, so any disagreement in an arm's tag set, recursion, or
// order-independence surfaces here rather than in a live conversation.
test "view equality and hash agree with the owned spine across every argument arm" {
    const allocator = std.testing.allocator;

    const call_args = [_]model.Argument{ .{ .integer = 1 }, .{ .integer = 2 } };
    const reordered_call_args = [_]model.Argument{ .{ .integer = 2 }, .{ .integer = 1 } };

    // The shared passable breadth, plus deliberately crafted twins: an
    // order-independent set and struct (equal to their reordered mates), an
    // order-sensitive list (unequal to its reordered mate), and a second
    // float64 that hashes tag-only-equal to the first while comparing distinct.
    const args = [_]model.Argument{
        .{ .integer = -99 },
        .{ .big_integer = .{ .negative = true, .digits = "340282366920938463463374607431768211456" } },
        .{ .float64 = 1.5 },
        .{ .float64 = 2.5 },
        .{ .boolean = true },
        .{ .bytes = &.{ 1, 2, 3 } },
        .{ .string = "hello" },
        .{ .symbol = "run" },
        .{ .keyword = "color" },
        .{ .void = {} },
        .{ .reference = .{ .far = model.FarRef.object(2) } },
        .{ .@"error" = .{ .message = "boom" } },
        .{ .tagged = .{ .tag = "point", .value = &call_args } },
        .{ .list = &call_args },
        .{ .list = &reordered_call_args },
        .{ .set = &.{ .{ .integer = 3 }, .{ .integer = 1 }, .{ .integer = 2 } } },
        .{ .set = &.{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } } },
        .{ .@"struct" = &.{
            .{ .key = "name", .value = .{ .string = "tabby" } },
            .{ .key = "age", .value = .{ .integer = 12 } },
        } },
        .{ .@"struct" = &.{
            .{ .key = "age", .value = .{ .integer = 12 } },
            .{ .key = "name", .value = .{ .string = "tabby" } },
        } },
    };

    const message: model.Message = .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(4) },
        .args = &args,
        .answer = .from(7),
    } };

    const body = model.view.Body.fromOwned(&message);
    const view_args = body.deliver.args;
    try std.testing.expectEqual(args.len, try view_args.len());

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const scratch = arena_state.allocator();
    // Generous: this cross-spine agreement check compares every pair in the
    // fixture, and the bound under test is the wire path's, not this walk's.
    var budget = model.equality.CompareBudget.init(1 << 20);
    const ctx = model.equality.CompareCtx{ .scratch = scratch, .budget = &budget };

    // Per element: every arm is reflexively equal on both spines, which also
    // runs both hashers on every arm. The two hashers seed on their own union's
    // tag order, so their numeric values are not comparable across
    // representations; only agreement within a representation is a contract.
    for (args, 0..) |owned_arg, i| {
        const view_arg = try view_args.at(i);
        try std.testing.expect(model.equality.argumentsEqual(owned_arg, owned_arg));
        try std.testing.expect(try model.equality.viewArgumentsEqualBounded(view_arg, view_arg, ctx));
    }

    // Per pair: the two equality predicates agree, and an equal pair hashes
    // equal within each spine (so an order-independent arm cannot hash-drift).
    for (args, 0..) |owned_a, i| {
        for (args, 0..) |owned_b, j| {
            const owned_eq = model.equality.argumentsEqual(owned_a, owned_b);
            const view_eq = try model.equality.viewArgumentsEqualBounded(
                try view_args.at(i),
                try view_args.at(j),
                ctx,
            );
            try std.testing.expectEqual(owned_eq, view_eq);
            if (owned_eq) {
                try std.testing.expectEqual(
                    model.equality.argumentHash(owned_a),
                    model.equality.argumentHash(owned_b),
                );
                try std.testing.expectEqual(
                    try model.equality.viewArgumentHash(try view_args.at(i)),
                    try model.equality.viewArgumentHash(try view_args.at(j)),
                );
            }
        }
    }
}

test "distinct values in a hashed arm do not collapse onto one hash" {
    // Callers group by hash and only then confirm with the equality predicate,
    // so an arm that hashed to its tag alone would put every value of that arm
    // in a single group and turn the confirmation into a quadratic scan. An
    // inbound frame can ask for exactly that: a set of distinct floats, or of
    // distinct broken references, costs the sender nothing to build.
    const floats = [_]f64{ 0.0, 1.0, 2.5, -3.75, 1e300, -1e-300 };
    var seen: [floats.len]u64 = undefined;
    for (floats, 0..) |f, i| {
        seen[i] = model.equality.argumentHash(.{ .float64 = f });
        for (seen[0..i]) |earlier| try std.testing.expect(earlier != seen[i]);
    }

    // Signed zeros are Equal under IEEE but not under this model's equality
    // (it keeps the sign for round-trip stability), so they must not share a
    // hash either.
    try std.testing.expect(
        model.equality.argumentHash(.{ .float64 = 0.0 }) !=
            model.equality.argumentHash(.{ .float64 = -0.0 }),
    );

    // Every NaN is one Equal class, so every NaN has to hash alike.
    const nan_a = std.math.nan(f64);
    const nan_b: f64 = @bitCast(@as(u64, 0x7ff8_0000_dead_beef));
    try std.testing.expect(std.math.isNan(nan_b));
    try std.testing.expectEqual(
        model.equality.argumentHash(.{ .float64 = nan_a }),
        model.equality.argumentHash(.{ .float64 = nan_b }),
    );

    // The same property for the other arms that used to hash to their tag.
    try std.testing.expect(
        model.equality.argumentHash(.{ .@"error" = .{ .message = "one" } }) !=
            model.equality.argumentHash(.{ .@"error" = .{ .message = "two" } }),
    );
    try std.testing.expect(
        model.equality.argumentHash(.{ .reference = .{ .broken = .{ .message = "one" } } }) !=
            model.equality.argumentHash(.{ .reference = .{ .broken = .{ .message = "two" } } }),
    );
    try std.testing.expect(
        model.equality.argumentHash(.{ .reference = .{ .far = .{ .import_position = .from(1) } } }) !=
            model.equality.argumentHash(.{ .reference = .{ .far = .{ .import_position = .from(2) } } }),
    );
}
