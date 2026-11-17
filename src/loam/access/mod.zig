//! Resource structure, managed grants, durable owner storage, and managed
//! capability hosting for applications. Core, codecs, and storage participants
//! perform no I/O. Loam owns shared transactions and residency.

const internal_records = @import("loam_access_records");

pub const core = @import("loam_access_core");
/// The record types an application reads and writes. The internal module also
/// holds helpers the access layer shares and does not publish.
pub const records = struct {
    pub const ResourceRecord = internal_records.ResourceRecord;
    pub const GrantRecord = internal_records.GrantRecord;
    pub const ChangeHistoryRecord = internal_records.ChangeHistoryRecord;
    pub const ChangeBatchRecord = internal_records.ChangeBatchRecord;
    pub const OwnerRecord = internal_records.OwnerRecord;
    pub const DirectoryPage = internal_records.DirectoryPage;
    pub const profile = internal_records.profile;
    pub const CapabilityRecord = internal_records.CapabilityRecord;
    pub const EndpointRecord = internal_records.EndpointRecord;
    pub const DerivationRecord = internal_records.DerivationRecord;
    pub const RetryWindow = internal_records.RetryWindow;
    pub const MutationRecord = internal_records.MutationRecord;
    pub const ValueRecord = internal_records.ValueRecord;
    pub const ObservationRecord = internal_records.ObservationRecord;
    pub const ObservationIndexRecord = internal_records.ObservationIndexRecord;
    pub const ObservationEndpointRecord = internal_records.ObservationEndpointRecord;
    pub const ChangeStamp = internal_records.ChangeStamp;
    pub const MaintenancePosition = internal_records.MaintenancePosition;
    pub const TerminalRecord = internal_records.TerminalRecord;
};
pub const storage = @import("loam_access_storage");
pub const hosting = @import("loam_access_hosting");
