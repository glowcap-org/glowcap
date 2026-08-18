const std = @import("std");
const shared = @import("c_abi_shared");

test "archive fingerprints separate sources and source boundaries" {
    try std.testing.expect(shared.archive_contract.fingerprint("archive-a", "symbols") != shared.archive_contract.fingerprint("archive-b", "symbols"));
    try std.testing.expect(shared.archive_contract.fingerprint("archive", "symbols-a") != shared.archive_contract.fingerprint("archive", "symbols-b"));
}
