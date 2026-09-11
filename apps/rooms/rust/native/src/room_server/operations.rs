//! What an operator holds over this server: the boot capabilities minted on
//! an explicit ask and published under unguessable swiss numbers that a
//! state directory keeps across restarts, and the behaviors behind them.
//! The policies are `rooms_application::server::operations`; this tier
//! keeps the swiss files, opens sockets, and answers over CapTP.
pub(super) mod document;
pub(super) mod inspect;
pub(super) mod listeners;
pub(super) mod operator;
pub(super) mod peering;
pub(super) mod viz;

use super::{error::Error, state::Shared};
use crate::storage;
use glowcap::Argument;
use rooms_application::server::operations::{is_swiss, BootCapability, SWISS_HEX_LEN};
use std::path::{Path, PathBuf};

/// Which boot capabilities an operator asked for.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Asked {
	pub admin_listeners: bool,
	pub diagnostics: bool,
	pub operator: bool,
	pub peering: bool,
	pub irc: bool,
	pub viz: bool,
}

impl Asked {
	pub fn any(&self) -> bool {
		self.admin_listeners || self.diagnostics || self.operator || self.peering || self.irc || self.viz
	}
	fn asked(&self, id: &str) -> bool {
		match id {
			"listeners" => self.admin_listeners,
			"diagnostics" => self.diagnostics,
			"operator" => self.operator,
			"peering" => self.peering,
			"viz" => self.viz,
			"irc" => self.irc,
			_ => false,
		}
	}
}

/// One minted capability: its token line and the swiss it answers under.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Minted {
	pub capability: &'static BootCapability,
	pub swiss: String,
}

impl Minted {
	/// The flush-left line an operator greps for.
	pub fn line(&self) -> String {
		format!("{} {}", self.capability.token, self.swiss)
	}
}

/// Mint or reuse the swiss number for each asked capability, in the boot
/// block's order. With a state directory the name is reused for the life of
/// that directory, so a supervised respawn republishes the same capability
/// the operator already copied.
pub async fn mint(asked: &Asked, state: Option<&Path>) -> Result<Vec<Minted>, Error> {
	let mut minted = Vec::new();
	for capability in rooms_application::server::operations::BOOT_CAPABILITIES.iter() {
		if !asked.asked(capability.id) {
			continue;
		}
		let swiss = match state {
			Some(directory) => {
				let path = directory.join(capability.file);
				let file = capability.file;
				tokio::task::spawn_blocking(move || persistent_swiss(&path, file))
					.await
					.map_err(|e| Error::Worker(e.to_string()))??
			}
			None => fresh_swiss()?,
		};
		minted.push(Minted { capability, swiss });
	}
	Ok(minted)
}

fn fresh_swiss() -> Result<String, Error> {
	let mut bytes = [0u8; SWISS_HEX_LEN / 2];
	getrandom::fill(&mut bytes).map_err(|e| Error::refused(format!("drawing a capability swiss failed: {e}")))?;
	Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

fn persistent_swiss(path: &PathBuf, file: &str) -> Result<String, Error> {
	if let Some(bytes) = storage::read(path, 256)? {
		let text = std::str::from_utf8(&bytes)
			.map_err(|_| Error::refused(format!("{file} state is not a complete swiss number")))?
			.trim();
		if !is_swiss(text) {
			return Err(Error::refused(format!("{file} state is not a complete swiss number")));
		}
		return Ok(text.into());
	}
	let directory = path
		.parent()
		.ok_or_else(|| Error::refused("the state directory has no parent"))?;
	std::fs::create_dir_all(directory)?;
	let swiss = fresh_swiss()?;
	let staged = directory.join(format!(".{file}.staged"));
	std::fs::write(&staged, format!("{swiss}\n"))?;
	std::fs::rename(&staged, path)?;
	Ok(swiss)
}

/// Publish every minted behavior on the Host before the listener opens, so
/// a reused swiss never has a window answering `unknown swissnum`.
pub(super) fn publish(state: &Shared, minted: &[Minted]) -> Result<(), Error> {
	let host = state.borrow().host.clone();
	for held in minted {
		let behavior: glowcap::Behavior = match held.capability.id {
			"listeners" => Box::new(listeners::behavior(state.clone())),
			"diagnostics" => Box::new(inspect::behavior(state.clone())),
			"operator" => Box::new(operator::behavior(state.clone())),
			"peering" => Box::new(peering::behavior(state.clone())),
			"irc" => Box::new(super::irc::behavior(state.clone())),
			// The other capabilities' behaviors land with their own owners.
			_ => continue,
		};
		host.publish_giftable(&held.swiss, move || behavior)?;
	}
	Ok(())
}

/// Whether any of `args` carries a capability, which the operations verbs
/// never take. The adapter releases what it refused.
pub(super) fn carries_capability(args: &[Argument]) -> bool {
	use rooms_application::room::ArgumentView;
	args.iter().any(|arg| rooms_glowcap::Value(arg).contains_capability())
}
