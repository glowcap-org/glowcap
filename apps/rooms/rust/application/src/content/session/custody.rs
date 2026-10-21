//! Version-one session custody and effect records. Capability fields have no
//! JSON codec: the hosting adapter supplies typed held references and shared
//! Loam owns their save/restore recipes. Workspace intent may retain FieldKey
//! values, which select an existing field and cannot restore authority alone.
use crate::{
	fields::{Hex, List, Text},
	session::state::OperationId,
};
use core::{marker::PhantomData, num::NonZeroU64};
use serde::{Deserialize, Deserializer, Serialize, Serializer, de::Error};

pub const MAX_FIELDS_PER_ROLE: usize = 256;
/// Aggregate admission stays fixed as new typed roles enter the vocabulary.
pub const MAX_CUSTODY_FIELDS: usize = 3072;
pub const MAX_EFFECTS: usize = 8;
pub const MAX_RESULT_FIELDS: usize = 32;
pub const MAX_TARGET_FIELDS: usize = 32;
pub const MAX_OBSERVATION_REASON_UNITS: usize = 4096;
pub const MAX_AUTHORITY_BYTES: usize = 1024 * 1024;

/// Data coordinate inside this session owner, not a publication or resource ID.
#[derive(Debug, PartialEq, Eq)]
pub struct FieldKey<K> {
	slot: NonZeroU64,
	generation: NonZeroU64,
	kind: PhantomData<K>,
}
impl<K> Copy for FieldKey<K> {}
impl<K> Clone for FieldKey<K> {
	fn clone(&self) -> Self {
		*self
	}
}
impl<K> FieldKey<K> {
	pub const fn new(slot: NonZeroU64, generation: NonZeroU64) -> Self {
		Self {
			slot,
			generation,
			kind: PhantomData,
		}
	}
	pub const fn slot(self) -> NonZeroU64 {
		self.slot
	}
	pub const fn generation(self) -> NonZeroU64 {
		self.generation
	}
}
impl<K> Serialize for FieldKey<K> {
	fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
		let mut bytes = [0; 16];
		bytes[..8].copy_from_slice(&self.slot.get().to_be_bytes());
		bytes[8..].copy_from_slice(&self.generation.get().to_be_bytes());
		Hex(bytes).serialize(s)
	}
}
impl<'de, K> Deserialize<'de> for FieldKey<K> {
	fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
		let bytes = Hex::<16>::deserialize(d)?.0;
		let half = |half: &[u8]| -> Result<Option<NonZeroU64>, D::Error> {
			let half: [u8; 8] = half
				.try_into()
				.map_err(|_| D::Error::custom("a custody key is two eight-byte halves"))?;
			Ok(NonZeroU64::new(u64::from_be_bytes(half)))
		};
		let slot = half(&bytes[..8])?;
		let generation = half(&bytes[8..])?;
		match (slot, generation) {
			(Some(slot), Some(generation)) => Ok(Self::new(slot, generation)),
			_ => Err(D::Error::custom("nonzero custody slot and generation")),
		}
	}
}

pub struct Held<K, C> {
	pub key: FieldKey<K>,
	pub reference: C,
}
impl<K, C: PartialEq> PartialEq for Held<K, C> {
	fn eq(&self, other: &Self) -> bool {
		self.key.slot() == other.key.slot()
			&& self.key.generation() == other.key.generation()
			&& self.reference == other.reference
	}
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
	Duplicate,
	Capacity,
}

