//! A returned lease is exact live custody, independently of listing readiness.
use super::{live::LiveRow, *};

impl LiveRow for Publication {
	const ROLE: custody::Role = custody::Role::PublicationLease;
	const NO_CAPABILITY: &'static str = "publication returned no lease capability";
	const INVALID_RESULT: &'static str = "invalid publication result";
	const INVALID_COORDINATE: &'static str = "invalid lease coordinate";
	fn with_key(key: FieldKey<()>) -> Self {
		Self { lease: key.retag() }
	}
	fn key(&self) -> FieldKey<()> {
		self.lease.retag()
	}
}
