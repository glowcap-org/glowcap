//! Schema identities for managed records inside a shared Loam store.
const records = @import("loam_records");
const terminal_record = @import("terminal_record.zig");
const owner_record = @import("owner_record.zig");
const directory_page = @import("directory_page.zig");
const resource_record = @import("resource_record.zig");
const grant_record = @import("grant_record.zig");
const capability_record = @import("capability_record.zig");
const endpoint_record = @import("endpoint_record.zig");
const derivation_record = @import("derivation_record.zig");
const mutation_record = @import("mutation_record.zig");
const change_history_record = @import("change_history_record.zig");
const change_batch_record = @import("change_batch_record.zig");
const observation_record = @import("observation_record.zig");
const observation_index_record = @import("observation_index_record.zig");
const observation_endpoint_record = @import("observation_endpoint_record.zig");
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
fn schema(id: u64, comptime Record: type) records.Schema {
    return .{ .id = id, .version = @intCast(Record.format_version), .max_payload = Record.max_encoded_bytes, .max_edges = Record.max_edges };
}

pub const schemas = [_]records.Schema{
    schema(terminal, terminal_record.TerminalRecord),
    schema(owner, owner_record.OwnerRecord),
    schema(directory, directory_page.DirectoryPage),
    schema(resource, resource_record.ResourceRecord),
    schema(grant, grant_record.GrantRecord),
    schema(capability, capability_record.CapabilityRecord),
    schema(endpoint, endpoint_record.EndpointRecord),
    schema(derivation, derivation_record.DerivationRecord),
    schema(mutation, mutation_record.MutationRecord),
    schema(change_history, change_history_record.ChangeHistoryRecord),
    schema(change_batch, change_batch_record.ChangeBatchRecord),
    schema(observation, observation_record.ObservationRecord),
    schema(observation_index, observation_index_record.ObservationIndexRecord),
    schema(observation_endpoint, observation_endpoint_record.ObservationEndpointRecord),
};
