//! One prepared command owns canonical upload intent and exact sender leases
//! through admission, interruption and result acquisition. No source refetch.
use super::super::{
	Tasks,
	sources::{Source, Sources},
};
use super::*;
use rooms_application::content::session::uploads::{Description, Intent, Kind};
impl<D: Deadline + Tasks + Clone + 'static> Workspace<D> {
	pub async fn prepare_upload(
		&self,
		intent: &Intent,
		pool: &Sources<D>,
		sources: Vec<Source>,
	) -> Result<Command<D>, Error> {
		let canonical = intent.canonical().map_err(|e| loam::refusal(e.to_string()))?;
		if intent.files.as_slice().len() != sources.len()
			|| intent
				.files
				.as_slice()
				.iter()
				.zip(&sources)
				.any(|(description, source)| *description != Description::from_file(source.description()))
		{
			return Err(loam::refusal("upload sources differ from the original descriptions").into());
		}
		let host = match &self.caller {
			Caller::Remote(client) => client.session().host(),
			Caller::Local { host, .. } => host.clone(),
		};
		let sources = pool.lend_repeatable_local(&host, sources)?;
		let method = match intent.upload {
			Kind::Post => "sendFiles",
			Kind::Refile(_) => "refileLine",
		};
		let mut arguments = Vec::with_capacity(
			5 + intent.keep.as_slice().len()
				+ intent.files.as_slice().len() * rooms_application::room::attachment::RECORD_SPAN,
		);
		arguments.extend([
			intent.operation.clone().into(),
			(intent.base as i64).into(),
			intent.conversation.clone().into(),
		]);
		match intent.upload {
			Kind::Post => arguments.extend([intent.caption.clone().into(), intent.previews.clone().into()]),
			Kind::Refile(line) => {
				arguments.extend([(line as i64).into(), intent.caption.clone().into()]);
				arguments.extend(intent.keep.as_slice().iter().map(|index| i64::from(*index).into()));
			}
		}
		sources.append_to(&mut arguments);
		Ok(Command {
			caller: self.caller.clone(),
			source: self.reference.clone(),
			method,
			operation: intent.operation.clone(),
			canonical,
			arguments,
			_sources: Some(sources),
		})
	}
}
