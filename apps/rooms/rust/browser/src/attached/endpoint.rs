//! Browser actions address either a held remote facet or the local session owner.
//! The endpoint selects transport; shared runtime owners execute local effects.
mod files;
mod grants;
mod history;
mod operations;
use super::{Platform, Result};
use rooms_application::session::{
	checkpoint::Checkpoint,
	snapshot::Snapshot,
	state::{OperationId, Outcome},
};
use rooms_glowcap::client::session::Session;
use rooms_runtime::session_service::{Local, LocalObservation as Observation};
use std::rc::Rc;

#[derive(Clone)]
pub(super) enum Endpoint {
	Remote(Session<Platform>),
	Local(Local<Platform>, Rc<Observation>),
}
impl From<Session<Platform>> for Endpoint {
	fn from(session: Session<Platform>) -> Self {
		Self::Remote(session)
	}
}
impl From<(Local<Platform>, Rc<Observation>)> for Endpoint {
	fn from((session, observation): (Local<Platform>, Rc<Observation>)) -> Self {
		Self::Local(session, observation)
	}
}
fn error(error: impl std::fmt::Display) -> String {
	error.to_string()
}
fn operation(id: &str) -> Result<OperationId> {
	OperationId::new(id.into()).ok_or_else(|| "Invalid Rooms operation identity".into())
}
impl Endpoint {
	pub async fn snapshot(&self) -> Result<Snapshot> {
		match self {
			Self::Remote(s) => s.snapshot().await.map_err(error),
			Self::Local(s, _) => s.snapshot().map_err(error),
		}
	}
	pub async fn command(&self, id: &str, base: u64, name: &str, arguments: &[String]) -> Result<u64> {
		match self {
			Self::Remote(s) => s.command(id, base, name, arguments).await.map_err(error),
			Self::Local(s, _) => {
				let args: Vec<_> = arguments.iter().cloned().map(glowcap::Argument::String).collect();
				let values: Vec<_> = args.iter().map(rooms_glowcap::Value).collect();
				let request = rooms_application::session::command::Request::new(
					rooms_application::grants::Access::Admin,
					id,
					base,
					name,
					&values,
				)
				.map_err(error)?;
				s.command(&request).map_err(error)?.wait().await.map_err(error)
			}
		}
	}
	pub async fn replace_checkpoint(&self, id: &str, base: u64, checkpoint: Checkpoint) -> Result<u64> {
		match self {
			Self::Remote(s) => s.replace_checkpoint(id, base, &checkpoint).await.map_err(error),
			Self::Local(s, _) => s
				.replace(operation(id)?, base, checkpoint)
				.map_err(error)?
				.wait()
				.await
				.map_err(error),
		}
	}
	pub async fn adopt_workspace(&self, id: &str, base: u64, checkpoint: Checkpoint) -> Result<u64> {
		match self {
			Self::Remote(s) => s.adopt_workspace(id, base, &checkpoint).await.map_err(error),
			Self::Local(s, _) => s
				.adopt(operation(id)?, base, checkpoint)
				.map_err(error)?
				.wait()
				.await
				.map_err(error),
		}
	}
	pub async fn resume_effect(&self, id: &str) -> Result<u64> {
		match self {
			Self::Remote(s) => s.resume_effect(id).await.map_err(error),
			Self::Local(s, _) => s.resume(operation(id)?).map_err(error)?.wait().await.map_err(error),
		}
	}
	pub async fn resolve_effect(&self, id: &str, committed: bool) -> Result<()> {
		match self {
			Self::Remote(s) => s.resolve_effect(id, committed).await.map_err(error),
			Self::Local(s, _) => s
				.resolve(
					operation(id)?,
					if committed {
						Outcome::Committed
					} else {
						Outcome::Abandoned
					},
				)
				.map_err(error)?
				.wait()
				.await
				.map(|_| ())
				.map_err(error),
		}
	}
	pub async fn typing(&self, conversation: &str, on: bool) -> Result<()> {
		match self {
			Self::Remote(s) => s.typing(conversation, on).await.map_err(error),
			Self::Local(s, observation) => s.typing(observation, conversation, on).map_err(error),
		}
	}
	pub async fn bridge_form(&self, conversation: &str) -> Result<Option<rooms_application::bridge::Form>> {
		match self {
			Self::Remote(s) => s.bridge_form(conversation).await.map_err(error),
			Self::Local(s, _) => s.bridge_form(conversation).await.map_err(error),
		}
	}
}
