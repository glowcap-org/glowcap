//! Scoped reconciliation of membership observations into committed intent.
use super::*;

impl<P: Platform> RoomWorker<P> {
	pub(super) async fn commit(
		&self,
		id: &str,
		epoch: u64,
		make: impl FnOnce(RoomContext) -> Result<Fact, String>,
	) -> Result<(), String> {
		let (before, scope) = {
			let state = self.shared.borrow();
			let Some(live) = state.rooms.get(id).filter(|live| live.epoch == epoch) else {
				return Ok(());
			};
			(live.intent.clone(), live.scope.clone())
		};
		if let Some(expected) = self.commit_observation(&before, &scope, make).await? {
			if let Some(live) = self
				.shared
				.borrow_mut()
				.rooms
				.get_mut(id)
				.filter(|live| live.epoch == epoch)
			{
				live.intent = expected;
			}
		}
		Ok(())
	}
	pub(super) async fn commit_observation(
		&self,
		before: &intent::Intent,
		scope: &crate::session_commands::FactScope,
		make: impl FnOnce(RoomContext) -> Result<Fact, String>,
	) -> Result<Option<intent::Intent>, String> {
		let id = before.id.as_str();
		if !scope.current() {
			return Ok(None);
		}
		let prepared = self
			.commands
			.view()
			.read(|state| {
				let checkpoint = state.checkpoint().map_err(|e| e.to_string())?;
				let Some(intent) = checkpoint.rooms().find(|intent| intent.id.text().as_str() == Some(id)) else {
					return Ok(None);
				};
				if intent::Intent::read(intent).as_ref() != Some(before) {
					return Ok(None);
				}
				let fact = make(RoomContext::capture(intent))?;
				let next = fact
					.apply(checkpoint, &rooms_glowcap::routes::CheckpointRoutes)
					.map_err(|e| e.to_string())?;
				let expected = next
					.as_ref()
					.unwrap_or(checkpoint)
					.rooms()
					.find(|intent| intent.id.text().as_str() == Some(id))
					.and_then(intent::Intent::read);
				Ok::<_, String>(Some((fact, expected)))
			})
			.map_err(|e| e.to_string())??;
		let Some((fact, expected)) = prepared else {
			return Ok(None);
		};
		let reply = self
			.commands
			.prepare_scoped_fact(fact, scope)
			.map_err(|e| e.to_string())?
			.send()
			.map_err(|e| e.to_string())?;
		let mut changes = self.directories.changes();
		changes.mark_unchanged();
		let mut stopping = self.stopping.clone();
		let wait = reply.wait();
		tokio::pin!(wait);
		loop {
			if *stopping.borrow() {
				scope.retire();
				return Ok(None);
			}
			let current = self.wanted()?.remove(id).map(|wanted| wanted.intent);
			if current.as_ref() != Some(before) && current != expected {
				scope.retire();
				return Ok(None);
			}
			tokio::select! {
				result = &mut wait => {
					result?;
					let current = self.wanted()?.remove(id).map(|wanted| wanted.intent);
					return Ok(if current == expected { expected } else { None });
				}
				_ = changes.changed() => {}
				_ = stopping.changed() => { scope.retire(); return Ok(None); }
			}
		}
	}
}
