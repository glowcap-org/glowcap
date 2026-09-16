//! Bounded Open Graph vocabulary and link-preview candidates.
//!
//! The shared application owns what a message link means and what remote
//! metadata may enter Rooms. Network adapters own DNS, HTTP, redirects, and
//! bytes; presentations own gestures and rendering, never either grammar.
use crate::markdown::{Document, Node};
use alloc::{collections::BTreeSet, string::String, vec::Vec};
use serde::{Deserialize, Serialize};
use url::Url;

mod metadata;
mod selection_wire;
pub use metadata::{
	Image, MAX_PROPERTIES, MAX_PROPERTY_CONTENT_BYTES, MAX_PROPERTY_KEY_BYTES, MAX_TITLE_BYTES, Metadata,
	OEmbedObservation, Observation, Property,
};

pub const MAX_PREVIEWS: usize = 5;
pub const MAX_URL_BYTES: usize = 2_048;
pub const WIRE_TAG: &str = "link-previews-v1";
pub const WIRE_FIELDS: usize = 2;
/// The room says whether these verbs are worth sending through what it
/// carries (`crate::room::carries`); a room that does not name previews gets
/// the plain `post` and `postFiles`.
pub const ROOM_POST_VERB: &str = "postWithPreviews";
pub const ROOM_POST_FILES_VERB: &str = "postFilesWithPreviews";

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Target {
	/// Canonical identity for reconciliation, fetching, suppression, and retry.
	pub url: String,
}

/// The previews the sender kept for one exact authored message. Metadata is
/// deliberately absent: every reader obtains and validates it through its own
/// preview service, while this bounded selection is the durable user intent.
#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize)]
#[serde(transparent)]
pub struct Selection(Vec<String>);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SelectionError {
	Shape,
	Target,
}

impl core::fmt::Display for SelectionError {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		f.write_str(match self {
			Self::Shape => "link preview selection has an invalid shape or exceeds its limit",
			Self::Target => "link preview selection names a URL outside the message",
		})
	}
}

impl core::error::Error for SelectionError {}

impl Selection {
	pub fn is_empty(&self) -> bool {
		self.0.is_empty()
	}

	/// Validate an untrusted selected subset against the shared Markdown
	/// projection, then retain it in authored order. Exact normalized identity
	/// prevents alternate spellings from bypassing suppression or cache bounds.
	pub fn new<'a>(text: &str, selected: impl IntoIterator<Item = &'a str>) -> Result<Self, SelectionError> {
		let selected: Vec<&str> = selected.into_iter().take(MAX_PREVIEWS + 1).collect();
		if selected.is_empty() {
			return Ok(Self::default());
		}
		if selected.len() > MAX_PREVIEWS {
			return Err(SelectionError::Shape);
		}
		let mut wanted = BTreeSet::new();
		for value in selected {
			let normalized = normalize_url(value).ok_or(SelectionError::Target)?;
			if normalized != value || !wanted.insert(normalized) {
				return Err(SelectionError::Target);
			}
		}
		let urls = Document::read(text)
			.preview_targets()
			.into_iter()
			.filter_map(|target| wanted.remove(&target.url).then_some(target.url))
			.collect();
		if !wanted.is_empty() {
			return Err(SelectionError::Target);
		}
		Ok(Self(urls))
	}

	#[must_use]
	pub fn all(text: &str) -> Self {
		Self(
			Document::read(text)
				.preview_targets()
				.into_iter()
				.map(|target| target.url)
				.collect(),
		)
	}

	#[must_use]
	pub fn urls(&self) -> &[String] {
		&self.0
	}

	/// Carry an existing removal decision through an edit. URLs still present
	/// stay selected; removed URLs disappear; newly typed URLs require an
	/// explicit new selection rather than silently gaining a network effect.
	#[must_use]
	pub fn retained_for(&self, text: &str) -> Self {
		if self.is_empty() {
			return Self::default();
		}
		let present: BTreeSet<_> = Document::read(text)
			.preview_targets()
			.into_iter()
			.map(|target| target.url)
			.collect();
		Self(self.0.iter().filter(|url| present.contains(*url)).cloned().collect())
	}

	#[must_use]
	pub fn encode(&self) -> String {
		if self.is_empty() {
			return "[]".into();
		}
		// Vec<String> has no fallible serialization arm: there are no maps with
		// non-string keys, floats, custom callbacks or I/O behind this formatter.
		serde_json::to_string(self).expect("a link preview selection encodes")
	}

	pub fn decode(text: &str, encoded: &str) -> Result<Self, SelectionError> {
		// Even fully Unicode-escaped URLs fit; excess whitespace cannot make
		// JSON escape scratch grow beyond the selection's own byte budget.
		if encoded.len() > selection_wire::MAX_ENCODED_BYTES {
			return Err(SelectionError::Shape);
		}
		let selected: Self = serde_json::from_str(encoded).map_err(|_| SelectionError::Shape)?;
		Self::new(text, selected.0.iter().map(String::as_str))
	}

	/// Read a display-only additive suffix. Unknown or malformed extensions do
	/// not erase the line before them; a recognized valid selection is the only
	/// shape that can request reader-side network effects.
	#[must_use]
	pub fn read_suffix<A: crate::room::ArgumentView>(text: &str, args: &[A], start: usize) -> Self {
		let Some(suffix) = args.get(start..) else {
			return Self::default();
		};
		match suffix {
			[tag, encoded] if tag.text() == Some(WIRE_TAG) => encoded
				.text()
				.and_then(|encoded| Self::decode(text, encoded).ok())
				.unwrap_or_default(),
			_ => Self::default(),
		}
	}

	#[must_use]
	pub fn retained_bytes(&self) -> usize {
		self.0.capacity() * core::mem::size_of::<String>() + self.0.iter().map(String::capacity).sum::<usize>()
	}
}

impl Document {
	/// Distinct HTTP(S) links in authored order. Links hidden in code, raw HTML,
	/// image syntax, or refused schemes never become network candidates.
	#[must_use]
	pub fn preview_targets(&self) -> Vec<Target> {
		let mut targets = Vec::new();
		let mut seen = BTreeSet::new();
		let mut pending: Vec<&Node> = self.blocks.iter().rev().collect();
		while let Some(node) = pending.pop() {
			if let Node::Link { destination, .. } = node
				&& let Some(url) = normalize_url(destination)
				&& seen.insert(url.clone())
			{
				targets.push(Target { url });
				if targets.len() == MAX_PREVIEWS {
					break;
				}
			}
			if let Some(children) = node.children() {
				pending.extend(children.iter().rev());
			}
		}
		targets
	}
}

/// Normalize the identity Rooms uses across discovery, cache, async outcome,
/// and suppression. Credentials and fragments are never sent to a preview
/// service; default ports and host case cannot create duplicate work.
#[must_use]
pub fn normalize_url(value: &str) -> Option<String> {
	if value.len() > MAX_URL_BYTES {
		return None;
	}
	let mut url = Url::parse(value).ok()?;
	if !matches!(url.scheme(), "http" | "https")
		|| url.host().is_none()
		|| !url.username().is_empty()
		|| url.password().is_some()
	{
		return None;
	}
	url.set_fragment(None);
	if matches!((url.scheme(), url.port()), ("http", Some(80)) | ("https", Some(443))) {
		url.set_port(None).ok()?;
	}
	let normalized = String::from(url.as_str());
	(normalized.len() <= MAX_URL_BYTES).then_some(normalized)
}

#[cfg(test)]
mod tests;
