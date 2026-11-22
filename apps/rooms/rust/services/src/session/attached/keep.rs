//! Keeping what a committed command returned. A posting command returns its
//! line as a result key, and `startDirect` returns the peer's route the same
//! way. The session holds either only once an acquisition moves that key into
//! the workspace. The plans are the ones the terminal front uses
//! (`adopt_line` and `adopt_direct`). This file prepares a plan against the
//! session, submits it, and retries it from a fresh snapshot when the
//! workspace moved underneath it. A result that cannot be kept gives its
//! receipt back.
use super::{Error, View};
use rooms_application::content::session::{
	custody::{self, FieldKey},
	results,
	workspace::{Adoption, Intent, LineReceipt, StartDirect, adopt_direct, adopt_line},
};
use rooms_glowcap::client::{
	Deadline, Error as ClientError, Tasks,
	workspace::{Command, ResultImport},
};

/// Fresh snapshots tried before a moving workspace is reported.
const ATTEMPTS: usize = 3;

/// One acquisition a keeper submits against the snapshot it planned from.
struct Plan {
	imports: Vec<ResultImport>,
	releases: Vec<custody::Coordinate>,
	intent: Intent,
	source: Option<FieldKey<custody::SessionAccess>>,
}
fn imports(mappings: Vec<[custody::Coordinate; 2]>) -> Vec<ResultImport> {
	mappings
		.into_iter()
		.map(|[result, destination]| ResultImport { result, destination })
		.collect()
}

impl<D: Deadline + Tasks + Clone + 'static> View<D> {
	/// Keep what a committed command returned, or give its receipt back, and
	/// report a result that could not be kept as `Unkept` for a line or
	/// `Unopened` for a route. `before` is the workspace the command was sent
	/// against. A command that returns nothing to keep keeps nothing.
	pub(super) async fn kept(
		&self,
		command: &Command<D>,
		base: u64,
		adoption: Adoption<'_>,
		before: Result<&Intent, Error>,
	) -> Result<(), Error> {
		let outcome = match before {
			Ok(before) => match adoption {
				Adoption::Line(conversation) => self.keep_line_result(command, conversation, before).await,
				Adoption::Direct(start) => self.keep_route(command, &start, before).await,
			},
			Err(cause) => Err(cause),
		};
		let Err(cause) = outcome else {
			return Ok(());
		};
		let (operation, cause) = (command.operation().into(), Box::new(cause));
		let released = command.release().await.is_ok();
		Err(match adoption {
			Adoption::Line(_) => Error::Unkept {
				operation,
				base,
				cause,
				released,
			},
			Adoption::Direct(_) => Error::Unopened {
				operation,
				base,
				cause,
				released,
			},
		})
	}
	/// Take the authority of the line `command` committed, unless the session
	/// already holds it or the command posted no numbered line. A conversation
	/// whose authority changed since `before` is refused, never adopted into.
	pub(super) async fn keep_line_result(
		&self,
		command: &Command<D>,
		conversation: &str,
		before: &Intent,
	) -> Result<(), Error> {
		if self.settled(command.adopted().await).await? {
			return Ok(());
		}
		let result = self.settled(command.result_text().await).await?;
		let receipt = LineReceipt::read(&result).map_err(|_| Error::Malformed("the line receipt did not decode"))?;
		let Some(receipt) = receipt else {
			return Ok(());
		};
		self.acquire(command, |current| {
			let plan = adopt_line(before, current, conversation, &receipt, fresh()?)
				.map_err(|refusal| Error::Input(refusal.to_string()))?;
			Ok(Plan {
				imports: imports(plan.mappings),
				releases: plan.releases,
				intent: plan.intent,
				source: None,
			})
		})
		.await
	}
	/// Move the route a committed `startDirect` returned into a direct
	/// conversation, unless the session already holds it. A directory whose
	/// contact changed since `before` is refused.
	async fn keep_route(&self, command: &Command<D>, start: &StartDirect<'_>, before: &Intent) -> Result<(), Error> {
		if self.settled(command.adopted().await).await? {
			return Ok(());
		}
		let result = self.settled(command.result_text().await).await?;
		let receipt: results::Direct =
			serde_json::from_str(&result).map_err(|_| Error::Malformed("the direct receipt did not decode"))?;
		super::fault("adopt-direct")?;
		self.acquire(command, |current| {
			let plan = adopt_direct(
				before,
				current,
				command.operation(),
				start,
				&receipt,
				fresh()?,
				fresh()?,
			)
			.map_err(|refusal| Error::Input(refusal.to_string()))?;
			Ok(Plan {
				imports: imports(plan.mappings),
				releases: Vec::new(),
				intent: plan.intent,
				source: Some(plan.source),
			})
		})
		.await
	}
	/// Submit the acquisition `plan` makes from a fresh snapshot, planning
	/// again after a conflict, which proves nothing was adopted.
	async fn acquire(&self, command: &Command<D>, plan: impl Fn(&Intent) -> Result<Plan, Error>) -> Result<(), Error> {
		for _ in 0..ATTEMPTS {
			let current = self.snapshot().await?;
			let plan = plan(&current.intent)?;
			let acquisition = command
				.prepare_result_acquisition_with_source(
					current.revision,
					&plan.imports,
					&plan.releases,
					&plan.intent,
					plan.source,
				)
				.map_err(|error| Error::Input(error.to_string()))?;
			match acquisition.submit().await {
				Ok(()) => return Ok(()),
				Err(ClientError::WorkspaceConflict) => {}
				Err(error) => return Err(self.failure(error).await),
			}
		}
		Err(Error::Peer(ClientError::WorkspaceConflict))
	}
	pub(super) async fn settled<T>(&self, outcome: Result<T, ClientError>) -> Result<T, Error> {
		match outcome {
			Ok(value) => Ok(value),
			Err(error) => Err(self.failure(error).await),
		}
	}
}
/// A key no held custody uses, from platform entropy.
fn fresh<K>() -> Result<FieldKey<K>, Error> {
	let mut entropy = [0; 16];
	rooms_platform::entropy::fill(&mut entropy).map_err(|error| Error::Input(error.to_string()))?;
	FieldKey::from_entropy(entropy).ok_or_else(|| Error::Input("platform entropy produced no key".into()))
}
