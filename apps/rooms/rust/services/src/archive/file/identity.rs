use super::*;
use rooms_application::archive::identity::{self, Identity};

#[cfg(feature = "processes")]
impl rooms_platform::serving::onion::KeyStore for FileArchive {
	async fn read_key(&mut self) -> Result<Option<Vec<u8>>, String> {
		match self
			.submit(|store| {
				rooms_platform::serving::onion::read(&store.directory)
					.map(Completion::OnionKey)
					.map_err(|reason| DiskFailure::Corrupt(reason.into()))
			})
			.await
			.map_err(|error| error.into_refusal())?
		{
			Completion::OnionKey(key) => Ok(key),
			_ => unreachable!("onion key completion"),
		}
	}
	async fn save_key(&mut self, key: Vec<u8>) -> Result<(), String> {
		rooms_platform::serving::onion::validate(&key)?;
		self.submit(move |store| {
			let written =
				storage::atomic::replace(&store.directory, rooms_platform::serving::onion::FILE, [key.as_slice()]);
			store.written(written)?;
			Ok(Completion::Cleaned)
		})
		.await
		.map(|_| ())
		.map_err(|error| error.into_refusal())
	}
}
impl FileArchive {
	/// Standalone peers explicitly request identity under the existing archive
	/// lease. Session-local archives do not create a peer identity as a side effect.
	pub async fn identity(&mut self) -> Result<Identity, Error> {
		match self
			.submit(|store| {
				let identity = match storage::read(&store.directory.path().join(identity::FILE), identity::MAX_BYTES)? {
					Some(bytes) => Identity::decode(&bytes).map_err(|e| DiskFailure::Corrupt(e.to_string().into()))?,
					None => {
						let mut seed = [0; 32];
						let mut entropy = [0; 16];
						rooms_platform::entropy::fill(&mut seed).map_err(entropy_failure)?;
						rooms_platform::entropy::fill(&mut entropy).map_err(entropy_failure)?;
						let identity = Identity::new(seed, entropy);
						let bytes = identity.encode();
						let written = storage::atomic::replace(&store.directory, identity::FILE, [bytes.as_slice()]);
						store.written(written)?;
						identity
					}
				};
				Ok(Completion::Identity(identity))
			})
			.await?
		{
			Completion::Identity(identity) => Ok(identity),
			_ => unreachable!("identity completion"),
		}
	}
}

/// The platform could not supply entropy. No identity exists yet and none was
/// written, so this is the host failing rather than the archive.
fn entropy_failure(error: impl std::fmt::Display) -> DiskFailure {
	DiskFailure::Corrupt(format!("archive identity needs platform entropy: {error}").into())
}

#[cfg(test)]
mod tests {
	use super::*;
	#[tokio::test]
	async fn identity_is_explicit_durable_and_never_replaces_malformed_state() {
		let temp = super::super::tests::Temp::new();
		let path = temp.0.join(identity::FILE);
		let mut archive = FileArchive::open(&temp.0, Options::default()).await.unwrap();
		assert!(!path.exists());
		let first = archive.identity().await.unwrap().encode();
		assert_eq!(archive.identity().await.unwrap().encode(), first);
		assert!(FileArchive::open(&temp.0, Options::default()).await.is_err());
		drop(archive);
		let mut archive = FileArchive::open(&temp.0, Options::default()).await.unwrap();
		assert_eq!(archive.identity().await.unwrap().encode(), first);
		#[cfg(unix)]
		{
			use std::os::unix::fs::PermissionsExt;
			assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
		}
		std::fs::write(&path, b"{broken").unwrap();
		assert!(archive.identity().await.is_err());
		assert_eq!(std::fs::read(&path).unwrap(), b"{broken");
	}
}
