//! A harness runs in its own process group so one signal ends the harness and
//! every process still in that group. A process that leaves the group, as one
//! started with `setsid` does, is not ended, and Claude Code, Codex, and Pi
//! each start the agent's tool commands in a session of their own, so no
//! verb or other command the agent ran is reached by this signal: a verb ends
//! by its own budget, and any other command by nothing here. While it runs, the bot records the group in its own
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
use super::{error::Error, store::Store, words::ENDED_GROUP};
use nix::{
	errno::Errno,
	sys::signal::{SigSet, Signal, killpg},
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

/// What `/proc/<pid>/stat` says of a process: its state letter and its start
/// time in clock ticks since boot.
#[cfg(target_os = "linux")]
struct Stat {
	state: char,
	start: u64,
}

#[cfg(target_os = "linux")]
fn stat(pid: u32) -> Result<Stat, std::io::Error> {
	let text = std::fs::read_to_string(format!("/proc/{pid}/stat"))?;
	// The command name may hold spaces and parentheses, so fields are counted
	// from the last closing parenthesis. The state is field 3 and the start
	// time field 22.
	let unreadable = || std::io::Error::other("not a /proc stat line");
	let (_, fields) = text.rsplit_once(')').ok_or_else(unreadable)?;
	let mut fields = fields.split_whitespace();
	let state = fields
		.next()
		.and_then(|state| state.chars().next())
		.ok_or_else(unreadable)?;
	let start = fields
		.nth(18)
		.and_then(|start| start.parse().ok())
		.ok_or_else(unreadable)?;
	Ok(Stat { state, start })
}

#[cfg(target_os = "linux")]
fn boot_id() -> Result<String, std::io::Error> {
	Ok(std::fs::read_to_string("/proc/sys/kernel/random/boot_id")?
		.trim()
		.to_owned())
}

/// The identity of a running process, where the platform gives one.
#[cfg(target_os = "linux")]
pub fn identity(pid: u32) -> Option<Identity> {
	Some(Identity {
		boot: boot_id().ok()?,
		start: stat(pid).ok()?.start,
	})
}

#[cfg(not(target_os = "linux"))]
pub fn identity(_pid: u32) -> Option<Identity> {
	None
}

/// A verb process as it wrote itself into its claim: its number, what tells
/// it apart from a later process with that number, and the process-number
/// namespace the number is in. The number means something only to a reader in
/// the same namespace, so a reader in another never judges it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Verb {
	pid: u32,
	identity: Identity,
	namespace: String,
}

/// Whether a recorded verb process is still running, as far as the reader can
/// tell.
#[derive(Debug, PartialEq, Eq)]
pub enum Presence {
	/// The process runs.
	Alive,
	/// Definitely not running: no such process, another process with that
	/// number (a different start time), a process that has ended and waits to
	/// be reaped, or a different boot.
	Gone,
	/// The reader cannot tell, for the reason given: a platform with no
	/// evidence, a namespace that is not the writer's, or a read that failed.
	Unknown(String),
}

#[cfg(target_os = "linux")]
fn namespace() -> Result<String, std::io::Error> {
	Ok(std::fs::read_link("/proc/self/ns/pid")?.to_string_lossy().into_owned())
}

impl Verb {
	/// This process, or none where the platform or a failed read gives no
	/// evidence. A claim written then names no verb and stays with its verb.
	pub fn this_process() -> Option<Self> {
		Self::of(std::process::id())
	}

	/// The process `pid`, in this process's namespace, as it runs now.
	#[cfg(target_os = "linux")]
	pub fn of(pid: u32) -> Option<Self> {
		Some(Self {
			pid,
			identity: identity(pid)?,
			namespace: namespace().ok()?,
		})
	}

	#[cfg(not(target_os = "linux"))]
	pub fn of(_pid: u32) -> Option<Self> {
		None
	}

