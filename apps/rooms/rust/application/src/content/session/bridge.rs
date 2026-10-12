//! Private bridge intent is tied to exact source and continuing room custody.
//! Credentials live at a separate owner. This record contains only their nonce.
use super::{custody, workspace};
use crate::{
	bridge::{Answers, Form, Id},
	fields::{Hex, SafeInteger},
	session::state::OperationId,
};
use serde::{Deserialize, Serialize};

pub const MAX_WITNESSES: usize = 64;

/// Public, exact input for one submitted effect. Secrets are a separate call
/// argument and have no serialization path into this canonical receipt.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Request {
	pub bridge: Intent,
	pub operation: OperationId,
	pub base: SafeInteger,
	pub room: workspace::Id,
	pub seat: custody::FieldKey<custody::RoomSeat>,
	pub access: Option<custody::Coordinate>,
	pub credentials: Option<Hex<16>>,
	pub reapply: Option<SafeInteger>,
}
impl Request {
	pub fn canonical(&self) -> Result<alloc::string::String, serde_json::Error> {
		serde_json::to_string(self)
	}
	pub fn read(raw: &str) -> Result<Self, serde_json::Error> {
		crate::fields::json_object(raw)
	}
	pub fn selected(&self, intent: &workspace::Intent) -> bool {
		self.bridge.validate()
			&& intent.conversations.as_slice().iter().any(|row| {
				let workspace::Conversation::Room(room) = row else {
					return false;
				};
				room.id == self.room && room.seat == Some(self.seat) && self.access == selection(room)
			})
	}
}
pub fn selection(room: &workspace::Room) -> Option<custody::Coordinate> {
	let (role, slot, generation) = match (room.access, room.accepted) {
		(Some(key), None) => (custody::Role::RoomAccess, key.slot(), key.generation()),
		(None, Some(key)) => (custody::Role::AcceptedAccess, key.slot(), key.generation()),
		_ => return None,
	};
	Some(custody::Coordinate {
		role,
		key: custody::FieldKey::new(slot, generation),
	})
}

/// A declaration, action and public answers identify the submitted form. Scope
/// text alone cannot justify sending saved credentials to a successor form.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Intent {
	pub declaration: Form,
	pub action: Id,
	pub answers: Answers,
}
impl Intent {
	pub fn validate(&self) -> bool {
		self.declaration.actions().iter().any(|action| action.id == self.action)
			&& self.declaration.split(self.answers.clone()).secrets().is_empty()
			&& self.answers.iter().all(|(id, _)| {
				self.declaration.leaves().any(|leaf| leaf.id() == id)
					|| self
						.declaration
						.fields
						.as_slice()
						.iter()
						.any(|field| matches!(field, crate::bridge::Field::Toggle(toggle) if toggle.id.as_str() == id))
			}) && self.declaration.encode().is_ok()
			&& self.answers.encode().is_ok()
	}
}

/// Independent of the bounded effect receipt window. A successful submission
/// enables reapplication only through the same source and continuing access.
/// An unresolved or refused first submission cannot become an automatic retry.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Witness {
	pub id: SafeInteger,
	pub operation: OperationId,
	pub room: workspace::Id,
	pub source: custody::FieldKey<custody::SessionAccess>,
	/// Original selection and independent private access have separate custody.
	pub selection: Option<custody::Coordinate>,
	pub access: Option<custody::Coordinate>,
	pub intent: Intent,
	pub credentials: Option<Hex<16>>,
	pub applied: bool,
}
impl Witness {
	pub fn validate<R: custody::References>(&self, held: &custody::Custody<R>) -> bool {
		self.id.get() != 0
			&& (held.next_identity().get() == 0 || self.id.get() < held.next_identity().get())
			&& self.access.is_some()
				== self
					.selection
					.is_some_and(|selection| selection.role == custody::Role::RoomAccess)
			&& self
				.selection
				.is_none_or(|access| matches!(access.role, custody::Role::RoomAccess | custody::Role::AcceptedAccess))
			&& self
				.access
				.is_none_or(|access| matches!(access.role, custody::Role::RoomAccess) && held.get(access).is_some())
			&& self
				.access
				.zip(self.selection)
				.is_none_or(|(access, selection)| access.role == selection.role)
			&& held.session_access(self.source).is_some()
			&& self.intent.validate()
	}
}

/// Explicitly releasing private origin custody forgets its witness atomically.
/// Selection changes alone preserve original custody for explicit recovery.
pub fn retire<R: custody::References, C>(record: &mut workspace::Record<R, C>) {
	let mut bridges = core::mem::take(&mut record.bridges);
	let retired = bridges.partition_out(|witness| {
		record.custody.session_access(witness.source).is_some()
			&& witness.access.is_none_or(|access| record.custody.get(access).is_some())
	});
	record.bridges = bridges;
	for witness in retired {
		let source = custody::Coordinate {
			role: custody::Role::SessionAccess,
			key: custody::FieldKey::new(witness.source.slot(), witness.source.generation()),
		};
		let keys: alloc::vec::Vec<_> = core::iter::once(source).chain(witness.access).collect();
		super::outgoing::release_sources(record, &keys);
	}
}

/// Forget only the selected room's private provenance and release custody no
/// longer used by another bridge or outgoing line. Receipts remain recoverable.
pub fn forget<R: custody::References, C>(record: &mut workspace::Record<R, C>, room: &str) {
	let forgotten = record
		.bridges
		.partition_out(|witness| witness.room.text().as_str() != Some(room));
	let keys: alloc::vec::Vec<_> = forgotten
		.into_iter()
		.flat_map(|witness| {
			core::iter::once(custody::Coordinate {
				role: custody::Role::SessionAccess,
				key: custody::FieldKey::new(witness.source.slot(), witness.source.generation()),
			})
			.chain(witness.access)
		})
		.collect();
	super::outgoing::release_sources(record, &keys);
}
