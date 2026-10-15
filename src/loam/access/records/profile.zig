//! Schema identities for managed records inside a shared Loam store.
const records = @import("loam_records");
pub const owner: u64 = 0x6163636573730001;
pub const directory: u64 = 0x6163636573730002;
pub const resource: u64 = 0x6163636573730003;
pub const grant: u64 = 0x6163636573730004;
pub const capability: u64 = 0x6163636573730006;
pub const endpoint: u64 = 0x6163636573730007;
pub const derivation: u64 = 0x6163636573730008;
pub const mutation: u64 = 0x6163636573730009;
pub const change_history: u64 = 0x616363657373000a;
pub const change_batch: u64 = 0x616363657373000b;
pub const observation: u64 = 0x616363657373000c;
pub const observation_index: u64 = 0x616363657373000d;
pub const observation_endpoint: u64 = 0x616363657373000e;
pub const terminal: u64 = 0x616363657373000f;
pub const schemas = [_]records.Schema{
    .{ .id = terminal, .version = 1, .max_payload = @import("terminal_record.zig").TerminalRecord.max_encoded_bytes, .max_edges = 0 },
    .{ .id = owner, .version = 1, .max_payload = @import("owner_record.zig").OwnerRecord.max_encoded_bytes, .max_edges = @import("owner_record.zig").OwnerRecord.max_edges },
    .{ .id = directory, .version = 1, .max_payload = 192, .max_edges = 256 },
    .{ .id = resource, .version = 1, .max_payload = @import("resource_record.zig").ResourceRecord.max_encoded_bytes, .max_edges = 2 },
    .{ .id = grant, .version = @import("grant_record.zig").GrantRecord.format_version, .max_payload = @import("grant_record.zig").GrantRecord.max_encoded_bytes, .max_edges = @import("grant_record.zig").GrantRecord.max_edges },
    .{ .id = capability, .version = @import("capability_record.zig").CapabilityRecord.version, .max_payload = @import("capability_record.zig").CapabilityRecord.max_encoded_bytes, .max_edges = 3 },
    .{ .id = endpoint, .version = @import("endpoint_record.zig").EndpointRecord.version, .max_payload = @import("endpoint_record.zig").EndpointRecord.max_encoded_bytes, .max_edges = @import("endpoint_record.zig").EndpointRecord.max_edges },
    .{ .id = derivation, .version = 1, .max_payload = @import("derivation_record.zig").DerivationRecord.max_encoded_bytes, .max_edges = 3 },
    .{ .id = mutation, .version = 1, .max_payload = @import("mutation_record.zig").MutationRecord.max_encoded_bytes, .max_edges = @import("mutation_record.zig").MutationRecord.max_edges },
    .{ .id = change_history, .version = 1, .max_payload = @import("change_history_record.zig").ChangeHistoryRecord.max_encoded_bytes, .max_edges = @import("change_history_record.zig").ChangeHistoryRecord.capacity },
    .{ .id = change_batch, .version = 1, .max_payload = @import("change_batch_record.zig").ChangeBatchRecord.max_encoded_bytes, .max_edges = 0 },
    .{ .id = observation, .version = 1, .max_payload = @import("observation_record.zig").ObservationRecord.max_encoded_bytes, .max_edges = @import("observation_record.zig").ObservationRecord.max_edges },
    .{ .id = observation_index, .version = 1, .max_payload = @import("observation_index_record.zig").ObservationIndexRecord.max_encoded_bytes, .max_edges = @import("observation_index_record.zig").ObservationIndexRecord.capacity },
    .{ .id = observation_endpoint, .version = 1, .max_payload = @import("observation_endpoint_record.zig").ObservationEndpointRecord.max_encoded_bytes, .max_edges = 1 },
};
