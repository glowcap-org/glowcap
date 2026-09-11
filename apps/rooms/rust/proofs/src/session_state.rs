use super::grants::ready;
use rooms_application::{
	documents::{SessionDocument, WriteFailure},
	grants::Access,
	session::{
		checkpoint::{Checkpoint, Routes},
		state::*,
	},
	text::DocumentText,
};
use serde_json::Value;
use std::collections::BTreeMap;
struct NoRoutes;
impl Routes for NoRoutes {
	fn locator_authority(&self, _: &str) -> Option<String> {
		None
	}
	fn sturdyref_authority(&self, _: &str) -> Option<String> {
		None
	}
}
struct Store {
	checkpoint: Vec<u8>,
	effects: Vec<u8>,
	frames: Vec<(SessionDocument, Vec<u8>)>,
}
impl Store {
	fn new(state: &SessionState) -> Self {
		Self {
			checkpoint: state.document(SessionDocument::Checkpoint).unwrap(),
			effects: state.document(SessionDocument::Effects).unwrap(),
			frames: vec![],
		}
	}
	fn restore(&self) -> SessionState {
		SessionState::restore(&self.checkpoint, &self.effects, &NoRoutes).unwrap()
	}
}
impl SessionStorage for Store {
	type Error = &'static str;
	async fn replace(&mut self, kind: SessionDocument, bytes: Vec<u8>) -> Result<(), WriteFailure<Self::Error>> {
		self.frames.push((kind, bytes.clone()));
		match kind {
			SessionDocument::Checkpoint => self.checkpoint = bytes,
			SessionDocument::Effects => self.effects = bytes,
			_ => panic!("unexpected document"),
		};
		Ok(())
	}
}
fn fresh() -> SessionState {
	SessionState::fresh([1; 32], [2; 16])
}
fn text<const N: usize>(s: &str) -> Text<N, true> {
	Text::new(s.into()).unwrap()
}
fn write(state: &mut SessionState, store: &mut Store, prepared: Prepared) -> Change {
	ready(prepared.persist(store)).unwrap().commit(state).unwrap()
}
fn admitted(state: &mut SessionState, store: &mut Store, value: Admission) {
	if let Admission::Write(v) = value {
		write(state, store, v);
	}
}
fn checkpoint(standing: &DocumentText) -> Checkpoint {
	let mut state: Value = serde_json::from_str(&Checkpoint::empty().encode_for(Access::Admin).unwrap()).unwrap();
	state["standing"] = Value::Null;
	let encoded = state.to_string().replace(
		"\"standing\":null",
		&format!("\"standing\":{}", serde_json::to_string(standing).unwrap()),
	);
	Checkpoint::decode(&encoded, &NoRoutes).unwrap()
}
fn apply_result(_: &Checkpoint, _: &ResultKind, _: &ResultText, result: &ResultText) -> Result<Checkpoint, Error> {
	Ok(checkpoint(result.text()))
}
fn advance(state: &mut SessionState, store: &mut Store, id: &OperationId) {
	while let ResultProgress::Write(v) = state.advance_result(id, apply_result).unwrap() {
		write(state, store, v);
	}
}
pub fn run() {
	command_preflight();
	schemas_and_trace();
	transaction_boundaries();
	result_recovery();
	reconciliation_closes_adoption_only_for_a_changed_checkpoint();
}
fn reconciliation_closes_adoption_only_for_a_changed_checkpoint() {
	use rooms_application::session::snapshot::views::Adoption;
	let mut state = fresh();
	let mut store = Store::new(&state);
	assert!(state
		.reconcile(Impact::Presentation, |_| Ok(Some(Checkpoint::empty())))
		.unwrap()
		.is_none());
	assert_eq!(state.workspace_adoption().unwrap(), Adoption::Available);
	let prepared = state
		.reconcile(Impact::Standing, |_| Ok(Some(checkpoint(&"learned".into()))))
		.unwrap()
		.unwrap();
	assert_eq!(state.workspace_adoption().unwrap(), Adoption::Available);
	let change = write(&mut state, &mut store, prepared);
	assert_eq!(change.revision, 0);
	assert_eq!(change.checkpoint, Some(Impact::Standing));
	assert_eq!(state.workspace_adoption().unwrap(), Adoption::Closed);
	state = store.restore();
	assert!(matches!(
		state.adopt(text("late"), 0, &"adopt".into(), Checkpoint::empty()),
		Err(Error::AdoptionClosed)
	));
	assert!(state
		.reconcile(Impact::Standing, |_| Ok(Some(checkpoint(&"learned".into()))))
		.unwrap()
		.is_none());
	assert_eq!(
		store.frames.len(),
		1,
		"unchanged facts require no write or notification"
	);
}
fn schemas_and_trace() {
	let fixture: Value = serde_json::from_str(include_str!("../fixtures/session-state.json")).unwrap();
	for row in fixture["schemas"].as_array().unwrap() {
		let restored = SessionState::restore(
			row["disk"].as_str().unwrap().as_bytes(),
			row["effects"].as_str().unwrap().as_bytes(),
			&NoRoutes,
		);
		assert_eq!(
			restored.is_ok(),
			row["accepted"].as_bool().unwrap(),
			"{}: {:?}",
			row["name"],
			restored.as_ref().err()
		);
		if let Ok(state) = restored {
			let store = Store::new(&state);
			assert!(SessionState::restore(&store.checkpoint, &store.effects, &NoRoutes).is_ok());
		}
	}
	let mut state = fresh();
	let mut store = Store::new(&state);
	for (at, raw) in fixture["actions"].as_array().unwrap().iter().enumerate() {
		let action: BTreeMap<String, Box<serde_json::value::RawValue>> =
			serde_json::from_str(raw.as_str().unwrap()).unwrap();
		let string = |key: &str| -> DocumentText { serde_json::from_str(action[key].get()).unwrap() };
		let id = Text::new(string("id")).unwrap();
		let base = action.get("base").map_or(0, |v| serde_json::from_str(v.get()).unwrap());
		let op: String = serde_json::from_str(action["op"].get()).unwrap();
		let result = (|| -> Result<(), Error> {
			match op.as_str() {
				"replace" => {
					let next = checkpoint(&string("value"));
					let material = next.encode_for(Access::Admin).unwrap().into();
					let v = state.mutate(id, base, &material, Impact::Realization, |_| Ok(next))?;
					admitted(&mut state, &mut store, v);
				}
				"prepare" => {
					let v = state.prepare_ordinary(id, base, &string("material"))?;
					admitted(&mut state, &mut store, v);
				}
				"commit" => {
					let v = state.commit_ordinary(&id, &string("material"))?;
					write(&mut state, &mut store, v);
				}
				"resolve" => {
					let outcome = serde_json::from_str(action["outcome"].get()).unwrap();
					let v = state.resolve(&id, outcome)?;
					write(&mut state, &mut store, v);
				}
				"result" => {
					if let ResultAdmission::Write(v) = state.prepare_result(
						id,
						base,
						&string("material"),
						Text::new(string("kind")).unwrap(),
						Text::new(string("intent")).unwrap(),
					)? {
						write(&mut state, &mut store, v);
					}
				}
				"return" => {
					if let ResultRecorded::Write(v) =
						state.record_result(&id, Some(&string("material")), Text::new(string("value")).unwrap())?
					{
						write(&mut state, &mut store, v);
					}
					advance(&mut state, &mut store, &id);
				}
				_ => panic!("unknown fixture action"),
			}
			Ok(())
		})();
		let expected = &fixture["outcomes"][at];
		assert_eq!(
			result.is_ok(),
			expected["accepted"].as_bool().unwrap(),
			"action {at}: {result:?}"
		);
		assert_eq!(
			state.revision().unwrap(),
			expected["revision"].as_u64().unwrap(),
			"action {at}"
		);
		let frames = expected["frames"].as_array().unwrap();
		assert_eq!(store.frames.len(), frames.len(), "action {at} writes");
		for ((kind, bytes), frame) in store.frames.drain(..).zip(frames) {
			assert_eq!(kind.key(), frame["kind"].as_str().unwrap());
			assert_eq!(
				String::from_utf8(bytes).unwrap(),
				frame["document"].as_str().unwrap(),
				"action {at} document"
			);
		}
	}
}
fn transaction_boundaries() {
	let mut state = fresh();
	let mut store = Store::new(&state);
	let Admission::Write(v) = state
		.mutate(text("one"), 0, &"one".into(), Impact::Realization, |_| {
			Ok(Checkpoint::empty())
		})
		.unwrap()
	else {
		panic!()
	};
	assert_eq!(state.revision().unwrap(), 0);
	assert!(matches!(
		state.prepare_ordinary(text("two"), 0, &"two".into()),
		Err(Error::Busy)
	));
	drop(v);
	assert_eq!(state.revision().unwrap(), 0);
	let Admission::Write(v) = state.prepare_ordinary(text("one"), 0, &"one".into()).unwrap() else {
		panic!()
	};
	let receipt = ready(v.persist(&mut store)).unwrap();
	assert_eq!(
		state.pending_ids().unwrap().len(),
		0,
		"unacknowledged receipt is not visible"
	);
	drop(receipt);
	assert!(matches!(state.revision(), Err(Error::RecoveryRequired)));
	state = store.restore();
	assert_eq!(state.pending_ids().unwrap().len(), 1);
	let Inspection::New(inspected) = state.inspect_ordinary(text("two"), 0, &"two".into()).unwrap() else {
		panic!()
	};
	assert!(matches!(
		fresh().prepare_inspected(inspected, &"two".into()),
		Err(Error::WrongOwner)
	));
	struct Failure(bool);
	impl SessionStorage for Failure {
		type Error = &'static str;
		async fn replace(&mut self, _: SessionDocument, _: Vec<u8>) -> Result<(), WriteFailure<Self::Error>> {
			Err(if self.0 {
				WriteFailure::Indeterminate("uncertain")
			} else {
				WriteFailure::Unchanged("unchanged")
			})
		}
	}
	for uncertain in [false, true] {
		let mut state = fresh();
		let Admission::Write(v) = state.prepare_ordinary(text("one"), 0, &"one".into()).unwrap() else {
			panic!()
		};
		assert!(ready(v.persist(&mut Failure(uncertain))).is_err());
		assert_eq!(state.revision().is_err(), uncertain);
	}
	struct Pending;
	impl SessionStorage for Pending {
		type Error = &'static str;
		async fn replace(&mut self, _: SessionDocument, _: Vec<u8>) -> Result<(), WriteFailure<Self::Error>> {
			core::future::pending().await
		}
	}
	let mut state = fresh();
	let Admission::Write(v) = state.prepare_ordinary(text("one"), 0, &"one".into()).unwrap() else {
		panic!()
	};
	let mut storage = Pending;
	{
		let mut future = Box::pin(v.persist(&mut storage));
		let mut cx = core::task::Context::from_waker(core::task::Waker::noop());
		assert!(core::future::Future::poll(future.as_mut(), &mut cx).is_pending());
	}
	assert!(matches!(state.revision(), Err(Error::RecoveryRequired)));
	let mut state = fresh();
	let mut store = Store::new(&state);
	for n in 0..64 {
		let Admission::Write(v) = state
			.prepare_ordinary(text(&format!("op-{n}")), 0, &"material".into())
			.unwrap()
		else {
			panic!()
		};
		write(&mut state, &mut store, v);
	}
	assert!(matches!(
		state.prepare_ordinary(text("overflow"), 0, &"material".into()),
		Err(Error::Full)
	));
}
fn result_recovery() {
	let id = text("result");
	let mut state = fresh();
	let mut store = Store::new(&state);
	let ResultAdmission::Write(v) = state
		.prepare_result(id.clone(), 0, &"material".into(), text("demo"), text("intent"))
		.unwrap()
	else {
		panic!()
	};
	write(&mut state, &mut store, v);
	let ResultRecorded::Write(v) = state
		.record_result(&id, Some(&"material".into()), text("authority"))
		.unwrap()
	else {
		panic!()
	};
	write(&mut state, &mut store, v);
	let returned = (store.checkpoint.clone(), store.effects.clone());
	let mut boundaries = vec![returned];
	let calls = core::cell::Cell::new(0);
	loop {
		match state
			.advance_result(&id, |c, k, i, r| {
				calls.set(calls.get() + 1);
				apply_result(c, k, i, r)
			})
			.unwrap()
		{
			ResultProgress::Write(v) => {
				write(&mut state, &mut store, v);
				boundaries.push((store.checkpoint.clone(), store.effects.clone()));
			}
			ResultProgress::Complete(revision) => {
				assert_eq!(revision, 1);
				break;
			}
		}
	}
	assert_eq!(calls.get(), 1, "normal application computes one candidate");
	assert_eq!(boundaries.len(), 4, "returned, marked, checkpointed, finalized");
	for (checkpoint, effects) in boundaries {
		let mut recovered = SessionState::restore(&checkpoint, &effects, &NoRoutes).unwrap();
		let mut disk = Store {
			checkpoint,
			effects,
			frames: vec![],
		};
		advance(&mut recovered, &mut disk, &id);
		assert_eq!(recovered.revision().unwrap(), 1);
		assert_eq!(recovered.pending_ids().unwrap().len(), 0);
		assert_eq!(disk.checkpoint, store.checkpoint);
		assert_eq!(disk.effects, store.effects);
	}
}
#[test]
fn durable_session_contract() {
	run();
}

