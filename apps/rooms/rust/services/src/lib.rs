//! Rooms service composition over portable policy and explicit host effects.
pub mod announce;
pub mod archive;
#[cfg(feature = "processes")]
use rooms_runtime::cleanup;
#[cfg(feature = "processes")]
pub mod chat;
pub mod documents;
#[cfg(all(test, feature = "processes"))]
mod front_options;
#[cfg(feature = "processes")]
pub mod irc;
#[cfg(feature = "processes")]
pub mod irc_bridge;
#[cfg(feature = "processes")]
pub mod irc_server;
pub mod media_files;
#[cfg(feature = "processes")]
pub mod server;
#[cfg(feature = "processes")]
pub mod trace_view;
#[cfg(feature = "processes")]
pub mod web;

#[cfg(feature = "processes")]
pub mod session;
pub mod session_archive;

/// A listener's address for clients in the same network namespace.
/// Wildcard binds are reached through loopback in the same address family.
#[cfg(feature = "processes")]
pub(crate) fn local_address(mut address: std::net::SocketAddr) -> std::net::SocketAddr {
	if address.ip().is_unspecified() {
		address.set_ip(if address.is_ipv4() {
			std::net::Ipv4Addr::LOCALHOST.into()
		} else {
			std::net::Ipv6Addr::LOCALHOST.into()
		});
	}
	address
}
