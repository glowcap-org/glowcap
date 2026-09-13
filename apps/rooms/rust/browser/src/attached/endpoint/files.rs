use super::*;
use rooms_glowcap::client::{
	session::{FileMessage, Refile},
	sources::{Source, Sources},
};
use rooms_runtime::rooms::FileCommand;
impl Endpoint {
	pub async fn archived_attachment(
		&self,
		record: &rooms_application::archive::Record,
		index: usize,
	) -> Result<super::super::files::Access> {
		match self {
			Self::Remote(s) => s
				.archived_attachment(record, index)
				.await
				.map(Into::into)
				.map_err(error),
			Self::Local(s, _) => s.archived_file(record.clone(), index).map(Into::into).map_err(error),
		}
	}
	pub async fn send_files(
		&self,
		pool: &Sources<Platform>,
		message: FileMessage<'_>,
		files: Vec<Source>,
	) -> Result<u64> {
		match self {
			Self::Remote(s) => s.send_files(pool, message, files).await.map_err(error),
			Self::Local(s, _) => s
				.files(
					operation(message.operation)?,
					message.base,
					message.conversation,
					FileCommand::Send {
						caption: message.caption.into(),
						previews: message.previews,
						files,
					},
				)
				.map_err(error)?
				.wait()
				.await
				.map_err(error),
		}
	}
	pub async fn refile(&self, pool: &Sources<Platform>, refile: Refile<'_>, files: Vec<Source>) -> Result<u64> {
		match self {
			Self::Remote(s) => s.refile(pool, refile, files).await.map_err(error),
			Self::Local(s, _) => s
				.files(
					operation(refile.message.operation)?,
					refile.message.base,
					refile.message.conversation,
					FileCommand::Refile {
						line: refile.line,
						caption: refile.message.caption.into(),
						keep: refile.keep.to_vec(),
						files,
					},
				)
				.map_err(error)?
				.wait()
				.await
				.map_err(error),
		}
	}
}
