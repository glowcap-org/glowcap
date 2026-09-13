//! Durable session grant policy and commit ordering. Storage execution is an
//! adapter effect. The native durable owner and shared contract proofs consume
//! this ledger; no browser or transport adapter owns grant policy.
mod model;
pub(crate) use model::{validate_id, validate_label};
pub mod protocol;
mod shared;
mod storage;
pub use model::{
	Access, Change, Command, Error, Grant, MAX_ACTIVE_GRANTS, MAX_DOCUMENT_BYTES, MAX_GRANT_LABEL_UNITS,
	MAX_GRANT_NOTE_UNITS, MAX_LIFETIME_GRANTS, PolicyPatch, Rights,
};
pub use shared::{GrantPolicy, GrantState};
use storage::Phase;
pub use storage::{ApplyError, GrantStorage, PersistedGrant, PreparedGrant};

use alloc::{collections::BTreeMap, rc::Rc, string::String, vec::Vec};
use core::cell::Cell;
use hmac::{Hmac, KeyInit, Mac};
use serde::{Deserialize, Serialize};
use sha2::Sha256;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Document {
	version: u32,
	grants: Vec<Grant>,
}

#[derive(Default)]
pub struct GrantLedger {
	grants: Vec<Grant>,
	by_id: BTreeMap<String, usize>,
	active: usize,
	phase: Rc<Cell<Phase>>,
}

impl GrantLedger {
	/// Decode an existing document. Absence is handled by the storage owner;
	/// malformed state must never be interpreted as an empty session.
	pub fn restore(bytes: &[u8]) -> Result<Self, Error> {
		if bytes.len() > MAX_DOCUMENT_BYTES {
			return Err(Error::DocumentTooLarge);
		}
		let text = crate::documents::SessionDocument::Grants
			.decode(bytes)
			.map_err(|_| Error::MalformedDocument)?;
		let document: Document = serde_json::from_str(text).map_err(|_| Error::MalformedDocument)?;
		if document.version != 1 {
			return Err(Error::UnsupportedVersion);
		}
		if document.grants.len() > MAX_LIFETIME_GRANTS {
			return Err(Error::LifetimeLimit);
		}
		let mut ledger = Self::default();
		for grant in document.grants {
			grant.validate()?;
			ledger.active += usize::from(!grant.revoked);
			if ledger.by_id.insert(grant.id.clone(), ledger.grants.len()).is_some() {
				return Err(Error::DuplicateId);
			}
			ledger.grants.push(grant);
		}
		if ledger.active > MAX_ACTIVE_GRANTS {
			return Err(Error::ActiveLimit);
		}
		Ok(ledger)
	}

	pub fn get(&self, id: &str) -> Result<Option<&Grant>, Error> {
		self.require_ready()?;
		Ok(self.lookup(id))
	}
	pub fn records(&self) -> Result<impl ExactSizeIterator<Item = &Grant>, Error> {
		self.require_ready()?;
		Ok(self.grants.iter())
	}
	fn lookup(&self, id: &str) -> Option<&Grant> {
		self.by_id.get(id).map(|&at| &self.grants[at])
	}
	pub fn active_count(&self) -> Result<usize, Error> {
		self.require_ready()?;
		Ok(self.active)
	}
	pub fn lifetime_count(&self) -> Result<usize, Error> {
		self.require_ready()?;
		Ok(self.grants.len())
	}

	pub fn document(&self) -> Result<Vec<u8>, Error> {
		self.require_ready()?;
		self.encode(None)
	}

	pub fn needs_recovery(&self) -> bool {
		self.phase.get() == Phase::Recovery
	}

	fn require_ready(&self) -> Result<(), Error> {
		if self.needs_recovery() {
			Err(Error::RecoveryRequired)
		} else {
			Ok(())
		}
	}

	/// Apply an administrator-admitted command only after storage acknowledges
	/// its write. The session facet owns admission through a held capability.
	/// An interrupted or indeterminate write disables reads and commands until
	/// the owner replaces this ledger with a restored durable document.
	pub async fn apply<S: GrantStorage>(
		&mut self,
		store: &mut S,
		command: Command,
	) -> Result<Change, ApplyError<S::Error>> {
		self.prepare(command)
			.map_err(ApplyError::Policy)?
			.persist(store)
			.await?
			.commit(self)
			.map_err(ApplyError::Policy)
	}

