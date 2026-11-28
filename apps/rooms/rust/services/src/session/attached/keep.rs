//! Keeping what a committed command returned. A posting command returns its
//! line as a result key, and `startDirect` returns the peer's route the same
//! way. The session holds either only once an acquisition moves that key into
//! the workspace. The plans are the ones the terminal front uses
//! (`adopt_line` and `adopt_direct`). This file prepares a plan against the
//! session, submits it, and retries it from a fresh snapshot when the
//! workspace moved underneath it. A result that cannot be kept for a reason
//! that never clears gives its receipt back (`Error::refuses_keeping`), and so
//! does a route whose peer an open conversation already reaches. A result
//! that failed to keep for a reason that clears with time holds its receipt,
//! so the line keeps its authority and a later keep adopts it.
use super::{Error, Files, GiveBack, View, fault::ViewFault};
use rooms_application::content::session::{
	custody::{self, FieldKey},
	effects::RUNNING_BOUND_MS,
	results,
	workspace::{Adoption, DirectRefusal, Id, Intent, LineReceipt, StartDirect, adopt_direct, adopt_line, open_direct},
};
use rooms_glowcap::client::{
	Deadline, Error as ClientError, Tasks,
	workspace::{Command, RecoveredEffect, Release, ResultAcquisition, ResultImport},
};

/// Fresh snapshots tried before a moving workspace is reported.
const ATTEMPTS: usize = 3;

