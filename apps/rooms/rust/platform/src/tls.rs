//! Host system trust, loaded off the capability executor. Callers name
//! their protocol when reporting failures; certificate policy lives here.
use std::sync::Arc;
use tokio_rustls::rustls;
pub async fn system_config() -> Result<rustls::ClientConfig, String> {
	tokio::task::spawn_blocking(|| {
		let loaded = rustls_native_certs::load_native_certs();
		if !loaded.errors.is_empty() {
			return Err(format!("loading TLS trust failed: {:?}", loaded.errors));
		}
		let mut roots = rustls::RootCertStore::empty();
		for certificate in loaded.certs {
			roots
				.add(certificate)
				.map_err(|e| format!("trust certificate is invalid: {e}"))?;
		}
		if roots.is_empty() {
			return Err("TLS trust store is empty".into());
		}
		let config = rustls::ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
			.with_safe_default_protocol_versions()
			.map_err(|e| e.to_string())?
			.with_root_certificates(roots)
			.with_no_client_auth();
		Ok(config)
	})
	.await
	.map_err(|e| format!("trust loader ended: {e}"))?
}