	/// Whether the recorded process runs. Only a definite "no such process, or
	/// another start" reads as gone, so a read that fails or a namespace that
	/// is not the reader's leaves the verb holding its claim.
	///
	/// A process number is reused only after the numbers wrap, and a process
	/// that takes the number later starts later in the same boot (and in
	/// another boot has another boot id), so the pair of number and start time
	/// names one process for ever.
	#[cfg(target_os = "linux")]
	pub fn presence(&self) -> Presence {
		let unreadable = |what: &str, error: std::io::Error| Presence::Unknown(format!("{what}: {error}"));
		match namespace() {
			Ok(own) if own == self.namespace => {}
			Ok(_) => return Presence::Unknown("the verb runs in another process-number namespace".into()),
			Err(error) => return unreadable("reading this process's namespace", error),
		}
		match boot_id() {
			Ok(boot) if boot != self.identity.boot => return Presence::Gone,
			Ok(_) => {}
			Err(error) => return unreadable("reading the boot id", error),
		}
		match stat(self.pid) {
			Ok(Stat { state: 'Z' | 'X', .. }) => Presence::Gone,
			Ok(Stat { start, .. }) if start != self.identity.start => Presence::Gone,
			Ok(_) => Presence::Alive,
			Err(error) if error.kind() == std::io::ErrorKind::NotFound => Presence::Gone,
			Err(error) => unreadable("reading the verb's process", error),
		}
	}

	#[cfg(not(target_os = "linux"))]
	pub fn presence(&self) -> Presence {
		Presence::Unknown("this platform gives no way to tell whether a process runs".into())
	}
}

fn pid(raw: u32) -> Result<Pid, Error> {
	i32::try_from(raw)
		.ok()
		.filter(|raw| *raw > 1)
		.map(Pid::from_raw)
		.ok_or_else(|| Error::state("groups", "a process group id out of range"))
}

/// End every process in the group. A group with no members is already ended.
fn kill(group: Pid) -> Result<(), Errno> {
	match killpg(group, Signal::SIGKILL) {
		Ok(()) | Err(Errno::ESRCH) => Ok(()),
		Err(errno) => Err(errno),
	}
}

fn signal_error(errno: Errno) -> Error {
	Error::io("ending the harness process group")(errno.into())
}

pub fn forget(record: &Path) -> Result<(), Error> {
	match std::fs::remove_file(record) {
		Ok(()) => Ok(()),
		Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
		Err(error) => Err(Error::io("removing a harness group record")(error)),
	}
}

/// The serving bot alone holds the store lease, and runs one turn per
/// conversation. From this check through recording the child, launch never
/// yields. Keep a previous group's evidence until startup reconciles it.
pub fn require_vacant(directory: &Path, name: &str) -> Result<(), Error> {
	match std::fs::symlink_metadata(directory.join(name)) {
		Ok(_) => Err(Error::state(
			"groups",
			format!("a harness group record remains for {name}; restart the bot to reconcile it"),
		)),
		Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
		Err(error) => Err(Error::io("checking the previous harness group record")(error)),
	}
}

