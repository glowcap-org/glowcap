//! A membership has one staged upload batch. Keep that custody exclusive until
//! posting/refiling acknowledges it or every staged upload is discarded.
use super::*;
use rooms_glowcap::client::{files::Upload, sources::Source};
use std::cell::Cell;

#[derive(Clone, Copy, Default)]
enum State {
	#[default]
	Available,
	Active {
		generation: u64,
		line: Option<u64>,
	},
	Uncertain,
}
#[derive(Default)]
struct Custody {
	state: Cell<State>,
	next: Cell<u64>,
	changed: tokio::sync::Notify,
}
#[derive(Default)]
pub(super) struct Slot(Rc<Custody>);
struct Batch {
	state: Rc<Custody>,
	settled: bool,
}
impl Slot {
	fn take(&self, line: Option<u64>) -> Result<Batch, Failure> {
		match self.0.state.get() {
			State::Available => {}
			State::Active { .. } => {
				return Err(Failure::NotApplied(Error::busy("this membership is changing files")));
			}
			State::Uncertain => {
				return Err(Failure::NotApplied(Error::uncertain(
					"the membership's staged files are uncertain; rejoin the room before changing files",
				)));
			}
		}
		let generation = self.0.next.get();
		self.0.next.set(
			generation
				.checked_add(1)
				.ok_or_else(|| Failure::NotApplied(Error::exhausted("file batch generations exhausted")))?,
		);
		self.0.state.set(State::Active { generation, line });
		Ok(Batch {
			state: self.0.clone(),
			settled: false,
		})
	}
	/// Wait only for the matching publication attempt. No bytes or capability
	/// authority ride this barrier; settling a newer batch cannot prolong it.
	pub(super) fn publication(
		&self,
		marker: Option<rooms_application::room::message::LineMarker>,
	) -> impl std::future::Future<Output = ()> + use<> {
		use rooms_application::room::message::ChangeKind;
		let active = match (self.0.state.get(), marker) {
			(
				State::Active {
					generation,
					line: Some(line),
				},
				Some(marker),
			) if line == marker.id.get() && matches!(marker.kind, ChangeKind::Refiled | ChangeKind::Withdrawn) => {
				Some((self.0.clone(), generation))
			}
			_ => None,
		};
		async move {
			if let Some((state, generation)) = active {
				loop {
					let changed = state.changed.notified();
					if !matches!(state.state.get(), State::Active { generation: current, .. } if current == generation)
					{
						break;
					}
					changed.await;
				}
			}
		}
	}
}
impl Batch {
	fn refiling(&self, line: u64) {
		let State::Active { generation, .. } = self.state.state.get() else {
			unreachable!("live file batch")
		};
		self.state.state.set(State::Active {
			generation,
			line: Some(line),
		});
	}
	fn settled(mut self) {
		self.state.state.set(State::Available);
		self.settled = true;
		self.state.changed.notify_waiters();
	}
}
impl Drop for Batch {
	fn drop(&mut self) {
		if !self.settled {
			self.state.state.set(State::Uncertain);
			self.state.changed.notify_waiters();
		}
	}
}

