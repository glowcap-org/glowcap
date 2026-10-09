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
enum Phase {
	Staging,
	Primary,
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
	continuation: Option<Continuation>,
	intent: Option<Intent>,
	released: Rc<Cell<bool>>,
	reply_bytes: usize,
	uploads: Vec<Upload>,
	pending: Option<EffectExecution>,
	phase: Phase,
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
			continuation: Some(continuation),
			intent: Some(intent),
			released,
			reply_bytes,
			uploads,
			pending: None,
			phase: Phase::Staging,
		}
	}
	async fn perform(&mut self, index: usize, verb: &str, args: &[Argument]) -> Result<EffectResult> {
		if self.pending.is_none() {
			match self
				.continuation
				.as_ref()
				.expect("active continuation")
				.execute(index, verb, args, self.reply_bytes)
			{
				Ok(execution) => self.pending = Some(execution),
				Err(error) => return Ok(EffectResult::Unsent(error)),
			}
		}
		let result = self
			.pending
			.as_mut()
			.expect("owned private execution")
			.completed()
			.await?;
		self.pending = None;
		Ok(result)
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
	pub async fn advance(&mut self) -> Result<Option<Settlement>> {
		loop {
			match &mut self.phase {
				Phase::Finished => return Ok(None),
				Phase::Completing(pending) => {
					let outcome = pending.await;
					self.phase = Phase::Finished;
					return Ok(outcome);
				}
				Phase::Staging => {
					let intent = self.intent.as_ref().expect("active upload intent");
					let Some(description) = intent.files.as_slice().get(self.uploads.len()) else {
						self.phase = Phase::Primary;
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
					match self.perform(0, rooms_application::room::receipt::ATTACH, &args).await? {
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
						EffectResult::Unsent(_) => self.cleanup(true),
						// An unanswered or malformed attach can have staged an
						// unseen upload. Returning known handles cannot prove empty.
						_ => self.cleanup(false),
					}
				}
				Phase::Primary => {
					let intent = self.intent.as_ref().expect("active upload intent");
					let (index, verb, args) = match intent.upload {
						Kind::Post => (
							0,
							rooms_application::open_graph::ROOM_POST_FILES_VERB,
							vec![intent.caption.clone().into(), intent.previews.clone().into()],
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
					let primary = match self.perform(index, verb, &args).await? {
						EffectResult::Ready(value) => value,
						EffectResult::Unsent(_) => {
							self.cleanup(true);
							continue;
						}
						_ => {
							self.cleanup(false);
							continue;
						}
					};
					let intent = self.intent.as_ref().expect("active upload intent");
					let reply = if intent.upload == Kind::Post {
						Reply::Line
					} else {
						Reply::Acknowledgment
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
					let continuation = self.continuation.take().expect("active continuation");
					let intent = self.intent.take().expect("active upload intent");
					let uploads = std::mem::take(&mut self.uploads);
					self.phase = Phase::Completing(Box::pin(async move {
						finish(&host, &continuation, intent.target_count(), uploads, settlement, reply)
							.await
							.unwrap_or(None)
					}));
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
	let failure = fill(host, continuation, source_start, &mut uploads)
		.await
		.err()
		.map(|error| {
			rooms_application::fields::Text::new(error.to_string().into()).unwrap_or_else(|| {
				rooms_application::fields::Text::new("the line stands, but its files could not be completed".into())
					.expect("bounded upload failure")
			})
		});
	if failure.is_some() {
		discard(host, &uploads).await;
	}
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