/// How long a release answered running waits before it asks again.
const RUNNING_PAUSE_MS: u64 = 250;

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
/// The receipt a keeper reads and gives back: a command this view sent, or one
/// recovered from the session by its operation alone.
pub(super) enum Effect<'a, D> {
	Command(&'a Command<D>),
	Recovered(&'a RecoveredEffect<D>),
}
impl<D> Clone for Effect<'_, D> {
	fn clone(&self) -> Self {
		*self
	}
}
impl<D> Copy for Effect<'_, D> {}
impl<D: Deadline + Clone> Effect<'_, D> {
	fn operation(&self) -> &str {
		match self {
			Self::Command(command) => command.operation(),
			Self::Recovered(effect) => effect.operation(),
		}
	}
	async fn adopted(&self) -> Result<bool, ClientError> {
		match self {
			Self::Command(command) => command.adopted().await,
			Self::Recovered(effect) => effect.adopted().await,
		}
	}
	async fn result_text(&self) -> Result<String, ClientError> {
		match self {
			Self::Command(command) => command.result_text().await,
			Self::Recovered(effect) => effect.result_text().await,
		}
	}
	async fn release(&self) -> Result<Release, ClientError> {
		match self {
			Self::Command(command) => command.release().await,
			Self::Recovered(effect) => effect.release().await,
		}
	}
	fn acquisition(&self, revision: u64, plan: &Plan) -> glowcap::Result<ResultAcquisition<D>> {
		let (imports, releases, intent, source) = (&plan.imports, &plan.releases, &plan.intent, plan.source);
		match self {
			Self::Command(command) => {
				command.prepare_result_acquisition_with_source(revision, imports, releases, intent, source)
			}
			Self::Recovered(effect) => {
				effect.prepare_result_acquisition_with_source(revision, imports, releases, intent, source)
			}
		}
	}
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
		command: Effect<'_, D>,
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
				// An adoption the session answers kept left the line in the
				// workspace, which is all keeping it does.
				self.given_back(command, base, adoption, outcome, async || Ok(())).await
			}
			Adoption::Direct(start) => self.kept_route(command, base, &start, before).await.map(|_| ()),
		}
	}
	/// Keep the route a committed `startDirect` returned, as `kept` does, and
	/// name the conversation that reaches the peer.
	pub(super) async fn kept_route(
		&self,
		command: Effect<'_, D>,
		base: u64,
		start: &StartDirect<'_>,
		before: Result<&Intent, Error>,
	) -> Result<Route, Error> {
		let outcome = match before {
			Ok(before) => self.keep_route(command, start, before).await,
			Err(cause) => Err(cause),
		};
		let route = self
			.given_back(command, base, Adoption::Direct(*start), outcome, async || {
				self.adopted_route(start).await
			})
			.await?;
		if !route.reused {
			return Ok(route);
		}
		let released = match self.give_back(command).await {
			Ok(release) => Ok(release),
			Err(error) => Err(self.failure(error).await),
		};
		reused_outcome(route, command.operation(), base, released)
	}
	/// How the files of the committed upload `command` stand. The post
	/// committed, so a failed read of its outcome is a failure to keep what it
	/// returned, answered by `given_back` as every other one is. A session that
	/// reports the line already adopted leaves the files unfinished.
	pub(super) async fn upload_outcome(
		&self,
		command: Effect<'_, D>,
		base: u64,
		conversation: &str,
	) -> Result<Files, Error> {
		let read = async {
			super::fault::lose_result()?;
			let result = self.settled(command.result_text().await).await?;
			super::files_of(&result)
		}
		.await;
		match read {
			Ok(files) => Ok(files),
			Err(cause) => {
				self.given_back(command, base, Adoption::Line(conversation), Err(cause), async || {
					Ok(Files::Unfinished)
				})
				.await
			}
		}
	}
	/// Say a result could not be kept, and settle its receipt by the cause
	/// (`Error::refuses_keeping`). A refusal that never clears gives the
	/// receipt back. A failure that clears holds it, so the line's authority
	/// survives for a later keep, and reports `GiveBack::Held`. A keeper's
	/// acquisition can commit while its answer is lost, so the session
	/// answering that the result is adopted is believed over the keeper's
	/// failure, and `adopted` reports what the workspace holds.
	pub(super) async fn given_back<T>(
		&self,
		command: Effect<'_, D>,
		base: u64,
		adoption: Adoption<'_>,
		outcome: Result<T, Error>,
		adopted: impl AsyncFnOnce() -> Result<T, Error>,
	) -> Result<T, Error> {
		let outcome = outcome.and_then(|kept| super::fault::lose(ViewFault::KeepLost).map(|()| kept));
		let cause = match outcome {
			Ok(kept) => return Ok(kept),
			Err(cause) => cause,
		};
		let receipt = if cause.refuses_keeping() {
			match given(match self.give_back(command).await {
				Ok(release) => Ok(release),
				Err(error) => Err(self.failure(error).await),
			}) {
				Given::Kept => return adopted().await,
				Given::Back(receipt) => receipt,
			}
		} else if matches!(command.adopted().await, Ok(true)) {
			return adopted().await;
		} else {
			GiveBack::Held
		};
		let (operation, cause) = (command.operation().into(), Box::new(cause));
		Err(match adoption {
			Adoption::Line(_) => Error::Unkept {
				operation,
				base,
				cause,
				receipt,
				files: None,
			},
			Adoption::Direct(_) => Error::Unopened {
				operation,
				base,
				cause,
				receipt,
			},
		})
	}
	/// Take the authority of the line `command` committed, unless the session
	/// already holds it or the command posted no numbered line. A conversation
	/// whose authority changed since `before` is refused, never adopted into.
	pub(super) async fn keep_line_result(
		&self,
		command: Effect<'_, D>,
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
			super::fault::refuse(ViewFault::KeepRefused)?;
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
	/// conversation already reaches the peer, that conversation is reported as
	/// reused, and `kept_route` gives the receipt back, unless this command's
	/// own result is the one adopted: a second caller of the same operation
	/// that loses the race has nothing to give back and reports the open as its
	/// own.
	async fn keep_route(
		&self,
		command: Effect<'_, D>,
		start: &StartDirect<'_>,
		before: &Intent,
	) -> Result<Route, Error> {
		if self.settled(command.adopted().await).await? {
			return self.adopted_route(start).await;
		}
		let result = self.settled(command.result_text().await).await?;
		let receipt: results::Direct =
			serde_json::from_str(&result).map_err(|_| Error::Malformed("the direct receipt did not decode"))?;
		super::fault::lose(ViewFault::AdoptDirect)?;
		super::fault::meet(command.operation(), || command.adopted()).await?;
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
		// A second caller of this operation that lost the race to adopt finds
		// the first one's open row. This command's own result is the adopted
		// one then, so there is nothing to give back and the open is its own.
		let reused = reused && !self.settled(command.adopted().await).await?;
		Ok(Route {
			conversation: text(&conversation)?,
			reused,
		})
	}
	/// Give back the receipt of a committed command whose result nothing here
	/// keeps, when the session lists it as holding a place: a result that
	/// carries capabilities waits for an adoption no keeper makes. A receipt
	/// that holds no place is left as it is. When the list cannot be read, the
	/// receipt is given back anyway, because a give-back changes nothing
	/// a caller could still use.
	pub(super) async fn forfeit(&self, command: Effect<'_, D>, base: u64) -> Result<(), Error> {
		super::fault::reach_forfeit(command.operation());
		let listed = match self.held().await {
			Ok(held) => held.iter().any(|operation| operation == command.operation()),
			// tolerant: an unread list gives back a receipt that may hold no
			// place, and that give-back is reported as any other.
			Err(_) => true,
		};
		if !listed {
			return Ok(());
		}
		let operation = command.operation().into();
		let receipt = match given(match self.give_back(command).await {
			Ok(release) => Ok(release),
			Err(error) => Err(self.failure(error).await),
		}) {
			Given::Kept => return Ok(()),
			Given::Back(receipt) => receipt,
		};
		Err(Error::Forfeited {
			operation,
			base,
			receipt,
		})
	}
	/// The conversation holding the route an adopted `startDirect` returned:
	/// the registration's one open row.
	async fn adopted_route(&self, start: &StartDirect<'_>) -> Result<Route, Error> {
		let now = self.snapshot().await?;
		let conversation = open_direct(&now.intent, start.directory, start.registration)
			.map(|row| row.id.clone())
			.ok_or_else(|| Error::Input(format!("the conversation with {} closed as it opened", start.peer)))?;
		Ok(Route {
			conversation: text(&conversation)?,
			reused: false,
		})
	}
	/// Submit the acquisition `plan` makes from a fresh snapshot, planning
	/// again after a conflict, which proves nothing was adopted.
	async fn acquire<T>(
		&self,
		command: Effect<'_, D>,
		plan: impl Fn(&Intent) -> Result<Step<T>, Error>,
	) -> Result<T, Error> {
		for _ in 0..ATTEMPTS {
			let current = self.snapshot().await?;
			let (plan, landed) = match plan(&current.intent)? {
				Step::Submit(plan, landed) => (plan, landed),
				Step::Held(landed) => return Ok(landed),
			};
			let acquisition = command
				.acquisition(current.revision, &plan)
				.map_err(|error| Error::Input(error.to_string()))?;
			let submitted = if super::fault::keep_moved(ATTEMPTS) {
				Err(ClientError::WorkspaceConflict)
			} else {
				acquisition.submit().await
			};
			match submitted {
				Ok(()) => return Ok(landed),
				Err(ClientError::WorkspaceConflict) => {}
				Err(error) => return Err(self.failure(error).await),
			}
		}
		Err(Error::Peer(ClientError::WorkspaceConflict))
	}
	/// Give `command`'s receipt back. The session answers running while the
	/// receipt's executor is still finishing, so the release is asked again
	/// until [`RUNNING_BOUND_MS`] has passed. The executor of a `say` or of a
	/// route ends within that bound. One filling the files of a posted
	/// `sendFiles` or `refileLine` can run past it, and then the release
	/// answers running and the caller reports the receipt as not released.
	pub(super) async fn give_back(&self, command: Effect<'_, D>) -> Result<Release, ClientError> {
		released_within(self.client.platform(), || command.release()).await
	}
	pub(super) async fn settled<T>(&self, outcome: Result<T, ClientError>) -> Result<T, Error> {
		match outcome {
			Ok(value) => Ok(value),
			Err(error) => Err(self.failure(error).await),
		}
	}
}
/// Ask `release` until it answers anything but running, or until
/// [`RUNNING_BOUND_MS`] has passed on `clock`, pausing [`RUNNING_PAUSE_MS`]
/// between asks. A refused ask ends the loop with its cause.
pub(crate) async fn released_within<F: std::future::Future<Output = Result<Release, ClientError>>>(
	clock: &impl Deadline,
	mut release: impl FnMut() -> F,
) -> Result<Release, ClientError> {
	let until = clock.monotonic_millis().saturating_add(RUNNING_BOUND_MS);
	loop {
		match release().await? {
			Release::Running if clock.monotonic_millis() < until => {
				// tolerant: this wait is a pause that ends at its deadline
				// by design, so its expiry is the expected answer.
				let _ = clock.within(RUNNING_PAUSE_MS, std::future::pending::<()>()).await;
			}
			answer => return Ok(answer),
		}
	}
}
/// What a give-back came to.
enum Given {
	/// The session answered that the result was adopted, so the workspace
	/// holds it and the receipt holds no place.
	Kept,
	/// The receipt was given back, or still holds a place, as this says.
	Back(GiveBack),
}
/// What a give-back came to, keeping the cause of one that failed.
fn given(released: Result<Release, Error>) -> Given {
	match released {
		Ok(Release::Kept) => Given::Kept,
		Ok(Release::Released) => Given::Back(GiveBack::Released),
		Ok(Release::Running) => Given::Back(GiveBack::Running),
		Err(cause) => Given::Back(GiveBack::Failed(Box::new(cause))),
	}
}
/// What giving back the receipt of a reused route answered says of the open.
/// Only a release the session confirmed leaves the open reused. One the
/// session answers kept had this command's own route adopted, by another
/// caller of the same operation, so the open is its own. A receipt still
/// running, or a release that failed, still holds one of the session's
/// places, so the open is reported unopened with its receipt held.
fn reused_outcome(route: Route, operation: &str, base: u64, released: Result<Release, Error>) -> Result<Route, Error> {
	let receipt = match given(released) {
		Given::Kept => return Ok(Route { reused: false, ..route }),
		Given::Back(receipt) => receipt,
	};
	if receipt.released() {
		return Ok(route);
	}
	Err(Error::Unopened {
		operation: operation.into(),
		base,
		cause: Box::new(Error::Input(format!(
			"conversation {} already reaches the peer",
			route.conversation
		))),
		receipt,
	})
}
pub(super) fn text(id: &Id) -> Result<String, Error> {
	id.text()
		.as_str()
		.map(str::to_owned)
		.ok_or(Error::Malformed("a direct conversation id is not text"))
}
/// A key no held custody uses, from platform entropy.
pub(super) fn fresh<K>() -> Result<FieldKey<K>, Error> {
	let mut entropy = [0; 16];
	rooms_platform::entropy::fill(&mut entropy).map_err(|error| Error::Input(error.to_string()))?;
	FieldKey::from_entropy(entropy).ok_or_else(|| Error::Input("platform entropy produced no key".into()))
}

