//! Raw calls deliberately retain the same input and request as the generated
//! wrapper. These are compared paths, not a second production receipt owner.
use crate::peer::Pair;
#[cfg(feature = "generated-client")]
use crate::{callbacks, creation};
use glowcap::{Argument, Ref, Session};
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
	Wide,
	WideReply,
}
impl Row {
	/// The wide rows have no generated wrapper, so only the raw client runs them.
	pub fn has_generated_call(self) -> bool {
		!matches!(self, Self::Wide | Self::WideReply)
	}
	pub const ALL: [Self; 6] = [
		Self::Ordinary,
		Self::Preparation,
		Self::Submission,
		Self::Replay,
		Self::Wide,
		Self::WideReply,
	];
	pub fn name(self) -> &'static str {
		match self {
			Self::Ordinary => "ordinary",
			Self::Preparation => "preparation",
			Self::Submission => "submission",
			Self::Replay => "replay",
			Self::Wide => "wide",
			Self::WideReply => "wide-reply",
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
/// One call whose arguments are wide and carry no capability. The served
/// behavior is the cost under test, so only the raw client runs it, through
/// the raw session call.
pub struct WideCall {
	session: Rc<Session>,
	target: Ref,
	arguments: Vec<Argument>,
}
/// A list of 256 elements with one string among integers, so it never rides
/// the integer-run encoding, a struct of 16 string fields, and a list nested
/// three deep.
pub fn wide_arguments() -> Vec<Argument> {
	let mut list: Vec<Argument> = (0..255).map(Argument::Integer).collect();
	list.push(Argument::String("tail".into()));
	let fields = (0..16)
		.map(|n| (format!("field{n:02}"), Argument::String(format!("value-{n:02}"))))
		.collect();
	let nested = Argument::List(vec![Argument::List(vec![Argument::List(vec![
		Argument::Integer(1),
		Argument::String("leaf".into()),
	])])]);
	vec![Argument::List(list), Argument::Struct(fields), nested]
}
/// The served shape check: constant time, so the profiled window stays the
/// delivery and not the assertion.
pub fn check_wide(args: &[Argument]) {
	assert_eq!(args.len(), 3);
	assert!(matches!(&args[0], Argument::List(items) if items.len() == 256));
	assert!(matches!(&args[1], Argument::Struct(fields) if fields.len() == 16));
	assert!(
		matches!(&args[2], Argument::List(outer) if matches!(&outer[..], [Argument::List(middle)] if matches!(&middle[..], [Argument::List(inner)] if inner.len() == 2)))
	);
}

/// The reply a served call returns for the wide-reply row: one 64 KiB bytes
/// leaf and a struct of 16 strings, with no capability.
pub fn wide_reply() -> Argument {
	let fields = (0..16)
		.map(|n| (format!("field{n:02}"), Argument::String(format!("value-{n:02}"))))
		.collect();
	Argument::List(vec![
		Argument::Bytes(vec![0x5a; WIDE_REPLY_BYTES]),
		Argument::Struct(fields),
	])
}
pub const WIDE_REPLY_BYTES: usize = 64 * 1024;
/// The client shape check: constant time, so the profiled window stays the
/// call and not the assertion.
pub fn check_wide_reply(reply: &Argument) {
	let Argument::List(items) = reply else {
		panic!("expected a wide reply list")
	};
	assert!(
		matches!(&items[..], [Argument::Bytes(bytes), Argument::Struct(fields)] if bytes.len() == WIDE_REPLY_BYTES && fields.len() == 16)
	);
}

pub enum Prepared {
	Wide(WideCall),
	#[cfg(feature = "raw-client")]
	Raw(RawPrepared),
	#[cfg(feature = "generated-client")]
	Generated(creation::PreparedMutation<Ref>),
}
impl Prepared {
	pub async fn submit(&self) -> Ref {
		match self {
			Self::Wide(_) => panic!("a wide call is not a mutation"),
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
	Void(Argument),
	Reply(Argument),
	Text(String),
	Prepared(Prepared),
	Child(Ref),
}
// Submission and replay begin with preparation outside their measured window.
// Preparation owns its result through the end snapshot before cleanup.
pub async fn setup(pair: &Pair, client: Client, row: Row) -> Option<Prepared> {
	match row {
		Row::Ordinary | Row::Preparation | Row::WideReply => None,
		Row::Wide => Some(Prepared::Wide(WideCall {
			session: pair.connection.client.clone(),
			target: pair.target.clone(),
			arguments: wide_arguments(),
		})),
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
		Row::WideReply => ResultValue::Reply(
			pair.connection
				.client
				.send(&pair.target, "wide-reply", &[])
				.await
				.unwrap(),
		),
		Row::Wide => {
			let Some(Prepared::Wide(call)) = request else {
				panic!("wide call not prepared")
			};
			ResultValue::Void(call.session.send(&call.target, "wide", &call.arguments).await.unwrap())
		}
	}
}

pub type State = (usize, usize, usize, usize, usize, usize);

pub fn verify(pair: &Pair, row: Row, before: State, result: &ResultValue) {
	let state = pair.effects.borrow();
	let after = (
		state.ordinary,
		state.queries,
		state.submissions,
		state.effects,
		state.wide,
		state.wide_replies,
	);
	let delta = (
		after.0 - before.0,
		after.1 - before.1,
		after.2 - before.2,
		after.3 - before.3,
		after.4 - before.4,
		after.5 - before.5,
	);
	assert_eq!(
		delta,
		match row {
			Row::Ordinary => (1, 0, 0, 0, 0, 0),
			Row::Preparation => (0, 1, 0, 0, 0, 0),
			Row::Submission => (0, 0, 1, 1, 0, 0),
			Row::Replay => (0, 0, 1, 0, 0, 0),
			Row::Wide => (0, 0, 0, 0, 1, 0),
			Row::WideReply => (0, 0, 0, 0, 0, 1),
		}
	);
	match result {
		ResultValue::Void(reply) => assert!(matches!(reply, Argument::Void)),
		ResultValue::Reply(reply) => check_wide_reply(reply),
		ResultValue::Text(text) => assert_eq!(text, "benchmark reply"),
		ResultValue::Prepared(request) => {
			std::hint::black_box(request);
		}
		ResultValue::Child(child) => {
			std::hint::black_box(child);
		}
	}
}
pub fn state(pair: &Pair) -> State {
	let state = pair.effects.borrow();
	(
		state.ordinary,
		state.queries,
		state.submissions,
		state.effects,
		state.wide,
		state.wide_replies,
	)
}
