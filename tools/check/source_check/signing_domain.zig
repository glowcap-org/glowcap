//! Every durable-key signature in `src/` is a registered, fixed-shape record,
//! and the Ed25519-to-X25519 bridge stays behind its named door.
//!
//! ADR-0107 accepts one cross-protocol hazard knowingly: the durable Ed25519
//! key both signs records and, mapped to X25519, runs the Noise handshake's
//! key agreement. That reuse is safe while everything the key signs is a
//! fixed-shape record under a known constructor, and it stops being safe the
//! day some site signs attacker-shaped bytes. This check is the mechanical
//! bound the ADR's step 2 calls for: a new signing site, a bare secret-key
//! read, or a conversion outside the wrappers fails the build and forces the
//! conversation instead of quietly widening what the key vouches for.
//!
//! Three rules, each a spelling scan with the same limits as every other scan
//! in this driver (an alias can evade a grep; the header of each rule names
//! the spelling it holds):
//!
//! 1. Every `crypto.sign(` site in `src/` sits in a registered file with the
//!    registered site count, and each row names the `codec.signed` constructor
//!    whose canonical bytes it signs.
//! 2. Outside the one `Node.sessionSecret` seam, `.secretKey()` appears only
//!    as `.secretKey().publicKey()`: identity derivation, never signing
//!    material.
//! 3. `fromEd25519(` and `publicKeyFromEd25519(` appear only in
//!    `foundation/crypto.zig`, and the wrappers built on them
//!    (`x25519FromPeerKey`, `x25519FromSecretKey`) are called only from files
//!    registered as channel owners.
//!
//! Validated against injected defects on 2026-08-09: a sixth `crypto.sign(`
//! in an unregistered file, a count drift in a registered file, a bare
//! `.secretKey()` outside the seam, and a `publicKeyFromEd25519(` call outside
//! `foundation/crypto.zig` were each injected and each failed the build; the
//! healthy tree passes.

const std = @import("std");
const util = @import("util.zig");

const appendViolation = util.appendViolation;

/// One file allowed to call `crypto.sign`, with the exact number of sites and
/// what each signs. A row is one authority: adding a site edits the count
/// here, in the same diff, with the record shape named.
const SigningFile = struct {
    /// Path under `src/`.
    file: []const u8,
    /// How many `crypto.sign(` sites the file carries.
    sites: usize,
    /// The fixed-shape record those sites sign, by its constructor.
    record: []const u8,
};

const signing_files = [_]SigningFile{
    .{
        .file = "ocapn/engine/hello.zig",
        .sites = 1,
        .record = "codec.signed.locationBytes: the hello's acceptable-location signature over the canonical advertised locator.",
    },
    .{
        .file = "ocapn/engine/pairing.zig",
        .sites = 2,
        .record = "codec.signed.locationBytes: both in-process peers' hello signatures in the pairing harness.",
    },
    .{
        .file = "ocapn/engine/handoff_gifter.zig",
        .sites = 1,
        .record = "codec.signed.wrapGive over giveBytes: the desc:handoff-give certificate.",
    },
    .{
        .file = "ocapn/engine/handoff_recipient.zig",
        .sites = 1,
        .record = "codec.signed.receiveBytes: the desc:handoff-receive certificate.",
    },
    .{
        .file = "foundation/sealed_identity.zig",
        .sites = 1,
        .record = "sealed_identity.statement: domain, role, initial transcript, exact Ed25519 identity, and authenticated X25519 static.",
    },
};

/// Files that may read a secret key as signing material without the
/// `.publicKey()` projection. Node owns session-signing derivation; the Host
/// session constructor borrows the durable key only to build the sealed
/// channel's registered identity proof.
const secret_seam_files = [_][]const u8{
    "ocapn/engine/node.zig",
    "driver/core/sessions.zig",
};

/// The one file that may touch the Ed25519-to-X25519 map directly.
const bridge_home = "foundation/crypto.zig";

/// Files that may call the conversion wrappers. `foundation/crypto.zig`
/// declares them; `foundation.sealed` constructs the Noise channel from the
/// local and named remote keys, while `foundation.sealed_identity` verifies
/// the remote mapping bound into the signed proof. Runtime tiers compose that
/// pair without receiving conversion authority.
const wrapper_callers = [_][]const u8{
    "foundation/crypto.zig",
    "foundation/sealed.zig",
    "foundation/sealed_identity.zig",
};

fn inList(list: []const []const u8, file: []const u8) bool {
    for (list) |entry| {
        if (std.mem.eql(u8, entry, file)) return true;
    }
    return false;
}

fn signingSites(file: []const u8) ?usize {
    for (signing_files) |row| {
        if (std.mem.eql(u8, row.file, file)) return row.sites;
    }
    return null;
}