	/// Prepare one serialized mutation without retaining a borrow across I/O.
	/// Reads keep the committed policy until persistence is acknowledged.
	pub fn prepare(&mut self, command: Command) -> Result<PreparedGrant, Error> {
		self.require_ready()?;
		if self.phase.get() == Phase::Writing {
			return Err(Error::Busy);
		}
		let (next, change) = match command {
			Command::Issue {
				id,
				rights,
				label,
				history,
			} => {
				let grant = Grant {
					id,
					rights,
					label,
					history,
					suspended: false,
					note: String::new().into(),
					revoked: false,
				};
				grant.validate()?;
				if let Some(existing) = self.lookup(&grant.id) {
					if existing.revoked {
						return Err(Error::Revoked);
					}
					if existing.rights != grant.rights
						|| existing.label != grant.label
						|| existing.history != grant.history
					{
						return Err(Error::Conflict);
					}
					(None, Change::Unchanged)
				} else {
					if self.grants.len() >= MAX_LIFETIME_GRANTS {
						return Err(Error::LifetimeLimit);
					}
					if self.active >= MAX_ACTIVE_GRANTS {
						return Err(Error::ActiveLimit);
					}
					(Some(grant), Change::Issued)
				}
			}
			Command::SetPolicy { id, patch } => {
				let mut grant = self.lookup(&id).ok_or(Error::Missing)?.clone();
				if grant.revoked {
					return Err(Error::Revoked);
				}
				if let Some(rights) = patch.rights {
					grant.rights = rights;
				}
				if let Some(history) = patch.history {
					grant.history = history;
				}
				if let Some(suspended) = patch.suspended {
					grant.suspended = suspended;
				}
				if patch.suspended == Some(false) {
					grant.note.clear();
				} else if let Some(note) = patch.note {
					grant.note = note;
				}
				grant.validate()?;
				(Some(grant), Change::PolicyChanged)
			}
			Command::Revoke { id } => match self.lookup(&id) {
				Some(grant) if !grant.revoked => {
					let mut revoked = grant.clone();
					revoked.revoked = true;
					(Some(revoked), Change::Revoked)
				}
				_ => (None, Change::Unchanged),
			},
		};
		let bytes = if next.is_some() {
			Some(self.encode(next.as_ref())?)
		} else {
			None
		};
		self.phase.set(Phase::Writing);
		Ok(PreparedGrant {
			phase: self.phase.clone(),
			started: false,
			next,
			bytes,
			change,
		})
	}

	fn encode(&self, next: Option<&Grant>) -> Result<Vec<u8>, Error> {
		#[derive(Serialize)]
		struct View<'a> {
			version: u32,
			grants: Vec<&'a Grant>,
		}
		// A bounded pointer list and document buffer are the cost of the existing
		// whole-document storage contract. Only a changed row clones its strings.
		// Preserve the existing document's issuance order across policy changes
		// and restart. The id index accelerates admission without owning order.
		let mut rows: Vec<_> = self
			.grants
			.iter()
			.map(|grant| next.filter(|next| next.id == grant.id).unwrap_or(grant))
			.collect();
		if let Some(next) = next
			&& !self.by_id.contains_key(&next.id)
		{
			rows.push(next);
		}
		let mut bytes = serde_json::to_vec(&View {
			version: 1,
			grants: rows,
		})
		.map_err(|_| Error::MalformedDocument)?;
		bytes.push(b'\n');
		if bytes.len() > MAX_DOCUMENT_BYTES {
			return Err(Error::DocumentTooLarge);
		}
		Ok(bytes)
	}
}

/// Preserve the current HMAC derivation and 16-byte truncation. Only immutable
/// grant identity enters the derivation, so changing policy preserves its link.
/// The caller owns root-entropy custody and publication through glowcap.
pub fn derive_entropy(root: &[u8; 16], id: &str) -> Result<[u8; 16], Error> {
	model::validate_id(id)?;
	let mut mac = Hmac::<Sha256>::new_from_slice(root).expect("HMAC accepts a 16-byte key");
	mac.update(b"glowcap Rooms session grant\0");
	mac.update(id.as_bytes());
	let mut entropy = [0; 16];
	entropy.copy_from_slice(&mac.finalize().into_bytes()[..16]);
	Ok(entropy)
}