#[cfg(test)]
mod tests {
	use super::{
		ClientError, Deadline, Error, GiveBack, RUNNING_BOUND_MS, RUNNING_PAUSE_MS, Release, Route, released_within,
		reused_outcome,
	};
	use std::cell::Cell;

	/// A clock that moves only when a pause on it ends.
	#[derive(Default)]
	struct Clock(Cell<u64>);
	impl Deadline for Clock {
		fn monotonic_millis(&self) -> u64 {
			self.0.get()
		}
		async fn within<T>(&self, milliseconds: u64, _work: impl std::future::Future<Output = T>) -> Option<T> {
			self.0.set(self.0.get() + milliseconds);
			None
		}
	}

	/// Ask with `answers` in order, then running forever, and count the asks.
	async fn asked(clock: &Clock, answers: &[Result<Release, ClientError>]) -> (Result<Release, ClientError>, usize) {
		let asks = Cell::new(0);
		let answer = released_within(clock, || {
			let n = asks.get();
			asks.set(n + 1);
			let answer = answers.get(n).cloned().unwrap_or(Ok(Release::Running));
			async move { answer }
		})
		.await;
		(answer, asks.get())
	}

	/// A release answered running is asked again after a pause until it is
	/// released.
	#[tokio::test]
	async fn a_running_receipt_is_asked_again_until_it_is_released() {
		let clock = Clock::default();
		let (answer, asks) = asked(
			&clock,
			&[Ok(Release::Running), Ok(Release::Running), Ok(Release::Released)],
		)
		.await;
		assert_eq!(answer.unwrap(), Release::Released);
		assert_eq!(asks, 3);
		assert_eq!(clock.monotonic_millis(), 2 * RUNNING_PAUSE_MS);
	}