/// Before spawning, replace any inherited auto-reaping disposition and
/// let this runtime thread receive child notifications, even when the bot's
/// parent blocked SIGCHLD. Every runner keeps its own subscription.
pub fn child_signals() -> std::io::Result<tokio::signal::unix::Signal> {
	let changes = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::child())?;
	let mut signals = SigSet::empty();
	signals.add(Signal::SIGCHLD);
	signals.thread_unblock()?;
	Ok(changes)
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

	/// Observe this child without reaping it, including before a group signal.
	/// ECHILD means the pid no longer identifies our child. Disarm even the
	/// drop guard immediately, because the number can be reused.
	fn leader_exited(&mut self) -> rustix::io::Result<bool> {
		use rustix::process::{Pid, WaitId, WaitIdOptions, waitid};
		if !self.live {
			return Err(rustix::io::Errno::CHILD);
		}
		let pid = i32::try_from(self.leader)
			.ok()
			.and_then(Pid::from_raw)
			.ok_or(rustix::io::Errno::INVAL)?;
		let flags = WaitIdOptions::EXITED | WaitIdOptions::NOHANG | WaitIdOptions::NOWAIT;
		loop {
			match waitid(WaitId::Pid(pid), flags) {
				Err(rustix::io::Errno::INTR) => continue,
				Err(error) => {
					if error == rustix::io::Errno::CHILD {
						self.live = false;
					}
					return Err(error);
				}
				Ok(status) => return Ok(status.is_some()),
			}
		}
	}

	/// Each SIGCHLD can cover several children. Check this leader before
	/// waiting and after each notification, including one delivered before
	/// the caller started waiting.
	pub async fn exited(&mut self, changes: &mut tokio::signal::unix::Signal) -> std::io::Result<()> {
		while !self.leader_exited()? {
			changes
				.recv()
				.await
				.ok_or_else(|| std::io::Error::other("the child signal stream closed"))?;
		}
		Ok(())
	}

	/// The target of a group signal, only while we still own its leader.
	fn target(&mut self) -> Result<Pid, Error> {
		self.leader_exited()
			.map_err(|error| Error::io("checking the harness group leader")(error.into()))?;
		pid(self.leader)
	}

	/// XNU's killpg1 skips zombies. If an exited leader was the only member,
	/// signalling the group reports EPERM until the leader is reaped.
	pub fn stop(&mut self, child: &mut tokio::process::Child) -> Result<(), Error> {
		let result = kill(self.target()?);
		if cfg!(target_os = "macos") && result == Err(Errno::EPERM) && self.gone_after_reap(child)? {
			return Ok(());
		}
		result.map_err(signal_error)
	}

	fn gone_after_reap(&mut self, child: &mut tokio::process::Child) -> Result<bool, Error> {
		if child.id() != Some(self.leader)
			|| !self
				.leader_exited()
				.map_err(|error| Error::io("checking the harness group leader")(error.into()))?
		{
			return Ok(false);
		}
		// From this point even Drop may only leave the record. Tokio caches
		// the child's exact exit status. Signal zero tests the former group's
		// existence without signalling any process that might reuse the id.
		self.live = false;
		let reaped = child.try_wait().map_err(Error::io("reaping the exited harness"))?;
		Ok(reaped.is_some() && killpg(pid(self.leader)?, None) == Err(Errno::ESRCH))
	}

	/// Remove the record of a group whose leader has been reaped. Its group id
	/// may be reused from then on, so the group is never signalled again. The
	/// caller ends it with [`Group::stop`].
	pub fn end(&mut self) -> Result<(), Error> {
		self.live = false;
		forget(&self.record)
	}

	/// A cancelled run still owns the child handle. Use it while its cached
	/// status and, on Darwin, the read-only group check are available.
	pub fn abandon(&mut self, child: &mut tokio::process::Child) {
		if self.live && self.stop(child).is_ok() {
			// best-effort: startup reconciles a record that could not be removed.
			let _ = self.end();
		}
		self.live = false;
	}
}

impl Drop for Group {
	fn drop(&mut self) {
		// best-effort: preserve the record for startup reconciliation when
		// ownership was lost or signalling failed.
		if self.live && self.target().is_ok_and(|target| kill(target).is_ok()) {
			let _ = forget(&self.record);
		}
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
	Left(u32, String),
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
		return Reaped::Left(group, "this platform gives no way to confirm the group's leader".into());
	};
	if identity(group).as_ref() != Some(&recorded) {
		return Reaped::Left(group, "its leader is gone or is another process now".into());
	}
	signalled(group, kill(target).map_err(signal_error))
}

/// What a restart did once it signalled a group whose leader it confirmed. A
/// signal that failed names its cause, so the log says why the group stayed.
fn signalled(group: u32, killed: Result<(), Error>) -> Reaped {
	match killed {
		Ok(()) => Reaped::Ended(group),
		Err(error) => Reaped::Left(group, format!("the group could not be signalled: {error}")),
	}
}

/// End harness groups a killed bot left running, where their leader is
/// confirmed, and clear every record. `serve` does it before it reads or
/// writes anything a left harness could still change.
pub fn reap_all(store: &Store) -> Result<(), Error> {
	let groups = store.groups()?;
	let entries = std::fs::read_dir(&groups).map_err(Error::io("listing harness group records"))?;
	for entry in entries {
		let path = entry.map_err(Error::io("listing harness group records"))?.path();
		match reap(&path) {
			Reaped::Gone => {}
			Reaped::Ended(id) => store.log(&format!("{ENDED_GROUP} {id}, left running by a killed bot")),
			Reaped::Left(id, why) => store.log(&format!("left harness group {id} alone: {why}")),
			Reaped::Discarded(why) => store.log(&format!("discarded {}: {why}", path.display())),
		}
		if let Err(error) = forget(&path) {
			store.log(&format!("removing {}: {error}", path.display()));
		}
	}
	Ok(())
}

#[cfg(test)]
mod tests;
