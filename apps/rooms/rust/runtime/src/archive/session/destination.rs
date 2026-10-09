//! Recording target restoration belongs to the archive worker, after delivery.
use std::{future::Future, pin::Pin, rc::Rc};

/// An admitted recording keeps its exact target; later selection cannot
/// redirect it. A deferred target restores held authority inside the existing
/// archive worker, so an unavailable archive cannot block message delivery.
#[derive(Clone)]
pub enum Destination {
	Device,
	Held(glowcap::Ref),
	Restoring(Rc<dyn Restore>),
}

/// The embedding owns exact selection and its restoration authority. The
/// archive admits its retained bytes under MAX_BYTES and resolves it once
/// before capture or storage; it never substitutes its current selection.
pub trait Restore {
	fn retained_bytes(&self) -> usize;
	fn reference(&self) -> Pin<Box<dyn Future<Output = glowcap::Result<glowcap::Ref>> + '_>>;
}
impl Destination {
	pub(super) fn retained_bytes(&self) -> usize {
		match self {
			Self::Restoring(target) => target.retained_bytes(),
			Self::Device | Self::Held(_) => 0,
		}
	}
}
