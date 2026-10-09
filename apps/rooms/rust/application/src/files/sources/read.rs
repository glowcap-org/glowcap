//! Source readers enforce file length and chunk-order contracts.
use super::*;
/// One active read pins its original source, even if another message expires
/// the blob. Finish or drop before its file's budget can be reused.
pub struct Read<S> {
	source: Rc<S>,
	slot: Rc<Slot<S>>,
	reads: Rc<Cell<usize>>,
	range: Range<usize>,
}
impl<S> Blob<S> {
	pub fn read_call<A: FileArgument>(&self, verb: &str, args: &[A]) -> Result<Option<Read<S>>, Error> {
		let [offset, length] = args else {
			return Err(Error::Arguments);
		};
		if verb != crate::protocol_data::READ {
			return Err(Error::Arguments);
		}
		self.read(
			offset.natural().ok_or(Error::Arguments)?,
			length.natural().ok_or(Error::Arguments)?,
		)
	}
	pub fn read(&self, offset: u64, maximum: u64) -> Result<Option<Read<S>>, Error> {
		if maximum == 0 {
			return Err(Error::Arguments);
		}
		let size = self.description().size();
		let start = offset.min(size as u64) as usize;
		let length = maximum.min(CHUNK_BYTES as u64).min((size - start) as u64) as usize;
		// EOF survives expiration and does not consume a read or source slot.
		if length == 0 {
			return Ok(None);
		}
		let source = self.slot.source.borrow().as_ref().cloned().ok_or(Error::Expired)?;
		if self.reads.get() >= MAX_READS {
			return Err(Error::Reads);
		}
		self.reads.set(self.reads.get() + 1);
		self.slot.reads.set(self.slot.reads.get() + 1);
		Ok(Some(Read {
			source,
			slot: self.slot.clone(),
			reads: self.reads.clone(),
			range: start..start + length,
		}))
	}
}
impl<S> Read<S> {
	pub fn source(&self) -> &S {
		&self.source
	}
	pub fn range(&self) -> Range<usize> {
		self.range.clone()
	}
	pub fn finish(self, length: usize) -> Result<(), Error> {
		if length != self.range.len() {
			return Err(Error::Reply);
		}
		if self.range.start <= self.slot.prefix.get() {
			self.slot.prefix.set(self.slot.prefix.get().max(self.range.end));
		}
		if !self.slot.repeatable && self.slot.prefix.get() == self.slot.description.size() {
			self.slot.source.borrow_mut().take();
		}
		Ok(())
	}
}
impl<S> Drop for Read<S> {
	fn drop(&mut self) {
		self.slot.reads.set(self.slot.reads.get() - 1);
		self.reads.set(self.reads.get() - 1);
	}
}
