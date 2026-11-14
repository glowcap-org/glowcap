//! Directory introductions retain exact private live inboxes, never alias URIs.
use super::{live::LiveRow, *};

impl LiveRow for Direct {
	const ROLE: custody::Role = custody::Role::DirectAccess;
	const NO_CAPABILITY: &'static str = "directory returned no direct inbox";
	const INVALID_RESULT: &'static str = "invalid direct result";
	const INVALID_COORDINATE: &'static str = "invalid direct coordinate";
	fn with_key(key: FieldKey<()>) -> Self {
		Self { inbox: key.retag() }
	}
	fn key(&self) -> FieldKey<()> {
		self.inbox.retag()
	}
}
