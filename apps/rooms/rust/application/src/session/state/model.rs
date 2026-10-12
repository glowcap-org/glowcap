//! Durable session state records commands, outcomes, and operation identities.
use super::{Error, OperationId, ResultKind, ResultText};
use crate::{
	documents::SessionDocument,
	session::{
		checkpoint::{Checkpoint, Routes},
		fields::{List, Nullable, SafeInteger, Text, version},
		snapshot::views::Adoption,
	},
	text::DocumentText,
};
use alloc::{collections::BTreeSet, rc::Rc, string::String};
use serde::{Deserialize, Deserializer, Serialize};

pub(super) use crate::fields::Hex;
pub(super) type Digest = Hex<32>;
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct RecentOperation {
	pub id: OperationId,
	pub digest: Digest,
	pub revision: SafeInteger,
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Disk {
	pub version: u8,
	pub identity_seed: Hex<32>,
	pub session_entropy: Hex<16>,
	pub revision: SafeInteger,
	pub workspace_adoption: Adoption,
	pub checkpoint: Rc<Checkpoint>,
	pub recent: List<Rc<RecentOperation>, 64>,
}
impl Disk {
	pub fn fresh(identity: [u8; 32], entropy: [u8; 16]) -> Self {
		Self {
			version: 1,
			identity_seed: Hex(identity),
			session_entropy: Hex(entropy),
			revision: SafeInteger::ZERO,
			workspace_adoption: Adoption::Available,
			checkpoint: Rc::new(Checkpoint::empty()),
			recent: List(alloc::vec::Vec::new()),
		}
	}
	pub fn decode(bytes: &[u8], routes: &impl Routes) -> Result<Self, Error> {
		#[derive(Deserialize)]
		#[serde(deny_unknown_fields, rename_all = "camelCase")]
		struct Raw<'a> {
			#[serde(deserialize_with = "version")]
			version: u8,
			identity_seed: Hex<32>,
			session_entropy: Hex<16>,
			revision: SafeInteger,
			workspace_adoption: Adoption,
			#[serde(borrow)]
			checkpoint: &'a serde_json::value::RawValue,
			recent: List<Rc<RecentOperation>, 64>,
		}
		let raw: Raw<'_> =
			serde_json::from_str(SessionDocument::Checkpoint.decode(bytes).map_err(|_| Error::Document)?)
				.map_err(|_| Error::Document)?;
		let value = Self {
			version: raw.version,
			identity_seed: raw.identity_seed,
			session_entropy: raw.session_entropy,
			revision: raw.revision,
			workspace_adoption: raw.workspace_adoption,
			checkpoint: Rc::new(
				Checkpoint::decode_embedded(raw.checkpoint.get(), routes).map_err(|_| Error::Checkpoint)?,
			),
			recent: raw.recent,
		};
		value.validate()?;
		Ok(value)
	}
	pub fn validate(&self) -> Result<(), Error> {
		let mut ids = BTreeSet::new();
		if (self.workspace_adoption == Adoption::Available && self.revision.get() != 0)
			|| self
				.recent
				.0
				.iter()
				.any(|v| !ids.insert(&v.id.0) || v.revision.get() == 0 || v.revision.get() > self.revision.get())
		{
			return Err(Error::Relation);
		}
		Ok(())
	}
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub(super) struct Marker {
	pub revision: SafeInteger,
	pub apply_kind: ResultKind,
	pub result_digest: Digest,
}
#[derive(Clone, Serialize, Deserialize)]
pub(super) enum OrdinaryTag {
	#[serde(rename = "ordinary")]
	Ordinary,
}
#[derive(Clone, Serialize, Deserialize)]
pub(super) enum ResultTag {
	#[serde(rename = "result")]
	Result,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Ordinary {
	#[serde(rename = "type")]
	pub kind: OrdinaryTag,
	pub id: OperationId,
	pub digest: Digest,
	pub subject: Text<256, true>,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub(super) struct ResultEffect {
	#[serde(rename = "type")]
	pub kind: ResultTag,
	pub id: OperationId,
	pub digest: Digest,
	pub result_kind: ResultKind,
	pub base_revision: SafeInteger,
	pub intent: Rc<ResultText>,
	pub result: Nullable<Rc<ResultText>>,
	pub marker: Nullable<Marker>,
}
#[derive(Clone, Serialize)]
#[serde(untagged)]
pub(super) enum Pending {
	Ordinary(Ordinary),
	Result(ResultEffect),
}
impl<'de> Deserialize<'de> for Pending {
	fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
		#[derive(Deserialize)]
		struct Tag {
			#[serde(rename = "type")]
			kind: String,
		}
		let raw = <&serde_json::value::RawValue>::deserialize(d)?;
		let tag: Tag = serde_json::from_str(raw.get()).map_err(serde::de::Error::custom)?;
		match tag.kind.as_str() {
			"ordinary" => serde_json::from_str(raw.get())
				.map(Self::Ordinary)
				.map_err(serde::de::Error::custom),
			"result" => serde_json::from_str(raw.get())
				.map(Self::Result)
				.map_err(serde::de::Error::custom),
			_ => Err(serde::de::Error::custom("effect type")),
		}
	}
}
impl Pending {
	pub fn id(&self) -> &OperationId {
		match self {
			Self::Ordinary(v) => &v.id,
			Self::Result(v) => &v.id,
		}
	}
	pub fn digest(&self) -> &Digest {
		match self {
			Self::Ordinary(v) => &v.digest,
			Self::Result(v) => &v.digest,
		}
	}
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Outcome {
	Committed,
	Abandoned,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub(super) struct RecentEffect {
	pub id: OperationId,
	pub digest: Digest,
	pub revision: SafeInteger,
	pub outcome: Outcome,
	pub result_kind: Nullable<ResultKind>,
	pub result: Nullable<Rc<ResultText>>,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Effects {
	#[serde(deserialize_with = "version")]
	pub version: u8,
	pub recent: List<Rc<RecentEffect>, 64>,
	pub pending: List<Rc<Pending>, 64>,
}
impl Effects {
	pub fn empty() -> Self {
		Self {
			version: 1,
			recent: List(alloc::vec::Vec::new()),
			pending: List(alloc::vec::Vec::new()),
		}
	}
	pub fn decode(bytes: &[u8]) -> Result<Self, Error> {
		let value: Self = serde_json::from_str(SessionDocument::Effects.decode(bytes).map_err(|_| Error::Document)?)
			.map_err(|_| Error::Document)?;
		value.validate()?;
		Ok(value)
	}
	pub fn validate(&self) -> Result<(), Error> {
		let mut ids = BTreeSet::new();
		for v in &self.recent.0 {
			if !ids.insert(&v.id.0)
				|| match v.outcome {
					Outcome::Committed => v.result_kind.as_ref().is_some() != v.result.as_ref().is_some(),
					Outcome::Abandoned => v.result.as_ref().is_some(),
				} {
				return Err(Error::Relation);
			}
		}
		let mut results = 0;
		for v in &self.pending.0 {
			if !ids.insert(&v.id().0) {
				return Err(Error::Relation);
			}
			if let Pending::Result(v) = v.as_ref() {
				results += 1;
				if v.marker.as_ref().is_some_and(|m| {
					v.result.as_ref().is_none()
						|| m.revision.get() <= v.base_revision.get()
						|| m.apply_kind != v.result_kind
				}) {
					return Err(Error::Relation);
				}
			}
		}
		if results > 1 {
			return Err(Error::Relation);
		}
		Ok(())
	}
}
pub(super) fn document<T: Serialize>(value: &T, kind: SessionDocument) -> Result<alloc::vec::Vec<u8>, Error> {
	let mut bytes = serde_json::to_vec(value).map_err(|_| Error::Document)?;
	if bytes.len() >= kind.max_bytes() {
		return Err(Error::Document);
	}
	bytes.push(b'\n');
	Ok(bytes)
}
pub(super) fn digest(material: &DocumentText) -> Digest {
	use sha2::Digest;
	let mut hasher = sha2::Sha256::new();
	if let Some(text) = material.as_str() {
		hasher.update(text.as_bytes());
	} else {
		let mut bytes = [0; 4];
		for ch in core::char::decode_utf16(material.utf16()) {
			hasher.update(
				ch.unwrap_or(core::char::REPLACEMENT_CHARACTER)
					.encode_utf8(&mut bytes)
					.as_bytes(),
			);
		}
	}
	Hex(hasher.finalize().into())
}
