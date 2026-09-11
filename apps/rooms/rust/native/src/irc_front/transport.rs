use super::config::{Config, DirectListener};
use crate::serving::{self, Listener, Transport};
use glowcap::{iroh, tcp, Host, ListenerIdentity, Locator, Runtime, RuntimeConfig};
use std::{rc::Rc, sync::Arc};
use tokio_rustls::{
	rustls::{
		self,
		pki_types::{pem::PemObject, CertificateDer, PrivateKeyDer},
	},
	TlsAcceptor,
};

pub(super) async fn tls(config: &Config) -> Result<Option<TlsAcceptor>, String> {
	let Some((cert, key)) = &config.tls else {
		return Ok(None);
	};
	let (cert, key) = (cert.clone(), key.clone());
	let config = tokio::task::spawn_blocking(move || {
		let cert = material(&cert)?;
		let key = material(&key)?;
		let certificates = CertificateDer::pem_slice_iter(&cert)
			.collect::<Result<Vec<_>, _>>()
			.map_err(|e| e.to_string())?;
		let key = PrivateKeyDer::from_pem_slice(&key).map_err(|e| e.to_string())?;
		rustls::ServerConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
			.with_safe_default_protocol_versions()
			.map_err(|e| e.to_string())?
			.with_no_client_auth()
			.with_single_cert(certificates, key)
			.map_err(|e| e.to_string())
	})
	.await
	.map_err(|e| e.to_string())??;
	Ok(Some(TlsAcceptor::from(Arc::new(config))))
}

pub(super) async fn open(config: &Config, host: &Host) -> Result<(Listener, Locator, Rc<Runtime>), String> {
	let (listener, locator) = match &config.dm {
		DirectListener::Iroh => Listener::open(
			&Transport::Iroh(iroh::Reachability::Direct),
			host,
			&mut serving::onion::KeyFile(None),
		)
		.await
		.map_err(|e| e.to_string())?,
		DirectListener::Tcp {
			noise,
			bind,
			announce,
			port,
		} => {
			let options = tcp::ListenOptions {
				identity: ListenerIdentity::Host(host.clone()),
				advertised_host: announce.clone(),
				..Default::default()
			};
			let server = if *noise {
				tcp::noise::listen(bind, *port, options).await
			} else {
				tcp::listen(bind, *port, options).await
			}
			.map_err(|e| e.to_string())?;
			let locator = match server.locator() {
				Ok(locator) => locator,
				Err(error) => {
					let result = crate::cleanup::combine(
						Err(error.to_string()),
						server.close().await.map_err(|e| e.to_string()),
					);
					return Err(result.expect_err("listener metadata failed"));
				}
			};
			(Listener::Tcp(server), locator)
		}
	};
	let mut providers = Vec::new();
	if matches!(config.dm, DirectListener::Iroh) {
		providers.push(tcp::provider(Default::default()));
	}
	if config.directory.transport == glowcap::TRANSPORT_IROH && !matches!(config.dm, DirectListener::Iroh) {
		providers.push(iroh::provider(serving::iroh_config(iroh::Reachability::Direct)));
	}
	match Runtime::open(RuntimeConfig::providers(providers).adopt_host(host)).await {
		Ok(runtime) => Ok((listener, locator, Rc::new(runtime))),
		Err(error) => Err(crate::cleanup::combine(
			Err(error.to_string()),
			listener.close().await.map_err(|e| e.to_string()),
		)
		.expect_err("runtime startup failed")),
	}
}

fn material(path: &std::path::Path) -> Result<Vec<u8>, String> {
	use std::io::Read;
	const LIMIT: u64 = 1024 * 1024;
	let mut bytes = Vec::new();
	std::fs::File::open(path)
		.map_err(|e| e.to_string())?
		.take(LIMIT + 1)
		.read_to_end(&mut bytes)
		.map_err(|e| e.to_string())?;
	if bytes.len() as u64 > LIMIT {
		return Err("IRC TLS material exceeds 1 MiB".into());
	}
	Ok(bytes)
}
