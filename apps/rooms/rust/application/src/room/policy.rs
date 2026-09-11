//! The three supported room policies. Impossible mode combinations cannot be
//! constructed; parsing holds the current three-slot Rooms wire contract.

#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MembershipKind {
	Observer,
	Participant,
}

impl MembershipKind {
	pub fn parse(value: &str) -> Option<Self> {
		match value {
			"observer" => Some(Self::Observer),
			"participant" => Some(Self::Participant),
			_ => None,
		}
	}

	pub const fn as_str(self) -> &'static str {
		match self {
			Self::Observer => "observer",
			Self::Participant => "participant",
		}
	}
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RoomPolicy {
	Open,
	Moderated,
	Private,
}

impl RoomPolicy {
	pub fn from_preset(preset: &str) -> Option<Self> {
		match preset {
			"open" => Some(Self::Open),
			"moderated" => Some(Self::Moderated),
			"private" => Some(Self::Private),
			_ => None,
		}
	}
	pub fn parse(modes: &[&str]) -> Option<Self> {
		match modes {
			["listed", "open", "open"] => Some(Self::Open),
			["listed", "open", "moderated"] => Some(Self::Moderated),
			["secret", "invite-only", "moderated"] => Some(Self::Private),
			_ => None,
		}
	}

	pub const fn modes(self) -> [&'static str; 3] {
		match self {
			Self::Open => ["listed", "open", "open"],
			Self::Moderated => ["listed", "open", "moderated"],
			Self::Private => ["secret", "invite-only", "moderated"],
		}
	}

	pub const fn is_listed(self) -> bool {
		!matches!(self, Self::Private)
	}

	/// The public entrance's offered facet. Private rooms have no public
	/// entrance; invitation authority chooses its facet independently.
	pub const fn public_membership(self) -> Option<MembershipKind> {
		match self {
			Self::Open => Some(MembershipKind::Participant),
			Self::Moderated => Some(MembershipKind::Observer),
			Self::Private => None,
		}
	}
}

impl serde::Serialize for RoomPolicy {
	fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
		use serde::ser::SerializeStruct;
		let [visibility, entry, speaking] = self.modes();
		let mut value = serializer.serialize_struct("RoomPolicy", 3)?;
		value.serialize_field("visibility", visibility)?;
		value.serialize_field("entry", entry)?;
		value.serialize_field("speaking", speaking)?;
		value.end()
	}
}
impl<'de> serde::Deserialize<'de> for RoomPolicy {
	fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
		#[derive(serde::Deserialize)]
		#[serde(deny_unknown_fields)]
		struct Modes {
			visibility: alloc::string::String,
			entry: alloc::string::String,
			speaking: alloc::string::String,
		}
		let m = Modes::deserialize(d)?;
		Self::parse(&[&m.visibility, &m.entry, &m.speaking]).ok_or_else(|| serde::de::Error::custom("room policy"))
	}
}