/// Count needle hits on non-comment lines.
fn countOnCode(contents: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "//")) continue;
        var rest = line;
        while (std.mem.indexOf(u8, rest, needle)) |at| {
            count += 1;
            rest = rest[at + needle.len ..];
        }
    }
    return count;
}

/// Whether any non-comment line holds `needle` without `qualified` covering
/// that same hit, e.g. a `.secretKey()` that is not `.secretKey().publicKey()`.
fn findUnqualified(contents: []const u8, needle: []const u8, qualified: []const u8) bool {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "//")) continue;
        var rest = line;
        while (std.mem.indexOf(u8, rest, needle)) |at| {
            if (!std.mem.startsWith(u8, rest[at..], qualified)) return true;
            rest = rest[at + needle.len ..];
        }
    }
    return false;
}

/// The durable-key signing and conversion discipline over `src/`, both
/// directions: every site registered, every registered row still real.
pub fn checkSigningDomains(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var seen_counts: std.StringHashMap(usize) = .init(gpa);
    defer {
        var it = seen_counts.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        seen_counts.deinit();
    }

    var dir = root.openDir(io, "src", .{ .iterate = true }) catch return;
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const rel = entry.path;
        const path = try std.fmt.allocPrint(gpa, "src/{s}", .{rel});
        defer gpa.free(path);
        const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch continue;
        defer gpa.free(contents);

        // Rule 1: registered signing sites only, at the registered count.
        // The needle also covers the `foundation.crypto.sign(` form.
        const sign_hits = countOnCode(contents, "crypto.sign(");
        if (sign_hits > 0) {
            if (signingSites(rel)) |expected| {
                if (sign_hits != expected) {
                    try appendViolation(gpa, violations, "src/{s}: {d} `crypto.sign(` sites, but tools/check/source_check/signing_domain.zig registers {d}. A durable-key signature signs a fixed-shape record under a named constructor; update the row in the same diff as the site.", .{ rel, sign_hits, expected });
                }
                const key = try gpa.dupe(u8, rel);
                if (seen_counts.contains(key)) gpa.free(key) else try seen_counts.put(key, sign_hits);
            } else {
                try appendViolation(gpa, violations, "src/{s}: `crypto.sign(` outside the registered signing files. The durable key signs only fixed-shape records; register the file and its record shape in tools/check/source_check/signing_domain.zig or route the signature through an existing seam.", .{rel});
            }
        }

        // Rule 2: outside the sessionSecret seam, a secret key surfaces only
        // to derive its public half.
        if (!inList(&secret_seam_files, rel)) {
            if (findUnqualified(contents, ".secretKey()", ".secretKey().publicKey()")) {
                try appendViolation(gpa, violations, "src/{s}: `.secretKey()` without an immediate `.publicKey()`. Signing material flows through `Node.sessionSecret` (the one registered seam); anything else reads only the public half.", .{rel});
            }
        }

        // Rule 3: the Ed25519-to-X25519 map and its wrappers stay confined.
        if (!std.mem.eql(u8, rel, bridge_home)) {
            if (countOnCode(contents, "fromEd25519(") > 0 or countOnCode(contents, "publicKeyFromEd25519(") > 0) {
                try appendViolation(gpa, violations, "src/{s}: direct Ed25519-to-X25519 conversion outside {s}. The bridge has one home so the key-reuse hazard ADR-0107 accepts stays inspectable; call `crypto.x25519FromPeerKey` / `crypto.x25519FromSecretKey` from a registered channel file instead.", .{ rel, bridge_home });
            }
            if (countOnCode(contents, ".keypair.sign(") > 0) {
                try appendViolation(gpa, violations, "src/{s}: raw Ed25519 signing outside {s}. Every signature goes through `crypto.sign` so rule 1 can see it.", .{ rel, bridge_home });
            }
            if (!inList(&wrapper_callers, rel)) {
                if (countOnCode(contents, "x25519FromPeerKey(") > 0 or countOnCode(contents, "x25519FromSecretKey(") > 0) {
                    try appendViolation(gpa, violations, "src/{s}: durable-key X25519 conversion outside the registered channel files. Register the file in tools/check/source_check/signing_domain.zig `wrapper_callers` in the same diff that gives it a sealed channel to own.", .{rel});
                }
            }
        }
    }

    // The other direction: a registered signing file that no longer signs is
    // a stale entry vouching for nothing.
    for (signing_files) |row| {
        if (!seen_counts.contains(row.file)) {
            try appendViolation(gpa, violations, "tools/check/source_check/signing_domain.zig: `signing_files` still lists src/{s}, which has no `crypto.sign(` site. Drop the row or fix the path.", .{row.file});
        }
    }
}
