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
pub const MAX_EFFECTS: usize = 8;
pub const MAX_RESULT_FIELDS: usize = 32;
pub const MAX_TARGET_FIELDS: usize = 32;
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
		let slot = NonZeroU64::new(u64::from_be_bytes(bytes[..8].try_into().expect("fixed slot")));
		let generation = NonZeroU64::new(u64::from_be_bytes(bytes[8..].try_into().expect("fixed generation")));
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
		impl Role { pub const ALL: &'static [Self] = &[$(Self::$kind,)*]; }
		pub struct Custody<R: References> { $($field: List<Held<$kind, R::$kind>, MAX_FIELDS_PER_ROLE>,)* }
		impl<R: References> Default for Custody<R> {
			fn default() -> Self { Self { $($field: List::new(alloc::vec::Vec::new()).expect("empty field table"),)* } }
		}
		impl<R: References> Custody<R> {
			/// Borrow the typed fields for a bounded hosting codec walk.
			pub fn fields(&self) -> impl Iterator<Item = Retained<'_, R>> {
				core::iter::empty()$(.chain(self.$field.as_slice().iter().map(Retained::$kind)))*
			}
			$(pub fn $field(&self, key: FieldKey<$kind>) -> Option<&Held<$kind, R::$kind>> {
				self.$field.as_slice().iter().find(|field| field.key == key)
			}
			pub fn $insert(&mut self, held: Held<$kind, R::$kind>) -> Result<(), Refusal> {
				if self.$field.as_slice().iter().any(|field| field.key.slot() == held.key.slot()) { return Err(Refusal::Duplicate); }
				self.$field.try_push(held).map_err(|_| Refusal::Capacity)
			}
			/// Release local custody without invoking grant revocation. The owner
			/// commits intent changes and this removal in the same transaction.
			pub fn $remove(&mut self, key: FieldKey<$kind>) -> Option<Held<$kind, R::$kind>> {
				let index = self.$field.0.iter().position(|field| field.key == key)?;
				Some(self.$field.0.remove(index))
			})*
		}
		pub enum Retained<'a, R: References> { $($kind(&'a Held<$kind, R::$kind>),)* }
		/// Receipt results retain exact typed roles, never bearer strings or a
		/// resource ID used to reconstruct a stronger capability.
		pub enum RetainedField<R: References> { $($kind(Held<$kind, R::$kind>),)* }
		impl<R: References> Retained<'_, R> {
			pub fn coordinate(&self) -> Coordinate {
				match self { $(Self::$kind(field) => Coordinate { role: Role::$kind, key: FieldKey::new(field.key.slot(), field.key.generation()) },)* }
			}
		}
		impl<R: References> RetainedField<R> {
			pub fn borrowed(&self) -> Retained<'_, R> { match self { $(Self::$kind(field) => Retained::$kind(field),)* } }
		}
		impl<R: References> Custody<R> {
			pub fn insert(&mut self, field: RetainedField<R>) -> Result<(), Refusal> {
				match field { $(RetainedField::$kind(field) => self.$insert(field),)* }
			}
		}
	};
}
custody! {
	SessionAccess => session_access, insert_session_access, remove_session_access;
	RoomAccess => room_access, insert_room_access, remove_room_access;
	DirectoryAccess => directory_access, insert_directory_access, remove_directory_access;
	DirectAccess => direct_access, insert_direct_access, remove_direct_access;
	ArchiveAccess => archive_access, insert_archive_access, remove_archive_access;
	Operator => operator, insert_operator, remove_operator;
	Offer => offer, insert_offer, remove_offer;
	AcceptedAccess => accepted_access, insert_accepted_access, remove_accepted_access;
	RoomControl => room_control, insert_room_control, remove_room_control;
	ArchiveControl => archive_control, insert_archive_control, remove_archive_control;
	CreationReceipt => creation_receipt, insert_creation_receipt, remove_creation_receipt;
	PublicationLease => publication_lease, insert_publication_lease, remove_publication_lease;
}

/// A record's typed field coordinate. Hosting supplies the corresponding held
/// reference separately; decoding these bytes cannot restore authority.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Coordinate {
	pub role: Role,
	pub key: FieldKey<()>,
}

/// Bind content to the shared managed resource without repeating its canonical
/// parent or resource identity. The hosting codec supplies this strong edge.
pub struct ResourceBinding<C> {
	pub resource: C,
}

pub struct EffectReceipt<R: References> {
	pub operation: OperationId,
	pub canonical_intent: Text<262144, true>,
	pub attachment_generation: NonZeroU64,
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
	KnownAbsent,
	Committed {
		result: Text<32768>,
		retained: List<RetainedField<R>, MAX_RESULT_FIELDS>,
	},
}
pub type EffectReceipts<R> = List<EffectReceipt<R>, MAX_EFFECTS>;
