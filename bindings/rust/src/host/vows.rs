//! Binding-side vow observation and bounded late-outcome retention.

use super::*;

pub(super) struct VowTable {
	rows: RefCell<HashMap<u64, VowRow>>,
	/// FIFO of settled-but-unobserved vow ids, for the eviction cap.
	unobserved: RefCell<VecDeque<u64>>,
	/// Exact terminal projection failure for late observers after teardown has
	/// cleared per-vow rows. Protocol authority remains in the native Host or
	/// driver loop; this only preserves the binding-side observation cause.
	terminal_failure: RefCell<Option<Error>>,
}

impl VowTable {
	pub(super) fn new() -> Self {
		Self {
			rows: RefCell::new(HashMap::new()),
			unobserved: RefCell::new(VecDeque::new()),
			terminal_failure: RefCell::new(None),
		}
	}

	fn insert(&self, vow: u64, row: VowRow) {
		self.rows.borrow_mut().insert(vow, row);
	}

	fn begin_await(&self, vow: u64) -> Waiting {
		let mut rows = self.rows.borrow_mut();
		match rows.get_mut(&vow) {
			// Evicted (never awaited until past the cap) or never minted here.
			None => Waiting::Now(Err(self.terminal_failure.borrow().clone().unwrap_or_else(|| {
				Error::with_detail(
					sys::ERR_CLOSED,
					"the vow's outcome is gone (unobserved past the cap)".to_string(),
				)
			}))),
			Some(row) => match std::mem::replace(&mut row.state, VowState::Minted) {
				VowState::Settled(outcome) => {
					rows.remove(&vow);
					Waiting::Now(outcome)
				}
				// Minted, or re-awaited: (re)park a waiter. A prior
				// `Awaited`'s sender is dropped here, breaking that stale
				// receiver — the same overwrite the two-field form performed.
				VowState::Minted | VowState::Awaited(_) => {
					let (tx, rx) = oneshot::channel();
					row.state = VowState::Awaited(tx);
					Waiting::Settled(rx)
				}
			},
		}
	}

	fn settle(&self, vow: u64, mut outcome: Result<Argument>) {
		{
			let mut rows = self.rows.borrow_mut();
			let Some(row) = rows.get_mut(&vow) else {
				return; // an outcome nobody registered for
			};
			if let (Ok(value), Some(session)) = (&mut outcome, row.gc_session.as_ref().and_then(std::rc::Weak::upgrade))
			{
				crate::gc::track_argument(&session, value);
			}
			match std::mem::replace(&mut row.state, VowState::Minted) {
				VowState::Awaited(waiter) => {
					rows.remove(&vow);
					drop(rows);
					// Send failure proves the awaiting future was cancelled. The vow
					// row is terminal and removed, and no native handle belongs to this
					// binding-side delivery.
					drop(waiter.send(outcome));
					return;
				}
				// Minted, or an already-settled row re-settled: hold the
				// outcome for a late observation.
				VowState::Minted | VowState::Settled(_) => {
					row.state = VowState::Settled(outcome);
				}
			}
		}
		let mut unobserved = self.unobserved.borrow_mut();
		unobserved.push_back(vow);
		while unobserved.len() > MAX_UNOBSERVED_OUTCOMES {
			let Some(oldest) = unobserved.pop_front() else {
				break;
			};
			let mut rows = self.rows.borrow_mut();
			// Only evict a row still parked unobserved; an observed one is gone.
			let evict = matches!(
				rows.get(&oldest),
				Some(stale) if matches!(stale.state, VowState::Settled(_))
			);
			if evict {
				rows.remove(&oldest);
			}
		}
	}

	fn fail_pending(&self, code: i32, detail: &str) {
		let failure = Error::with_detail(code, detail.to_string());
		let mut terminal = self.terminal_failure.borrow_mut();
		if terminal.is_none() {
			*terminal = Some(failure.clone());
		}
		drop(terminal);
		let vows: Vec<u64> = self.rows.borrow().keys().copied().collect();
		for vow in vows {
			self.settle(vow, Err(failure.clone()));
		}
	}

	pub(super) fn only_settled(&self) -> bool {
		self.rows
			.borrow()
			.values()
			.all(|row| matches!(row.state, VowState::Settled(_)))
	}

	pub(super) fn clear(&self) {
		self.rows.borrow_mut().clear();
		self.unobserved.borrow_mut().clear();
	}
}

enum Waiting {
	Now(Result<Argument>),
	Settled(oneshot::Receiver<Result<Argument>>),
}

// A host vow's pending state: exactly three shapes, so the illegal "settled AND
// a live waiter" combination cannot be represented. Minted the instant the vow
// is registered (the mint IS the registration); an outcome that lands before
// anyone awaits is held as `Settled` for a late observation instead of hanging;
// a waiter lives only in `Awaited`, so an unobserved broken answer never strands
// a channel.
enum VowState {
	/// Registered, not yet awaited and not yet settled.
	Minted,
	/// A caller is awaiting; the outcome fires this sender.
	Awaited(oneshot::Sender<Result<Argument>>),
	/// The outcome landed before anyone awaited; held for a late observation.
	Settled(Result<Argument>),
}

