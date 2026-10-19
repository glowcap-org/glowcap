//! Generates `src/ocapn/model/own_wire.zig`: a fingerprint of the frames
//! glowcap alone defines (ADR-0001).
//!
//! Each owned (version, codec) pair encodes the corpus below. The fingerprint
//! hashes every frame, or the error that refused it, so any change to what an
//! owned encoder writes changes the fingerprint.
//!
//! The build fails if the corpus misses a message, argument, reference,
//! handoff, or resolution kind, and generation fails if a case's outcome under
//! a version is not the one it states.

const std = @import("std");
const model = @import("model");
const codec = @import("codec");
const Output = @import("output").Output;

pub const step_name = "gen-own-wire";

pub const outputs = [_]Output{
    .{ .path = "src/ocapn/model/own_wire.zig", .generate = generate },
};

const Case = struct {
    name: []const u8,
    expected: Expected,
    message: model.Message,
};

const Outcome = enum { framed, refused };

/// What each version's encoders do with the message. A codec never refuses
/// what its version takes, so a case states one outcome per version.
const Expected = std.EnumArray(model.CaptpVersion, Outcome);
const framed: Expected = .initFill(.framed);
const refused: Expected = .initFill(.refused);
/// An operation or form `next` removed.
const v1_0_only: Expected = .init(.{ .v1_0 = .framed, .next = .refused });

// Sample values. They are arbitrary, but they are part of the fingerprint.

const target: model.Reference = .{ .far = model.FarRef.object(1) };
const answer: model.AnswerPosition = .from(2);
const resolver: model.Reference = .{ .near = model.NearRef.object(3) };

const ping = [_]model.Argument{.{ .bytes = "ping" }};
const integers = [_]model.Argument{ .{ .integer = 100 }, .{ .integer = -200 }, .{ .integer = 300 } };
const members = [_]model.Argument{ .{ .integer = 1 }, .{ .symbol = "two" } };
const tagged = [_]model.Argument{.{ .string = "inside" }};
const entries = [_]model.StructEntry{
    .{ .key = "name", .value = .{ .string = "a" } },
    .{ .key = "count", .value = .{ .integer = 2 } },
};

const locator: model.PeerLocator = .{ .transport = "tcp", .designator = "127.0.0.1:9" };
const sturdy: model.SturdyRef = .{ .peer = locator, .swissnum = "swiss" };
const give: model.Handoff = .{ .give = .{
    .recipient_key = &filled(32, 0x01),
    .exporter = locator,
    .gifter_exporter_session = &filled(32, 0x02),
    .gifter_side = &filled(32, 0x03),
    .gift_id = &filled(32, 0x04),
    .signature = &filled(64, 0x05),
} };
const receive: model.Handoff = .{ .receive = .{
    .receiving_session = &filled(32, 0x06),
    .receiving_side = &filled(32, 0x07),
    .handoff_count = 3,
    .signed_give = give.give,
    .signature = &filled(64, 0x08),
} };

fn filled(comptime len: usize, comptime byte: u8) [len]u8 {
    return @splat(byte);
}

