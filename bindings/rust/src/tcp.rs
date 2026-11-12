//! TCP profile locators and optional FFI transport.
//!
//! Locator construction requires no socket provider. The `tcp` feature adds
//! the blocking frame transport. `tcp` plus `async` adds runtime integration.

#[cfg(all(feature = "tcp", feature = "async"))]
use crate::Result;
use crate::{HintValue, HintWireForm, Locator};

#[cfg(feature = "tcp")]
mod transport;
#[cfg(all(feature = "tcp", feature = "async"))]
pub(crate) use transport::ensure_loop_provider;
#[cfg(feature = "tcp")]
pub use transport::{
	Config, Connection, ConnectionShutdown, Keepalive, Listener, ListenerShutdown, Netlayer, Profiles, StreamOptions,
};
#[cfg(all(feature = "tcp", feature = "async"))]
pub use transport::{OperationOptions, provider};

#[cfg(all(feature = "tcp", feature = "async"))]
pub use crate::ListenerIdentity;
#[cfg(all(feature = "tcp", feature = "async"))]
pub use crate::tcp_listen::{ListenOptions, Server};

/// Bind the plain TCP profile through this package's FFI provider.
#[cfg(all(feature = "tcp", feature = "async"))]
pub async fn listen(bind_host: &str, port: u16, options: ListenOptions) -> Result<Server> {
	crate::tcp_listen::listen(bind_host, port, crate::TRANSPORT_TCP, Profiles::TCP, options).await
}

/// Spell a TCP `host:port` designator, including IPv6 brackets.
pub fn address_designator(host: &str, port: u16) -> String {
	if host.contains(':') && !(host.starts_with('[') && host.ends_with(']')) {
		format!("[{host}]:{port}")
	} else {
		format!("{host}:{port}")
	}
}

/// Build the plain TCP profile's typed OCapN locator.
pub fn locator(host: &str, port: u16) -> Locator {
	Locator {
		transport: crate::TRANSPORT_TCP.to_string(),
		designator: address_designator(host, port),
		hints: std::collections::BTreeMap::new(),
		hint_wire_form: HintWireForm::BooleanFalse,
	}
}

fn key_addressed_locator(transport: &str, designator: &str, host: &str, port: u16) -> Locator {
	let mut hints = std::collections::BTreeMap::new();
	hints.insert(
		crate::HINT_DIRECT_ADDRESSES.to_string(),
		HintValue::String(address_designator(host, port)),
	);
	Locator {
		transport: transport.to_string(),
		designator: designator.to_string(),
		hints,
		hint_wire_form: HintWireForm::Map,
	}
}

/// Identity-addressed cleartext over this TCP package.
pub mod keyed {
	#[cfg(all(feature = "tcp", feature = "async"))]
	use super::{ListenOptions, Profiles, Server};
	use crate::Locator;
	#[cfg(all(feature = "tcp", feature = "async"))]
	use crate::Result;

	pub fn locator(designator: &str, host: &str, port: u16) -> Locator {
		super::key_addressed_locator(crate::TRANSPORT_KEYED_TCP, designator, host, port)
	}

	/// Bind identity-addressed cleartext through this package's FFI provider.
	#[cfg(all(feature = "tcp", feature = "async"))]
	pub async fn listen(bind_host: &str, port: u16, options: ListenOptions) -> Result<Server> {
		crate::tcp_listen::listen(
			bind_host,
			port,
			crate::TRANSPORT_KEYED_TCP,
			Profiles::KEYED_TCP,
			options,
		)
		.await
	}
}

/// Noise_XK-sealed streams over this TCP package.
pub mod noise {
	#[cfg(all(feature = "tcp", feature = "async"))]
	use super::{ListenOptions, Profiles, Server};
	use crate::Locator;
	#[cfg(all(feature = "tcp", feature = "async"))]
	use crate::Result;

	pub fn locator(designator: &str, host: &str, port: u16) -> Locator {
		super::key_addressed_locator(crate::TRANSPORT_NOISE_TCP, designator, host, port)
	}

	/// Bind Noise_XK-sealed streams through this package's FFI provider.
	#[cfg(all(feature = "tcp", feature = "async"))]
	pub async fn listen(bind_host: &str, port: u16, options: ListenOptions) -> Result<Server> {
		crate::tcp_listen::listen(
			bind_host,
			port,
			crate::TRANSPORT_NOISE_TCP,
			Profiles::NOISE_TCP,
			options,
		)
		.await
	}
}

#[cfg(test)]
mod tests {
	use super::{address_designator, keyed, locator, noise};

	#[test]
	fn ipv6_hosts_keep_their_brackets_in_every_locator() {
		assert_eq!(address_designator("::1", 4242), "[::1]:4242");
		assert_eq!(address_designator("[::1]", 4242), "[::1]:4242");
		assert_eq!(address_designator("127.0.0.1", 4242), "127.0.0.1:4242");
		assert_eq!(locator("::1", 4242).designator, "[::1]:4242");
		assert_eq!(locator("127.0.0.1", 4242).designator, "127.0.0.1:4242");
		for build in [keyed::locator, noise::locator] {
			let v6 = build("peer", "::1", 4242);
			assert_eq!(
				v6.string_hint(crate::HINT_DIRECT_ADDRESSES).expect("string hint"),
				Some("[::1]:4242")
			);
			let v4 = build("peer", "127.0.0.1", 4242);
			assert_eq!(
				v4.string_hint(crate::HINT_DIRECT_ADDRESSES).expect("string hint"),
				Some("127.0.0.1:4242")
			);
		}
	}
}
