//! Terminal room retirement versus recoverable membership loss.
use super::*;

impl<P: Platform> RoomWorker<P> {
	pub(super) async fn retired(&mut self, id: String, epoch: u64, reason: String, terminal: bool) {
		let retired = {
			let mut state = self.shared.borrow_mut();
			match state.rooms.get(&id) {
				Some(live) if live.epoch == epoch => state.rooms.remove(&id),
				_ => None,
			}
		};
		if let Some(live) = retired {
			let subject = format!("room:{}:{}", live.directory, id);
			if terminal {
				self.shared
					.borrow_mut()
					.terminal
					.insert(id.clone(), live.intent.clone());
			}
			self.retire_live(live).await;
			self.shared.borrow_mut().issues.insert(subject, reason);
			self.changed.send_replace(());
			if !terminal {
				self.schedule_retry();
			}
		}
	}
}
