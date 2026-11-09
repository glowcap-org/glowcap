//! What an operator holds over this server: the boot capabilities minted on
//! an explicit ask and published under unguessable swiss numbers that a
//! state directory keeps across restarts, and the behaviors behind them.
//! The policies are `rooms_application::server::operations`. This tier
//! keeps the swiss files, opens sockets, and answers over CapTP.
pub(super) mod document;
pub(super) mod inspect;
pub(super) mod listeners;
pub(super) mod operator;
pub(super) mod peering;
pub(super) mod trace;

use super::{error::Error, state::Shared};
use glowcap::Argument;
use rooms_application::server::operations::{BOOT_CAPABILITIES, BootCapability, Kind, SWISS_HEX_LEN, is_swiss};
use rooms_platform::storage;
use std::path::{Path, PathBuf};

/// Which boot capabilities an operator asked for: a set over
/// `BOOT_CAPABILITIES`, indexed by `Kind`, so `parse`, `mint`, and every
/// other reader agree on the one table.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Asked {
	held: [bool; BOOT_CAPABILITIES.len()],
}

impl Asked {
	/// Read `--capabilities`: `all`, or a comma-separated list of boot
	/// capability names. Leaving a name out withholds it, and a name that is
	/// unknown, empty, or repeated is refused.
	pub(crate) fn parse(list: &str) -> Result<Self, Error> {
		let refuse = |what: String| {
			let names = BOOT_CAPABILITIES
				.iter()
				.map(|capability| capability.name)
				.collect::<Vec<_>>()
				.join(", ");
			Error::refused(format!("--capabilities {what}; use all, or names from {names}"))
		};
		if list == "all" {
			return Ok(Self {
				held: [true; BOOT_CAPABILITIES.len()],
			});
		}
		let mut asked = Self::default();
		for name in list.split(',') {
			if name == "all" {
				return Err(refuse("takes all on its own, not in a list".into()));
			}
			let Some(capability) = BOOT_CAPABILITIES.iter().find(|capability| capability.name == name) else {
				return Err(refuse(if name.is_empty() {
					"has an empty item".into()
				} else {
					format!("does not know {name:?}")
				}));
			};
			if asked.holds(capability.kind) {
				return Err(refuse(format!("repeats {name:?}")));
			}
			asked.held[capability.kind as usize] = true;
		}
		Ok(asked)
	}
	pub(crate) fn holds(&self, kind: Kind) -> bool {
		self.held[kind as usize]
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
	pub fn line(&self, locator: &glowcap::Locator) -> Result<String, Error> {
		let uri = glowcap::format_sturdyref(locator, self.swiss.as_bytes(), glowcap::CaptpVersion::V1_0)?;
		Ok(format!("{} {uri}", self.capability.token))
	}
}

/// Mint or reuse the swiss number for each asked capability, in the boot
/// block's order. With a state directory the name is reused for the life of
/// that directory, so a supervised respawn republishes the same capability
/// the operator already copied.
pub async fn mint(asked: &Asked, state: Option<&Path>) -> Result<Vec<Minted>, Error> {
	let mut minted = Vec::new();
	for capability in BOOT_CAPABILITIES.iter() {
		if !asked.holds(capability.kind) {
			continue;
		}
		let swiss = match state {
			Some(directory) => {
				let path = directory.join(capability.name);
				let file = capability.name;
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
	rooms_platform::entropy::fill(&mut bytes)
		.map_err(|e| Error::refused(format!("drawing a capability swiss failed: {e}")))?;
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
		let behavior: glowcap::Behavior = match held.capability.kind {
			Kind::Listeners => Box::new(listeners::behavior(state.clone())),
			Kind::Diagnostics => Box::new(inspect::behavior(state.clone())),
			Kind::Operator => Box::new(operator::behavior(state.clone())),
			Kind::Peering => Box::new(peering::behavior(state.clone())),
			Kind::Irc => Box::new(super::irc::behavior(state.clone())),
			// The timeline publishes the trace behavior itself.
			Kind::Trace => continue,
		};
		host.publish(&held.swiss, move || behavior)?;
	}
	Ok(())
}

/// Whether any of `args` carries a capability, which the operations verbs
/// never take. The adapter releases what it refused.
pub(super) fn carries_capability(args: &[Argument]) -> bool {
	use rooms_application::room::ArgumentView;
	args.iter().any(|arg| rooms_glowcap::Value(arg).contains_capability())
}
