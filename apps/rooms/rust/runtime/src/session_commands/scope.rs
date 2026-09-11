//! A runtime producer owns a scope; queued facts only observe its lifetime.
//! Retirement wakes the serializer even while a failed fact is backing off.
use tokio::sync::watch;

pub struct FactScope(watch::Sender<bool>);
pub(super) struct FactGuard(watch::Receiver<bool>);
impl Default for FactScope {
	fn default() -> Self {
		Self::new()
	}
}
impl FactScope {
	pub fn new() -> Self {
		let (sender, _) = watch::channel(true);
		Self(sender)
	}
	pub fn current(&self) -> bool {
		*self.0.borrow()
	}
	pub fn retire(&self) {
		if self.current() {
			self.0.send_replace(false);
		}
	}
	pub async fn retired(&self) {
		self.guard().retired().await;
	}
	pub(super) fn guard(&self) -> FactGuard {
		FactGuard(self.0.subscribe())
	}
}
impl Drop for FactScope {
	fn drop(&mut self) {
		self.retire();
	}
}
impl FactGuard {
	pub fn current(&self) -> bool {
		*self.0.borrow() && self.0.has_changed().is_ok()
	}
	pub async fn retired(&mut self) {
		while self.current() {
			if self.0.changed().await.is_err() {
				break;
			}
		}
	}
}
