//! File custody is explicit for a remote grant, local media, or retained archive.
//! All three feed the same bounded display and cancellation owner.
use super::{Platform, Result};
use rooms_application::files::FileDescription;
use rooms_glowcap::client::files::File;
use rooms_runtime::{media_files::FileView, session_service::ArchivedFile};

pub(crate) enum Access {
	Remote(File<Platform>),
	Local(FileView),
	Archived(ArchivedFile<Platform>),
}
impl Access {
	pub fn description(&self) -> Result<FileDescription> {
		match self {
			Self::Remote(file) => Ok(file.attachment().description.clone()),
			Self::Local(file) => Ok(file.description().clone()),
			Self::Archived(file) => file.description().live_description().map_err(|e| e.to_string()),
		}
	}
	pub async fn read(&self, offset: u64, maximum: usize) -> Result<Vec<u8>> {
		match self {
			Self::Remote(file) => file.read(offset, maximum).await.map_err(|e| e.to_string()),
			Self::Local(file) => file.read(offset, maximum).await,
			Self::Archived(file) => file.read(offset, maximum).await.map_err(|e| e.to_string()),
		}
	}
}
impl From<File<Platform>> for Access {
	fn from(file: File<Platform>) -> Self {
		Self::Remote(file)
	}
}
impl From<FileView> for Access {
	fn from(file: FileView) -> Self {
		Self::Local(file)
	}
}
impl From<ArchivedFile<Platform>> for Access {
	fn from(file: ArchivedFile<Platform>) -> Self {
		Self::Archived(file)
	}
}
