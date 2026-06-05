const std = @import("std");
const pancake = @import("pancake");

const model = pancake.model;

test "far references are equal on import id and wire kind" {
    const a: model.Reference = .{ .far = .{ .import_id = 7, .kind = .object } };
    try std.testing.expect(model.referencesEqual(a, .{ .far = .{ .import_id = 7, .kind = .object } }));
    // Distributed-equality evidence: same (import_id, kind) ⇒ equal target.
    try std.testing.expect(!model.referencesEqual(a, .{ .far = .{ .import_id = 8, .kind = .object } }));
    // The wire-kind discriminator participates (ADR-0010 § Decision 5).
    try std.testing.expect(!model.referencesEqual(a, .{ .far = .{ .import_id = 7, .kind = .promise } }));
}

test "references of differing variants are never equal" {
    const far: model.Reference = .{ .far = .{ .import_id = 1 } };
    const near: model.Reference = .{ .near = .{ .export_id = 1 } };
    try std.testing.expect(!model.referencesEqual(far, near));
}

test "near references compare on export id and kind" {
    const a: model.Reference = .{ .near = .{ .export_id = 3, .kind = .promise } };
    try std.testing.expect(model.referencesEqual(a, .{ .near = .{ .export_id = 3, .kind = .promise } }));
    try std.testing.expect(!model.referencesEqual(a, .{ .near = .{ .export_id = 3, .kind = .object } }));
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
    // empty_wire_was_false is a wire-shape artifact, not a semantic value.
    const a: model.PeerLocator = .{ .transport = "tcp", .designator = "h", .hints = model.Hints.emptyMap() };
    const b: model.PeerLocator = .{ .transport = "tcp", .designator = "h", .hints = model.Hints.emptyFalse() };
    try std.testing.expect(model.peerLocatorsEqual(a, b));
}

test "promise references compare on answer id and pipeline path" {
    const ops = [_]model.PipelineOp{.{ .field = "method" }};
    const a: model.Reference = .{ .promise = .{ .answer_id = 5, .path = .{ .ops = &ops } } };
    try std.testing.expect(model.referencesEqual(a, .{ .promise = .{ .answer_id = 5, .path = .{ .ops = &ops } } }));
    // Same answer, empty path ≠ non-empty path.
    try std.testing.expect(!model.referencesEqual(a, .{ .promise = .{ .answer_id = 5 } }));
    try std.testing.expect(!model.referencesEqual(a, .{ .promise = .{ .answer_id = 6, .path = .{ .ops = &ops } } }));
}

test "argument equality recurses through lists and nested references" {
    const inner_a = [_]model.Argument{
        .{ .integer = 1 },
        .{ .reference = .{ .far = .{ .import_id = 9 } } },
    };
    const inner_b = [_]model.Argument{
        .{ .integer = 1 },
        .{ .reference = .{ .far = .{ .import_id = 9 } } },
    };
    try std.testing.expect(model.argumentsEqual(.{ .list = &inner_a }, .{ .list = &inner_b }));

    const inner_c = [_]model.Argument{
        .{ .integer = 1 },
        .{ .reference = .{ .far = .{ .import_id = 10 } } },
    };
    try std.testing.expect(!model.argumentsEqual(.{ .list = &inner_a }, .{ .list = &inner_c }));

    // Differing arity is unequal.
    const shorter = [_]model.Argument{.{ .integer = 1 }};
    try std.testing.expect(!model.argumentsEqual(.{ .list = &inner_a }, .{ .list = &shorter }));
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
