//! Bounded, versioned managed access record encoding. Database execution is separate.
pub const ResourceRecord = @import("resource_record.zig").ResourceRecord;
pub const GrantRecord = @import("grant_record.zig").GrantRecord;
pub const ChangeRecord = @import("change_record.zig").ChangeRecord;
pub const OwnerRecord = @import("owner_record.zig").OwnerRecord;
pub const DirectoryPage = @import("directory_page.zig").DirectoryPage;
pub const profile = @import("profile.zig");
pub const CapabilityRecord = @import("capability_record.zig").CapabilityRecord;
pub const EndpointRecord = @import("endpoint_record.zig").EndpointRecord;
pub const DerivationRecord = @import("derivation_record.zig").DerivationRecord;
