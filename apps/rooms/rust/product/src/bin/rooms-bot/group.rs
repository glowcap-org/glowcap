//! A harness runs in its own process group so one signal ends the harness and
//! every process still in that group. A process that leaves the group, as one
//! started with `setsid` does, is not ended. While it runs, the bot records the group in its own
//! directory, `<bot>/groups/<conversation>`, out of the harness's reach,
//! together with what identifies the group's leader beyond its number. A
//! restarted bot ends a group a killed bot left behind only when that identity
//! still matches, so a reused process number is never signalled.
//!
//! On Linux the identity is the boot id and the leader's start time from
//! `/proc/<pid>/stat`. Elsewhere there is no such evidence, so a restart logs
//! the recorded group and leaves it alone.
//!
//! Some harnesses still outlive a killed bot. A bot killed between starting a
//! harness and writing its record leaves a harness that has not been given its
//! prompt and whose output nobody reads, so it ends at end of input or at its
//! first write. One that does neither runs on, because finding it would mean
//! scanning every process. A group whose leader has exited while other members
//! live is left alone too, since nothing confirms who those members are.
use super::error::Error;
use nix::{
	errno::Errno,
	sys::signal::{Signal, killpg},
	unistd::{Pid, getpgrp},
};
use rooms_platform::storage::{self, atomic};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

const MAX_RECORD_BYTES: usize = 512;

/// What tells a group's leader apart from a later process with its number.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Identity {
	pub boot: String,
	pub start: u64,
}

#[derive(Debug, Serialize, Deserialize)]
struct Record {
	group: u32,
	identity: Option<Identity>,
}

/// The identity of a running process, where the platform gives one.
#[cfg(target_os = "linux")]
pub fn identity(pid: u32) -> Option<Identity> {
	let boot = std::fs::read_to_string("/proc/sys/kernel/random/boot_id").ok()?;
	let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
	// The command name may hold spaces and parentheses, so fields are counted
	// from the last closing parenthesis. The start time is field 22.
	let (_, fields) = stat.rsplit_once(')')?;
	let start = fields.split_whitespace().nth(19)?.parse().ok()?;
	Some(Identity {
		boot: boot.trim().to_owned(),
		start,
	})
}

#[cfg(not(target_os = "linux"))]
pub fn identity(_pid: u32) -> Option<Identity> {
	None
}

fn pid(raw: u32) -> Result<Pid, Error> {
	i32::try_from(raw)
		.ok()
		.filter(|raw| *raw > 1)
		.map(Pid::from_raw)
		.ok_or_else(|| Error::state("groups", "a process group id out of range"))
}

/// End every process in the group. A group with no members is already ended.
fn kill(group: u32) -> Result<(), Error> {
	match killpg(pid(group)?, Signal::SIGKILL) {
		Ok(()) | Err(Errno::ESRCH) => Ok(()),
		Err(errno) => Err(Error::Io {
			context: "ending the harness process group",
			source: errno.into(),
		}),
	}
}

pub fn forget(record: &Path) -> Result<(), Error> {
	match std::fs::remove_file(record) {
		Ok(()) => Ok(()),
		Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
		Err(error) => Err(Error::io("removing a harness group record")(error)),
	}
}

/// A running harness group and its record. Dropping it ends the group, so a
/// turn that is abandoned mid-run never leaves its harness behind.
pub struct Group {
	leader: u32,
	record: PathBuf,
	/// Whether the leader may still be unreaped, so its group id is safe to
	/// signal.
	live: bool,
}

impl Group {
	/// Record a group that just started. A group that cannot be recorded is
	/// ended at once, so no unrecorded group is left running.
	pub fn record(directory: &Path, name: &str, leader: u32) -> Result<Self, Error> {
		let group = Self {
			leader,
			record: directory.join(name),
			live: true,
		};
		let record = Record {
			group: leader,
			identity: identity(leader),
		};
		let bytes = serde_json::to_vec(&record).map_err(|error| Error::state("groups", error))?;
		atomic::replace_at(directory, name, [&bytes[..]])?;
		Ok(group)
	}

	/// Signal the whole group. The record stays until [`Group::end`].
	pub fn kill(&self) -> Result<(), Error> {
		kill(self.leader)
	}

	/// Remove the record of a group whose leader has been reaped. Its group id
	/// may be reused from then on, so the group is never signalled again. The
	/// caller signals it with [`Group::kill`] before it reaps the leader.
	pub fn end(mut self) -> Result<(), Error> {
		self.live = false;
		forget(&self.record)
	}
}

impl Drop for Group {
	fn drop(&mut self) {
		// best-effort: abandoned early, a group that cannot be signalled is
		// ended by the next start.
		if self.live {
			let _ = kill(self.leader);
		}
		// best-effort: a record that stays is discarded by the next start.
		let _ = forget(&self.record);
	}
}

/// What a restart did with a record a previous bot left.
#[derive(Debug, PartialEq, Eq)]
pub enum Reaped {
	/// The leader matched its identity, and the group was ended.
	Ended(u32),
	/// No process holds the group any more.
	Gone,
	/// The group may still run, but nothing confirms it is the recorded one.
	Left(u32, &'static str),
	/// The record is not one the bot writes.
	Discarded(String),
}

/// Look at one record and end its group when its leader is confirmed. The
/// caller removes the record afterwards whatever the answer.
pub fn reap(record: &Path) -> Reaped {
	let raw = match storage::read(record, MAX_RECORD_BYTES) {
		Ok(Some(raw)) => raw,
		Ok(None) => return Reaped::Gone,
		Err(error) => return Reaped::Discarded(error.to_string()),
	};
	let Ok(Record {
		group,
		identity: recorded,
	}) = serde_json::from_slice::<Record>(&raw)
	else {
		return Reaped::Discarded("not a group record".into());
	};
	// The bot never records group 0, group 1, or its own group.
	let own = u32::try_from(getpgrp().as_raw()).unwrap_or(0);
	let target = match pid(group) {
		Ok(target) if group != own => target,
		_ => return Reaped::Discarded(format!("names group {group}, which the bot never records")),
	};
	if killpg(target, None) == Err(Errno::ESRCH) {
		return Reaped::Gone;
	}
	let Some(recorded) = recorded else {
		return Reaped::Left(group, "this platform gives no way to confirm the group's leader");
	};
	if identity(group).as_ref() != Some(&recorded) {
		return Reaped::Left(group, "its leader is gone or is another process now");
	}
	match kill(group) {
		Ok(()) => Reaped::Ended(group),
		Err(_) => Reaped::Left(group, "the group could not be signalled"),
	}
}

#[cfg(test)]
mod tests;
