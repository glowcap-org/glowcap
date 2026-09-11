//! Adapter actions and protocol refusals produced by the bridged room.
use super::super::{relay, wire::Notice};
use crate::failure::FailureCode;
use alloc::{format, string::String, vec::Vec};

/// One thing a bridged room asks the adapter to do.
#[derive(Debug)]
pub struct Effects<C, R> {
	pub tells: Vec<(C, R, Notice)>,
	/// Connections whose membership annotation must be recomputed.
	pub presence: Vec<C>,
	/// Inboxes given back on the connection they came from.
	pub releases: Vec<(C, R)>,
	/// The member count a directory lists changed.
	pub count_changed: bool,
	/// What the feed must do for this channel's membership.
	pub relay: Vec<relay::Action>,
}

impl<C, R> Default for Effects<C, R> {
	fn default() -> Self {
		Self {
			tells: Vec::new(),
			presence: Vec::new(),
			releases: Vec::new(),
			count_changed: false,
			relay: Vec::new(),
		}
	}
}

impl<C, R> Effects<C, R> {
	pub fn extend(&mut self, other: Self) {
		self.tells.extend(other.tells);
		self.presence.extend(other.presence);
		self.releases.extend(other.releases);
		self.count_changed |= other.count_changed;
		self.relay.extend(other.relay);
	}
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refusal {
	pub code: Option<FailureCode>,
	pub detail: String,
}

impl Refusal {
	pub(super) fn plain(detail: impl Into<String>) -> Self {
		Self {
			code: None,
			detail: detail.into(),
		}
	}
	pub(super) fn coded(code: FailureCode, detail: impl Into<String>) -> Self {
		Self {
			code: Some(code),
			detail: detail.into(),
		}
	}
	pub fn reason(&self) -> String {
		match self.code {
			Some(code) => format!("{}: {}", code.wire(), self.detail),
			None => self.detail.clone(),
		}
	}
}
