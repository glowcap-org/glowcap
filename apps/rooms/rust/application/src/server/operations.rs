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

/// One boot capability: the flag that mints it, the state file its swiss
/// number persists in, and the token line an operator greps for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BootCapability {
	pub id: &'static str,
	pub flag: &'static str,
	pub env: &'static str,
	pub file: &'static str,
	pub token: &'static str,
}

/// Every boot capability, in the order the boot block prints them.
pub const BOOT_CAPABILITIES: [BootCapability; 6] = [
	BootCapability {
		id: "listeners",
		flag: "--admin-listeners",
		env: "GLOWCAP_ROOMS_ADMIN_LISTENERS",
		file: "admin-listeners",
		token: "ROOMS-ADMIN-LISTENERS",
	},
	BootCapability {
		id: "diagnostics",
		flag: "--diagnostics",
		env: "GLOWCAP_ROOMS_DIAGNOSTICS",
		file: "diagnostics",
		token: "ROOMS-DIAGNOSTICS",
	},
	BootCapability {
		id: "irc",
		flag: "--irc",
		env: "GLOWCAP_ROOMS_IRC",
		file: "irc",
		token: "ROOMS-IRC",
	},
	BootCapability {
		id: "operator",
		flag: "--operator",
		env: "GLOWCAP_ROOMS_OPERATOR",
		file: "operator",
		token: "ROOMS-OPERATOR",
	},
	BootCapability {
		id: "peering",
		flag: "--peering",
		env: "GLOWCAP_ROOMS_PEERING",
		file: "peering",
		token: "ROOMS-PEERING",
	},
	BootCapability {
		id: "trace",
		flag: "--trace",
		env: "GLOWCAP_ROOMS_TRACE",
		file: "trace",
		token: "ROOMS-TRACE",
	},
];

pub fn boot_capability(id: &str) -> Option<&'static BootCapability> {
	BOOT_CAPABILITIES.iter().find(|cap| cap.id == id)
}

/// A swiss number as the state file keeps it: 32 bytes as lowercase hex.
pub const SWISS_HEX_LEN: usize = 64;

pub fn is_swiss(text: &str) -> bool {
	text.len() == SWISS_HEX_LEN && text.bytes().all(|b| b.is_ascii_digit() || matches!(b, b'a'..=b'f'))
}
