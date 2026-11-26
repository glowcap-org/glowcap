//! The worker owns private observations independently of the task polling them.
use super::super::results::{Prepared, Settlement};
use super::*;
use crate::session::managed::executor::paused;
use glowcap::{
	Host,
	loam::{Continuation, EffectExecution, EffectResult},
};
use rooms_application::{
	content::session::effects::{FILL_ROUND_MS, OBSERVATION_MS},
	files::{self, transfer::UploadProgress},
	session::effect::Reply,
};
use rooms_glowcap::client::Deadline;
use std::{cell::Cell, future::Future, pin::Pin, rc::Rc};

struct Upload {
	reference: Ref,
	progress: UploadProgress,
}
type Completion = Pin<Box<dyn Future<Output = Ending>>>;
/// The continuation and intent live in the phases that use them. The final
/// phase moves them into its future, so nothing in the pipeline is optional.
enum Phase {
	Staging {
		continuation: Continuation,
		intent: Intent,
	},
	Primary {
		continuation: Continuation,
		intent: Intent,
	},
	Completing(Completion),
	/// The post is acknowledged and the room holds the line. The fill's output
	/// is a settlement and nothing else, so no deadline can pause it or leave
	/// the receipt unresolved: a round that does not finish ends it as an
	/// incomplete line.
	Filling(Fill),
	Finished,
}
type Fill = Pin<Box<dyn Future<Output = Settlement>>>;
/// Where `acknowledge` stopped.
enum Step {
	/// The upload ended before any file was filled.
	Ended(Option<Ending>),
	/// The post is acknowledged and the fill is next.
	Posted,
}
/// A private EffectExecution stays here after drive or projection refusal.
/// Retrying observation never recreates its dispatch. Filling and cleanup own
/// their full futures, so task cancellation also preserves an admitted append.
/// Only one <= CHUNK_BYTES owning byte reply exists before write admission.
/// UploadProgress remains the sole byte-offset and acknowledgement owner.
pub(in crate::session::managed) struct Pipeline {
	host: Host,
	released: Rc<Cell<bool>>,
	reply_bytes: usize,
	uploads: Vec<Upload>,
	pending: Option<EffectExecution>,
	phase: Phase,
}
/// Drive one private effect to completion, keeping a refused dispatch out of
/// `pending` so a retried observation never recreates it.
async fn perform(
	pending: &mut Option<EffectExecution>,
	continuation: &Continuation,
	reply_bytes: usize,
	index: usize,
	verb: &str,
	args: &[Argument],
) -> Result<EffectResult> {
	let execution = match pending {
		Some(execution) => execution,
		None => match continuation.execute(index, verb, args, reply_bytes) {
			Ok(execution) => pending.insert(execution),
			Err(error) => return Ok(EffectResult::Unsent(error)),
		},
	};
	let result = execution.completed().await?;
	*pending = None;
	Ok(result)
}
impl Pipeline {
	pub fn new(
		host: Host,
		continuation: Continuation,
		intent: Intent,
		released: Rc<Cell<bool>>,
		reply_bytes: usize,
	) -> Self {
		let uploads = Vec::with_capacity(intent.files.as_slice().len());
		Self {
			host,
			released,
			reply_bytes,
			uploads,
			pending: None,
			phase: Phase::Staging { continuation, intent },
		}
	}
	/// Discard the staged uploads and end unresolved by `cause`. The receipt
	/// cannot settle on a lost answer: a lost attach may have staged an upload
	/// no handle names, and a lost post may have posted the line, so a
	/// confirmed discard of the known handles proves neither absent.
	fn cleanup(&mut self, cause: glowcap::Error) {
		let host = self.host.clone();
		let uploads = std::mem::take(&mut self.uploads);
		self.phase = Phase::Completing(Box::pin(async move {
			// best-effort: the receipt stays unresolved whatever the discard
			// confirms, and an unconfirmed upload expires with its staging.
			discard(&host, &uploads).await;
			Ending::Unresolved(cause)
		}));
	}
	/// Confirm compensation before declaring the original post absent. A failed
	/// discard remains an uncertain outcome with its diagnostic retained.
	fn cleanup_refused(&mut self, error: glowcap::Error) {
		let host = self.host.clone();
		let uploads = std::mem::take(&mut self.uploads);
		self.phase = Phase::Completing(Box::pin(async move {
			Ending::Settled(if discard(&host, &uploads).await {
				Settlement::refused(&error)
			} else {
				Settlement::unknown(&error.with_context("upload cleanup was not confirmed after admission refusal"))
			})
		}));
	}
	/// Every file is staged: the next phase posts the primary.
	fn staged(&mut self) {
		self.phase = match std::mem::replace(&mut self.phase, Phase::Finished) {
			Phase::Staging { continuation, intent } => Phase::Primary { continuation, intent },
			other => other,
		};
	}
	/// Run the upload to its ending. Staging and the post are one observation
	/// of [`OBSERVATION_MS`], whose expiry pauses the job, because their
	/// outcome is unknown. Files already staged may expire during a pause. The
	/// next observation resumes with the remaining files. After the
	/// post's acknowledgement the fill runs under no observation of the
	/// executor's. Each round of it has its own bound.
	pub async fn advance<P: Deadline + Clone + 'static>(&mut self, platform: &P) -> Result<Option<Ending>> {
		if !matches!(self.phase, Phase::Filling(_)) {
			let step = platform
				.within(OBSERVATION_MS, self.acknowledge(platform))
				.await
				.ok_or_else(|| paused("upload observation deadline expired"))??;
			if let Step::Ended(ending) = step {
				return Ok(ending);
			}
		}
		let Phase::Filling(fill) = &mut self.phase else {
			return Ok(None);
		};
		let settlement = fill.await;
		self.phase = Phase::Finished;
		Ok(Some(Ending::Settled(settlement)))
	}
	async fn acknowledge<P: Deadline + Clone + 'static>(&mut self, platform: &P) -> Result<Step> {
		loop {
			match &mut self.phase {
				Phase::Finished => return Ok(Step::Ended(None)),
				Phase::Filling(_) => return Ok(Step::Posted),
				Phase::Completing(pending) => {
					let outcome = pending.await;
					self.phase = Phase::Finished;
					return Ok(Step::Ended(Some(outcome)));
				}
				Phase::Staging { continuation, intent } => {
					let Some(description) = intent.files.as_slice().get(self.uploads.len()) else {
						self.staged();
						continue;
					};
					let file = description.file().map_err(|error| refuse(&error.to_string()))?;
					let (width, height) = file.dimensions();
					let args = [
						file.name().into(),
						file.mime().into(),
						Argument::Integer(file.size() as i64),
						Argument::Integer(width.into()),
						Argument::Integer(height.into()),
					];
					let reply_bytes = self.reply_bytes;
					let outcome = perform(
						&mut self.pending,
						continuation,
						reply_bytes,
						0,
						rooms_application::room::receipt::ATTACH,
						&args,
					)
					.await?;
					match outcome {
						EffectResult::Ready(Argument::List(pair))
							if matches!(pair.as_slice(), [Argument::Reference(_), Argument::Reference(_)]) =>
						{
							let Argument::Reference(reference) = &pair[0] else {
								unreachable!("checked upload pair")
							};
							self.uploads.push(Upload {
								reference: reference.clone(),
								progress: UploadProgress::new(file.size())
									.map_err(|_| refuse("invalid upload progress"))?,
							});
						}
						EffectResult::Unsent(error) => self.cleanup_refused(error),
						EffectResult::Unknown(error)
							if rooms_glowcap::client::binding_admission_refusal(&error).is_some() =>
						{
							self.cleanup_refused(error)
						}
						// An unanswered or malformed attach can have staged an
						// unseen upload. Returning known handles cannot prove empty.
						EffectResult::Unknown(cause) => self.cleanup(cause),
						_ => self.cleanup(refuse("upload attach answered without its upload")),
					}
				}
				Phase::Primary { continuation, intent } => {
					let (index, verb, args) = match intent.upload {
						Kind::Post => (
							0,
							rooms_application::room::correlation::POST_FILES,
							vec![
								intent.caption.clone().into(),
								intent.previews.clone().into(),
								intent.operation.clone().into(),
							],
						),
						Kind::Refile(_) => {
							let mut args = vec![intent.caption.clone().into()];
							args.extend(
								intent
									.keep
									.as_slice()
									.iter()
									.map(|index| Argument::Integer((*index).into())),
							);
							(1, rooms_application::protocol_data::REFILE, args)
						}
					};
					let reply = if intent.upload == Kind::Post {
						Reply::Line
					} else {
						Reply::Acknowledgment
					};
					let reply_bytes = self.reply_bytes;
					let primary =
						match perform(&mut self.pending, continuation, reply_bytes, index, verb, &args).await? {
							EffectResult::Ready(value) => value,
							EffectResult::Unsent(error) => {
								self.cleanup_refused(error);
								continue;
							}
							EffectResult::Unknown(error)
								if rooms_glowcap::client::binding_admission_refusal(&error).is_some() =>
							{
								self.cleanup_refused(error);
								continue;
							}
							EffectResult::Unknown(cause) => {
								self.cleanup(cause);
								continue;
							}
							EffectResult::Pending => unreachable!("completed upload post"),
						};
					let posted = match Prepared::read(reply, &primary, "", None).and_then(|read| match read {
						Prepared::Complete(settlement) => Posted::read(settlement, reply),
						_ => Err(refuse("upload post answer is not a settlement")),
					}) {
						Ok(posted) => posted,
						Err(cause) => {
							self.cleanup(cause);
							continue;
						}
					};
					// Known primary acknowledgement consumed this exact batch.
					// Cold unresolved custody conservatively excludes it again.
					self.released.set(true);
					let host = self.host.clone();
					let platform = platform.clone();
					let uploads = std::mem::take(&mut self.uploads);
					self.phase = match std::mem::replace(&mut self.phase, Phase::Finished) {
						Phase::Primary { continuation, intent } => Phase::Filling(Box::pin(async move {
							fill(&host, &platform, &continuation, intent.target_count(), uploads, posted).await
						})),
						other => other,
					};
				}
			}
		}
	}
}
async fn discard(host: &Host, uploads: &[Upload]) -> bool {
	let mut complete = true;
	for upload in uploads {
		complete &= matches!(
			host.send(&upload.reference, rooms_application::protocol_data::DISCARD, &[])
				.await,
			Ok(Argument::Void)
		);
	}
	complete
}
/// Fill every file, a chunk of each in turn, and settle the posted line as
/// complete or as standing with its files incomplete. The room renews a
/// file's lease when a write crosses a multiple of the chunk size or finishes
/// the file, so a file whose chunks come whole renews with each, and the files
/// advance together. A source that answers with less than a chunk may cross no
/// multiple for some rounds, and the room ends the lease of that file after
/// its idle time all the same. Each round is one chunk of every unfinished
/// file, bounded by [`FILL_ROUND_MS`]: a whole-chunk file waits less than two
/// rounds between its chunks, which is below the room's lease. A round that
/// does not finish within its bound ends the fill, and so does a failed read
/// or write, which keeps its typed cause.
async fn fill<P: Deadline>(
	host: &Host,
	platform: &P,
	continuation: &Continuation,
	source_start: usize,
	mut uploads: Vec<Upload>,
	posted: Posted,
) -> Settlement {
	let mut failure = None;
	while uploads.iter().any(|upload| !upload.progress.complete()) {
		let round = platform.within(
			FILL_ROUND_MS,
			round(host, platform, continuation, source_start, &mut uploads),
		);
		match round.await {
			Some(Ok(())) => {}
			Some(Err(error)) => {
				failure = Some(Settlement::reason_text(&error));
				break;
			}
			None => {
				failure = Some(format!(
					"a round of one piece of each file did not finish within {FILL_ROUND_MS} ms"
				));
				break;
			}
		}
	}
	if failure.is_some() {
		// best-effort: the line stands and its files are reported incomplete
		// whatever the discard confirms, and an unconfirmed upload expires
		// with the room's lease.
		let _ = platform.within(OBSERVATION_MS, discard(host, &uploads)).await;
	}
	posted.finish(failure)
}
/// One chunk of every unfinished file, read from its source and appended to
/// its upload.
async fn round<P: Deadline>(
	host: &Host,
	platform: &P,
	continuation: &Continuation,
	source_start: usize,
	uploads: &mut [Upload],
) -> Result<()> {
	for (index, upload) in uploads.iter_mut().enumerate() {
		if upload.progress.complete() {
			continue;
		}
		// Recheck original upload admission before dispatch and after each read.
		let source = continuation.project(source_start + index)?;
		let args = [
			Argument::Integer(upload.progress.written() as i64),
			Argument::Integer(files::CHUNK_BYTES.min(upload.progress.remaining()) as i64),
		];
		let value = host
			.send(&source, rooms_application::protocol_data::READ, &args)
			.await?;
		let Argument::Bytes(bytes) = value else {
			return Err(refuse("upload source returned no bytes"));
		};
		upload
			.progress
			.begin(bytes.len())
			.map_err(|_| refuse("upload source returned an invalid chunk"))?;
		if let Some(delay) = crate::session::fault::upload_write_delay_ms() {
			// tolerant: the pause ends at its deadline by design.
			let _ = platform.within(delay, std::future::pending::<()>()).await;
		}
		let value = host
			.send(
				&upload.reference,
				rooms_application::protocol_data::WRITE,
				&[Argument::Bytes(bytes)],
			)
			.await?;
		if !matches!(value, Argument::Void) {
			return Err(refuse("upload write returned no acknowledgement"));
		}
		upload
			.progress
			.acknowledge()
			.map_err(|_| refuse("upload append has no acknowledgement"))?;
	}
	Ok(())
}
