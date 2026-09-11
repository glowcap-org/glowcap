//! Execute the shared coordinator against a live session view. Recovery reads
//! admitted Rust snapshots directly; it never round-trips through a UI model.
use rooms_application::session::{
	controller::{Authority, Commands, Pending, Step},
	snapshot::Snapshot,
	state::OperationId,
};
use std::rc::Rc;

pub trait Observation {
	fn issue(
		&self,
		id: &str,
		base: u64,
		name: &str,
		args: &[String],
	) -> impl std::future::Future<Output = Result<u64, String>>;
	fn resume(&self, id: &str) -> impl std::future::Future<Output = Result<u64, String>>;
	fn current(&self) -> Result<Rc<Snapshot>, String>;
	fn refresh(&self) -> impl std::future::Future<Output = Result<Rc<Snapshot>, String>>;
	fn settle(&self, revision: u64) -> impl std::future::Future<Output = Result<Rc<Snapshot>, String>>;
}
pub async fn run(
	view: &impl Observation,
	commands: &Commands,
	id: OperationId,
	name: &str,
	args: &[String],
) -> Result<Rc<Snapshot>, String> {
	run_checked(view, commands, id, name, args, |_| Ok(())).await
}
/// The guard runs against the base snapshot before every command issue.
/// Completed effects are observed without retroactively rejecting their result.
pub async fn run_checked(
	view: &impl Observation,
	commands: &Commands,
	id: OperationId,
	name: &str,
	args: &[String],
	check: impl Fn(&Snapshot) -> Result<(), String>,
) -> Result<Rc<Snapshot>, String> {
	let mut operation = commands
		.begin(name, id, |command| {
			if !command.arity().contains(&args.len()) {
				return Err(rooms_application::session::controller::Error::Arguments);
			}
			Ok(args.iter().map(|arg| arg.as_str().into()).collect())
		})
		.map_err(|e| e.to_string())?;
	let mut snapshot = view.current()?;
	while operation.step() != Step::Done {
		match operation.step() {
			Step::Refresh => {
				snapshot = view.refresh().await?;
				operation
					.refreshed(
						snapshot
							.pending_effect_details
							.as_slice()
							.iter()
							.map(|(id, kind, subject, _)| Pending {
								id: id.text(),
								kind: kind.text(),
								subject: subject.text(),
							}),
					)
					.map_err(|e| e.to_string())?;
			}
			Step::Resume => {
				let (id, subject) = operation.resuming().ok_or("Rooms resume lost its operation")?;
				let revision = view
					.resume(
						id.text()
							.as_str()
							.ok_or("Rooms operation identity is not scalar text")?,
					)
					.await
					.map_err(|error| resume_failure(subject, &error.to_string()))?;
				operation.acknowledged(revision).map_err(|e| e.to_string())?;
			}
			Step::SettleResume(revision) => {
				let (_, subject) = operation.resuming().ok_or("Rooms resume lost its operation")?;
				snapshot = view
					.settle(revision)
					.await
					.map_err(|error| resume_failure(subject, &error))?;
				operation
					.resumed(snapshot.checkpoint.rooms().map(|room| Authority {
						id: room.id.text(),
						link: room.link.map(|v| v.text()),
						manager: room.manager.map(|v| v.text()),
						steward: room.steward.map(|v| v.text()),
					}))
					.map_err(|e| e.to_string())?;
			}
			Step::Issue => {
				check(&snapshot)?;
				let id = operation
					.id()
					.text()
					.as_str()
					.ok_or("Rooms operation identity is not scalar text")?;
				match view.issue(id, snapshot.revision.get(), name, args).await {
					Ok(revision) => operation.acknowledged(revision).map_err(|e| e.to_string())?,
					Err(error) => {
						let reason = error.to_string();
						if !operation.refused(&reason).map_err(|e| e.to_string())? {
							return Err(reason);
						}
					}
				}
			}
			Step::SettleCommand(revision) => {
				snapshot = view.settle(revision).await?;
				operation.committed().map_err(|e| e.to_string())?;
			}
			Step::Refused => return Err("the Rooms command was already refused".into()),
			Step::Done => {}
		}
	}
	Ok(snapshot)
}
fn resume_failure(subject: &rooms_application::text::DocumentText, reason: &str) -> String {
	format!(
		"Could not resume “{}”: {reason}. It remains under Settings → Session, where you can retry or abandon it.",
		subject
			.as_str()
			.map(std::borrow::Cow::Borrowed)
			.unwrap_or_else(|| std::borrow::Cow::Owned(String::from_utf16_lossy(&subject.utf16().collect::<Vec<_>>())))
	)
}