impl<P: Platform> RoomRuntime<P> {
	fn file_batch(&self, conversation: &str) -> Result<(Rc<Room<P>>, Batch), Failure> {
		let state = self.shared.borrow();
		let live = connected(&state, conversation).map_err(Failure::NotApplied)?;
		Ok((live.room.clone(), live.file_batch.take(None)?))
	}
	/// Post first, then fill the membership's newly published uploads. A failed
	/// fill reports that the line stands and attempts to discard incomplete files.
	pub async fn send_files(&self, conversation: &str, caption: &str, files: Vec<Source>) -> Result<(), Failure> {
		self.send_files_with_previews(conversation, caption, Default::default(), files)
			.await
	}
	pub async fn send_files_with_previews(
		&self,
		conversation: &str,
		caption: &str,
		previews: rooms_application::open_graph::Selection,
		files: Vec<Source>,
	) -> Result<(), Failure> {
		validate(caption, &files)?;
		if files.is_empty() {
			return self.say_with_previews(conversation, caption, previews).await;
		}
		let (room, batch) = self.file_batch(conversation)?;
		let PendingSend { request, mut slot, .. } = match self.reserve_pending(conversation) {
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
		slot.dispatched(room.supports_retained(), &self.notices);
		let posted = match room.post_files_retained(caption, &previews, request).await {
			Ok(posted) => posted,
			Err(error) => {
				slot.failed(&error);
				return Err(rejected(batch, error, uploads).await);
			}
		};
		// The peer has moved this whole batch out of staging. Later batches
		// cannot consume these files, even while their bytes are still arriving.
		batch.settled();
		// The pump waits on this slot before admitting the receipt's files.
		// Eviction starts only after the peer committed the post.
		let captures = self.upload_captures(&room, &uploads, &files, None);
		slot.complete(posted);
		if let Err(error) = fill(&self.platform, &mut uploads, &files, captures).await {
			let (reason, _) = discarding(
				Error::closed(format!("the line was posted, but its files failed: {error}")),
				uploads,
			)
			.await;
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
			return Err(Failure::NotApplied(Error::invalid(
				"a line may carry at most eight files",
			)));
		}
		let posted = self.line(conversation, line).map_err(Failure::NotApplied)?;
		// A refile with no new files still consumes whatever this membership
		// staged. It must participate in the same exclusive batch admission.
		let (room, batch) = self.file_batch(conversation)?;
		let mut uploads = stage(&room, &files).await.map_err(Failure::NotApplied)?;
		batch.refiling(line);
		if let Err(error) = posted.refile(caption, keep).await {
			return Err(rejected(batch, error, uploads).await);
		}
		// A matching refile event waits for this batch before media admission.
		let line_key = (!uploads.is_empty() && !keep.is_empty()).then(|| (conversation.to_owned(), line));
		let captures = self.upload_captures(&room, &uploads, &files, line_key.as_ref());
		batch.settled();
		if let Err(error) = fill(&self.platform, &mut uploads, &files, captures).await {
			let (reason, _) = discarding(
				Error::closed(format!("the line was refiled, but its files failed: {error}")),
				uploads,
			)
			.await;
			return Err(Failure::Applied(reason));
		}
		Ok(())
	}
	fn upload_captures(
		&self,
		room: &Room<P>,
		uploads: &[Upload<P>],
		files: &[Source],
		previous: Option<&(String, u64)>,
	) -> Option<Vec<crate::files::media_files::UploadCapture>> {
		if uploads.is_empty() {
			return None;
		}
		let candidates: Option<Vec<_>> = uploads
			.iter()
			.zip(files)
			.map(|(upload, file)| Some((upload.blob()?.clone(), file.capture()?)))
			.collect();
		// Receiver pressure must not refuse a send. The normal receive path
		// still owns admission diagnostics and the archive fallback.
		candidates.and_then(|candidates| {
			let state = self.shared.borrow();
			let protected = previous.map(|line| state.history.attachments(line)).unwrap_or_default();
			state
				.media
				.uploads(room.client().session(), candidates, &protected)
				.ok()
		})
	}
}

fn validate(caption: &str, files: &[Source]) -> Result<(), Failure> {
	if caption.len() > rooms_application::room::line::MAX_LINE_BYTES
		|| !rooms_application::files::receiving::selection_fits(files.iter().map(Source::description))
	{
		return Err(Failure::NotApplied(Error::invalid(
			"the caption or file selection exceeds its limit",
		)));
	}
	Ok(())
}
async fn stage<P: Platform>(room: &Room<P>, files: &[Source]) -> Result<Vec<Upload<P>>, Error> {
	let mut uploads = Vec::with_capacity(files.len());
	for file in files {
		match room.stage(file.description().clone()).await {
			Ok(upload) => uploads.push(upload),
			Err(error) => {
				// An unanswered attach may have staged a file whose capability we
				// never received. The batch remains uncertain even after cleanup
				// of the uploads we do hold, until the membership is retired.
				return Err(discarding(Error::peer(error), uploads).await.0);
			}
		}
	}
	Ok(uploads)
}
/// The room's verdict on the post decides the batch: a refusal it never
/// applied frees the batch once every staged upload is given back, and any
/// other verdict leaves it uncertain.
async fn rejected<P: Platform>(batch: Batch, error: rooms_glowcap::client::Error, uploads: Vec<Upload<P>>) -> Failure {
	match failure(error) {
		Failure::NotApplied(reason) => {
			let (reason, cleared) = discarding(reason, uploads).await;
			if cleared {
				batch.settled();
			}
			Failure::NotApplied(reason)
		}
		Failure::Applied(reason) => Failure::Applied(discarding(reason, uploads).await.0),
		Failure::Unknown(reason) => Failure::Unknown(discarding(reason, uploads).await.0),
	}
}

/// A source that stops early is a closed source; an upload the room refuses
/// is the peer's answer.
async fn fill<P: Platform>(
	platform: &P,
	uploads: &mut [Upload<P>],
	files: &[Source],
	captures: Option<Vec<crate::files::media_files::UploadCapture>>,
) -> Result<(), Error> {
	let mut captures = captures.map(Vec::into_iter);
	for (upload, file) in uploads.iter_mut().zip(files) {
		let mut offset = 0;
		while offset < file.description().size() as u64 {
			let chunk = file
				.read(platform, offset, rooms_application::files::CHUNK_BYTES)
				.await
				.map_err(Error::closed)?;
			let length = chunk.as_ref().len();
			if length == 0 {
				return Err(Error::closed("the file ended before its declared size"));
			}
			upload.write(chunk.into_vec()).await.map_err(Error::peer)?;
			offset += length as u64;
		}
		if let Some(capture) = captures.as_mut().and_then(Iterator::next) {
			capture.complete();
		}
	}
	Ok(())
}
/// Give back every staged upload. A discard that also fails is retained
/// behind the failure it was cleaning up after.
async fn discarding<P: Platform>(primary: Error, uploads: Vec<Upload<P>>) -> (Error, bool) {
	let mut reason = primary;
	let mut cleared = true;
	for upload in uploads {
		if let Err(error) = upload.discard().await {
			cleared = false;
			reason = reason.retain(Error::peer(error));
		}
	}
	(reason, cleared)
}

#[cfg(test)]
mod tests {
	use super::*;
	use rooms_application::room::message::{ChangeKind, LineId, LineMarker};
	use std::{
		future::Future,
		sync::{
			Arc,
			atomic::{AtomicUsize, Ordering},
		},
		task::{Context, Poll, Wake, Waker},
	};
	#[derive(Default)]
	struct Wakes(AtomicUsize);
	impl Wake for Wakes {
		fn wake(self: Arc<Self>) {
			self.0.fetch_add(1, Ordering::Relaxed);
		}
		fn wake_by_ref(self: &Arc<Self>) {
			self.0.fetch_add(1, Ordering::Relaxed);
		}
	}
	fn marker(line: u64, kind: ChangeKind) -> Option<LineMarker> {
		Some(LineMarker {
			id: LineId::new(line).unwrap(),
			kind,
		})
	}
	#[test]
	fn publication_waits_only_for_its_refile_attempt_and_wakes_on_every_exit() {
		let slot = Slot::default();
		let wakes = Arc::new(Wakes::default());
		let waker = Waker::from(wakes.clone());
		let mut context = Context::from_waker(&waker);
		let first = slot.take(None).ok().expect("available batch");
		assert!(
			Box::pin(slot.publication(marker(1, ChangeKind::Refiled)))
				.as_mut()
				.poll(&mut context)
				.is_ready(),
			"staging cannot delay somebody else's publication"
		);
		first.refiling(1);
		for unrelated in [
			None,
			marker(2, ChangeKind::Refiled),
			marker(1, ChangeKind::Said),
			marker(1, ChangeKind::Edited),
		] {
			assert!(
				Box::pin(slot.publication(unrelated))
					.as_mut()
					.poll(&mut context)
					.is_ready()
			);
		}
		let mut waiting = Box::pin(slot.publication(marker(1, ChangeKind::Refiled)));
		assert_eq!(waiting.as_mut().poll(&mut context), Poll::Pending);
		first.settled();
		assert_eq!(wakes.0.load(Ordering::Relaxed), 1);
		let next = slot.take(Some(1)).ok().expect("available batch");
		assert!(
			waiting.as_mut().poll(&mut context).is_ready(),
			"a newer refile cannot extend an older wait"
		);
		let mut withdrawn = Box::pin(slot.publication(marker(1, ChangeKind::Withdrawn)));
		assert!(withdrawn.as_mut().poll(&mut context).is_pending());
		drop(next);
		assert_eq!(wakes.0.load(Ordering::Relaxed), 2);
		assert!(
			withdrawn.as_mut().poll(&mut context).is_ready(),
			"cancellation cannot strand the stream"
		);
		assert!(
			slot.take(Some(1)).is_err(),
			"uncertain staged custody still requires rejoin"
		);
	}
}
