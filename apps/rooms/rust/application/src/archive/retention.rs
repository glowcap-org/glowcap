//! A disabled committed checkpoint is the durable erase intent. Adapters settle
//! the resulting barrier before another checkpoint can re-enable recording.
#[derive(Debug)]
pub struct Retention {
	keep: bool,
	erase: bool,
}
impl Retention {
	/// Restoring disabled history requires cleanup before archive readiness.
	pub fn restore(keep: bool) -> Self {
		Self { keep, erase: !keep }
	}
	pub fn disables(&self, keep: bool) -> bool {
		self.keep && !keep
	}
	pub fn observe(&mut self, keep: bool) {
		self.erase |= self.keep && !keep;
		self.keep = keep;
	}
	pub fn requires_erasure(&self) -> bool {
		self.erase
	}
	/// Only a successful local erase acknowledges the outstanding intent.
	pub fn erased(&mut self) {
		self.erase = false;
	}
}
