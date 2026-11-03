//! Raw calls deliberately retain the same input and request as the generated
//! wrapper. These are compared paths, not a second production receipt owner.
use crate::peer::Pair;
#[cfg(feature = "generated-client")]
use crate::{callbacks, creation};
use glowcap::Ref;
#[cfg(feature = "raw-client")]
use glowcap::{Argument, Session};
#[cfg(feature = "raw-client")]
use std::rc::Rc;

pub const INPUT: &str = "benchmark input";
#[derive(Clone, Copy, Debug)]
pub enum Client {
	#[cfg(feature = "raw-client")]
	Raw,
	#[cfg(feature = "generated-client")]
	Generated,
}
#[derive(Clone, Copy, Debug)]
pub enum Row {
	Ordinary,
	Preparation,
	Submission,
	Replay,
}
impl Row {
	pub const ALL: [Self; 4] = [Self::Ordinary, Self::Preparation, Self::Submission, Self::Replay];
	pub fn name(self) -> &'static str {
		match self {
			Self::Ordinary => "ordinary",
			Self::Preparation => "preparation",
			Self::Submission => "submission",
			Self::Replay => "replay",
		}
	}
}
impl Client {
	pub const ALL: &'static [Self] = &[
		#[cfg(feature = "raw-client")]
		Self::Raw,
		#[cfg(feature = "generated-client")]
		Self::Generated,
	];
	pub fn name(self) -> &'static str {
		match self {
			#[cfg(feature = "raw-client")]
			Self::Raw => "raw",
			#[cfg(feature = "generated-client")]
			Self::Generated => "generated",
		}
	}
}

#[cfg(feature = "raw-client")]
pub struct RawPrepared {
	session: Rc<Session>,
	target: Ref,
	arguments: Vec<Argument>,
}
pub enum Prepared {
	#[cfg(feature = "raw-client")]
	Raw(RawPrepared),
	#[cfg(feature = "generated-client")]
	Generated(creation::PreparedMutation<Ref>),
}
impl Prepared {
	pub async fn submit(&self) -> Ref {
		match self {
			#[cfg(feature = "raw-client")]
			Self::Raw(request) => {
				let result = request
					.session
					.send(&request.target, "mutate", &request.arguments)
					.await
					.unwrap();
				Ref::try_from(&result).unwrap()
			}
			#[cfg(feature = "generated-client")]
			Self::Generated(request) => request.submit().await.unwrap(),
		}
	}
}

async fn prepare(pair: &Pair, client: Client) -> Prepared {
	let session = pair.connection.client.clone();
	let target = pair.target.clone();
	match client {
		#[cfg(feature = "generated-client")]
		Client::Generated => Prepared::Generated(creation::prepare_add(session, target, INPUT).unwrap().await.unwrap()),
		#[cfg(feature = "raw-client")]
		Client::Raw => {
			assert!(!INPUT.is_empty() && INPUT.len() <= 4096);
			let snapshot = INPUT.to_owned();
			let reply = session.send(&target, "mutation-sequence", &[]).await.unwrap();
			let sequence = reply.as_i64().filter(|n| *n > 0).unwrap();
			Prepared::Raw(RawPrepared {
				session,
				target,
				arguments: vec![sequence.into(), "add".into(), snapshot.into()],
			})
		}
	}
}

pub enum ResultValue {
	Text(String),
	Prepared(Prepared),
	Child(Ref),
}
// Submission and replay begin with preparation outside their measured window.
// Preparation owns its result through the end snapshot before cleanup.
pub async fn setup(pair: &Pair, client: Client, row: Row) -> Option<Prepared> {
	match row {
		Row::Ordinary | Row::Preparation => None,
		Row::Submission => Some(prepare(pair, client).await),
		Row::Replay => {
			let request = prepare(pair, client).await;
			let child = request.submit().await;
			drop(child);
			Some(request)
		}
	}
}
pub async fn operation(pair: &Pair, client: Client, row: Row, request: Option<&Prepared>) -> ResultValue {
	match row {
		Row::Ordinary => ResultValue::Text(match client {
			#[cfg(feature = "raw-client")]
			Client::Raw => {
				let result = pair
					.connection
					.client
					.send(&pair.target, None::<&str>, &[Argument::String(INPUT.to_owned())])
					.await
					.unwrap();
				let Argument::String(text) = result else {
					panic!("expected text")
				};
				text
			}
			#[cfg(feature = "generated-client")]
			Client::Generated => callbacks::invoke_direct(&pair.connection.client, &pair.target, INPUT)
				.await
				.unwrap(),
		}),
		Row::Preparation => ResultValue::Prepared(prepare(pair, client).await),
		Row::Submission | Row::Replay => ResultValue::Child(request.unwrap().submit().await),
	}
}

pub fn verify(pair: &Pair, row: Row, before: (usize, usize, usize, usize), result: &ResultValue) {
	let state = pair.effects.borrow();
	let after = (state.ordinary, state.queries, state.submissions, state.effects);
	let delta = (
		after.0 - before.0,
		after.1 - before.1,
		after.2 - before.2,
		after.3 - before.3,
	);
	assert_eq!(
		delta,
		match row {
			Row::Ordinary => (1, 0, 0, 0),
			Row::Preparation => (0, 1, 0, 0),
			Row::Submission => (0, 0, 1, 1),
			Row::Replay => (0, 0, 1, 0),
		}
	);
	match result {
		ResultValue::Text(text) => assert_eq!(text, "benchmark reply"),
		ResultValue::Prepared(request) => {
			let _held_until_after_snapshot = request;
		}
		ResultValue::Child(child) => {
			let _held_until_after_snapshot = child;
		}
	}
}
pub fn state(pair: &Pair) -> (usize, usize, usize, usize) {
	let state = pair.effects.borrow();
	(state.ordinary, state.queries, state.submissions, state.effects)
}
