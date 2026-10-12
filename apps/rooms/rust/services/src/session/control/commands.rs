//! Interrupted socket requests lend waits to retained command observations.
//! Operation identity never acquires a new sequence or replacement source.
use super::{Failure, peer_failure};
use rooms_application::{content::session::custody, session::command::Request};
use rooms_glowcap::client::workspace::{Command, EffectStatus, Workspace};
use rooms_platform::HostPlatform;
use std::{collections::BTreeMap, rc::Rc};
use tokio::sync::{Mutex, watch};

const MAX_BYTES: usize = 16 * 1024 * 1024;
#[cfg(test)]
mod tests;
struct Pending {
	command: Rc<Command<HostPlatform>>,
	result: watch::Receiver<Option<Result<EffectStatus, rooms_glowcap::client::Error>>>,
	_task: Task,
}
struct Task(tokio::task::JoinHandle<()>);
impl Drop for Task {
	fn drop(&mut self) {
		self.0.abort();
	}
}
impl Pending {
	async fn admitted(
		result: &mut watch::Receiver<Option<Result<EffectStatus, rooms_glowcap::client::Error>>>,
	) -> Result<EffectStatus, Failure> {
		loop {
			if let Some(result) = result.borrow_and_update().as_ref() {
				return result.clone().map_err(peer_failure);
			}
			result.changed().await.map_err(Failure::uncertain)?;
		}
	}
}
#[derive(Default)]
pub(super) struct Commands(Mutex<BTreeMap<String, Pending>>);
impl Commands {
	pub async fn submit(
		&self,
		workspace: &Workspace<HostPlatform>,
		id: &str,
		base: u64,
		name: &str,
		args: &[String],
	) -> Result<EffectStatus, Failure> {
		let canonical = Request::from_parts(id, base, name, args)
			.map_err(Failure::invalid)?
			.canonical()
			.map_err(Failure::invalid)?;
		let mut commands = self.0.lock().await;
		if let Some(pending) = commands.get(id) {
			if pending.command.canonical() != canonical || pending.command.source() != workspace.reference() {
				return Err(Failure::invalid("operation already retains another request or source"));
			}
		} else {
			if commands.len() == custody::MAX_EFFECTS {
				return Err(Failure::exhausted(
					"release completed local commands before admitting another",
				));
			}
			let command = workspace
				.prepare_command(id, base, name, args)
				.await
				.map_err(peer_failure)?;
			let retained = commands
				.values()
				.map(|pending| pending.command.retained_bytes())
				.sum::<usize>();
			if command.retained_bytes() > MAX_BYTES.saturating_sub(retained) {
				return Err(Failure::exhausted("local command input budget is full"));
			}
			let mut submission = command.start_submission();
			let (completed, result) = watch::channel(None);
			let task = tokio::task::spawn_local(async move {
				completed.send_replace(Some(submission.completed().await));
			});
			commands.insert(
				id.into(),
				Pending {
					command: Rc::new(command),
					result,
					_task: Task(task),
				},
			);
		}
		let pending = commands
			.get(id)
			.ok_or_else(|| Failure::invalid("local command left the pending table before it was observed"))?;
		let command = pending.command.clone();
		let mut result = pending.result.clone();
		drop(commands);
		let admission = tokio::time::timeout(std::time::Duration::from_secs(20), Pending::admitted(&mut result))
			.await
			.map_err(|_| Failure::uncertain("command admission is pending; retry this exact request"))??;
		if admission == EffectStatus::Conflict {
			return Ok(admission);
		}
		command.status().await.map_err(peer_failure)
	}
	pub async fn release(&self, id: &str) -> Result<(), Failure> {
		let commands = self.0.lock().await;
		let Some(pending) = commands.get(id) else {
			return Ok(());
		};
		let absent = match pending.result.borrow().as_ref() {
			Some(Ok(EffectStatus::Conflict)) => true,
			Some(Err(error)) => error.known_absent(),
			_ => false,
		};
		let command = pending.command.clone();
		drop(commands);
		if !absent
			&& !matches!(
				command.status().await.map_err(peer_failure)?,
				EffectStatus::Committed | EffectStatus::Unsent
			) {
			return Err(Failure::uncertain(
				"command remains unresolved; retain its original request",
			));
		}
		let mut commands = self.0.lock().await;
		if commands
			.get(id)
			.is_some_and(|pending| Rc::ptr_eq(&pending.command, &command))
		{
			commands.remove(id);
		}
		Ok(())
	}
	pub async fn close(&self) -> Result<(), Failure> {
		let mut commands = self.0.lock().await;
		for pending in commands.values_mut() {
			// Terminal admission failures are evidence too. Only an unknown
			// admission keeps this observation barrier open.
			let _terminal = tokio::time::timeout(
				std::time::Duration::from_secs(20),
				Pending::admitted(&mut pending.result),
			)
			.await
			.map_err(|_| Failure::uncertain("retain local control while command admission is unresolved"))?;
		}
		commands.clear();
		Ok(())
	}
}
