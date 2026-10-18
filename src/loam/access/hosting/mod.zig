//! Managed endpoints on the existing durable Host attachment. No I/O owner.
const hosting = @import("loam_hosting");
const records = @import("loam_access_records");
const loam = @import("loam_core");
pub const Service = @import("service.zig").Service;
pub const ContentBehavior = @import("service.zig").ContentBehavior;
pub const ContentCall = @import("service.zig").ContentCall;
pub const ForwardWork = @import("service.zig").ForwardWork;
pub const ContentInvocation = @import("service.zig").ContentInvocation;
pub const graph = @import("content_graph.zig");
pub const graphAllocationBound = @import("working.zig").graphAllocationBound;
pub const InvocationBounds = @import("working.zig").InvocationBounds;
pub const invocationAllocationBound = @import("working.zig").invocationAllocationBound;
pub const GraphPage = @import("service.zig").GraphPage;
pub const GraphField = @import("service.zig").GraphField;
pub const stageEndpoint = @import("service.zig").stageEndpoint;
pub const stageDerivedEndpoint = @import("service.zig").stageDerivedEndpoint;
pub const stagePublication = @import("service.zig").stagePublication;
pub const RetryMode = @import("service.zig").RetryMode;
pub const Participant = @import("service.zig").Participant;
pub const ParticipantView = @import("service.zig").ParticipantView;
pub const ResourceEffect = @import("service.zig").ResourceEffect;
pub const Creation = @import("service.zig").Creation;
pub const max_participants = @import("service.zig").max_participants;
pub const Owner = @import("owner.zig").Owner;
pub const StagedOwner = @import("owner.zig").Staged;
pub const stageOwner = @import("owner.zig").stageOwner;
pub const vocabulary = @import("vocabulary.zig");
/// The records every managed hosting store declares beside its application
/// content schemas.
pub const system_schemas = records.profile.schemas ++ [_]loam.Schema{ hosting.publication.schema, hosting.references.schema, hosting.LiveEpoch.schema };
