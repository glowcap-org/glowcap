//! Settling a receipt this access holds from its operation alone, as a
//! program that no longer has the request it sent does. The session tells the
//! access that sent a request what that request was (`effect-intent`), so
//! the request is read back from the session and never from the caller. A
//! look here sends nothing and resends nothing. A committed result is kept
//! the way the command that sent it keeps one, and one that cannot be kept
//! gives its receipt back.
use super::{
	Error, Files, View,
	fault::{self, ViewFault},
	keep::Effect,
};
use rooms_application::content::session::{uploads, workspace::Adoption};
use rooms_glowcap::client::{
	Deadline, Tasks,
	workspace::{EffectStatus, RecoveredEffect, Release},
};

/// What a look at a receipt recovered by its operation found.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Recovered {
	/// The session holds no receipt this access can still settle: it was
	/// adopted or released, or it left the session's window of receipts.
	Gone,
	/// The request still runs in the session.
	Pending,
	/// The session cannot say whether the request committed, because the work
	/// that would settle it ended. Only giving the receipt back settles it.
	Unknown,
	/// The request committed nothing, as this status says.
	Unapplied(EffectStatus),
	/// The request committed, and what it returned is kept. A post's `files`
	/// say how they stand, as the committed result records them, read by the
	/// reader `send_files` uses.
	Committed { files: Option<Files> },
}

/// The request a receipt holds, read from its original intent.
enum Original {
	/// A session command, as `command` sent it.
	Command {
		base: u64,
		name: String,
		arguments: Vec<String>,
	},
	/// Files posted, as `send_files` sent them.
	Upload { base: u64, conversation: String },
}

impl Original {
	/// Read `canonical`, the intent the session holds for `operation`. An
	/// intent of another shape, or one that names another operation, is no
	/// request this view sends.
	fn read(operation: &str, canonical: &str) -> Result<Self, Error> {
		if let Ok((id, base, name, arguments)) = serde_json::from_str::<(String, u64, String, Vec<String>)>(canonical)
			&& id == operation
		{
			return Ok(Self::Command { base, name, arguments });
		}
		match uploads::Intent::read(canonical) {
			Ok(intent) if intent.operation == operation => Ok(Self::Upload {
				base: intent.base,
				conversation: intent.conversation,
			}),
			_ => Err(Error::Malformed("the original request is not one this view sends")),
		}
	}

	/// The base the request was sent at, and what its committed result is
	/// adopted into, or none when it returns nothing to keep.
	fn adoption(&self) -> (u64, Option<Adoption<'_>>) {
		match self {
			Self::Command { base, name, arguments } => (*base, Adoption::of(name, arguments)),
			Self::Upload { base, conversation } => (*base, Some(Adoption::Line(conversation))),
		}
	}
}

impl<D: Deadline + Tasks + Clone + 'static> View<D> {
	/// Look at the receipt of `operation`, which this access sent, and keep
	/// what it committed. `Unkept` and `Unopened` report a result that could
	/// not be kept, with what became of its receipt: given back for a refusal
	/// that never clears, held for a failure that clears, so a later look
	/// keeps it (`Error::refuses_keeping`).
	pub async fn settle_effect(&self, operation: &str) -> Result<Recovered, Error> {
		let Some(effect) = self.recovered(operation).await? else {
			return Ok(Recovered::Gone);
		};
		let status = self.settled(effect.status().await).await?;
		match status {
			EffectStatus::Pending => return Ok(Recovered::Pending),
			EffectStatus::Unknown => return Ok(Recovered::Unknown),
			EffectStatus::Unsent | EffectStatus::Conflict => return Ok(Recovered::Unapplied(status)),
			EffectStatus::Committed => {}
		}
		let original = Original::read(operation, effect.canonical())?;
		let (base, adoption) = original.adoption();
		let Some(adoption) = adoption else {
			self.forfeit(Effect::Recovered(&effect), base).await?;
			return Ok(Recovered::Committed { files: None });
		};
		// Read before the result is kept, as `send_files` reads it, because
		// keeping it may give the receipt back.
		let files = match &original {
			Original::Upload { conversation, .. } => Some(
				self.upload_outcome(Effect::Recovered(&effect), base, conversation)
					.await?,
			),
			Original::Command { .. } => None,
		};
		// The workspace read now stands for the one the request was sent
		// against, as `keep_command` reads it.
		let now = match fault::lose(ViewFault::PostLostUnkept) {
			Ok(()) => self.snapshot().await,
			Err(injected) => Err(injected),
		};
		match now {
			Ok(now) => {
				self.kept(Effect::Recovered(&effect), base, adoption, Ok(&now.intent))
					.await
			}
			Err(cause) => self.kept(Effect::Recovered(&effect), base, adoption, Err(cause)).await,
		}
		.map_err(|error| error.read_files(files.clone()))?;
		Ok(Recovered::Committed { files })
	}

	/// Give back the receipt of `operation`, which this access sent, as
	/// `release_line` gives one back. A receipt the session no longer holds for
	/// this access answers [`Release::Released`].
	pub async fn release_effect(&self, operation: &str) -> Result<Release, Error> {
		let Some(effect) = self.recovered(operation).await? else {
			return Ok(Release::Released);
		};
		match self.give_back(Effect::Recovered(&effect)).await {
			Ok(release) => Ok(release),
			Err(error) => Err(self.failure(error).await),
		}
	}

	async fn recovered(&self, operation: &str) -> Result<Option<RecoveredEffect<D>>, Error> {
		self.settled(self.workspace.recover_effect(operation).await).await
	}
}

#[cfg(test)]
mod tests {
	use super::Original;

	#[test]
	fn a_command_intent_is_read_with_its_adoption_and_another_operation_is_refused() {
		let canonical = serde_json::to_string(&("op1", 7u64, "say", ["c1", "hello"])).unwrap();
		let original = Original::read("op1", &canonical).unwrap();
		let (base, adoption) = original.adoption();
		assert_eq!(base, 7);
		assert!(matches!(
			adoption,
			Some(rooms_application::content::session::workspace::Adoption::Line("c1"))
		));
		assert!(Original::read("op2", &canonical).is_err());
		let edit = serde_json::to_string(&("op1", 7u64, "editLine", ["c1", "3", "hi"])).unwrap();
		assert!(Original::read("op1", &edit).unwrap().adoption().1.is_none());
		assert!(Original::read("op1", "{}").is_err());
	}
}
