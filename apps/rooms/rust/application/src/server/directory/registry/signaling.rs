//! Filing signaling replaces only the inbox owned by the current registration.
use super::*;

impl<C: Copy + Ord, R: Clone> Registry<C, R> {
	pub fn offer_signaling(&mut self, connection: C, inbox: R) -> Result<Option<super::super::Release<C, R>>, Refusal> {
		let Some(key) = self.by_connection.get(&connection).cloned() else {
			return Err(Refusal::coded(
				FailureCode::NotRegistered,
				"offerSignaling needs a registered name",
			));
		};
		let row = self.rows.get_mut(&key).expect("a registered connection has its row");
		Ok(row
			.signaling
			.replace(inbox)
			.map(|capability| super::super::Release { connection, capability }))
	}
}
