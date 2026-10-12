//! IRC as an edge of this server, read as values: the line grammar and the
//! registration a socket driver runs, the channel relay that keeps a feed's
//! membership aligned with its readers, the bridged room a channel becomes,
//! the seat a member holds on it, and the gateway an operator administers
//! as an ordinary bridge gateway. Sockets, timers, TLS, and the file live
//! in the adapter.
pub mod front;
pub mod gateway;
pub mod model;
pub mod protocol;
pub mod registration;
pub mod relay;
pub mod room;
pub mod roster;
pub mod seat;
pub mod wire;

/// How many channels one directory bridges at once.
pub const MAX_BRIDGED_ROOMS: usize = 16;
/// How many members one bridged channel seats on IRC at once. Past it a
/// member still reads. Their posts are refused with the reason.
pub const MAX_READERS_PER_CHANNEL: usize = 32;
/// How many Rooms members one bridged room admits.
pub const VIEWER_LIMIT: usize = 256;