fn command_preflight() {
	let mut state = fresh();
	let mut store = Store::new(&state);
	let id = text("accept");
	let material = "same command".into();
	assert_eq!(state.inspect_command(&id, 0, &material).unwrap(), None);
	assert_eq!(state.pending().unwrap().len(), 0);
	let first = state
		.mutate(text("first"), 0, &"first".into(), Impact::Presentation, |_| {
			Ok(Checkpoint::empty())
		})
		.unwrap();
	admitted(&mut state, &mut store, first);
	assert!(matches!(state.inspect_command(&id, 0, &material), Err(Error::Revision)));
	assert!(matches!(
		state.mutate(id.clone(), 0, &material, Impact::Presentation, |_| panic!(
			"stale preflight"
		)),
		Err(Error::Revision)
	));
	let accept = state
		.mutate(id.clone(), 1, &material, Impact::Presentation, |_| {
			Ok(Checkpoint::empty())
		})
		.unwrap();
	admitted(&mut state, &mut store, accept);
	assert_eq!(state.inspect_command(&id, 0, &material).unwrap(), Some(2));
	assert!(matches!(
		state.inspect_command(&id, 2, &"different".into()),
		Err(Error::Reused)
	));
	let restored = store.restore();
	assert_eq!(restored.inspect_command(&id, 0, &material).unwrap(), Some(2));
	assert!(matches!(
		restored.inspect_ordinary(id, 2, &material),
		Err(Error::OtherLedger)
	));
}
