//! A membership has one staged upload batch. Keep that custody exclusive until
//! posting/refiling acknowledges it or every staged upload is discarded.
use super::*;
use rooms_glowcap::client::{files::Upload, sources::Source};
use std::cell::Cell;

#[derive(Clone, Copy, Default)]
enum State {
	#[default]
	Available,
	Active,
	Uncertain,
}
#[derive(Default)]
pub(super) struct Slot(Rc<Cell<State>>);
struct Batch {
	state: Rc<Cell<State>>,
	settled: bool,
}
impl Slot {
	fn take(&self) -> Result<Batch, Failure> {
		match self.0.get() {
			State::Available => self.0.set(State::Active),
			State::Active => return Err(Failure::NotApplied("this membership is changing files".into())),
			State::Uncertain => {
				return Err(Failure::NotApplied(
					"the membership's staged files are uncertain; rejoin the room before changing files".into(),
				))
			}
		}
		Ok(Batch {
			state: self.0.clone(),
			settled: false,
		})
	}
}
impl Batch {
	fn settled(mut self) {
		self.state.set(State::Available);
		self.settled = true;
	}
}
impl Drop for Batch {
	fn drop(&mut self) {
		if !self.settled {
			self.state.set(State::Uncertain);
		}
	}
}

impl<P: Platform> RoomRuntime<P> {
	fn file_batch(&self, conversation: &str) -> Result<(Rc<Room<P>>, Batch), Failure> {
		let state = self.shared.borrow();
		let live = connected(&state, conversation).map_err(Failure::NotApplied)?;
		Ok((live.room.clone(), live.file_batch.take()?))
	}
	/// Post first, then fill the membership's newly published uploads. A failed
	/// fill reports that the line stands and attempts to discard incomplete files.
	pub async fn send_files(&self, conversation: &str, caption: &str, files: Vec<Source>) -> Result<(), Failure> {
		validate(caption, &files)?;
		if files.is_empty() {
			return self.say(conversation, caption).await;
		}
		let (room, batch) = self.file_batch(conversation)?;
		let (_, slot) = match self.reserve_pending(conversation) {
			Ok(reserved) => reserved,
			Err(reason) => {
				batch.settled();
				return Err(Failure::NotApplied(reason));
			}
		};
		let mut uploads = match stage(&room, &files).await {
			Ok(uploads) => uploads,
			Err(reason) => {
				slot.abort();
				return Err(Failure::NotApplied(reason));
			}
		};
		let posted = match room.post_files(caption).await {
			Ok(posted) => posted,
			Err(error) => {
				slot.abort();
				return Err(rejected(batch, error, uploads).await);
			}
		};
		// The peer has moved this whole batch out of staging. Later batches
		// cannot consume these files, even while their bytes are still arriving.
		batch.settled();
		slot.complete(posted);
		if let Err(error) = fill(&self.platform, &mut uploads, &files).await {
			let (reason, _) = discarding(format!("the line was posted, but its files failed: {error}"), uploads).await;
			return Err(Failure::Applied(reason));
		}
		Ok(())
	}
	/// Room refiles take indices and membership-staged uploads. Inline blob
	/// records belong to direct lines and never enter this path.
	pub async fn refile(
		&self,
		conversation: &str,
		line: u64,
		caption: &str,
		keep: &[u32],
		files: Vec<Source>,
	) -> Result<(), Failure> {
		validate(caption, &files)?;
		if keep.len() + files.len() > rooms_application::room::line::MAX_MESSAGE_FILES {
			return Err(Failure::NotApplied("a line may carry at most eight files".into()));
		}
		let posted = self.line(conversation, line).map_err(Failure::NotApplied)?;
		// A refile with no new files still consumes whatever this membership
		// staged. It must participate in the same exclusive batch admission.
		let (room, batch) = self.file_batch(conversation)?;
		let mut uploads = stage(&room, &files).await.map_err(Failure::NotApplied)?;
		if let Err(error) = posted.refile(caption, keep).await {
			return Err(rejected(batch, error, uploads).await);
		}
		batch.settled();
		if let Err(error) = fill(&self.platform, &mut uploads, &files).await {
			let (reason, _) = discarding(format!("the line was refiled, but its files failed: {error}"), uploads).await;
			return Err(Failure::Applied(reason));
		}
		Ok(())
	}
}

fn validate(caption: &str, files: &[Source]) -> Result<(), Failure> {
	if caption.len() > rooms_application::room::line::MAX_LINE_BYTES
		|| !rooms_application::files::receiving::selection_fits(files.iter().map(Source::description))
	{
		return Err(Failure::NotApplied(
			"the caption or file selection exceeds its limit".into(),
		));
	}
	Ok(())
}
async fn stage<P: Platform>(room: &Room<P>, files: &[Source]) -> Result<Vec<Upload<P>>, String> {
	let mut uploads = Vec::with_capacity(files.len());
	for file in files {
		match room.stage(file.description().clone()).await {
			Ok(upload) => uploads.push(upload),
			Err(error) => {
				// An unanswered attach may have staged a file whose capability we
				// never received. The batch remains uncertain even after cleanup
				// of the uploads we do hold, until the membership is retired.
				return Err(discarding(error.to_string(), uploads).await.0);
			}
		}
	}
	Ok(uploads)
}
async fn rejected<P: Platform>(batch: Batch, error: rooms_glowcap::client::Error, uploads: Vec<Upload<P>>) -> Failure {
	let verdict = failure(error);
	let primary = match &verdict {
		Failure::NotApplied(reason) | Failure::Applied(reason) | Failure::Unknown(reason) => reason.clone(),
	};
	let (reason, cleared) = discarding(primary, uploads).await;
	if cleared && matches!(verdict, Failure::NotApplied(_)) {
		batch.settled();
	}
	match verdict {
		Failure::NotApplied(_) => Failure::NotApplied(reason),
		Failure::Applied(_) => Failure::Applied(reason),
		Failure::Unknown(_) => Failure::Unknown(reason),
	}
}

async fn fill<P: Platform>(platform: &P, uploads: &mut [Upload<P>], files: &[Source]) -> Result<(), String> {
	for (upload, file) in uploads.iter_mut().zip(files) {
		let mut offset = 0;
		while offset < file.description().size() as u64 {
			let chunk = file
				.read(platform, offset, rooms_application::files::CHUNK_BYTES)
				.await?;
			let length = chunk.as_ref().len();
			if length == 0 {
				return Err("the file ended before its declared size".into());
			}
			upload
				.write(chunk.into_vec())
				.await
				.map_err(|error| error.to_string())?;
			offset += length as u64;
		}
	}
	Ok(())
}
async fn discarding<P: Platform>(primary: String, uploads: Vec<Upload<P>>) -> (String, bool) {
	let mut reason = primary;
	let mut cleared = true;
	for upload in uploads {
		if let Err(error) = upload.discard().await {
			cleared = false;
			reason = format!("{reason}; discarding a staged upload also failed: {error}");
		}
	}
	(reason, cleared)
}
