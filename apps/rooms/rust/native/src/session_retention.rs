//! Native clock specialization of the shared local-history barrier.
use std::rc::Rc;
pub type RetentionEvents<E> = rooms_runtime::session_retention::RetentionEvents<E, crate::client::Deadline>;
#[cfg(test)]
mod tests;

/// Compose directory realization with the session's local-history barrier.
/// Drive the archive worker first; this call restores retention before any
/// returned owner is published or either returned worker starts.
pub async fn directories(
	runtime: Rc<glowcap::Runtime>,
	commands: crate::session_commands::SessionCommands,
	member_locator: String,
	archive: Rc<crate::session_archive::SessionArchive>,
) -> Result<
	(
		crate::session_runtime::DirectoryRuntime,
		crate::session_runtime::DirectoryWorker,
		crate::session_retention::RetentionEvents<crate::session_runtime::RuntimeEvents>,
		crate::session_runtime::RegistrationInbox,
	),
	String,
> {
	let view = commands.view();
	let (owner, worker, events, inbox) = crate::session_runtime::DirectoryRuntime::new(
		runtime,
		commands,
		member_locator,
		crate::client::Deadline,
		crate::entropy::OsEntropy,
	)?;
	let events = crate::session_retention::RetentionEvents::open(events, archive, &view).await?;
	Ok((owner, worker, events, inbox))
}
