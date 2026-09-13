//! Structured markers on room notifications. This reads metadata only; inbox
//! admission, attachment custody, and bounded delivery are separate owners.
use super::ArgumentView;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LineId(u64);

impl LineId {
	/// Existing clients read ids as positive JavaScript safe integers.
	pub const fn new(value: u64) -> Option<Self> {
		if value > 0 && value < (1_u64 << 53) {
			Some(Self(value))
		} else {
			None
		}
	}

	pub const fn get(self) -> u64 {
		self.0
	}

	pub(crate) fn read(value: &impl ArgumentView) -> Option<Self> {
		if let Some(integer) = value.integer() {
			return u64::try_from(integer).ok().and_then(Self::new);
		}
		let number = value.float()?;
		// Range checks also reject infinities and NaN before integer conversion.
		if !(number > 0.0 && number < (1_u64 << 53) as f64) {
			return None;
		}
		let integer = number as u64;
		(integer as f64 == number).then_some(Self(integer))
	}
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ChangeKind {
	Said,
	Edited,
	Refiled,
	Withdrawn,
}

impl ChangeKind {
	/// The marker word on the room inbox wire, where a fresh line is `line`.
	pub const fn wire_tag(self) -> &'static str {
		match self {
			Self::Said => crate::protocol_data::LINE,
			Self::Edited => crate::protocol_data::EDITED,
			Self::Refiled => crate::protocol_data::REFILED,
			Self::Withdrawn => crate::protocol_data::WITHDRAWN,
		}
	}
	/// The change word in an attached view's `event` notification. It is a
	/// different vocabulary from the room wire: a fresh line is `said` there,
	/// and a view's parser refuses `line`.
	pub const fn event_change(self) -> &'static str {
		match self {
			Self::Said => "said",
			Self::Edited => crate::protocol_data::EDITED,
			Self::Refiled => crate::protocol_data::REFILED,
			Self::Withdrawn => crate::protocol_data::WITHDRAWN,
		}
	}
	pub fn parse(tag: &str) -> Option<Self> {
		match tag {
			crate::protocol_data::LINE => Some(Self::Said),
			crate::protocol_data::EDITED => Some(Self::Edited),
			crate::protocol_data::REFILED => Some(Self::Refiled),
			crate::protocol_data::WITHDRAWN => Some(Self::Withdrawn),
			_ => None,
		}
	}
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LineMarker {
	pub id: LineId,
	pub kind: ChangeKind,
}

impl LineMarker {
	/// Unknown tags and malformed ids contribute no marker. They do not by
	/// themselves discard the notification's display text. The caller still
	/// owns every argument and must perform full inbox and attachment admission.
	pub fn read<A: ArgumentView>(args: &[A]) -> Option<Self> {
		Some(Self {
			kind: ChangeKind::parse(args.get(2)?.text()?)?,
			id: LineId::read(args.get(3)?)?,
		})
	}
}
