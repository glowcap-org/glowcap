// Generated from checked interface descriptions.
pub use __glowcap::Error;
pub use __glowcap::Observation;
pub use __glowcap::Pending;
pub use __glowcap::call_0 as list;
pub use __glowcap::call_1 as limited;
pub use __glowcap::call_2 as tuple;
pub use __glowcap::call_3 as zero;
pub use __glowcap::call_4 as nested;

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
			Self {
				raw: raw.with_owned_outcome(),
				decode,
			}
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
	fn capability(value: Argument) -> Result<Ref, Error> {
		if let Argument::Reference(reference) = value {
			Ok(reference)
		} else {
			Err(Error::InvalidReply)
		}
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
	pub type Compound0 = Vec<String>;
	pub type Compound1 = Vec<String>;
	pub type Compound2 = (Vec<u8>, Ref, bool);
	pub type Compound3 = ();
	pub type Compound4 = Vec<Compound5>;
	pub type Compound5 = (String, Ref, Argument);
	fn bytes_2_2(value: Argument) -> Result<Vec<u8>, Error> {
		let value = bytes(value)?;
		if !(2u128..=2u128).contains(&(value.len() as u128)) {
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
	fn compound_0(value: Argument) -> Result<Compound0, Error> {
		compound_0_at(
			value,
			&mut DecodeBudget {
				remaining: MAX_REPLY_WORK,
			},
		)
	}
	fn compound_0_at(value: Argument, budget: &mut DecodeBudget) -> Result<Compound0, Error> {
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
	fn compound_1(value: Argument) -> Result<Compound1, Error> {
		compound_1_at(
			value,
			&mut DecodeBudget {
				remaining: MAX_REPLY_WORK,
			},
		)
	}
	fn compound_1_at(value: Argument, budget: &mut DecodeBudget) -> Result<Compound1, Error> {
		budget.step()?;
		let Argument::List(values) = value else {
			return Err(Error::InvalidReply);
		};
		if values.len() as u128 > 2u128 {
			return Err(Error::InvalidReply);
		}
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
	fn compound_2(value: Argument) -> Result<Compound2, Error> {
		compound_2_at(
			value,
			&mut DecodeBudget {
				remaining: MAX_REPLY_WORK,
			},
		)
	}
	fn compound_2_at(value: Argument, budget: &mut DecodeBudget) -> Result<Compound2, Error> {
		budget.step()?;
		let Argument::List(values) = value else {
			return Err(Error::InvalidReply);
		};
		if values.len() != 3 {
			return Err(Error::InvalidReply);
		}
		let mut fields = values.into_iter();
		Ok((
			{
				budget.step()?;
				bytes_2_2(fields.next().ok_or(Error::InvalidReply)?)
			}?,
			{
				budget.step()?;
				capability(fields.next().ok_or(Error::InvalidReply)?)
			}?,
			{
				budget.step()?;
				boolean(fields.next().ok_or(Error::InvalidReply)?)
			}?,
		))
	}
	fn compound_3(value: Argument) -> Result<Compound3, Error> {
		compound_3_at(
			value,
			&mut DecodeBudget {
				remaining: MAX_REPLY_WORK,
			},
		)
	}
	fn compound_3_at(value: Argument, budget: &mut DecodeBudget) -> Result<Compound3, Error> {
		budget.step()?;
		let Argument::List(values) = value else {
			return Err(Error::InvalidReply);
		};
		if !values.is_empty() {
			return Err(Error::InvalidReply);
		}
		Ok(())
	}
	fn compound_4(value: Argument) -> Result<Compound4, Error> {
		compound_4_at(
			value,
			&mut DecodeBudget {
				remaining: MAX_REPLY_WORK,
			},
		)
	}
	fn compound_4_at(value: Argument, budget: &mut DecodeBudget) -> Result<Compound4, Error> {
		budget.step()?;
		let Argument::List(values) = value else {
			return Err(Error::InvalidReply);
		};
		if values.len() > budget.remaining / 4 {
			return Err(Error::ResourceLimit);
		}
		let mut result = Vec::with_capacity(values.len());
		for value in values {
			result.push(compound_5_at(value, budget)?);
		}
		Ok(result)
	}
	fn compound_5_at(value: Argument, budget: &mut DecodeBudget) -> Result<Compound5, Error> {
		budget.step()?;
		let Argument::List(values) = value else {
			return Err(Error::InvalidReply);
		};
		if values.len() != 3 {
			return Err(Error::InvalidReply);
		}
		let mut fields = values.into_iter();
		Ok((
			{
				budget.step()?;
				symbol(fields.next().ok_or(Error::InvalidReply)?)
			}?,
			{
				budget.step()?;
				capability(fields.next().ok_or(Error::InvalidReply)?)
			}?,
			{
				budget.step()?;
				Ok::<_, Error>(fields.next().ok_or(Error::InvalidReply)?)
			}?,
		))
	}

	pub fn call_0(session: &Session, target: impl AsSendTarget) -> Pending<Compound0> {
		let raw = session.send(target, "list", &[]);
		Pending::new(raw, compound_0)
	}

	pub fn call_1(session: &Session, target: impl AsSendTarget) -> Pending<Compound1> {
		let raw = session.send(target, "limited", &[]);
		Pending::new(raw, compound_1)
	}

	pub fn call_2(session: &Session, target: impl AsSendTarget) -> Pending<Compound2> {
		let raw = session.send(target, "tuple", &[]);
		Pending::new(raw, compound_2)
	}

	pub fn call_3(session: &Session, target: impl AsSendTarget) -> Pending<Compound3> {
		let raw = session.send(target, "zero", &[]);
		Pending::new(raw, compound_3)
	}

	pub fn call_4(session: &Session, target: impl AsSendTarget) -> Pending<Compound4> {
		let raw = session.send(target, "nested", &[]);
		Pending::new(raw, compound_4)
	}
}
