//! Owning one-call driver facade.
//!
//! The public surface stays here while its private subjects live under the
//! session directory: client session ownership, shared runtime leasing, and
//! server admission. All three ride the same driver_core.Host and HostRuntime;
//! this split introduces no second runtime or protocol authority.

const client = @import("session/client.zig");
const server = @import("session/server.zig");

pub const Promise = client.Promise;
pub const SessionOptions = client.SessionOptions;
pub const Session = client.Session;
pub const connect = client.connect;
pub const connectProviders = @import("session/connect.zig").connectProviders;
pub const connectUriOwned = client.connectUriOwned;

pub const Server = server.Server;
pub const listen = server.listen;
pub const listenProviders = server.listenProviders;
