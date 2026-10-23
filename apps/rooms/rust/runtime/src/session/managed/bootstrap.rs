//! Private bootstrap data survives every creation boundary. Only established
//! absence of an unconfirmed root permits another fresh preparation.
use super::{Opened, Session, StartupAnchor, initial_payload, schemas};
use glowcap::{
	ErrorKind, Host, Result,
	loam::{self, Store},
};
use rooms_application::content::session;
use rooms_glowcap::client::{Deadline, Tasks};
use std::{future::Future, num::NonZeroUsize};

/// Fixed private metadata, never workspace export or client custody. Identity
/// is persisted before opening the physical Store. A prepared anchor precedes
/// resource commit. A live marker precedes public branch exposure.
#[derive(Clone, Copy)]
pub struct Bootstrap {
	pub seed: [u8; 32],
	pub store_identity: [u8; 16],
	pub owner_identity: [u8; 16],
	pub anchor: Option<StartupAnchor>,
}
/// Fixed hosting budgets and the initial transport choice. No runtime state or
/// authority is retained by these options.
pub struct BootstrapOptions {
	pub reply_bytes: NonZeroUsize,
	pub live_capacity: u32,
	pub initial_connection: session::workspace::Connection,
}
impl Bootstrap {
	pub const BYTES: usize = 8 + 32 + 16 + 16 + 1 + StartupAnchor::BYTES;
	const HEADER: [u8; 8] = *b"RLOAM\0\0\x01";
	pub fn encode(self) -> [u8; Self::BYTES] {
		let mut bytes = [0; Self::BYTES];
		bytes[..8].copy_from_slice(&Self::HEADER);
		bytes[8..40].copy_from_slice(&self.seed);
		bytes[40..56].copy_from_slice(&self.store_identity);
		bytes[56..72].copy_from_slice(&self.owner_identity);
		if let Some(anchor) = self.anchor {
			bytes[72] = 1;
			bytes[73..].copy_from_slice(&anchor.encode());
		}
		bytes
	}
	pub fn decode(bytes: [u8; Self::BYTES]) -> Result<Self> {
		if bytes[..8] != Self::HEADER {
			return Err(loam::refusal("unsupported private Rooms bootstrap format"));
		}
		let malformed = || loam::refusal("invalid private Rooms bootstrap");
		let anchor = match bytes[72] {
			0 if bytes[73..].iter().all(|byte| *byte == 0) => None,
			1 => Some(StartupAnchor::decode(bytes[73..].try_into().map_err(|_| malformed())?)?),
			_ => return Err(loam::refusal("invalid private Rooms bootstrap anchor")),
		};
		Ok(Self {
			seed: bytes[8..40].try_into().map_err(|_| malformed())?,
			store_identity: bytes[40..56].try_into().map_err(|_| malformed())?,
			owner_identity: bytes[56..72].try_into().map_err(|_| malformed())?,
			anchor,
		})
	}

	/// The embedding holds exclusive metadata custody and has already persisted
	/// these identities. Persistence refusal exposes no public authority. Resource
	/// preparation owns one existing core staging guard. This composition adds
	/// fixed metadata only, without a grant inventory or independent scheduler.
	pub async fn open<P, F>(
		mut self,
		mut store: Store,
		host: Host,
		platform: P,
		options: BootstrapOptions,
		mut persist: impl FnMut(Self) -> F,
	) -> Result<Opened<P>>
	where
		P: Tasks + Deadline + Clone + 'static,
		F: Future<Output = Result<()>>,
	{
		let BootstrapOptions {
			reply_bytes,
			live_capacity,
			initial_connection,
		} = options;
		let result = self
			.prepare(&store, &host, &platform, reply_bytes, initial_connection, &mut persist)
			.await;
		let anchor = match result {
			Ok(anchor) => anchor,
			Err(error) => {
				#[cfg(not(target_arch = "wasm32"))]
				let closed = store.close();
				#[cfg(target_arch = "wasm32")]
				let closed = store.close().await;
				return Err(error.with_cleanup(closed));
			}
		};
		Opened::open(
			store,
			host,
			platform,
			anchor,
			reply_bytes,
			live_capacity,
			move |anchor| {
				self.anchor = Some(anchor);
				persist(self)
			},
		)
		.await
	}
	async fn prepare<P, F>(
		&mut self,
		store: &Store,
		host: &Host,
		platform: &P,
		reply_bytes: NonZeroUsize,
		initial_connection: session::workspace::Connection,
		persist: &mut impl FnMut(Self) -> F,
	) -> Result<StartupAnchor>
	where
		P: Tasks + Deadline + Clone + 'static,
		F: Future<Output = Result<()>>,
	{
		if let Some(anchor) = self.anchor {
			// Probe exact committed names. An I/O, corruption or policy refusal
			// cannot justify replacing a root; neither can absence after live use.
			let session = Session::new(host.clone(), platform.clone(), reply_bytes);
			let mut attachment = store.attach(host, vec![session.registration()])?;
			let restored = attachment.restore(anchor.resource).await;
			let absent = match restored {
				Ok(held) => {
					drop(held);
					false
				}
				Err(error) if error.kind() == ErrorKind::NotFound && anchor.marker.is_none() => true,
				Err(error) => return Err(error.with_cleanup(attachment.close().await)),
			};
			attachment.close().await?;
			if !absent {
				return Ok(anchor);
			}
		}
		let policy = rooms_glowcap::policy::descriptor()?;
		let staged = store.stage_resource(
			&policy,
			schemas()[0],
			session::KIND,
			&initial_payload(initial_connection)?,
			4,
			self.owner_identity,
		)?;
		let prepared = StartupAnchor {
			resource: staged.resource(),
			marker: None,
		};
		// Aborted IDs and physical incarnations never repeat. Known absence of
		// this private, unexposed preparation permits new names, persisted before
		// their commit. A confirmed root always follows restoration above.
		self.anchor = Some(prepared);
		persist(*self).await?;
		#[cfg(not(target_arch = "wasm32"))]
		staged.commit()?;
		#[cfg(target_arch = "wasm32")]
		staged.commit().await?;
		Ok(prepared)
	}
}
