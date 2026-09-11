//! Operator mutations observe their owners' completion before reporting counts.
//! The operations worker owns the batch even after its caller disconnects.
use super::{acts, irc, sources, Category, ResetScope, Shared, Value};
use glowcap::Argument;
use rooms_application::server::operations::operator::{inventory::Act, page, read_retire, rows};

struct Notices(Shared);
impl Notices {
	fn hold(shared: &Shared) -> Self {
		shared.borrow().operator.borrow_mut().hold();
		Self(shared.clone())
	}
}
impl Drop for Notices {
	fn drop(&mut self) {
		let state = self.0.borrow();
		let announce = state.operator.borrow_mut().release_hold();
		if let Some(revision) = announce {
			state.announce_revision(revision.0);
		}
	}
}
pub(super) fn retire_matching(shared: &Shared, caller: u64, values: &[Value<'_>]) -> Result<Argument, String> {
	let ask = read_retire(values)?;
	let state = shared.borrow();
	let shared = shared.clone();
	state.operations.later(&state, "operatorRetireMatching", move |store| {
		Box::pin(async move {
			let _notices = Notices::hold(&shared);
			let selected = page::query_batch(
				sources(&shared.borrow(), caller, ask.category, ask.kind)?.into_iter(),
				&ask.query,
				ask.limit,
			)
			.0;
			let pending: Vec<_> = selected
				.into_iter()
				.map(|act| acts::prepare(&shared, &store, caller, act))
				.collect();
			let mut retired = 0;
			let mut refused = String::new();
			for work in pending {
				match work.await {
					Ok(()) => retired += 1,
					Err(reason) if refused.is_empty() => refused = reason,
					Err(_) => {}
				}
			}
			let remaining = page::query_batch(
				sources(&shared.borrow(), caller, ask.category, ask.kind)?.into_iter(),
				&ask.query,
				0,
			)
			.1;
			Ok(Argument::List(vec![
				Argument::Integer(retired),
				Argument::Integer(remaining as i64),
				refused.into(),
			]))
		})
	})
}

pub(super) fn disconnect_session(shared: &Shared, caller: u64, id: String) -> Result<Argument, String> {
	let state = shared.borrow();
	let shared = shared.clone();
	state.operations.later(&state, "disconnectSession", move |store| {
		Box::pin(async move {
			acts::prepare(&shared, &store, caller, Act::Disconnect(id)).await?;
			Ok(Argument::Void)
		})
	})
}

pub(super) fn remove_room(shared: &Shared, caller: u64, id: String) -> Result<Argument, String> {
	let state = shared.borrow();
	let shared = shared.clone();
	state.operations.later(&state, "removeOperatorRoom", move |store| {
		Box::pin(async move {
			let act = if irc::operator::contains(&shared.borrow(), &id) {
				Act::RemoveIrc(id)
			} else {
				Act::RemoveRoom(id)
			};
			acts::prepare(&shared, &store, caller, act).await?;
			Ok(Argument::Void)
		})
	})
}
pub(super) fn release_reference(shared: &Shared, caller: u64, id: String) -> Result<Argument, String> {
	let state = shared.borrow();
	let shared = shared.clone();
	state
		.operations
		.later(&state, "releaseOperatorReference", move |store| {
			Box::pin(async move {
				let act = sources(&shared.borrow(), caller, Category::References, None)?
					.into_iter()
					.find_map(|source| match &source.row {
						rows::Row::Reference { id: held, .. } if *held == id => source.retire,
						_ => None,
					})
					.ok_or("that retained reference is no longer present")?;
				acts::prepare(&shared, &store, caller, act).await?;
				Ok(Argument::Void)
			})
		})
}

pub(super) fn reset(shared: &Shared, caller: u64, scope: ResetScope) -> Result<Argument, String> {
	let state = shared.borrow();
	let shared = shared.clone();
	state.operations.later(&state, "resetOperatorScope", move |store| {
		Box::pin(async move {
			let _notices = Notices::hold(&shared);
			let categories: &[Category] = match scope {
				ResetScope::Links => &[Category::Links],
				ResetScope::Registrations => &[Category::Registrations],
				ResetScope::Sessions => &[Category::Sessions],
				ResetScope::Rooms => &[Category::Rooms],
				ResetScope::Runtime | ResetScope::All => {
					&[Category::Rooms, Category::Registrations, Category::Sessions]
				}
			};
			let mut selected = Vec::new();
			for category in categories {
				selected.extend(
					sources(&shared.borrow(), caller, *category, None)?
						.into_iter()
						.filter(|source| !matches!(source.row, rows::Row::Session { you: true, .. }))
						.filter_map(|source| source.retire),
				);
			}
			if scope == ResetScope::All {
				// Durable retirement must finish while memberships can still
				// receive authority changes. Preparing room removals already
				// mutates their state, even before their futures are awaited.
				let retirement = acts::factory_reset(&shared.borrow());
				retirement.await?;
			}
			if matches!(scope, ResetScope::Runtime | ResetScope::All) {
				shared.borrow().journal.borrow_mut().clear();
			}
			let pending: Vec<_> = selected
				.into_iter()
				.map(|act| acts::prepare(&shared, &store, caller, act))
				.collect();
			let mut failed = None;
			for work in pending {
				if let Err(reason) = work.await {
					failed.get_or_insert(reason);
				}
			}
			shared.borrow().changed();
			match failed {
				Some(reason) => Err(reason),
				None => Ok(Argument::Void),
			}
		})
	})
}