macro_rules! custody {
	($($kind:ident => $field:ident, $insert:ident, $remove:ident;)*) => {
		/// Implementations distinguish checked application roles even if their
		/// transport represents every capability with the same Ref type.
		pub trait References { $(type $kind;)* }
		$(#[derive(Clone, Copy, Debug, PartialEq, Eq)] pub enum $kind {})*
		#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
		#[serde(rename_all = "camelCase")]
		pub enum Role { $($kind,)* }
		impl Role {
			pub const ALL: &'static [Self] = &[$(Self::$kind,)*];
			/// This role's position in `ALL`, which lists the roles in declaration order.
			pub const fn index(self) -> usize { self as usize }
		}
		pub struct Custody<R: References> { count: usize, next_identity: crate::fields::SafeInteger, $($field: List<Held<$kind, R::$kind>, MAX_FIELDS_PER_ROLE>,)* }
		impl<R: References> Default for Custody<R> {
			fn default() -> Self { Self { count: 0, next_identity: crate::fields::SafeInteger::literal(1), $($field: List::default(),)* } }
		}
		impl<R: References> Custody<R> {
			pub fn next_identity(&self) -> crate::fields::SafeInteger { self.next_identity }
			pub fn set_next_identity(&mut self, next: crate::fields::SafeInteger) { self.next_identity = next; }
			pub fn len(&self) -> usize { self.count }
			pub fn is_empty(&self) -> bool { self.count == 0 }
			/// Borrow the typed fields for a bounded hosting codec walk.
			pub fn fields(&self) -> impl Iterator<Item = Retained<'_, R>> {
				core::iter::empty()$(.chain(self.$field.as_slice().iter().map(Retained::$kind)))*
			}
			$(pub fn $field(&self, key: FieldKey<$kind>) -> Option<&Held<$kind, R::$kind>> {
				self.$field.as_slice().iter().find(|field| field.key == key)
			}
			pub fn $insert(&mut self, held: Held<$kind, R::$kind>) -> Result<(), Refusal> {
				if self.$field.as_slice().iter().any(|field| field.key.slot() == held.key.slot()) { return Err(Refusal::Duplicate); }
				if self.count >= MAX_CUSTODY_FIELDS { return Err(Refusal::Capacity); }
				self.$field.try_push(held).map_err(|_| Refusal::Capacity)?;
				self.count += 1;
				Ok(())
			}
			/// Release local custody without invoking grant revocation. The owner
			/// commits intent changes and this removal in the same transaction.
			pub fn $remove(&mut self, key: FieldKey<$kind>) -> Option<Held<$kind, R::$kind>> {
				let index = self.$field.0.iter().position(|field| field.key == key)?;
				self.count -= 1;
				Some(self.$field.0.remove(index))
			})*
		}
		pub enum Retained<'a, R: References> { $($kind(&'a Held<$kind, R::$kind>),)* }
		/// Receipt results retain exact typed roles, never bearer strings or a
		/// resource ID used to reconstruct a stronger capability. status-allow: purpose clause
		pub enum RetainedField<R: References> { $($kind(Held<$kind, R::$kind>),)* }
		impl<R: References> PartialEq for RetainedField<R> where $(R::$kind: PartialEq,)* {
			fn eq(&self, other: &Self) -> bool {
				match (self, other) { $((Self::$kind(left), Self::$kind(right)) => left == right,)* _ => false }
			}
		}
		impl<R: References> PartialEq for Outcome<R> where $(R::$kind: PartialEq,)* {
			fn eq(&self, other: &Self) -> bool {
				match (self, other) {
					(Self::Unresolved, Self::Unresolved) | (Self::KnownAbsent, Self::KnownAbsent) => true,
					(Self::Unknown { reason: left }, Self::Unknown { reason: right })
					| (Self::Refused { reason: left }, Self::Refused { reason: right }) => left == right,
					(Self::Committed { result: left, retained: left_fields }, Self::Committed { result: right, retained: right_fields }) =>
						left == right && left_fields.as_slice() == right_fields.as_slice(),
					_ => false,
				}
			}
		}
		impl<R: References> Retained<'_, R> {
			pub fn coordinate(&self) -> Coordinate {
				match self { $(Self::$kind(field) => Coordinate { role: Role::$kind, key: FieldKey::new(field.key.slot(), field.key.generation()) },)* }
			}
		}
		impl<R: References> RetainedField<R> {
			pub fn borrowed(&self) -> Retained<'_, R> { match self { $(Self::$kind(field) => Retained::$kind(field),)* } }
		}
		impl<R: References> Custody<R> {
			/// Select an existing exact typed field, never reconstruct authority.
			pub fn get(&self, coordinate: Coordinate) -> Option<Retained<'_, R>> {
				let key = coordinate.key;
				match coordinate.role { $(Role::$kind => self.$field(FieldKey::new(key.slot(), key.generation())).map(Retained::$kind),)* }
			}
			/// Remove only the exact role, slot and generation. Effects retain their
			/// own occurrences independently of workspace custody.
			pub fn remove(&mut self, coordinate: Coordinate) -> Option<RetainedField<R>> {
				let key = coordinate.key;
				match coordinate.role { $(Role::$kind => self.$remove(FieldKey::new(key.slot(), key.generation())).map(RetainedField::$kind),)* }
			}
			pub fn insert(&mut self, field: RetainedField<R>) -> Result<(), Refusal> {
				match field { $(RetainedField::$kind(field) => self.$insert(field),)* }
			}
		}
	};
}
custody! {
	SessionAccess => session_access, insert_session_access, remove_session_access;
	SessionControl => session_control, insert_session_control, remove_session_control;
	RoomAccess => room_access, insert_room_access, remove_room_access;
	DirectoryAccess => directory_access, insert_directory_access, remove_directory_access;
	DirectAccess => direct_access, insert_direct_access, remove_direct_access;
	DirectInbox => direct_inbox, insert_direct_inbox, remove_direct_inbox;
	ArchiveAccess => archive_access, insert_archive_access, remove_archive_access;
	Operator => operator, insert_operator, remove_operator;
	Operations => operations, insert_operations, remove_operations;
	IrcConnection => irc_connection, insert_irc_connection, remove_irc_connection;
	Offer => offer, insert_offer, remove_offer;
	AcceptedAccess => accepted_access, insert_accepted_access, remove_accepted_access;
	RoomControl => room_control, insert_room_control, remove_room_control;
	ArchiveControl => archive_control, insert_archive_control, remove_archive_control;
	CreationReceipt => creation_receipt, insert_creation_receipt, remove_creation_receipt;
	PublicationLease => publication_lease, insert_publication_lease, remove_publication_lease;
	RoomSeat => room_seat, insert_room_seat, remove_room_seat;
	RoomSubject => room_subject, insert_room_subject, remove_room_subject;
	RoomInbox => room_inbox, insert_room_inbox, remove_room_inbox;
	RoomFiles => room_files, insert_room_files, remove_room_files;
	Line => line, insert_line, remove_line;
	DirectoryName => directory_name, insert_directory_name, remove_directory_name;
	DirectoryInbox => directory_inbox, insert_directory_inbox, remove_directory_inbox;
	SourceBlob => source_blob, insert_source_blob, remove_source_blob;
}

