//! Managed driver and byte-fed connection composition.
//!
//! A [`Runtime`] is the one durable owner of a Host and its transport authority.
//! Providers are installed once into one driver loop; byte-fed connectors
//! are installed once into the Host's transport registry. A connect operation
//! selects only the already-installed transport, so provider construction and
//! connector retention never sit on the wire path.

use std::rc::Rc;

use crate::dial::{dial_with_connector, ConnectOptions};
use crate::driver_loop::{LoopShared, Provider};
use crate::host::Host;
use crate::session::Session;
use crate::{sys, Connector, Error, Locator, PendingWork, Result};

enum Mode {
	Driver(Rc<LoopShared>),
	ByteFed {
		handshake_timeout: Option<std::time::Duration>,
	},
}

enum Composition {
	Providers(Vec<Provider>),
	Connectors(Vec<Connector>),
}

/// Configuration for one managed [`Runtime`].
///
/// A configuration chooses one transport ownership model. Driver providers
/// make the Runtime the owner of one driver loop; connectors retain the
/// embedder's byte-channel callbacks on the Runtime's Host. The configuration
/// owns the selected values until [`Runtime::open`] commits them.
pub struct RuntimeConfig {
	adopt_host: Option<Host>,
	composition: Composition,
	handshake_timeout: Option<std::time::Duration>,
}

impl RuntimeConfig {
	/// Configure a Runtime from transport providers.
	pub fn providers<I>(providers: I) -> Self
	where
		I: IntoIterator<Item = Provider>,
	{
		Self {
			adopt_host: None,
			composition: Composition::Providers(providers.into_iter().collect()),
			handshake_timeout: Some(crate::session::HANDSHAKE_TIMEOUT),
		}
	}

	/// Configure a byte-fed Runtime from retained transport connectors.
	pub fn connectors<I>(connectors: I) -> Self
	where
		I: IntoIterator<Item = Connector>,
	{
		Self {
			adopt_host: None,
			composition: Composition::Connectors(connectors.into_iter().collect()),
			handshake_timeout: Some(crate::session::HANDSHAKE_TIMEOUT),
		}
	}

	/// Adopt an existing quiescent Host as the Runtime's session authority.
	/// The caller retains its handle, including any loop created before a later
	/// provider setup failure, so the same Host can be repaired and retried.
	pub fn adopt_host(mut self, host: &Host) -> Self {
		self.adopt_host = Some(host.clone());
		self
	}

	/// Set the driver handshake budget. A zero duration means unbounded.
	pub fn with_handshake_timeout(mut self, timeout: std::time::Duration) -> Self {
		self.handshake_timeout = Some(timeout);
		self
	}
}

/// One managed Host and one long-lived transport composition.
///
/// `Runtime` has no asynchronous destructor. Dropping it releases the Host and
/// its driver loop through the Host's owner, while [`Runtime::close`] is the
/// explicit async barrier for callers that must know every session and I/O
/// task has stopped.
pub struct Runtime {
	host: Host,
	mode: Mode,
}

fn composition_error(message: impl Into<String>) -> Error {
	Error::with_detail(sys::ERR_INVALID_ARGUMENT, message.into())
}

impl Runtime {
	/// Open a managed Runtime and commit its selected transport composition.
	pub async fn open(config: RuntimeConfig) -> Result<Self> {
		let RuntimeConfig {
			adopt_host,
			composition,
			handshake_timeout,
		} = config;
		let providers = match composition {
			Composition::Providers(providers) => providers,
			Composition::Connectors(connectors) => {
				return Self::open_connectors(adopt_host, handshake_timeout, connectors).await;
			}
		};
		let created_host = adopt_host.is_none();
		let handshake_ms = Self::timeout_millis(handshake_timeout)?;
		let settle_ms = crate::abi_constants::HANDSHAKE_TIMEOUT_MS as u32;
		let (host, loop_) = match adopt_host {
			Some(host) => {
				let loop_ = host.shared().ensure_driver_loop(handshake_ms, settle_ms)?;
				(host, loop_)
			}
			None => {
				let loop_ = LoopShared::open(handshake_ms, settle_ms)?;
				let host = Host::from_shared(loop_.wrapper_host()?);
				(host, loop_)
			}
		};

		let installed = async {
			for provider in &providers {
				provider.install(Rc::clone(&loop_)).await?;
			}
			Ok::<(), Error>(())
		}
		.await;
		if let Err(mut error) = installed {
			if created_host {
				error = crate::retain_cleanup_failure(error, host.close(PendingWork::Cancel).await);
			}
			return Err(error);
		}

		Ok(Self {
			host,
			mode: Mode::Driver(loop_),
		})
	}

