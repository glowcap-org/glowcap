//! Schema identities for managed records inside a shared Loam store.
const records = @import("loam_records");
pub const owner: u64 = 0x6163636573730001;
pub const directory: u64 = 0x6163636573730002;
pub const resource: u64 = 0x6163636573730003;
pub const grant: u64 = 0x6163636573730004;
pub const change: u64 = 0x6163636573730005;
pub const capability: u64 = 0x6163636573730006;
pub const endpoint: u64 = 0x6163636573730007;
pub const derivation: u64 = 0x6163636573730008;
pub const schemas = [_]records.Schema{
    .{ .id = owner, .version = 1, .max_payload = 4096, .max_edges = 3 },
    .{ .id = directory, .version = 1, .max_payload = 192, .max_edges = 256 },
    .{ .id = resource, .version = 1, .max_payload = @import("resource_record.zig").ResourceRecord.max_encoded_bytes, .max_edges = 1 },
    .{ .id = grant, .version = 1, .max_payload = @import("grant_record.zig").GrantRecord.max_encoded_bytes, .max_edges = 514 },
    .{ .id = change, .version = 1, .max_payload = @import("change_record.zig").ChangeRecord.max_encoded_bytes, .max_edges = 1 },
    .{ .id = capability, .version = 1, .max_payload = @import("capability_record.zig").CapabilityRecord.max_encoded_bytes, .max_edges = 2 },
    .{ .id = endpoint, .version = @import("endpoint_record.zig").EndpointRecord.version, .max_payload = @import("endpoint_record.zig").EndpointRecord.max_encoded_bytes, .max_edges = @import("endpoint_record.zig").EndpointRecord.max_edges },
    .{ .id = derivation, .version = 1, .max_payload = @import("derivation_record.zig").DerivationRecord.max_encoded_bytes, .max_edges = 2 },
};