const operations = [_]Case{
    .{ .name = "deliver with answer", .expected = v1_0_only, .message = .{ .deliver = .{
        .target = target,
        .args = &ping,
        .answer = answer,
    } } },
    .{ .name = "deliver with resolver", .expected = framed, .message = .{ .deliver = .{
        .target = target,
        .args = &ping,
        .answer = answer,
        .resolve_me_desc = resolver,
    } } },
    .{ .name = "deliver shortening only", .expected = framed, .message = .{ .deliver = .{
        .target = target,
        .args = &ping,
        .resolve_me_desc = resolver,
        .listen_mode = .shortening_only,
    } } },
    .{ .name = "deliver settling only", .expected = v1_0_only, .message = .{ .deliver = .{
        .target = target,
        .args = &ping,
        .resolve_me_desc = resolver,
        .listen_mode = .settling_only,
    } } },
    .{ .name = "deliver only", .expected = framed, .message = .{ .deliver = .{
        .target = target,
        .args = &ping,
    } } },
    .{ .name = "deliver to an answer", .expected = framed, .message = .{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = answer } },
        .args = &ping,
        .answer = .from(4),
        .resolve_me_desc = resolver,
    } } },
    .{ .name = "resolve fulfill", .expected = v1_0_only, .message = .{ .resolve = .{
        .answer = answer,
        .resolution = .{ .fulfill = .{ .bytes = "pong" } },
    } } },
    .{ .name = "resolve fulfill handoff", .expected = v1_0_only, .message = .{ .resolve = .{
        .answer = answer,
        .resolution = .{ .fulfill = .{ .handoff = &give } },
    } } },
    .{ .name = "resolve break", .expected = v1_0_only, .message = .{ .resolve = .{
        .answer = answer,
        .resolution = .{ .@"break" = .{ .message = "fail" } },
    } } },
    .{ .name = "gc export", .expected = framed, .message = .{ .gc_export = .{
        .positions = &.{ 2, 3 },
        .deltas = &.{ 1, 1 },
    } } },
    .{ .name = "gc answer", .expected = framed, .message = .{ .gc_answer = .{
        .positions = &.{ 1, 4, 9 },
    } } },
    .{ .name = "start session", .expected = framed, .message = .{ .start_session = .{
        .captp_version = .v1_0,
        .session_pubkey = .{ .bytes = &filled(32, 0x09) },
        .acceptable_location = .{
            .transport = locator.transport,
            .designator = locator.designator,
            .hints = model.Hints.emptyFalse(),
        },
        .acceptable_location_sig = .{ .bytes = &filled(64, 0x0a) },
    } } },
    .{ .name = "abort", .expected = framed, .message = .{ .abort = .{
        .kind = .protocol_error,
        .message = "nope",
    } } },
    .{ .name = "listen settling", .expected = framed, .message = .{ .listen = .{
        .target = target,
        .listener = resolver,
        .mode = .settling_only,
    } } },
    .{ .name = "listen either", .expected = framed, .message = .{ .listen = .{
        .target = target,
        .listener = .{ .far = model.FarRef.object(5) },
        .mode = .shortening_or_settling,
    } } },
    .{ .name = "get", .expected = v1_0_only, .message = .{ .get = .{
        .receiver = target,
        .field = "x",
        .answer = answer,
    } } },
    .{ .name = "index", .expected = v1_0_only, .message = .{ .index = .{
        .receiver = target,
        .index = .{ .integer = 2 },
        .answer = answer,
    } } },
    .{ .name = "untag", .expected = v1_0_only, .message = .{ .untag = .{
        .receiver = target,
        .tag = "t",
        .answer = answer,
    } } },
};

/// One deliver per argument kind, in the form every version accepts, so a
/// refused value cannot hide another.
const values = [_]Case{
    valueCase("bytes", .{ .bytes = "raw" }, framed),
    valueCase("symbol", .{ .symbol = "sym" }, framed),
    valueCase("string", .{ .string = "text" }, framed),
    valueCase("keyword", .{ .keyword = "key" }, framed),
    valueCase("integer", .{ .integer = -7 }, framed),
    valueCase("big integer", .{ .big_integer = .{
        .negative = true,
        .digits = "123456789012345678901234567890",
    } }, framed),
    valueCase("float64", .{ .float64 = 1.5 }, framed),
    valueCase("boolean", .{ .boolean = true }, framed),
    valueCase("void", .void, framed),
    valueCase("error", .{ .@"error" = .{ .message = "broke" } }, framed),
    valueCase("list", .{ .list = &integers }, framed),
    valueCase("set", .{ .set = &members }, framed),
    valueCase("tagged", .{ .tagged = .{ .tag = "t", .value = &tagged } }, framed),
    valueCase("struct", .{ .@"struct" = &entries }, framed),
    valueCase("handoff give", .{ .handoff = &give }, framed),
    valueCase("handoff receive", .{ .handoff = &receive }, framed),
    valueCase("near object", .{ .reference = .{ .near = model.NearRef.object(6) } }, framed),
    valueCase("near promise", .{ .reference = .{ .near = model.NearRef.promise(6) } }, framed),
    valueCase("far object", .{ .reference = .{ .far = model.FarRef.object(6) } }, framed),
    valueCase("far promise", .{ .reference = .{ .far = model.FarRef.promise(6) } }, framed),
    valueCase("answer promise", .{ .reference = .{ .promise = .{ .answer_position = answer } } }, framed),
    valueCase("sturdy", .{ .reference = .{ .sturdy = &sturdy } }, framed),
    // Node-local, so no codec writes it.
    valueCase("routed", .{ .reference = .{ .routed = .{ .id = .from(6) } } }, refused),
    // Sent as a `break` resolution, never as a value.
    valueCase("broken", .{ .reference = .{ .broken = .{ .message = "gone" } } }, refused),
};

fn valueCase(comptime name: []const u8, comptime argument: model.Argument, comptime expected: Expected) Case {
    const args = [_]model.Argument{argument};
    return .{ .name = "value " ++ name, .expected = expected, .message = .{ .deliver = .{
        .target = target,
        .args = &args,
        .answer = answer,
        .resolve_me_desc = resolver,
    } } };
}

const corpus = operations ++ values;

comptime {
    @setEvalBranchQuota(200_000);
    var coverage: Coverage = .{};
    for (corpus) |case| coverage.add(case.message);
    coverage.require();
}

