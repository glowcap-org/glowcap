//! Managed endpoints on the existing durable Host attachment. No I/O owner.
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
