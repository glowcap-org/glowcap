//! Build-derived identity for one separately loaded C archive's callable
//! surface. A binding checks this value before its first call into the archive,
//! so source and shared provider-contract drift is a typed load refusal rather
//! than an invocation through an incompatible C signature.

const offset_basis: u64 = 14695981039346656037;
const prime: u64 = 1099511628211;

fn mix(hash: *u64, bytes: []const u8) void {
    for (bytes) |byte| {
        hash.* ^= byte;
        hash.* *%= prime;
    }
    // Preserve source boundaries: concatenating ["ab", "c"] must not name
    // the same contract as ["a", "bc"].
    hash.* ^= 0xff;
    hash.* *%= prime;
}

/// Fingerprint one archive's source plus every shared C layout/callback source
/// its exports exchange. This deliberately follows source rather than a
/// hand-bumped version: a changed function or shared table cannot ship with an
/// unchanged value. Formatting-only changes may require rebuilding companions;
/// that conservative refusal is preferable to calling across uncertain ABIs.
pub fn fingerprint(comptime archive_source: []const u8, comptime symbols_source: []const u8) u64 {
    return fingerprintParts(&.{archive_source}, symbols_source);
}

/// Variant for an archive whose callable contract has been split into focused
/// source files. Every part that owns an exported layout or signature belongs
/// in `archive_sources`; internal mechanics deliberately do not.
pub fn fingerprintParts(comptime archive_sources: []const []const u8, comptime symbols_source: []const u8) u64 {
    @setEvalBranchQuota(10_000_000);
    var hash = offset_basis;
    inline for (.{
        @embedFile("mod.zig"),
        @embedFile("locator.zig"),
        @embedFile("multiplexed_transport.zig"),
        @embedFile("transport_provider.zig"),
    }) |source| mix(&hash, source);
    for (archive_sources) |source| mix(&hash, source);
    mix(&hash, symbols_source);
    return hash;
}
