// Generated from checked interface descriptions.
pub use __glowcap::Error;
pub use __glowcap::Observation;
pub use __glowcap::Pending;
pub use __glowcap::PreparedMutation;
pub use __glowcap::ProjectedType0 as LoamObservation;
pub use __glowcap::ProjectedType1 as LoamRegistration;
pub use __glowcap::Reference;
pub use __glowcap::add;
pub use __glowcap::call_0 as board_list;
pub use __glowcap::call_1 as list_name;
pub use __glowcap::call_2 as list_count;
pub use __glowcap::call_3 as list_task;
pub use __glowcap::call_4 as task_text;
pub use __glowcap::call_5 as receiver_poll;
pub use __glowcap::call_6 as prepare_move;
pub use __glowcap::call_7 as prepare_observe;
pub use __glowcap::call_8 as cancel;
pub use __glowcap::prepare_add;

mod __glowcap {
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
	fn integer(value: Argument) -> Result<i64, Error> {
		value.as_i64().ok_or(Error::InvalidReply)
	}
	fn boolean(value: Argument) -> Result<bool, Error> {
		if let Argument::Boolean(value) = value {
			Ok(value)
		} else {
			Err(Error::InvalidReply)
		}
	}
	fn bytes(value: Argument) -> Result<Vec<u8>, Error> {
		if let Argument::Bytes(value) = value {
			Ok(value)
		} else {
			Err(Error::InvalidReply)
		}
	}
	fn symbol(value: Argument) -> Result<String, Error> {
		if let Argument::Symbol(value) = value {
			Ok(value)
		} else {
			Err(Error::InvalidReply)
		}
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
		prepare_mutation(
			session,
			target,
			move |number| vec![number.into(), ADD_VERB.into(), snapshot.into()],
			capability,
		)
	}

	/// Submit once. Use prepare_add when the caller needs to retain and replay.
	pub fn add(session: Rc<Session>, target: Ref, text: &str) -> impl Future<Output = Result<Ref, Error>> + use<> {
		let preparation = prepare_add(session, target, text);
		async move { preparation?.await?.submit().await }
	}
	pub struct ProjectedType0(pub Vec<u8>, pub Argument, pub bool, pub bool, pub Compound1);
	pub struct ProjectedType1(pub Ref, pub Ref);
	pub type Compound1 = Vec<String>;
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
	fn bytes_56_56(value: Argument) -> Result<Vec<u8>, Error> {
		let value = bytes(value)?;
		if !(56u128..=56u128).contains(&(value.len() as u128)) {
			Err(Error::InvalidReply)
		} else {
			Ok(value)
		}
	}
	const MAX_REPLY_WORK: usize = 65536;
	// This is a decoder work limit, not a schema collection bound. Opaque value
	// fields move intact. Lists whose element layout differs from Argument need
	// one result Vec allocation, owned until result drop or refusal.
	struct DecodeBudget {
		remaining: usize,
	}
	impl DecodeBudget {
		fn step(&mut self) -> Result<(), Error> {
			if self.remaining == 0 {
				return Err(Error::ResourceLimit);
			}
			self.remaining -= 1;
			Ok(())
		}
	}
	fn compound_0(value: Argument) -> Result<ProjectedType0, Error> {
		compound_0_at(
			value,
			&mut DecodeBudget {
				remaining: MAX_REPLY_WORK,
			},
		)
	}
	fn compound_0_at(value: Argument, budget: &mut DecodeBudget) -> Result<ProjectedType0, Error> {
		budget.step()?;
		let Argument::Tagged { tag, value: values } = value else {
			return Err(Error::InvalidReply);
		};
		if tag != "access:observation" {
			return Err(Error::InvalidReply);
		}
		if values.len() != 5 {
			return Err(Error::InvalidReply);
		}
		let mut fields = values.into_iter();
		Ok(ProjectedType0(
			{
				budget.step()?;
				bytes_56_56(fields.next().ok_or(Error::InvalidReply)?)
			}?,
			{
				budget.step()?;
				Ok::<_, Error>(fields.next().ok_or(Error::InvalidReply)?)
			}?,
			{
				budget.step()?;
				boolean(fields.next().ok_or(Error::InvalidReply)?)
			}?,
			{
				budget.step()?;
				boolean(fields.next().ok_or(Error::InvalidReply)?)
			}?,
			compound_1_at(fields.next().ok_or(Error::InvalidReply)?, budget)?,
		))
	}
	fn compound_1_at(value: Argument, budget: &mut DecodeBudget) -> Result<Compound1, Error> {
		budget.step()?;
		let Argument::List(values) = value else {
			return Err(Error::InvalidReply);
		};
		if values.len() > budget.remaining {
			return Err(Error::ResourceLimit);
		}
		let mut result = Vec::with_capacity(values.len());
		for value in values {
			result.push({
				budget.step()?;
				symbol(value)
			}?);
		}
		Ok(result)
	}
	fn compound_2(value: Argument) -> Result<ProjectedType1, Error> {
		compound_2_at(
			value,
			&mut DecodeBudget {
				remaining: MAX_REPLY_WORK,
			},
			0,
		)
	}
	fn compound_2_at(value: Argument, budget: &mut DecodeBudget, depth: usize) -> Result<ProjectedType1, Error> {
		budget.step(depth)?;
		let Argument::List(values) = value else {
			return Err(Error::InvalidReply);
		};
		if values.len() != 2 {
			return Err(Error::InvalidReply);
		}
		let mut fields = values.into_iter();
		Ok(ProjectedType1(
			{
				budget.step(depth + 1)?;
				capability(fields.next().ok_or(Error::InvalidReply)?)
			}?,
			{
				budget.step(depth + 1)?;
				capability(fields.next().ok_or(Error::InvalidReply)?)
			}?,
		))
	}

