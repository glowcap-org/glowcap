//! Managed endpoints on the existing durable Host attachment; no I/O owner.
pub const Service = @import("service.zig").Service;
pub const ContentBehavior = @import("service.zig").ContentBehavior;
pub const ContentCall = @import("service.zig").ContentCall;
pub const stageEndpoint = @import("service.zig").stageEndpoint;
pub const stageDerivedEndpoint = @import("service.zig").stageDerivedEndpoint;
pub const stagePublication = @import("service.zig").stagePublication;
pub const RetryMode = @import("service.zig").RetryMode;
