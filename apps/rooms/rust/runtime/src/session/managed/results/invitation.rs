//! Claimed entrances remain private live custody until mediated subscription.
use super::{live::LiveRow, *};

impl LiveRow for Acceptance {
	const ROLE: custody::Role = custody::Role::AcceptedAccess;
	const NO_CAPABILITY: &'static str = "invitation returned no entrance capability";
	const INVALID_RESULT: &'static str = "invalid acceptance result";
	const INVALID_COORDINATE: &'static str = "invalid entrance coordinate";
	fn with_key(key: FieldKey<()>) -> Self {
		Self { entrance: key.retag() }
	}
	fn key(&self) -> FieldKey<()> {
		self.entrance.retag()
	}
}
