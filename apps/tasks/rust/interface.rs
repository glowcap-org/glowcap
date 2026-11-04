// Generated from checked interface descriptions.
const MIN_TEXT_BYTES: usize = 1;
const MAX_TEXT_BYTES: usize = 4096;
const ADD_VERB: &str = "add";
use glowcap::Argument;
use glowcap::AsSendTarget;
use glowcap::Ref;
use glowcap::RemotePromise;
use glowcap::Session;
#[derive(Debug)]
pub enum Error {
	InvalidArgument,
	InvalidSequence,
	InvalidReply,
	Runtime(glowcap::Error),
}
impl std::fmt::Display for Error {
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		match self {
			Self::InvalidArgument => f.write_str("an argument is outside the bounds the interface declares"),
			Self::InvalidSequence => f.write_str("the target returned no positive mutation sequence"),
			Self::InvalidReply => f.write_str("the reply does not have the type the interface declares"),
			Self::Runtime(error) => error.fmt(f),
		}
	}
}
impl std::error::Error for Error {
	fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
		match self {
			Self::Runtime(error) => Some(error),
			_ => None,
		}
	}
}
impl From<glowcap::Error> for Error {
	fn from(error: glowcap::Error) -> Self {
		Self::Runtime(error)
	}
}
use std::{
	future::{Future, IntoFuture},
	pin::Pin,
	task::{Context, Poll},
};
pub struct Pending<T> {
	raw: RemotePromise,
	decode: fn(Argument) -> Result<T, Error>,
}
impl<T> Pending<T> {
	fn new(raw: RemotePromise, decode: fn(Argument) -> Result<T, Error>) -> Self {
		Self { raw, decode }
	}
	pub fn raw(&self) -> &RemotePromise {
		&self.raw
	}
}
pub struct Observation<T> {
	raw: <RemotePromise as IntoFuture>::IntoFuture,
	decode: fn(Argument) -> Result<T, Error>,
}
impl<T> Future for Observation<T> {
	type Output = Result<T, Error>;
	fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
		let this = self.get_mut();
		match this.raw.as_mut().poll(cx) {
			Poll::Pending => Poll::Pending,
			Poll::Ready(result) => Poll::Ready(result.map_err(Error::Runtime).and_then(this.decode)),
		}
	}
}
impl<T> IntoFuture for Pending<T> {
	type Output = Result<T, Error>;
	type IntoFuture = Observation<T>;
	fn into_future(self) -> Self::IntoFuture {
		Observation {
			raw: self.raw.into_future(),
			decode: self.decode,
		}
	}
}
use std::rc::Rc;

/// Exact target, sequence, and owned arguments, retained for submission and replay.
pub struct PreparedMutation<T> {
	session: Rc<Session>,
	target: Ref,
	arguments: Vec<Argument>,
	decode: fn(Argument) -> Result<T, Error>,
}
impl<T> PreparedMutation<T> {
	pub fn submit(&self) -> Pending<T> {
		Pending::new(self.session.send(&self.target, "mutate", &self.arguments), self.decode)
	}
}

// Snapshots live inline in the future until acquisition succeeds. Cancellation
// releases them without allocating the request vector or copying its wire verb.
// A successful preparation owns one vector through submission and replay.
fn prepare_mutation<T, Arguments>(
	session: Rc<Session>,
	target: Ref,
	make_arguments: Arguments,
	decode: fn(Argument) -> Result<T, Error>,
) -> impl Future<Output = Result<PreparedMutation<T>, Error>> + use<T, Arguments>
where
	Arguments: FnOnce(i64) -> Vec<Argument>,
{
	let sequence = session.send(&target, "mutation-sequence", &[]);
	async move {
		let reply = sequence.await?;
		let number = reply.as_i64().filter(|n| *n > 0).ok_or(Error::InvalidSequence)?;
		Ok(PreparedMutation {
			session,
			target,
			arguments: make_arguments(number),
			decode,
		})
	}
}
fn capability(value: Argument) -> Result<Ref, Error> {
	Ref::try_from(&value).map_err(|_| Error::InvalidReply)
}
fn text(value: Argument) -> Result<String, Error> {
	if let Argument::String(text) = value {
		Ok(text)
	} else {
		Err(Error::InvalidReply)
	}
}
fn integer(value: Argument) -> Result<i64, Error> {
	value.as_i64().ok_or(Error::InvalidReply)
}
/// Copies text before acquiring a sequence. The prepared request owns that
/// snapshot until it is dropped, so caller edits cannot change submission or replay.
pub fn prepare_add(
	session: Rc<Session>,
	target: Ref,
	text: &str,
) -> Result<impl Future<Output = Result<PreparedMutation<Ref>, Error>> + use<>, Error> {
	if text.len() < MIN_TEXT_BYTES || text.len() > MAX_TEXT_BYTES {
		return Err(Error::InvalidArgument);
	}
	let snapshot = text.to_owned();
	Ok(prepare_mutation(
		session,
		target,
		move |number| vec![number.into(), ADD_VERB.into(), snapshot.into()],
		capability,
	))
}

/// Submit once. Use prepare_add when the caller needs to retain and replay.
pub fn add(session: Rc<Session>, target: Ref, text: &str) -> impl Future<Output = Result<Ref, Error>> + use<> {
	let preparation = prepare_add(session, target, text);
	async move { preparation?.await?.submit().await }
}
fn text_1_64(value: Argument) -> Result<String, Error> {
	let value = text(value)?;
	if !(1u128..=64u128).contains(&(value.len() as u128)) {
		Err(Error::InvalidReply)
	} else {
		Ok(value)
	}
}
fn integer_p0_p256(value: Argument) -> Result<i64, Error> {
	let value = integer(value)?;
	if !(0..=256).contains(&value) {
		Err(Error::InvalidReply)
	} else {
		Ok(value)
	}
}
fn text_1_4096(value: Argument) -> Result<String, Error> {
	let value = text(value)?;
	if !(1u128..=4096u128).contains(&(value.len() as u128)) {
		Err(Error::InvalidReply)
	} else {
		Ok(value)
	}
}

pub fn board_list(session: &Session, target: impl AsSendTarget, arg0: i64) -> Result<Pending<Ref>, Error> {
	if !(0..=9223372036854775807).contains(&arg0) {
		return Err(Error::InvalidArgument);
	}
	let raw = session.send(target, "list", &[arg0.into()]);
	Ok(Pending::new(raw, capability))
}

pub fn list_name(session: &Session, target: impl AsSendTarget) -> Pending<String> {
	let raw = session.send(target, "name", &[]);
	Pending::new(raw, text_1_64)
}

pub fn list_count(session: &Session, target: impl AsSendTarget) -> Pending<i64> {
	let raw = session.send(target, "count", &[]);
	Pending::new(raw, integer_p0_p256)
}

pub fn list_task(session: &Session, target: impl AsSendTarget, arg0: i64) -> Result<Pending<Ref>, Error> {
	if !(0..=9223372036854775807).contains(&arg0) {
		return Err(Error::InvalidArgument);
	}
	let raw = session.send(target, "task", &[arg0.into()]);
	Ok(Pending::new(raw, capability))
}

pub fn task_text(session: &Session, target: impl AsSendTarget) -> Pending<String> {
	let raw = session.send(target, "text", &[]);
	Pending::new(raw, text_1_4096)
}
