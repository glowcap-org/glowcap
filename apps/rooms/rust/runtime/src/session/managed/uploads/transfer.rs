//! The worker owns private observations independently of the task polling them.
use super::super::results::{Prepared, Settlement};
use super::*;
use glowcap::{
	Host,
	loam::{Continuation, EffectExecution, EffectResult},
};
use rooms_application::{
	files::{self, transfer::UploadProgress},
	session::effect::Reply,
};
use std::{cell::Cell, future::Future, pin::Pin, rc::Rc};

struct Upload {
	reference: Ref,
	progress: UploadProgress,
}
type Completion = Pin<Box<dyn Future<Output = Option<Settlement>>>>;
/// The continuation and intent live in the phases that use them. The final
/// phase moves them into its future, so nothing in the pipeline is optional.
enum Phase {
	Staging { continuation: Continuation, intent: Intent },
	Primary { continuation: Continuation, intent: Intent },
	Completing(Completion),
	Finished,
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
	fn cleanup(&mut self, known_absent: bool) {
		let host = self.host.clone();
		let uploads = std::mem::take(&mut self.uploads);
		self.phase = Phase::Completing(Box::pin(async move {
			let empty = discard(&host, &uploads).await;
			if known_absent && empty {
				Some(Settlement::absent())
			} else {
				None
			}
		}));
	}
	/// Confirm compensation before declaring the original post absent. A failed
	/// discard remains an uncertain outcome with its diagnostic retained.
	fn cleanup_refused(&mut self, error: glowcap::Error) {
		let host = self.host.clone();
		let uploads = std::mem::take(&mut self.uploads);
		self.phase = Phase::Completing(Box::pin(async move {
			Some(if discard(&host, &uploads).await {
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
	pub async fn advance(&mut self) -> Result<Option<Settlement>> {
		loop {
			match &mut self.phase {
				Phase::Finished => return Ok(None),
				Phase::Completing(pending) => {
					let outcome = pending.await;
					self.phase = Phase::Finished;
					return Ok(outcome);
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
						_ => self.cleanup(false),
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
							_ => {
								self.cleanup(false);
								continue;
							}
						};
					let settlement = match Prepared::read(reply, &primary, "") {
						Ok(Prepared::Complete(settlement)) => settlement,
						_ => {
							self.cleanup(false);
							continue;
						}
					};
					// Known primary acknowledgement consumed this exact batch.
					// Cold unresolved custody conservatively excludes it again.
					self.released.set(true);
					let host = self.host.clone();
					let uploads = std::mem::take(&mut self.uploads);
					self.phase = match std::mem::replace(&mut self.phase, Phase::Finished) {
						Phase::Primary { continuation, intent } => Phase::Completing(Box::pin(async move {
							finish(&host, &continuation, intent.target_count(), uploads, settlement, reply)
								.await
								.unwrap_or(None)
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
async fn finish(
	host: &Host,
	continuation: &Continuation,
	source_start: usize,
	mut uploads: Vec<Upload>,
	settlement: Settlement,
	reply: Reply,
) -> Result<Option<Settlement>> {
	let filled = fill(host, continuation, source_start, &mut uploads).await;
	if filled.is_err() {
		discard(host, &uploads).await;
	}
	let failure = filled
		.err()
		.map(|error| {
			rooms_application::fields::Text::new(error.to_string().into())
				.or_else(|| {
					rooms_application::fields::Text::new("the line stands, but its files could not be completed".into())
				})
				.ok_or_else(|| refuse("upload failure text is not admitted"))
		})
		.transpose()?;
	complete(settlement, reply, failure).map(Some)
}
async fn fill(host: &Host, continuation: &Continuation, source_start: usize, uploads: &mut [Upload]) -> Result<()> {
	for (index, upload) in uploads.iter_mut().enumerate() {
		// Recheck original upload admission before dispatch and after each read.
		let source = continuation.project(source_start + index)?;
		while !upload.progress.complete() {
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
	}
	Ok(())
}
