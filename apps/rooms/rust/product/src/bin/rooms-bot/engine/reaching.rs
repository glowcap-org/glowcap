//! The link's storing as the serving loop sees it: what the session's first
//! answer to the link stores, written again with backoff until it is written.
use super::{Backoff, Core, Env};
use crate::bot::{
	error::{Error, LinkStage},
	rooms::Rooms,
	status::Activity,
	words,
};
use std::time::Duration;

/// The link's storing while it is pending, with the stage that words a
/// refusal until then. Whether the link is stored is [`Env::is_linked`], the
/// one fact, which [`Reaching::run`] sets once the write succeeds.
pub struct Reaching {
	stage: LinkStage,
	/// The writes still to try are on this backoff.
	backoff: Backoff,
	/// A write failed, so its success is logged.
	failed: bool,
}

/// What a read's success means for the link's storing.
pub enum Reached {
	/// The link is stored, so the batch is taken.
	Go,
	/// The write failed and the events stay unread: read again after this long.
	Again(Duration),
	/// The write failed for good.
	End(Error),
}

impl Reaching {
	pub fn new(stage: LinkStage) -> Self {
		Self {
			stage,
			backoff: Backoff::standard(),
			failed: false,
		}
	}

	/// How the link stands, as a refusal words it.
	pub fn stage<R: Rooms>(&self, env: &Env<'_, R>) -> LinkStage {
		if env.is_linked() { LinkStage::Stored } else { self.stage }
	}

	/// Run `reached` once a read has succeeded and until it has.
	pub fn run<R: Rooms>(&mut self, env: &Env<'_, R>, reached: &mut impl FnMut() -> Result<(), Error>) -> Reached {
		if env.is_linked() {
			return Reached::Go;
		}
		match reached() {
			Ok(()) => {
				env.link_reached();
				if self.failed {
					env.store.log(words::SAVED_ON_RETRY);
					env.facts.borrow_mut().recovered(Activity::Saving);
					env.publish();
				}
				Reached::Go
			}
			Err(error) if error.is_transient() => {
				self.failed = true;
				note_failed(env, &error);
				Reached::Again(self.backoff.next())
			}
			Err(error) => Reached::End(error),
		}
	}
}

fn note_failed<R: Rooms>(env: &Core<'_, R>, error: &Error) {
	env.store
		.log(&format!("{} {}: {error}", words::SAVING_LINK, words::TRYING_AGAIN));
	env.facts.borrow_mut().failed(Activity::Saving, error);
	env.publish();
}
