//! Keeping a posted line. A posting command returns its line as a result key,
//! and the session holds authority over the line only once an acquisition
//! moves that key into the conversation. The plan is the one the terminal
//! front uses. This file prepares it against the session, submits it, and
//! retries it from a fresh snapshot when the workspace moved underneath it. A
//! line that cannot be kept gives its receipt back.
use super::{Error, View};
use rooms_application::content::session::{
	custody::{self, FieldKey},
	workspace::{Intent, LineReceipt, adopt_line},
};
use rooms_glowcap::client::{
	Deadline, Error as ClientError, Tasks,
	workspace::{Command, ResultImport},
};

/// Fresh snapshots tried before a moving workspace is reported.
const ATTEMPTS: usize = 3;

impl<D: Deadline + Tasks + Clone + 'static> View<D> {
	/// Take the authority of the line `command` committed, unless the session
	/// already holds it or the command posted no numbered line. `before` is
	/// the workspace the command was prepared against. A conversation whose
	/// authority changed since then is refused, never adopted into.
	pub(super) async fn keep(&self, command: &Command<D>, conversation: &str, before: &Intent) -> Result<(), Error> {
		if self.settled(command.adopted().await).await? {
			return Ok(());
		}
		let result = self.settled(command.result_text().await).await?;
		let receipt = LineReceipt::read(&result).map_err(|_| Error::Malformed("the line receipt did not decode"))?;
		let Some(receipt) = receipt else {
			return Ok(());
		};
		for _ in 0..ATTEMPTS {
			let current = self.snapshot().await?;
			let plan = adopt_line(before, &current.intent, conversation, &receipt, destination()?)
				.map_err(|refusal| Error::Input(refusal.to_string()))?;
			let mappings: Vec<_> = plan
				.mappings
				.into_iter()
				.map(|[result, destination]| ResultImport { result, destination })
				.collect();
			let acquisition = command
				.prepare_result_acquisition(current.revision, &mappings, &plan.releases, &plan.intent)
				.map_err(|error| Error::Input(error.to_string()))?;
			match acquisition.submit().await {
				Ok(()) => return Ok(()),
				// A conflict proves nothing was adopted, so a fresh plan is safe.
				Err(ClientError::WorkspaceConflict) => {}
				Err(error) => return Err(self.failure(error).await),
			}
		}
		Err(Error::Peer(ClientError::WorkspaceConflict))
	}
	/// Keep the line `command` committed at `base`, or release its receipt when
	/// the session will not keep it, so an unkept line holds none of the
	/// session's receipt places. A line that could not be kept is `Unkept`,
	/// which says whether the release went through.
	pub(super) async fn kept(
		&self,
		command: &Command<D>,
		base: u64,
		conversation: &str,
		before: &Intent,
	) -> Result<(), Error> {
		let Err(cause) = self.keep(command, conversation, before).await else {
			return Ok(());
		};
		Err(self.unkept(command, base, cause).await)
	}
	/// Report a committed line whose keeping failed with `cause`, after giving
	/// its receipt back.
	pub(super) async fn unkept(&self, command: &Command<D>, base: u64, cause: Error) -> Error {
		Error::Unkept {
			operation: command.operation().into(),
			base,
			cause: Box::new(cause),
			released: command.release().await.is_ok(),
		}
	}
	async fn settled<T>(&self, outcome: Result<T, ClientError>) -> Result<T, Error> {
		match outcome {
			Ok(value) => Ok(value),
			Err(error) => Err(self.failure(error).await),
		}
	}
}
/// A key no held line uses, from platform entropy.
fn destination() -> Result<FieldKey<custody::Line>, Error> {
	let mut entropy = [0; 16];
	rooms_platform::entropy::fill(&mut entropy).map_err(|error| Error::Input(error.to_string()))?;
	FieldKey::from_entropy(entropy).ok_or_else(|| Error::Input("platform entropy produced no key".into()))
}
