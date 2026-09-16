//! Record-backed durable actors, using the existing Host and Vat.
pub const Attachment = @import("attachment.zig").Attachment;
pub const Options = @import("attachment.zig").Options;
pub const Stats = @import("attachment.zig").Stats;
pub const Work = @import("attachment.zig").Work;
pub const Behavior = @import("behavior.zig").Behavior;
pub const Call = @import("behavior.zig").Call;
pub const Preparation = @import("preparation.zig").Preparation;
pub const publication = @import("publication.zig");