	/// A receipt still running at the bound answers running, after one ask
	/// per pause that fits in the bound and one at the bound.
	#[tokio::test]
	async fn a_receipt_still_running_past_the_bound_answers_running() {
		let clock = Clock::default();
		let (answer, asks) = asked(&clock, &[]).await;
		assert_eq!(answer.unwrap(), Release::Running);
		assert_eq!(asks as u64, RUNNING_BOUND_MS.div_ceil(RUNNING_PAUSE_MS) + 1);
		assert!(clock.monotonic_millis() >= RUNNING_BOUND_MS);
	}

	/// A refused ask ends the loop at once with its cause.
	#[tokio::test]
	async fn a_refused_release_is_not_asked_again() {
		let clock = Clock::default();
		let (answer, asks) = asked(&clock, &[Ok(Release::Running), Err(ClientError::WorkspaceConflict)]).await;
		assert!(matches!(answer, Err(ClientError::WorkspaceConflict)), "{answer:?}");
		assert_eq!(asks, 2);
	}

	/// A reused route stays reused only once the session confirms its receipt
	/// is given back. One still running, or a release that failed, reports the
	/// open unopened with its receipt held, so the caller counts its place.
	#[test]
	fn a_reused_route_whose_receipt_is_still_held_is_reported_unopened() {
		let route = || Route {
			conversation: "c1".into(),
			reused: true,
		};
		let outcome = reused_outcome(route(), "op", 3, Ok(Release::Released));
		assert!(outcome.is_ok_and(|route| route.reused));
		let outcome = reused_outcome(route(), "op", 3, Ok(Release::Running));
		assert!(
			matches!(
				&outcome,
				Err(Error::Unopened {
					base: 3,
					receipt: GiveBack::Running,
					..
				})
			),
			"{:?}",
			outcome.err()
		);
		// A give-back that failed keeps its cause for the caller.
		let outcome = reused_outcome(route(), "op", 3, Err(Error::Refused));
		assert!(
			matches!(
				&outcome,
				Err(Error::Unopened {
					base: 3,
					receipt: GiveBack::Failed(cause),
					..
				}) if matches!(**cause, Error::Refused)
			),
			"{:?}",
			outcome.err()
		);
	}
}
