use super::*;
use crate::files::media_files::FileView;
use rooms_application::files::FileDescription;
pub(super) enum Sources<P: Platform> {
	Live(Vec<File<P>>),
	Views(Vec<FileView>),
}
impl<P: Platform> Sources<P> {
	pub fn len(&self) -> usize {
		match self {
			Self::Live(v) => v.len(),
			Self::Views(v) => v.len(),
		}
	}
	pub fn is_empty(&self) -> bool {
		self.len() == 0
	}
	pub fn descriptions(&self) -> impl ExactSizeIterator<Item = &FileDescription> {
		(0..self.len()).map(|i| match self {
			Self::Live(v) => &v[i].attachment().description,
			Self::Views(v) => v[i].description(),
		})
	}
	pub fn budget(&self, record: &Record) -> Result<(usize, usize), Error> {
		if let Self::Live(v) = self {
			return input_budget(record, v);
		}
		let Self::Views(v) = self else { unreachable!() };
		let bytes = v.iter().fold(
			record
				.retained_bytes()
				.saturating_add(v.capacity() * core::mem::size_of::<FileView>()),
			|bytes, file| bytes.saturating_add(file.description().retained_bytes()),
		);
		let files = v
			.iter()
			.try_fold(0usize, |sum, file| sum.checked_add(file.description().size()))
			.ok_or_else(|| Error::invalid("archive file budget overflow"))?;
		Ok((bytes, files))
	}
}
