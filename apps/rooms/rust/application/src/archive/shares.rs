//! Immutable durable share identity and revocation. The adapter supplies the
//! atomic write; this ledger publishes changes only after acknowledgement.
use super::Filter;
pub mod protocol;
use crate::{
	documents::WriteFailure,
	fields::{List, SafeInteger},
	grants,
	text::DocumentText,
};
use alloc::{collections::BTreeMap, string::String, vec::Vec};
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::Sha256;
pub const FILE: &str = "shares.json";
pub const MAX_DOCUMENT_BYTES: usize = 128 * 1024;
pub const MAX_ACTIVE: usize = 32;
pub const MAX_LIFETIME: usize = 256;
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Share {
	id: String,
	label: DocumentText,
	filter: Filter,
	revoked: bool,
}
impl Share {
	pub fn new(id: String, label: DocumentText, filter: Filter) -> Result<Self, Error> {
		let share = Self {
			id,
			label,
			filter,
			revoked: false,
		};
		share.validate()?;
		Ok(share)
	}
	pub fn validate(&self) -> Result<(), Error> {
		grants::validate_id(&self.id).map_err(|_| Error::Invalid)?;
		grants::validate_label(self.label.utf16()).map_err(|_| Error::Invalid)?;
		self.filter.validate().map_err(|_| Error::Invalid)
	}
	pub fn id(&self) -> &str {
		&self.id
	}
	pub fn label(&self) -> &DocumentText {
		&self.label
	}
	pub fn filter(&self) -> &Filter {
		&self.filter
	}
	pub fn revoked(&self) -> bool {
		self.revoked
	}
	/// JSON tuple order and UTF-16 escaping preserve the existing HMAC material.
	/// Labels do not enter identity; scope does. Root entropy belongs to the host.
	pub fn entropy(&self, root: &[u8; 16]) -> [u8; 16] {
		let f = &self.filter;
		let row = serde_json::to_vec(&(
			&f.source,
			&f.generation,
			&f.kind,
			&f.conversation_kind,
			&f.directory,
			&f.conversation,
			&f.digest,
		))
		.expect("validated archive scope serializes");
		let mut mac = Hmac::<Sha256>::new_from_slice(root).expect("HMAC accepts a 16-byte key");
		mac.update(b"glowcap Rooms archive share\0");
		mac.update(self.id.as_bytes());
		mac.update(b"\0");
		mac.update(&row);
		let mut entropy = [0; 16];
		entropy.copy_from_slice(&mac.finalize().into_bytes()[..16]);
		entropy
	}
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Document {
	version: SafeInteger,
	shares: List<Share, MAX_LIFETIME>,
}
#[derive(Default)]
pub struct Ledger {
	rows: Vec<Share>,
	by_id: BTreeMap<String, usize>,
	active: usize,
	recovery: bool,
}
#[derive(Clone, Debug)]
pub enum Command {
	Issue(Share),
	Revoke(String),
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Change {
	Issued,
	Revoked,
	Unchanged,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
	Invalid,
	Document,
	Limit,
	Conflict,
	Revoked,
	Recovery,
}
impl core::fmt::Display for Error {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		f.write_str(match self {
			Self::Invalid => "invalid archive share",
			Self::Document => "invalid archive share document",
			Self::Limit => "archive share ledger capacity exceeded",
			Self::Conflict => "archive share id already names a different share",
			Self::Revoked => "archive share id is revoked and cannot be reused",
			Self::Recovery => "archive share storage outcome is uncertain; reload required",
		})
	}
}
impl core::error::Error for Error {}
#[derive(Debug, PartialEq, Eq)]
pub enum ApplyError<E> {
	Policy(Error),
	Storage(WriteFailure<E>),
}
impl Ledger {
	pub fn restore(bytes: &[u8]) -> Result<Self, Error> {
		if bytes.len() > MAX_DOCUMENT_BYTES {
			return Err(Error::Limit);
		}
		let text = core::str::from_utf8(bytes).map_err(|_| Error::Document)?;
		let doc: Document =
			serde_json::from_str(text.strip_prefix('\u{feff}').unwrap_or(text)).map_err(|_| Error::Document)?;
		if doc.version.get() != 1 {
			return Err(Error::Document);
		}
		let mut ledger = Self::default();
		for share in doc.shares.0 {
			share.validate()?;
			ledger.active += usize::from(!share.revoked);
			if ledger.by_id.insert(share.id.clone(), ledger.rows.len()).is_some() {
				return Err(Error::Document);
			}
			ledger.rows.push(share);
		}
		if ledger.active > MAX_ACTIVE {
			return Err(Error::Limit);
		}
		Ok(ledger)
	}
	pub fn needs_recovery(&self) -> bool {
		self.recovery
	}
	fn ready(&self) -> Result<(), Error> {
		if self.recovery {
			Err(Error::Recovery)
		} else {
			Ok(())
		}
	}
	pub fn records(&self) -> Result<impl ExactSizeIterator<Item = &Share>, Error> {
		self.ready()?;
		Ok(self.rows.iter())
	}
	pub fn get(&self, id: &str) -> Result<Option<&Share>, Error> {
		self.ready()?;
		Ok(self.by_id.get(id).map(|&at| &self.rows[at]))
	}
	pub fn document(&self) -> Result<Vec<u8>, Error> {
		self.ready()?;
		self.encode(None)
	}
	fn encode(&self, next: Option<&Share>) -> Result<Vec<u8>, Error> {
		#[derive(Serialize)]
		struct View<'a> {
			version: u32,
			shares: Vec<&'a Share>,
		}
		// The existing whole-document format costs one bounded pointer vector
		// and encoded buffer; unchanged rows retain their strings in place.
		let mut shares: Vec<_> = self
			.rows
			.iter()
			.map(|s| next.filter(|n| n.id == s.id).unwrap_or(s))
			.collect();
		if let Some(next) = next {
			if !self.by_id.contains_key(&next.id) {
				shares.push(next);
			}
		}
		let mut bytes = serde_json::to_vec(&View { version: 1, shares }).map_err(|_| Error::Document)?;
		bytes.push(b'\n');
		if bytes.len() > MAX_DOCUMENT_BYTES {
			return Err(Error::Limit);
		}
		Ok(bytes)
	}
	/// Exclusive borrowing keeps admission and commitment on one serial owner.
	/// The write callback is an adapter effect, never a publication callback.
	/// A panic or indeterminate outcome disables the ledger until restoration.
	pub fn apply<E>(
		&mut self,
		command: Command,
		write: impl FnOnce(&[u8]) -> Result<(), WriteFailure<E>>,
	) -> Result<Change, ApplyError<E>> {
		let next = self.prepare(command).map_err(ApplyError::Policy)?;
		let Some((share, change)) = next else {
			return Ok(Change::Unchanged);
		};
		let bytes = self.encode(Some(&share)).map_err(ApplyError::Policy)?;
		self.recovery = true;
		match write(&bytes) {
			Ok(()) => (),
			Err(WriteFailure::Unchanged(e)) => {
				self.recovery = false;
				return Err(ApplyError::Storage(WriteFailure::Unchanged(e)));
			}
			Err(WriteFailure::Indeterminate(e)) => return Err(ApplyError::Storage(WriteFailure::Indeterminate(e))),
		}
		match change {
			Change::Issued => self.active += 1,
			Change::Revoked => self.active -= 1,
			Change::Unchanged => unreachable!(),
		}
		if let Some(&at) = self.by_id.get(&share.id) {
			self.rows[at] = share;
		} else {
			self.by_id.insert(share.id.clone(), self.rows.len());
			self.rows.push(share);
		}
		self.recovery = false;
		Ok(change)
	}
	fn prepare(&self, command: Command) -> Result<Option<(Share, Change)>, Error> {
		self.ready()?;
		match command {
			Command::Issue(share) => {
				share.validate()?;
				if share.revoked {
					return Err(Error::Revoked);
				}
				if let Some(existing) = self.get(&share.id)? {
					if existing.revoked {
						return Err(Error::Revoked);
					}
					return if *existing == share {
						Ok(None)
					} else {
						Err(Error::Conflict)
					};
				}
				if self.rows.len() == MAX_LIFETIME || self.active == MAX_ACTIVE {
					return Err(Error::Limit);
				}
				Ok(Some((share, Change::Issued)))
			}
			Command::Revoke(id) => {
				let Some(existing) = self.get(&id)?.filter(|s| !s.revoked) else {
					return Ok(None);
				};
				let mut share = existing.clone();
				share.revoked = true;
				Ok(Some((share, Change::Revoked)))
			}
		}
	}
}
