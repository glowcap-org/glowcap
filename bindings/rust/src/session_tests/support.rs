//! Shared runtime and TCP fixtures for the Session scenario leaves.

pub(super) use super::super::*;
pub(super) use crate::sys;
pub(super) use crate::sys::host as ffi;
pub(super) use crate::tcp;
pub(super) use crate::AbortDomain;
pub(super) use crate::Codec;
pub(super) use crate::ErrorKind;
pub(super) use crate::Host;
pub(super) use crate::Ref;
pub(super) use crate::{ConnectOptions, RuntimeConfig};
pub(super) use std::cell::Cell;
pub(super) use std::sync::atomic::{AtomicUsize, Ordering};
pub(super) use tokio::sync::oneshot;
pub(super) use tokio::task::LocalSet;

pub(super) async fn connect(locator: &crate::Locator, options: ConnectOptions<'_>) -> crate::Result<crate::Session> {
	let runtime = crate::Runtime::open(RuntimeConfig::providers([crate::tcp::provider(Default::default())])).await?;
	runtime.connect(locator, options).await
}

pub(super) async fn connect_with_host(locator: &crate::Locator, host: Host) -> crate::Result<crate::Session> {
	let runtime =
		crate::Runtime::open(RuntimeConfig::providers([crate::tcp::provider(Default::default())]).adopt_host(&host))
			.await?;
	runtime.connect(locator, ConnectOptions::default()).await
}

pub(super) async fn connect_with_runtime_options(
	locator: &crate::Locator,
	options: crate::RuntimeConfig,
) -> crate::Result<crate::Session> {
	let runtime = crate::Runtime::open(options).await?;
	runtime.connect(locator, ConnectOptions::default()).await
}

pub(super) async fn listen(address: &str) -> crate::Result<tcp::Server> {
	let (host, port) = crate::designator_host_port(address)?;
	tcp::listen(&host, port, tcp::ListenOptions::default()).await
}

pub(super) async fn listen_with_host(address: &str, host: Host) -> crate::Result<tcp::Server> {
	let (bind_host, port) = crate::designator_host_port(address)?;
	tcp::listen(
		&bind_host,
		port,
		tcp::ListenOptions {
			identity: crate::ListenerIdentity::Host(host),
			..tcp::ListenOptions::default()
		},
	)
	.await
}

pub(super) use tokio::io::{AsyncRead, AsyncWrite};
