//! Owning receipt and effect handles exercised by Linux and Chromium consumers.
use super::{Argument, Call, Content, Invocation, Method, Ref, Registration, Requirement, Retry, Session, refusal};
use std::{
	cell::{Cell, RefCell},
	rc::{Rc, Weak},
};
use std::{
	future::{Future, poll_fn},
	task::Poll,
};

#[derive(Default)]
pub struct State {
	pub target: RefCell<Option<Ref>>,
	pending: RefCell<Option<super::PendingContinuation>>,
	reserved: tokio::sync::Notify,
	pub effects: Cell<usize>,
	execution: RefCell<Option<super::EffectExecution>>,
	confirmation_parked: Cell<bool>,
	confirmation_waiting: tokio::sync::Notify,
}
impl State {
	#[cfg(target_arch = "wasm32")]
	pub async fn wait_for_confirmation_park(&self) {
		loop {
			let notified = self.confirmation_waiting.notified();
			tokio::pin!(notified);
			notified.as_mut().enable();
			if self.confirmation_parked.get() {
				return;
			}
			notified.await;
		}
	}
}
struct Probe {
	inner: Box<dyn Content>,
	state: Weak<State>,
}
pub fn wrap(mut registration: Registration, state: &Rc<State>) -> Registration {
	registration.content = Box::new(Probe {
		inner: registration.content,
		state: Rc::downgrade(state),
	});
	for verb in [
		"effect-reserve",
		"effect-refuse",
		"effect-abandon",
		"effect-fail",
		"effect-drop",
	] {
		registration.methods.push(Method {
			verb: verb.into(),
			retry: if matches!(verb, "effect-fail" | "effect-drop") {
				Retry::ReadOnly
			} else {
				Retry::Receipt
			},
		});
	}
	registration
}
impl Content for Probe {
	fn requirement(&self, input: Invocation<'_>) -> super::HostResult<Requirement> {
		self.inner.requirement(input)
	}
	fn references(&self, input: Invocation<'_>) -> super::HostResult<Vec<super::ReferenceRequest>> {
		self.inner.references(input)
	}
	fn dependent_requirement(&self, input: Invocation<'_>) -> super::HostResult<Requirement> {
		self.inner.dependent_requirement(input)
	}
	fn invoke(&self, call: &mut Call<'_>, input: Invocation<'_>) -> super::HostResult<Argument> {
		if input.verb.starts_with("effect-") {
			let state = self
				.state
				.upgrade()
				.ok_or_else(|| refusal("effect executor is closed"))?;
			if input.verb == "effect-drop" {
				assert!(state.execution.borrow_mut().take().is_some());
				return Ok(Argument::Boolean(true));
			}
			if input.verb == "effect-fail" {
				state.effects.set(state.effects.get() + 1);
				return Err(refusal("target admitted before application refusal"));
			}
			if matches!(input.verb, "effect-reserve" | "effect-refuse" | "effect-abandon") {
				let target = state.target.borrow().as_ref().unwrap().clone();
				let (reservation, pending) = call.reserve_continuation_copying(&[target])?;
				// These getters grant ordinary independently owned Ref guards. Their
				// Drop is legal inside the callback and leaves kernel custody intact.
				drop(reservation.source()?);
				drop(reservation.target(0)?);
				if input.verb == "effect-abandon" {
					drop(pending);
				} else {
					state.pending.borrow_mut().replace(pending);
					state.reserved.notify_one();
				}
				if input.verb == "effect-refuse" {
					return Err(refusal("receipt refuses before commit"));
				}
				return Ok(Argument::Boolean(true));
			}
		}
		self.inner.invoke(call, input)
	}
}
async fn pending(state: &State) -> super::PendingContinuation {
	loop {
		let notified = state.reserved.notified();
		tokio::pin!(notified);
		notified.as_mut().enable();
		if let Some(value) = state.pending.borrow_mut().take() {
			return value;
		}
		notified.await;
	}
}
pub async fn exercise(session: &Session, root: &Ref, control: &Ref, state: &State, sequence: i64, require_park: bool) {
	let request = [Argument::Integer(sequence), Argument::String("effect-reserve".into())];
	let effect = async {
		let mut pending = pending(state).await;
		let continuation = {
			let confirming = pending.confirmed();
			tokio::pin!(confirming);
			match poll_fn(|cx| Poll::Ready(confirming.as_mut().poll(cx))).await {
				Poll::Pending => {
					state.confirmation_parked.set(true);
					state.confirmation_waiting.notify_one();
					confirming.await.unwrap()
				}
				Poll::Ready(value) => {
					assert!(!require_park, "storage hold must park the actual confirmation future");
					value.unwrap()
				}
			}
		};
		assert!(pending.try_take().is_err(), "confirmation transfers once");
		let mut execution = continuation.execute(0, "get", &[], 4096).unwrap();
		drop(continuation);
		let first = match execution.completed().await.unwrap() {
			super::EffectResult::Ready(value) => value,
			super::EffectResult::Unsent(error) => panic!("private target unsent: {error}"),
			super::EffectResult::Unknown(error) => panic!("private target unknown: {error}"),
			super::EffectResult::Pending => panic!("completed returned pending"),
		};
		let super::EffectResult::Ready(second) = execution.result().unwrap() else {
			panic!("ready result remains observable")
		};
		assert_eq!(
			first.as_list().unwrap()[0].as_bytes(),
			second.as_list().unwrap()[0].as_bytes()
		);
		drop(execution);
		assert!(
			first.as_list().unwrap()[0].as_bytes().is_some(),
			"ordinary Rust result survives observer release"
		);
	};
	let (receipt, ()) = tokio::join!(session.send(root, "mutate", &request), effect);
	assert!(receipt.unwrap().as_bool().unwrap());
	let request = [
		Argument::Integer(sequence + 1),
		Argument::String("effect-refuse".into()),
	];
	assert_eq!(
		session.send(root, "mutate", &request).await.err().unwrap().message(),
		Some("ApplicationRefused")
	);
	let mut canceled = pending(state).await;
	assert_eq!(canceled.confirmed().await.err().unwrap().code(), super::UNCHANGED);
	drop(canceled);
	let request = [
		Argument::Integer(sequence + 1),
		Argument::String("effect-abandon".into()),
	];
	assert!(
		session.send(root, "mutate", &request).await.is_ok(),
		"callback Drop detaches only observation"
	);
	let request = [
		Argument::Integer(sequence + 2),
		Argument::String("effect-reserve".into()),
	];
	assert!(session.send(root, "mutate", &request).await.is_ok());
	let mut pending = pending(state).await;
	let continuation = pending.confirmed().await.unwrap();
	let mut execution = continuation.execute(0, "effect-fail", &[], 4096).unwrap();
	let super::EffectResult::Unknown(error) = execution.completed().await.unwrap() else {
		panic!("application refusal after target admission cannot prove absence")
	};
	assert_eq!(error.message(), Some("ApplicationRefused"));
	assert_eq!(state.effects.get(), 1);
	session
		.send(
			control,
			"pause",
			&[Argument::Bytes(
				super::management::revision(session, control)
					.await
					.to_be_bytes()
					.to_vec(),
			)],
		)
		.await
		.unwrap();
	let mut denied = continuation.execute(0, "effect-fail", &[], 4096).unwrap();
	assert!(
		matches!(denied.completed().await.unwrap(), super::EffectResult::Unsent(_)),
		"paused source refuses before target admission"
	);
	assert_eq!(state.effects.get(), 1);
	drop(denied);
	session
		.send(
			control,
			"resume",
			&[Argument::Bytes(
				super::management::revision(session, control)
					.await
					.to_be_bytes()
					.to_vec(),
			)],
		)
		.await
		.unwrap();
	// No wire verb follows: only local Loam progress can retire a destructor
	// that was refused inside the actual content callback.
	state.execution.borrow_mut().replace(execution);
	let mut dropping = continuation.execute(0, "effect-drop", &[], 4096).unwrap();
	drop(continuation);
	assert!(matches!(
		dropping.completed().await.unwrap(),
		super::EffectResult::Ready(Argument::Boolean(true))
	));
	drop(dropping);
	assert!(state.execution.borrow().is_none());
	state.target.borrow_mut().take();
}

#[cfg(not(target_arch = "wasm32"))]
pub async fn abandon_executor(session: &Session, root: &Ref, state: Rc<State>, target: Ref, sequence: i64) {
	state.target.borrow_mut().replace(target);
	let request = [Argument::Integer(sequence), Argument::String("effect-reserve".into())];
	assert!(session.send(root, "mutate", &request).await.is_ok());
	assert!(
		state.pending.borrow().is_some(),
		"committed custody remains in the executor mailbox"
	);
	let executor = Rc::downgrade(&state);
	drop(state);
	assert!(
		executor.upgrade().is_none(),
		"content must not retain the abandoned executor"
	);
}
