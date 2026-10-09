//! One effect owner keeps form observation, credential write and submission.
use super::credentials::Credentials;
use crate::session::managed::results::{Prepared, Settlement};
use glowcap::{
	Argument, Result,
	loam::{self, Continuation, EffectExecution, EffectResult},
};
use rooms_application::{
	bridge::{self, Answers},
	content::session::bridge::Request,
	fields::SafeInteger,
	session::effect::Reply,
};
use std::{future::Future, pin::Pin, rc::Rc};

pub(in crate::session::managed) struct Intent {
	pub request: Request,
	pub id: SafeInteger,
	pub secrets: Answers,
	pub credentials: Rc<Credentials>,
}
type Storage = Pin<Box<dyn Future<Output = Result<Answers>>>>;
enum Phase {
	Inspect,
	Store(Storage),
	Submit,
	Finished,
}

/// A bounded worker owns one form request and one submit observation. Storage
/// owns its full future, lock and journal through interruption. Public answers
/// and secrets are combined only for target dispatch, never for receipt storage.
pub(in crate::session::managed) struct Pipeline {
	continuation: Continuation,
	intent: Intent,
	reply_bytes: usize,
	phase: Phase,
	pending: Option<EffectExecution>,
	answers: Option<Answers>,
}
impl Pipeline {
	pub fn new(continuation: Continuation, intent: Intent, reply_bytes: usize) -> Self {
		Self {
			continuation,
			intent,
			reply_bytes,
			phase: Phase::Inspect,
			pending: None,
			answers: None,
		}
	}
	async fn perform(&mut self, verb: &str, args: &[Argument]) -> Result<EffectResult> {
		if self.pending.is_none() {
			match self.continuation.execute(0, verb, args, self.reply_bytes) {
				Ok(execution) => self.pending = Some(execution),
				Err(error) => return Ok(EffectResult::Unsent(error)),
			}
		}
		let result = self
			.pending
			.as_mut()
			.expect("owned bridge observation")
			.completed()
			.await?;
		if !matches!(result, EffectResult::Unknown(_)) {
			self.pending = None;
		}
		Ok(result)
	}
	pub async fn advance(&mut self) -> Result<Option<Settlement>> {
		loop {
			match &mut self.phase {
				Phase::Inspect => {
					let result = self.perform(bridge::ASK, &[]).await?;
					let exact = match result {
						EffectResult::Ready(value) => {
							bridge::read_form(&rooms_glowcap::Value(&value)).ok().flatten().as_ref()
								== Some(&self.intent.request.bridge.declaration)
						}
						_ => false,
					};
					if !exact {
						self.phase = Phase::Finished;
						return Ok(Some(Settlement::absent()));
					}
					let credentials = self.intent.credentials.clone();
					let id = self.intent.id;
					let nonce = self.intent.request.credentials.clone();
					let reapply = self.intent.request.reapply.is_some();
					let secrets = core::mem::take(&mut self.intent.secrets);
					self.phase = Phase::Store(Box::pin(async move {
						if reapply {
							match nonce {
								Some(nonce) => credentials.answers(id, &nonce).await,
								None => Ok(Answers::default()),
							}
						} else {
							if secrets.is_empty() {
								return Ok(secrets);
							}
							credentials.stage(id, nonce, secrets.clone()).await?;
							Ok(secrets)
						}
					}));
				}
				Phase::Store(pending) => {
					let result = pending.await;
					self.phase = Phase::Finished;
					let secrets = result?;
					let mut answers = self.intent.request.bridge.answers.clone();
					for (id, value) in secrets.iter() {
						answers
							.insert(id.into(), value.clone())
							.map_err(|_| loam::refusal("combined bridge answers exceed their bound"))?;
					}
					self.answers = Some(answers);
					self.phase = Phase::Submit;
				}
				Phase::Submit => {
					let args = [
						self.intent.request.bridge.action.as_str().into(),
						self.answers
							.as_ref()
							.expect("private target answers")
							.encode()
							.map_err(|_| loam::refusal("invalid bridge target answers"))?
							.into(),
					];
					let result = self.perform(bridge::SUBMIT, &args).await?;
					self.answers.take();
					self.phase = Phase::Finished;
					return match result {
						EffectResult::Ready(value) => match Prepared::read(Reply::Acknowledgment, &value, "")? {
							Prepared::Complete(outcome) => Ok(Some(outcome)),
							_ => unreachable!("acknowledgment has no acquisition"),
						},
						EffectResult::Unsent(_) => Ok(Some(Settlement::absent())),
						EffectResult::Unknown(error) => Err(error),
						EffectResult::Pending => unreachable!("completed bridge observation"),
					};
				}
				Phase::Finished => return Ok(None),
			}
		}
	}
}