impl Role {
	/// These exact actors expire with the attachment's actual Host lifetime.
	/// Direct inboxes are registration-scoped Host aliases, not durable grants.
	pub const fn live(self) -> bool {
		matches!(
			self,
			Self::Offer
				| Self::DirectAccess
				| Self::DirectInbox
				| Self::IrcConnection
				| Self::AcceptedAccess
				| Self::RoomSeat
				| Self::RoomSubject
				| Self::RoomInbox
				| Self::RoomFiles
				| Self::Line | Self::PublicationLease
				| Self::DirectoryName
				| Self::DirectoryInbox
				| Self::SourceBlob
		)
	}
}

/// A record's typed field coordinate. Hosting supplies the corresponding held
/// reference separately. Decoding these bytes cannot restore authority.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Coordinate {
	pub role: Role,
	pub key: FieldKey<()>,
}
impl Coordinate {
	/// Wire coordinates are JSON objects with an exact typed key. Positional
	/// arrays cannot supply a checked role or select receipt/custody authority.
	pub fn decode(raw: &str) -> Result<Self, serde_json::Error> {
		crate::fields::json_object(raw)
	}
}

/// Bind content to the shared managed resource without repeating its canonical
/// parent or resource identity. The hosting codec supplies this strong edge.
pub struct ResourceBinding<C> {
	pub resource: C,
}

pub struct EffectReceipt<R: References> {
	pub operation: OperationId,
	/// The first workspace adoption commits with its exact transferred fields.
	/// Recovery cannot install the same result into a second topology.
	pub adopted: bool,
	/// Private capacity and coordinate reservation, committed before dispatch.
	/// Exported intent cannot supply this sender provenance.
	pub outgoing: Option<super::outgoing::Update>,
	/// Scalar contact provenance captured at introduction admission. One bounded
	/// registration and opening identity survive in the receipt. Coordinates stay inline.
	/// Recovery cannot replace it with a subsequently selected registration.
	pub introduction: Option<super::workspace::Introduction>,
	pub canonical_intent: Text<262144, true>,
	pub resource_generation: NonZeroU64,
	/// The original mediation grant and exact targets survive workspace changes.
	/// Recovery cannot select replacement authority from current intent.
	pub source: Held<SessionAccess, R::SessionAccess>,
	pub targets: List<RetainedField<R>, MAX_TARGET_FIELDS>,
	pub outcome: Outcome<R>,
}
/// Known absence and uncertain completion are distinct. Committed capability
/// results remain in the bounded receipt rather than being minted on replay.
pub enum Outcome<R: References> {
	Unresolved,
	/// A terminal observation failed. The reason is diagnostic, never proof
	/// that the target did nothing or permission to dispatch the effect again.
	Unknown {
		reason: Text<MAX_OBSERVATION_REASON_UNITS, true>,
	},
	KnownAbsent,
	/// Host admission or a validated Rooms refusal proves no dispatch and retains
	/// its diagnostic. It neither admits a retry nor queues a future mutation.
	Refused {
		reason: Text<MAX_OBSERVATION_REASON_UNITS, true>,
	},
	Committed {
		result: Text<32768>,
		retained: List<RetainedField<R>, MAX_RESULT_FIELDS>,
	},
}
pub type EffectReceipts<R> = List<EffectReceipt<R>, MAX_EFFECTS>;

#[cfg(test)]
mod role_order {
	use super::Role;

	#[test]
	fn a_role_indexes_its_own_row_in_all() {
		for (index, role) in Role::ALL.iter().enumerate() {
			assert_eq!(role.index(), index);
		}
	}
}