	async fn open_connectors(
		host: Option<Host>,
		handshake_timeout: Option<std::time::Duration>,
		connectors: Vec<Connector>,
	) -> Result<Self> {
		let created_host = host.is_none();
		let host = match host {
			Some(host) => host,
			None => Host::with_options(Default::default())?,
		};
		if host.shared().driver_loop().is_some() {
			let mut error = composition_error("a driver-loop Host cannot be transferred to a byte-fed Runtime");
			if created_host {
				error = crate::retain_cleanup_failure(error, host.close(PendingWork::Cancel).await);
			}
			return Err(error);
		}
		if let Err(mut error) = host.install_connectors(&connectors) {
			if created_host {
				error = crate::retain_cleanup_failure(error, host.close(PendingWork::Cancel).await);
			}
			return Err(error);
		}
		Ok(Self {
			host,
			mode: Mode::ByteFed { handshake_timeout },
		})
	}

	/// Convert the public duration to the driver's bounded millisecond
	/// representation. A zero duration is the explicit unbounded form.
	fn timeout_millis(timeout: Option<std::time::Duration>) -> Result<u32> {
		match timeout {
			None => Ok(0),
			Some(timeout) if timeout.is_zero() => Ok(0),
			Some(timeout) => u32::try_from(timeout.as_millis())
				.map(|milliseconds| milliseconds.max(1))
				.map_err(|_| composition_error("handshake timeout exceeds the driver range")),
		}
	}

	/// The Host that owns identity, session state, and handoff authority.
	pub fn host(&self) -> &Host {
		&self.host
	}

	/// Connect through this Runtime's already-installed transport composition.
	pub async fn connect(&self, locator: &Locator, options: ConnectOptions<'_>) -> Result<Session> {
		self.host.shared().guard_handle()?;
		match &self.mode {
			Mode::Driver(loop_) => {
				let transport_options = options.transport_options(locator)?;
				let session = loop_.dial_locator(locator, transport_options).await?;
				crate::driver_loop::loop_session(loop_, session)
			}
			Mode::ByteFed { handshake_timeout } => {
				let transport_options = options.transport_options(locator)?;
				let connector = self.host.shared().connector(&locator.transport).ok_or_else(|| {
					composition_error(format!(
						"Runtime has no connector for transport {:?}",
						locator.transport
					))
				})?;
				dial_with_connector(
					connector,
					locator,
					self.host.clone(),
					false,
					transport_options,
					*handshake_timeout,
				)
				.await
			}
		}
	}

	/// Close all sessions and release the Runtime's driver transport authority.
	pub async fn close(&self, pending: PendingWork) -> Result<()> {
		self.host.close(pending).await
	}
}

#[cfg(all(test, feature = "tcp"))]
mod tests {
	use super::*;
	use std::cell::RefCell;
	use std::rc::Rc;

	#[test]
	fn construction_cleanup_retains_primary_and_secondary_errors() {
		let primary = Error::with_detail(sys::ERR_INTERNAL, "setup failed".to_string());
		let cleanup = Error::with_detail(sys::ERR_IO, "close failed".to_string());
		let combined = crate::retain_cleanup_failure(primary.clone(), Err(cleanup.clone()));
		assert_eq!(combined.code(), primary.code());
		assert_eq!(combined.message(), primary.message());
		assert_eq!(combined.secondary_errors(), &[cleanup]);
	}

	#[tokio::test]
	async fn failed_provider_setup_reaches_created_loop_release_barrier() {
		let local = tokio::task::LocalSet::new();
		local
			.run_until(async {
				let observed = Rc::new(RefCell::new(None));
				let capture = Rc::clone(&observed);
				let failing = Provider::new(move |loop_| {
					*capture.borrow_mut() = Some(loop_);
					async {
						Err(Error::with_detail(
							sys::ERR_INTERNAL,
							"provider setup failed".to_string(),
						))
					}
				});

				let error = match Runtime::open(RuntimeConfig::providers([failing])).await {
					Ok(_) => panic!("provider setup must fail"),
					Err(error) => error,
				};
				assert_eq!(error.code(), sys::ERR_INTERNAL);
				assert!(
					observed.borrow().as_ref().is_some_and(|loop_| loop_.is_released()),
					"failed setup returned before its created native loop released"
				);
			})
			.await;
	}

	#[tokio::test]
	async fn failed_provider_setup_preserves_an_adopted_host_for_retry() {
		let local = tokio::task::LocalSet::new();
		local
			.run_until(async {
				let host = Host::new_host();
				let failing = Provider::new(|_| async {
					Err(Error::with_detail(
						sys::ERR_INTERNAL,
						"provider setup failed".to_string(),
					))
				});

				let error = match Runtime::open(RuntimeConfig::providers([failing]).adopt_host(&host)).await {
					Ok(_) => panic!("provider setup must fail"),
					Err(error) => error,
				};
				assert_eq!(error.code(), sys::ERR_INTERNAL);
				assert!(
					host.shared().driver_loop().is_some(),
					"failed setup released the adopted Host's native loop"
				);

				let runtime = Runtime::open(
					RuntimeConfig::providers([crate::tcp::provider(Default::default())]).adopt_host(&host),
				)
				.await
				.expect("the same Host accepts a repaired provider setup");
				runtime.close(PendingWork::Cancel).await.unwrap();
			})
			.await;
	}
}
