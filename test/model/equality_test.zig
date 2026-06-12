const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;

test "far references are equal on import id and wire kind" {
    const a: model.Reference = .{ .far = .{ .import_position = 7, .kind = .object } };
    try std.testing.expect(model.referencesEqual(a, .{ .far = .{ .import_position = 7, .kind = .object } }));
    // Distributed-equality evidence: same (import_position, kind) ⇒ equal target.
    try std.testing.expect(!model.referencesEqual(a, .{ .far = .{ .import_position = 8, .kind = .object } }));
    // The wire-kind discriminator participates (ADR-0010 § Decision 5).
    try std.testing.expect(!model.referencesEqual(a, .{ .far = .{ .import_position = 7, .kind = .promise } }));
}

test "references of differing variants are never equal" {
    const far: model.Reference = .{ .far = .{ .import_position = 1 } };
    const near: model.Reference = .{ .near = .{ .export_position = 1 } };
    try std.testing.expect(!model.referencesEqual(far, near));
}

test "near references compare on export id and kind" {
    const a: model.Reference = .{ .near = .{ .export_position = 3, .kind = .promise } };
    try std.testing.expect(model.referencesEqual(a, .{ .near = .{ .export_position = 3, .kind = .promise } }));
    try std.testing.expect(!model.referencesEqual(a, .{ .near = .{ .export_position = 3, .kind = .object } }));
}

test "broken references compare on message" {
    const a: model.Reference = .{ .broken = .{ .message = "gone" } };
    try std.testing.expect(model.referencesEqual(a, .{ .broken = .{ .message = "gone" } }));
    try std.testing.expect(!model.referencesEqual(a, .{ .broken = .{ .message = "other" } }));
}

test "sturdy references compare structurally on (peer, swissnum)" {
    const a: model.Reference = .{ .sturdy = .{
        .peer = .{ .transport = "memory", .designator = "host" },
        .swissnum = "abc",
    } };
    try std.testing.expect(model.referencesEqual(a, .{ .sturdy = .{
        .peer = .{ .transport = "memory", .designator = "host" },
        .swissnum = "abc",
    } }));
    try std.testing.expect(!model.referencesEqual(a, .{ .sturdy = .{
        .peer = .{ .transport = "memory", .designator = "host" },
        .swissnum = "xyz",
    } }));
    try std.testing.expect(!model.referencesEqual(a, .{ .sturdy = .{
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
    // information which need to match" — hints are connection advice, not
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
    const hinted: model.Reference = .{ .sturdy = .{
        .peer = .{ .transport = "tcp", .designator = "host", .hints = .{ .entries = &entries } },
        .swissnum = "abc",
    } };
    const bare: model.Reference = .{ .sturdy = .{
        .peer = .{ .transport = "tcp", .designator = "host" },
        .swissnum = "abc",
    } };
    try std.testing.expect(model.referencesEqual(hinted, bare));
}

test "promise references compare on answer id and pipeline path" {
    const ops = [_]model.PipelineOp{.{ .field = "method" }};
    const a: model.Reference = .{ .promise = .{ .answer_position = 5, .path = .{ .ops = &ops } } };
    try std.testing.expect(model.referencesEqual(a, .{ .promise = .{ .answer_position = 5, .path = .{ .ops = &ops } } }));
    // Same answer, empty path ≠ non-empty path.
    try std.testing.expect(!model.referencesEqual(a, .{ .promise = .{ .answer_position = 5 } }));
    try std.testing.expect(!model.referencesEqual(a, .{ .promise = .{ .answer_position = 6, .path = .{ .ops = &ops } } }));
}

test "argument equality recurses through lists and nested references" {
    const inner_a = [_]model.Argument{
        .{ .integer = 1 },
        .{ .reference = .{ .far = .{ .import_position = 9 } } },
    };
    const inner_b = [_]model.Argument{
        .{ .integer = 1 },
        .{ .reference = .{ .far = .{ .import_position = 9 } } },
    };
    try std.testing.expect(model.argumentsEqual(.{ .list = &inner_a }, .{ .list = &inner_b }));

    const inner_c = [_]model.Argument{
        .{ .integer = 1 },
        .{ .reference = .{ .far = .{ .import_position = 10 } } },
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

    // The two integer arms never compare equal — decode keeps every i64-range
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

    // The same elements as a list in a different order are NOT equal — lists are
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
    // so a NaN-bearing value that round-trips the network stays Equal to itself —
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
    // cycle — dropping it at the reference arm or restarting it at the path
    // would let a tall enough tower recurse off the native stack.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const buildTower = struct {
        fn build(a: std.mem.Allocator, levels: usize) !model.Reference {
            var reference: model.Reference = .{ .promise = .{ .answer_position = 0 } };
            var level: usize = 0;
            while (level < levels) : (level += 1) {
                const args = try a.alloc(model.Argument, 1);
                args[0] = .{ .reference = reference };
                const ops = try a.alloc(model.PipelineOp, 1);
                ops[0] = .{ .call = args };
                reference = .{ .promise = .{ .answer_position = 0, .path = .{ .ops = ops } } };
            }
            return reference;
        }
    }.build;

    // A shallow tower is well inside the cap and compares equal to itself.
    const shallow = try buildTower(allocator, 8);
    try std.testing.expect(model.referencesEqual(shallow, shallow));

    // A tower past `max_equality_depth` (256) bails out as unequal — even
    // against itself — rather than recursing one native frame per level.
    const deep = try buildTower(allocator, 100_000);
    try std.testing.expect(!model.referencesEqual(deep, deep));
    try std.testing.expect(!model.argumentsEqual(.{ .reference = deep }, .{ .reference = deep }));
}
