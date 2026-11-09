//! What an operator holds over a Rooms server, read as values: the trouble
//! journal, the listener seats and the intent kept for them, the diagnostic
//! snapshot, and the faces the inventories draw a room's authority in. Each
//! capability's adapter performs what these decide and reads nothing else.
pub mod bundle;
pub mod document;
pub mod faces;
pub mod inspect;
pub mod journal;
pub mod listeners;
pub mod operator;

/// The most rows one operations answer carries.
pub const MAX_OPERATIONS_ROWS: usize = 1024;

/// The boot capabilities as code tells them apart. Each row of
/// `BOOT_CAPABILITIES` carries its kind at the index the discriminant names,
/// so a set over the table is indexed by kind and a match on one is
/// exhaustive.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
	Listeners = 0,
	Diagnostics = 1,
	Operator = 2,
	Peering = 3,
	Irc = 4,
	Trace = 5,
}

/// One boot capability: its kind, the `id` the wire and the page's catalog
/// name it by, the `name` `--capabilities` takes (which is also the state file
/// its swiss number persists in), and the token line an operator greps for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BootCapability {
	pub kind: Kind,
	pub id: &'static str,
	pub name: &'static str,
	pub token: &'static str,
}

/// Every boot capability, in the order the boot block prints them and the
/// help texts list them.
pub const BOOT_CAPABILITIES: [BootCapability; 6] = [
	BootCapability {
		kind: Kind::Listeners,
		id: "listeners",
		name: "admin-listeners",
		token: "ROOMS-ADMIN-LISTENERS",
	},
	BootCapability {
		kind: Kind::Diagnostics,
		id: "diagnostics",
		name: "diagnostics",
		token: "ROOMS-DIAGNOSTICS",
	},
	BootCapability {
		kind: Kind::Operator,
		id: "operator",
		name: "operator",
		token: "ROOMS-OPERATOR",
	},
	BootCapability {
		kind: Kind::Peering,
		id: "peering",
		name: "peering",
		token: "ROOMS-PEERING",
	},
	BootCapability {
		kind: Kind::Irc,
		id: "irc",
		name: "irc",
		token: "ROOMS-IRC",
	},
	BootCapability {
		kind: Kind::Trace,
		id: "trace",
		name: "trace",
		token: "ROOMS-TRACE",
	},
];

/// The row the wire `id` names: the entry point for ids read off the wire or
/// a page's catalog, where code that already holds a row matches its `kind`.
pub fn boot_capability(id: &str) -> Option<&'static BootCapability> {
	BOOT_CAPABILITIES.iter().find(|cap| cap.id == id)
}

/// A swiss number as the state file keeps it: 32 bytes as lowercase hex.
pub const SWISS_HEX_LEN: usize = 64;

pub fn is_swiss(text: &str) -> bool {
	text.len() == SWISS_HEX_LEN && text.bytes().all(|b| b.is_ascii_digit() || matches!(b, b'a'..=b'f'))
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn the_table_is_indexed_by_kind() {
		for (index, capability) in BOOT_CAPABILITIES.iter().enumerate() {
			assert_eq!(capability.kind as usize, index, "{}", capability.name);
		}
	}
}