struct VowRow {
	state: VowState,
	/// Session whose opt-in owns finalizer policy for this application-facing
	/// outcome. Weak: a late settlement cannot keep a closed Session alive.
	gc_session: Option<std::rc::Weak<SessionShared>>,
}

impl HostShared {
	// ── The vow table ──────────────────────────────────────────────────────────

	/// Record a freshly minted vow so the drain can route its completion. Must
	/// run in the same synchronous block as the minting FFI call, so no drain
	/// can pop the completion first.
	pub(crate) fn vow_minted(&self, vow: u64, gc_session: Option<&Rc<SessionShared>>) {
		// Finalizer policy belongs to the operation that exposes the value, so
		// sample the opt-in at mint rather than letting a later toggle rewrite
		// an already-admitted outcome's ownership contract.
		let gc_session = gc_session.filter(|session| session.gc.get()).map(Rc::downgrade);
		self.vows.insert(
			vow,
			VowRow {
				state: VowState::Minted,
				gc_session,
			},
		);
	}

	/// The vow's eventual outcome: the fulfilled wire value, or a typed
	/// rejection — `ErrorKind::Broken` for a partner break, `ErrorKind::Closed`
	/// when the settle was the disconnect's own break. Settles immediately
	/// from the recorded state when the outcome already landed.
	pub(crate) fn await_vow(self: &Rc<HostShared>, vow: u64) -> impl std::future::Future<Output = Result<Argument>> {
		let waiting = self.vows.begin_await(vow);
		// The future holds the host alive so a parked waiter cannot outlive the
		// vow table it is registered in.
		let host = Rc::clone(self);
		async move {
			let _hold = host;
			match waiting {
				Waiting::Now(outcome) => outcome,
				Waiting::Settled(rx) => rx.await.unwrap_or_else(|_| {
					Err(Error::with_detail(
						sys::ERR_CLOSED,
						"the host was released with the vow still pending".to_string(),
					))
				}),
			}
		}
	}

	// The drain's settle arms: fire the waiter, or record the outcome for a
	// late observation (bounded FIFO — an outcome nobody ever awaits is evicted
	// at the cap). Called from `action::run`'s SETTLE / FAIL arms.
	pub(crate) fn settle_vow(&self, vow: u64, outcome: Result<Argument>) {
		self.vows.settle(vow, outcome);
	}

	/// Settle every binding-side waiter after the loop itself has failed before
	/// it could project C ABI FAIL events. The core Host remains the semantic
	/// authority; this only prevents its wrapper promises from parking forever
	/// when the projection path is what died.
	pub(crate) fn fail_pending_vows(&self, code: i32, detail: &str) {
		self.vows.fail_pending(code, detail);
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	fn row() -> VowRow {
		VowRow {
			state: VowState::Minted,
			gc_session: None,
		}
	}

	fn err(code: i32, detail: impl Into<String>) -> Result<Argument> {
		Err(Error::with_detail(code, detail.into()))
	}

	fn now(table: &VowTable, vow: u64) -> Result<Argument> {
		match table.begin_await(vow) {
			Waiting::Now(outcome) => outcome,
			Waiting::Settled(_) => panic!("vow parked instead of settling immediately"),
		}
	}

	#[test]
	fn unobserved_outcomes_evict_the_oldest_at_the_cap() {
		let table = VowTable::new();
		for vow in 0..=(MAX_UNOBSERVED_OUTCOMES as u64) {
			table.insert(vow, row());
			table.settle(vow, err(sys::ERR_BROKEN, format!("break {vow}")));
		}

		assert_eq!(now(&table, 0).unwrap_err().code(), sys::ERR_CLOSED);
		assert_eq!(now(&table, 1).unwrap_err().code(), sys::ERR_BROKEN);
	}

	#[test]
	fn pending_waiter_receives_terminal_failure_and_table_becomes_settled() {
		let table = VowTable::new();
		table.insert(7, row());
		let mut receiver = match table.begin_await(7) {
			Waiting::Settled(receiver) => receiver,
			Waiting::Now(_) => panic!("fresh vow settled before an outcome"),
		};

		table.fail_pending(sys::ERR_INTERNAL, "driver loop failed");

		let outcome = receiver.try_recv().expect("pending waiter should fire");
		assert_eq!(outcome.unwrap_err().code(), sys::ERR_INTERNAL);
		assert!(table.only_settled());
	}

	#[test]
	fn clear_retains_terminal_failure_for_late_observers() {
		let table = VowTable::new();
		table.insert(9, row());
		table.fail_pending(sys::ERR_INTERNAL, "driver loop failed");
		assert!(table.only_settled());

		table.clear();

		assert_eq!(now(&table, 9).unwrap_err().code(), sys::ERR_INTERNAL);
	}

	#[test]
	fn clear_without_terminal_failure_reports_missing_outcome() {
		let table = VowTable::new();
		table.insert(11, row());
		table.settle(11, Ok(Argument::Void));
		assert!(table.only_settled());

		table.clear();

		assert_eq!(now(&table, 11).unwrap_err().code(), sys::ERR_CLOSED);
	}
}
