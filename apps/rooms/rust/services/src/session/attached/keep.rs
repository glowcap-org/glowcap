//! Keeping what a committed command returned. A posting command returns its
//! line as a result key, and `startDirect` returns the peer's route the same
//! way. The session holds either only once an acquisition moves that key into
//! the workspace. The plans are the ones the terminal front uses
//! (`adopt_line` and `adopt_direct`). This file prepares a plan against the
//! session, submits it, and retries it from a fresh snapshot when the
//! workspace moved underneath it. A result that cannot be kept gives its
//! receipt back, and so does a route whose peer an open conversation already
//! reaches.
use super::{Error, View};
use rooms_application::content::session::{
	custody::{self, FieldKey},
	results,
	workspace::{Adoption, DirectRefusal, Id, Intent, LineReceipt, StartDirect, adopt_direct, adopt_line, open_direct},
};
use rooms_glowcap::client::{
	Deadline, Error as ClientError, Tasks,
	workspace::{Command, ResultImport},
};

/// Fresh snapshots tried before a moving workspace is reported.
const ATTEMPTS: usize = 3;

/// Where a committed `startDirect` left its peer.
pub(super) struct Route {
	/// The open direct conversation that reaches the peer.
	pub conversation: String,
	/// Another open conversation already reached the peer, so this command's
	/// receipt was given back and its route forfeited.
	pub reused: bool,
}

/// What a keeper does against one snapshot, and what it reports after.
enum Step<T> {
	/// Submit this acquisition, then report the value. Boxed because a
	/// plan carries a whole workspace.
	Submit(Box<Plan>, T),
	/// Submit nothing, because the snapshot already holds what the command
	/// would add.
	Held(T),
}

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
		match adoption {
			Adoption::Line(conversation) => {
				let outcome = match before {
					Ok(before) => self.keep_line_result(command, conversation, before).await,
					Err(cause) => Err(cause),
				};
				self.given_back(command, base, adoption, outcome).await
			}
			Adoption::Direct(start) => self.kept_route(command, base, &start, before).await.map(|_| ()),
		}
	}
	/// Keep the route a committed `startDirect` returned, as `kept` does, and
	/// name the conversation that reaches the peer.
	pub(super) async fn kept_route(
		&self,
		command: &Command<D>,
		base: u64,
		start: &StartDirect<'_>,
		before: Result<&Intent, Error>,
	) -> Result<Route, Error> {
		let outcome = match before {
			Ok(before) => self.keep_route(command, start, before).await,
			Err(cause) => Err(cause),
		};
		self.given_back(command, base, Adoption::Direct(*start), outcome).await
	}
	/// Give the receipt of a result that could not be kept back, and say so.
	async fn given_back<T>(
		&self,
		command: &Command<D>,
		base: u64,
		adoption: Adoption<'_>,
		outcome: Result<T, Error>,
	) -> Result<T, Error> {
		let cause = match outcome {
			Ok(kept) => return Ok(kept),
			Err(cause) => cause,
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
			let plan = Plan {
				imports: imports(plan.mappings),
				releases: plan.releases,
				intent: plan.intent,
				source: None,
			};
			Ok(Step::Submit(Box::new(plan), ()))
		})
		.await
	}
	/// Move the route a committed `startDirect` returned into a direct
	/// conversation, unless the session already holds it. A directory whose
	/// contact changed since `before` is refused. When another open
	/// conversation already reaches the peer, the receipt is given back and
	/// that conversation is reported as reused.
	async fn keep_route(&self, command: &Command<D>, start: &StartDirect<'_>, before: &Intent) -> Result<Route, Error> {
		if self.settled(command.adopted().await).await? {
			// The registration's one open row holds the route this command kept.
			let now = self.snapshot().await?;
			let conversation = open_direct(&now.intent, start.directory, start.registration)
				.map(|row| row.id.clone())
				.ok_or_else(|| Error::Input(format!("the conversation with {} closed as it opened", start.peer)))?;
			return Ok(Route {
				conversation: text(&conversation)?,
				reused: false,
			});
		}
		let result = self.settled(command.result_text().await).await?;
		let receipt: results::Direct =
			serde_json::from_str(&result).map_err(|_| Error::Malformed("the direct receipt did not decode"))?;
		super::fault("adopt-direct")?;
		let (conversation, reused) = self
			.acquire(command, |current| {
				let plan = match adopt_direct(
					before,
					current,
					command.operation(),
					start,
					&receipt,
					fresh()?,
					fresh()?,
				) {
					Ok(plan) => plan,
					Err(DirectRefusal::Open(open)) => return Ok(Step::Held((open, true))),
					Err(refusal) => return Err(Error::Input(refusal.to_string())),
				};
				let landed = (plan.conversation, false);
				let plan = Plan {
					imports: imports(plan.mappings),
					releases: Vec::new(),
					intent: plan.intent,
					source: Some(plan.source),
				};
				Ok(Step::Submit(Box::new(plan), landed))
			})
			.await?;
		if reused {
			self.settled(command.release().await).await?;
		}
		Ok(Route {
			conversation: text(&conversation)?,
			reused,
		})
	}
	/// Submit the acquisition `plan` makes from a fresh snapshot, planning
	/// again after a conflict, which proves nothing was adopted.
	async fn acquire<T>(
		&self,
		command: &Command<D>,
		plan: impl Fn(&Intent) -> Result<Step<T>, Error>,
	) -> Result<T, Error> {
		for _ in 0..ATTEMPTS {
			let current = self.snapshot().await?;
			let (plan, landed) = match plan(&current.intent)? {
				Step::Submit(plan, landed) => (plan, landed),
				Step::Held(landed) => return Ok(landed),
			};
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
				Ok(()) => return Ok(landed),
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
pub(super) fn text(id: &Id) -> Result<String, Error> {
	id.text()
		.as_str()
		.map(str::to_owned)
		.ok_or(Error::Malformed("a direct conversation id is not text"))
}
/// A key no held custody uses, from platform entropy.
fn fresh<K>() -> Result<FieldKey<K>, Error> {
	let mut entropy = [0; 16];
	rooms_platform::entropy::fill(&mut entropy).map_err(|error| Error::Input(error.to_string()))?;
	FieldKey::from_entropy(entropy).ok_or_else(|| Error::Input("platform entropy produced no key".into()))
}