/// The tags of each union the corpus reaches, at any depth.
const Coverage = struct {
    message: std.EnumSet(std.meta.Tag(model.Message)) = .{},
    argument: std.EnumSet(std.meta.Tag(model.Argument)) = .{},
    reference: std.EnumSet(std.meta.Tag(model.Reference)) = .{},
    handoff: std.EnumSet(std.meta.Tag(model.Handoff)) = .{},
    resolution: std.EnumSet(std.meta.Tag(model.Resolution)) = .{},

    fn add(comptime coverage: *Coverage, comptime node: anytype) void {
        switch (@typeInfo(@TypeOf(node))) {
            .@"struct" => |info| {
                inline for (info.field_names) |name| coverage.add(@field(node, name));
            },
            .@"union" => |info| {
                const Tag = info.tag_type orelse return;
                inline for (@typeInfo(Coverage).@"struct".field_names) |name| {
                    if (@FieldType(Coverage, name).Key == Tag) @field(coverage, name).insert(node);
                }
                switch (node) {
                    inline else => |payload| coverage.add(payload),
                }
            },
            .optional => {
                if (node) |payload| coverage.add(payload);
            },
            .pointer => |info| switch (info.size) {
                .one => coverage.add(node.*),
                .slice => {
                    // Byte and position slices hold no tagged unions.
                    if (@typeInfo(info.child) == .int) return;
                    for (node) |item| coverage.add(item);
                },
                else => {},
            },
            else => {},
        }
    }

    fn require(comptime coverage: Coverage) void {
        for (@typeInfo(Coverage).@"struct".field_names) |name| {
            const tags = @field(coverage, name);
            for (std.enums.values(@TypeOf(tags).Key)) |tag| {
                if (!tags.contains(tag)) {
                    @compileError("own-wire corpus: no " ++ name ++ " case for ." ++ @tagName(tag));
                }
            }
        }
    }
};

const Pair = struct { version: model.CaptpVersion, codec: codec.registry.Spec };

/// The (version, codec) pairs whose bytes glowcap alone defines.
const owned_pairs = pairs: {
    var pairs: []const Pair = &.{};
    for (std.enums.values(model.CaptpVersion)) |version| {
        for (codec.registry.active) |spec| {
            if (version.ownedByGlowcap() or spec.id.ownedByGlowcap()) {
                pairs = pairs ++ [_]Pair{.{ .version = version, .codec = spec }};
            }
        }
    }
    if (pairs.len == 0) @compileError("own-wire corpus: glowcap owns no wire");
    break :pairs pairs;
};

/// SHA-256 over length-prefixed fields, so field boundaries are unambiguous.
const Transcript = struct {
    sha256: std.crypto.hash.sha2.Sha256 = .init(.{}),

    fn append(transcript: *Transcript, bytes: []const u8) void {
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(bytes.len), .little);
        transcript.sha256.update(&len);
        transcript.sha256.update(bytes);
    }
};

fn generate(gpa: std.mem.Allocator) ![]u8 {
    var transcript: Transcript = .{};
    inline for (owned_pairs) |pair| {
        for (corpus) |case| {
            const expected = case.expected.get(pair.version);
            transcript.append(pair.version.wireString());
            transcript.append(@tagName(pair.codec.id));
            transcript.append(case.name);
            if (pair.codec.module.encodeMessageForProfile(gpa, pair.version, case.message)) |frame_owned| {
                var frame = frame_owned;
                defer frame.deinit();
                if (expected == .refused) return outcomeMismatch(pair, case, "framed");
                transcript.append("framed");
                transcript.append(frame.bytes());
            } else |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                if (expected == .framed) return outcomeMismatch(pair, case, @errorName(err));
                transcript.append("refused");
                transcript.append(@errorName(err));
            }
        }
    }
    const digest = transcript.sha256.finalResult();
    const fingerprint = std.fmt.bytesToHex(digest[0..8].*, .lower);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa,
        \\//! GENERATED by `zig build gen-own-wire` from `tools/gen/own_wire.zig`.
        \\//! Do not edit. `zig build gen-own-wire-check` keeps this fresh.
        \\
        \\/// The first 64 bits of SHA-256 over every frame of glowcap's own wire
        \\/// in the generator's corpus, in lowercase hex (ADR-0001). The hint
        \\/// tokens of a CapTP version or codec that glowcap owns carry it.
        \\pub const fingerprint = "{s}";
        \\
    , .{&fingerprint});
    return out.toOwnedSlice(gpa);
}

fn outcomeMismatch(comptime pair: Pair, case: Case, got: []const u8) error{OutcomeMismatch} {
    std.log.err("{s}/{s} \"{s}\": expected {s}, got {s}", .{
        pair.version.wireString(), @tagName(pair.codec.id), case.name, @tagName(case.expected.get(pair.version)), got,
    });
    return error.OutcomeMismatch;
}
