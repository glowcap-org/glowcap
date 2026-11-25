//! Whose receipt an operation is, and which of this access's own receipts
//! still keep a place, asked through one access without sending anything. The
//! session keeps a receipt under the access that sent it, so the answers tell
//! whether this access is the one that did.
use super::{Error, View};
use rooms_glowcap::client::{Deadline, Tasks, workspace::Holder};

impl<D: Deadline + Tasks + Clone + 'static> View<D> {
	/// Whose receipt `operation` is. This is a read: it never submits a
	/// command or changes a receipt.
	pub async fn holder(&self, operation: &str) -> Result<Holder, Error> {
		match self.workspace.effect_holder(operation).await {
			Ok(holder) => Ok(holder),
			Err(error) => Err(self.failure(error).await),
		}
	}
	/// The operations of this access's own receipts that still keep a place
	/// in the session. This is a read: it never submits a command or changes
	/// a receipt.
	pub async fn held(&self) -> Result<Vec<String>, Error> {
		match self.workspace.held_effects().await {
			Ok(held) => Ok(held),
			Err(error) => Err(self.failure(error).await),
		}
	}
}
