// Generated from checked interface descriptions.
pub use __glowcap::Error;
pub use __glowcap::Observation;
pub use __glowcap::Pending;
pub use __glowcap::PreparedMutation;
pub use __glowcap::Reference;
pub use __glowcap::call_0 as introducer_get_greeter;
pub use __glowcap::call_1 as factory_open;
pub use __glowcap::call_2 as factory_accept;
pub use __glowcap::call_3 as sink_push;
pub use __glowcap::call_4 as sink_changed;
pub use __glowcap::call_5 as reader_read;
pub use __glowcap::call_6 as reader_then;
pub use __glowcap::call_7 as invoke_direct;
pub use __glowcap::call_8 as notify_direct;
pub use __glowcap::call_9 as invoke_empty;
pub use __glowcap::call_10 as invoke_named;
pub use __glowcap::call_11 as presence_required;
pub use __glowcap::call_12 as presence_optional;
pub use __glowcap::call_13 as presence_suffix;
pub use __glowcap::call_14 as presence_pair;
pub use __glowcap::call_15 as presence_references;
pub use __glowcap::call_16 as presence_value;
pub use __glowcap::call_17 as presence_notify;
pub use __glowcap::call_18 as prepare_accept;

mod __glowcap {
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
		ResourceLimit,
		Runtime(glowcap::Error),
	}
	impl std::fmt::Display for Error {
		fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
			match self {
				Self::InvalidArgument => f.write_str("an argument is outside the bounds the interface declares"),
				Self::InvalidSequence => f.write_str("the target returned no positive mutation sequence"),
				Self::InvalidReply => f.write_str("the reply does not have the type the interface declares"),
				Self::ResourceLimit => f.write_str("reply decoder work or depth limit exceeded"),
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
	/// A borrowed reference argument, lowered synchronously before the send returns.
	/// Receipt preparation retains it independently before acquiring a sequence.
	pub enum Reference<'a> {
		Target(&'a Ref),
		Pending(&'a RemotePromise),
	}
	impl<'a> From<&'a Ref> for Reference<'a> {
		fn from(value: &'a Ref) -> Self {
			Self::Target(value)
		}
	}
	impl<'a> From<&'a RemotePromise> for Reference<'a> {
		fn from(value: &'a RemotePromise) -> Self {
			Self::Pending(value)
		}
	}
	impl Reference<'_> {
		fn argument(self) -> Argument {
			match self {
				Self::Target(value) => value.into(),
				Self::Pending(value) => value.into(),
			}
		}
	}
	// Presence is fixed stack scratch. A missing optional argument ends the supplied
	// prefix; a later Some is refused before arguments acquire wire custody.
	fn optional_argument_count(present: &[bool]) -> Result<usize, Error> {
		let count = present.iter().take_while(|value| **value).count();
		if present[count..].iter().any(|value| *value) {
			return Err(Error::InvalidArgument);
		}
		Ok(count)
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
	) -> Result<impl Future<Output = Result<PreparedMutation<T>, Error>> + use<T, Arguments>, Error>
	where
		Arguments: FnOnce(i64) -> Vec<Argument>,
	{
		let target = target.retain_for(&session.host())?;
		let sequence = session.send(&target, "mutation-sequence", &[]);
		Ok(async move {
			let reply = sequence.await?;
			let number = reply.as_i64().filter(|n| *n > 0).ok_or(Error::InvalidSequence)?;
			Ok(PreparedMutation {
				session,
				target,
				arguments: make_arguments(number),
				decode,
			})
		})
	}
	fn capability(value: Argument) -> Result<Ref, Error> {
		if let Argument::Reference(reference) = value {
			Ok(reference)
		} else {
			Err(Error::InvalidReply)
		}
	}
	fn text(value: Argument) -> Result<String, Error> {
		if let Argument::String(text) = value {
			Ok(text)
		} else {
			Err(Error::InvalidReply)
		}
	}
	fn nothing(value: Argument) -> Result<(), Error> {
		if matches!(value, Argument::Void) {
			Ok(())
		} else {
			Err(Error::InvalidReply)
		}
	}

	pub fn call_0(session: &Session, target: impl AsSendTarget) -> Pending<Ref> {
		let raw = session.send(target, "get-greeter", &[]);
		Pending::new(raw, capability)
	}

	pub fn call_1<'a>(session: &Session, target: impl AsSendTarget, arg0: impl Into<Reference<'a>>) -> Pending<Ref> {
		let raw = session.send(target, "open", &[arg0.into().argument()]);
		Pending::new(raw, capability)
	}

	pub fn call_2<'a>(session: &Session, target: impl AsSendTarget, arg0: impl Into<Reference<'a>>) -> Pending<()> {
		let raw = session.send(target, "accept", &[arg0.into().argument()]);
		Pending::new(raw, nothing)
	}

	pub fn call_3<'a>(session: &Session, target: impl AsSendTarget, arg0: impl Into<Reference<'a>>) -> Pending<()> {
		let raw = session.send(target, "push", &[arg0.into().argument()]);
		Pending::new(raw, nothing)
	}

	pub fn call_4(session: &Session, target: impl AsSendTarget, arg0: Argument) -> Result<(), Error> {
		let result = session.tell(target, "changed", &[arg0]);
		result.map_err(Error::Runtime)
	}

	pub fn call_5(session: &Session, target: impl AsSendTarget) -> Pending<String> {
		let raw = session.send(target, "read", &[]);
		Pending::new(raw, text)
	}

	pub fn call_6(session: &Session, target: impl AsSendTarget) -> Pending<String> {
		let raw = session.send(target, "then", &[]);
		Pending::new(raw, text)
	}

	pub fn call_7(session: &Session, target: impl AsSendTarget, arg0: &str) -> Pending<String> {
		let raw = session.send(target, None::<&str>, &[arg0.into()]);
		Pending::new(raw, text)
	}

	pub fn call_8(session: &Session, target: impl AsSendTarget, arg0: Argument) -> Result<(), Error> {
		let result = session.tell(target, None::<&str>, &[arg0]);
		result.map_err(Error::Runtime)
	}

	pub fn call_9(session: &Session, target: impl AsSendTarget) -> Pending<String> {
		let raw = session.send(target, "", &[]);
		Pending::new(raw, text)
	}

	pub fn call_10(session: &Session, target: impl AsSendTarget) -> Pending<String> {
		let raw = session.send(target, "then", &[]);
		Pending::new(raw, text)
	}

	pub fn call_11(session: &Session, target: impl AsSendTarget, arg0: ()) -> Pending<()> {
		let raw = session.send(target, "required", &[arg0.into()]);
		Pending::new(raw, nothing)
	}

	pub fn call_12(
		session: &Session,
		target: impl AsSendTarget,
		// Omit only a trailing suffix of these arguments.
		arg0: Option<()>,
	) -> Result<Pending<()>, Error> {
		let count = optional_argument_count(&[arg0.is_some()])?;
		let arguments = [
			// Fixed stack scratch; omitted slots are outside the sent prefix.
			arg0.map(Argument::from).unwrap_or(Argument::Void),
		];
		let raw = session.send(target, "optional", &arguments[..count]);
		Ok(Pending::new(raw, nothing))
	}

	pub fn call_13(
		session: &Session,
		target: impl AsSendTarget,
		arg0: &str,
		// Omit only a trailing suffix of these arguments.
		arg1: Option<()>,
	) -> Result<Pending<()>, Error> {
		let count = 1 + optional_argument_count(&[arg1.is_some()])?;
		let arguments = [
			// Fixed stack scratch; omitted slots are outside the sent prefix.
			arg0.into(),
			arg1.map(Argument::from).unwrap_or(Argument::Void),
		];
		let raw = session.send(target, "suffix", &arguments[..count]);
		Ok(Pending::new(raw, nothing))
	}

	pub fn call_14(
		session: &Session,
		target: impl AsSendTarget,
		// Omit only a trailing suffix of these arguments.
		arg0: Option<&str>,
		arg1: Option<&str>,
	) -> Result<Pending<()>, Error> {
		let count = optional_argument_count(&[arg0.is_some(), arg1.is_some()])?;
		let arguments = [
			// Fixed stack scratch; omitted slots are outside the sent prefix.
			arg0.map(Argument::from).unwrap_or(Argument::Void),
			arg1.map(Argument::from).unwrap_or(Argument::Void),
		];
		let raw = session.send(target, "pair", &arguments[..count]);
		Ok(Pending::new(raw, nothing))
	}

	pub fn call_15<'a>(
		session: &Session,
		target: impl AsSendTarget,
		// Omit only a trailing suffix of these arguments.
		arg0: Option<Reference<'a>>,
		arg1: Option<Reference<'a>>,
	) -> Result<Pending<()>, Error> {
		let count = optional_argument_count(&[arg0.is_some(), arg1.is_some()])?;
		let arguments = [
			// Fixed stack scratch; omitted slots are outside the sent prefix.
			arg0.map(Reference::argument).unwrap_or(Argument::Void),
			arg1.map(Reference::argument).unwrap_or(Argument::Void),
		];
		let raw = session.send(target, "references", &arguments[..count]);
		Ok(Pending::new(raw, nothing))
	}

	pub fn call_16(
		session: &Session,
		target: impl AsSendTarget,
		// Omit only a trailing suffix of these arguments.
		arg0: Option<Argument>,
	) -> Result<Pending<()>, Error> {
		let count = optional_argument_count(&[arg0.is_some()])?;
		let arguments = [
			// Fixed stack scratch; omitted slots are outside the sent prefix.
			arg0.unwrap_or(Argument::Void),
		];
		let raw = session.send(target, "value", &arguments[..count]);
		Ok(Pending::new(raw, nothing))
	}

	pub fn call_17(
		session: &Session,
		target: impl AsSendTarget,
		// Omit only a trailing suffix of these arguments.
		arg0: Option<()>,
	) -> Result<(), Error> {
		let count = optional_argument_count(&[arg0.is_some()])?;
		let arguments = [
			// Fixed stack scratch; omitted slots are outside the sent prefix.
			arg0.map(Argument::from).unwrap_or(Argument::Void),
		];
		let result = session.tell(target, "notify", &arguments[..count]);
		result.map_err(Error::Runtime)
	}

	pub fn call_18(
		session: Rc<Session>,
		target: Ref,
		arg0: &RemotePromise,
	) -> Result<impl Future<Output = Result<PreparedMutation<()>, Error>> + use<>, Error> {
		let arg0 = arg0.retain_for(&session.host())?;
		prepare_mutation(
			session,
			target,
			move |number| vec![number.into(), "accept".into(), arg0.into()],
			nothing,
		)
	}
}