	pub fn call_0(session: &Session, target: impl AsSendTarget, arg0: i64) -> Result<Pending<Ref>, Error> {
		if !(0..=9223372036854775807).contains(&arg0) {
			return Err(Error::InvalidArgument);
		}
		let raw = session.send(target, "list", &[arg0.into()]);
		Ok(Pending::new(raw, capability))
	}

	pub fn call_1(session: &Session, target: impl AsSendTarget) -> Pending<String> {
		let raw = session.send(target, "name", &[]);
		Pending::new(raw, text_1_64)
	}

	pub fn call_2(session: &Session, target: impl AsSendTarget) -> Pending<i64> {
		let raw = session.send(target, "count", &[]);
		Pending::new(raw, integer_p0_p256)
	}

	pub fn call_3(session: &Session, target: impl AsSendTarget, arg0: i64) -> Result<Pending<Ref>, Error> {
		if !(0..=9223372036854775807).contains(&arg0) {
			return Err(Error::InvalidArgument);
		}
		let raw = session.send(target, "task", &[arg0.into()]);
		Ok(Pending::new(raw, capability))
	}

	pub fn call_4(session: &Session, target: impl AsSendTarget) -> Pending<String> {
		let raw = session.send(target, "text", &[]);
		Pending::new(raw, text_1_4096)
	}

	pub fn call_5(
		session: &Session,
		target: impl AsSendTarget,
		// Omit only a trailing suffix of these arguments.
		arg0: Option<Vec<u8>>,
	) -> Result<Pending<ProjectedType0>, Error> {
		if let Some(value) = arg0.as_ref()
			&& !(56u128..=56u128).contains(&(value.len() as u128))
		{
			return Err(Error::InvalidArgument);
		}
		let count = optional_argument_count(&[arg0.is_some()])?;
		let arguments = [
			// Fixed stack scratch; omitted slots are outside the sent prefix.
			arg0.map(Argument::Bytes).unwrap_or(Argument::Void),
		];
		let raw = session.send(target, "poll", &arguments[..count]);
		Ok(Pending::new(raw, compound_0))
	}

	pub fn call_6<'a>(
		session: Rc<Session>,
		target: Ref,
		arg0: Reference<'a>,
		arg1: Reference<'a>,
	) -> Result<impl Future<Output = Result<PreparedMutation<i64>, Error>> + use<>, Error> {
		let arg0 = match arg0 {
			Reference::Target(value) => value.retain_for(&session.host()),
			Reference::Pending(value) => value.retain_for(&session.host()),
		}?;
		let arg1 = match arg1 {
			Reference::Target(value) => value.retain_for(&session.host()),
			Reference::Pending(value) => value.retain_for(&session.host()),
		}?;
		prepare_mutation(
			session,
			target,
			move |number| vec![number.into(), "move".into(), arg0.into(), arg1.into()],
			integer_p0_p256,
		)
	}

	pub fn call_7(
		session: Rc<Session>,
		target: Ref,
	) -> Result<impl Future<Output = Result<PreparedMutation<ProjectedType1>, Error>> + use<>, Error> {
		prepare_mutation(
			session,
			target,
			move |number| vec![number.into(), "observe".into()],
			compound_2,
		)
	}

	pub fn call_8(session: &Session, target: impl AsSendTarget) -> Pending<bool> {
		let raw = session.send(target, "cancel", &[]);
		Pending::new(raw, boolean)
	}
}
