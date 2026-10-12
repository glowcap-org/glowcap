//! Direct delivery lends exact sources through restricted shared read scopes.
use super::super::results::{Prepared, Settlement};
use super::*;
use glowcap::loam::{Continuation, EffectExecution, EffectResult, ReadInterface, ReadMethod};
use rooms_application::session::effect::Reply;

pub(in crate::session::managed) struct Pipeline {
	continuation: Continuation,
	intent: Intent,
	reply_bytes: usize,
	pending: Option<EffectExecution>,
	finished: bool,
}
impl Pipeline {
	pub fn new(continuation: Continuation, intent: Intent, reply_bytes: usize) -> Self {
		Self {
			continuation,
			intent,
			reply_bytes,
			pending: None,
			finished: false,
		}
	}
	fn start(&self) -> Result<EffectExecution> {
		let intent = &self.intent;
		let mut args = Vec::with_capacity(
			1 + intent.keep.as_slice().len()
				+ intent.files.as_slice().len() * attachment::RECORD_SPAN
				+ rooms_application::open_graph::WIRE_FIELDS,
		);
		args.push(intent.caption.clone().into());
		args.extend(
			intent
				.keep
				.as_slice()
				.iter()
				.map(|index| Argument::Integer((*index).into())),
		);
		let methods = [ReadMethod {
			verb: rooms_application::protocol_data::READ,
			results: &[],
		}];
		let interfaces = [ReadInterface { methods: &methods }];
		for (index, description) in intent.files.as_slice().iter().enumerate() {
			let file = description.file().map_err(|error| refuse(&error.to_string()))?;
			let reader = self
				.continuation
				.project_reads_copying(intent.target_count() + index, &interfaces, 0)?;
			let (width, height) = file.dimensions();
			args.extend([
				"file".into(),
				file.name().into(),
				file.mime().into(),
				Argument::Integer(file.size() as i64),
				reader.into(),
				Argument::Integer(width.into()),
				Argument::Integer(height.into()),
			]);
		}
		let (index, verb) = match intent.upload {
			Kind::Post => {
				let previews = rooms_application::open_graph::Selection::decode(&intent.caption, &intent.previews)
					.map_err(|_| refuse("invalid direct previews"))?;
				if !previews.is_empty() {
					args.extend([
						rooms_application::open_graph::WIRE_TAG.into(),
						intent.previews.clone().into(),
					]);
				}
				(0, rooms_application::direct::DM)
			}
			Kind::Refile(_) => (1, rooms_application::protocol_data::REFILE),
		};
		self.continuation.execute(index, verb, &args, self.reply_bytes)
	}
	pub async fn advance(&mut self) -> Result<Option<Settlement>> {
		if self.finished {
			return Ok(None);
		}
		if self.pending.is_none() {
			match self.start() {
				Ok(execution) => self.pending = Some(execution),
				Err(error) => {
					self.finished = true;
					return Ok(Some(Settlement::refused(&error)));
				}
			}
		}
		let outcome = self
			.pending
			.as_mut()
			.ok_or_else(|| refuse("direct upload execution is not retained"))?
			.completed()
			.await?;
		self.pending = None;
		self.finished = true;
		match outcome {
			EffectResult::Ready(value) => {
				let reply = if self.intent.upload == Kind::Post {
					Reply::Line
				} else {
					Reply::Acknowledgment
				};
				let Ok(Prepared::Complete(settlement)) = Prepared::read(reply, &value, "") else {
					return Ok(None);
				};
				complete(settlement, reply, None).map(Some)
			}
			EffectResult::Unsent(error) => Ok(Some(Settlement::refused(&error))),
			EffectResult::Unknown(error) if rooms_glowcap::client::binding_admission_refusal(&error).is_some() => {
				Ok(Some(Settlement::refused(&error)))
			}
			_ => Ok(None),
		}
	}
}
