// Generated from checked interface descriptions.
pub use __glowcap::Error;
pub use __glowcap::Observation;
pub use __glowcap::Pending;
pub use __glowcap::call_0 as bool_call;
pub use __glowcap::call_1 as bool_optional;
pub use __glowcap::call_2 as bool_tell;
pub use __glowcap::call_3 as bool_optional_tell;
pub use __glowcap::call_4 as bytes_call;
pub use __glowcap::call_5 as bytes_optional;
pub use __glowcap::call_6 as bytes_tell;
pub use __glowcap::call_7 as bytes_optional_tell;
pub use __glowcap::call_8 as bounded_call;
pub use __glowcap::call_9 as bounded_optional;
pub use __glowcap::call_10 as bounded_tell;
pub use __glowcap::call_11 as bounded_optional_tell;
pub use __glowcap::call_12 as symbol_call;
pub use __glowcap::call_13 as symbol_optional;
pub use __glowcap::call_14 as symbol_tell;
pub use __glowcap::call_15 as symbol_optional_tell;
pub use __glowcap::call_16 as float_call;
pub use __glowcap::call_17 as float_optional;
pub use __glowcap::call_18 as float_tell;
pub use __glowcap::call_19 as float_optional_tell;
pub use __glowcap::call_20 as error_call;
pub use __glowcap::call_21 as error_optional;
pub use __glowcap::call_22 as error_tell;
pub use __glowcap::call_23 as error_optional_tell;

mod __glowcap {
	use glowcap::Argument;
	use glowcap::AsSendTarget;
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
	// Presence is fixed stack scratch. A missing optional argument ends the supplied
	// prefix; a later Some is refused before arguments acquire wire custody.
	fn optional_argument_count(present: &[bool]) -> Result<usize, Error> {
		let count = present.iter().take_while(|value| **value).count();
		if present[count..].iter().any(|value| *value) {
			return Err(Error::InvalidArgument);
		}
		Ok(count)
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
	fn float64(value: Argument) -> Result<f64, Error> {
		if let Argument::Float(value) = value {
			Ok(value)
		} else {
			Err(Error::InvalidReply)
		}
	}
	fn error_value(value: Argument) -> Result<String, Error> {
		if let Argument::Error(value) = value {
			Ok(value)
		} else {
			Err(Error::InvalidReply)
		}
	}
	fn bytes_1_4(value: Argument) -> Result<Vec<u8>, Error> {
		let value = bytes(value)?;
		if !(1u128..=4u128).contains(&(value.len() as u128)) {
			Err(Error::InvalidReply)
		} else {
			Ok(value)
		}
	}

	pub fn call_0(session: &Session, target: impl AsSendTarget, arg0: bool) -> Pending<bool> {
		let raw = session.send(target, "bool_call", &[arg0.into()]);
		Pending::new(raw, boolean)
	}

	pub fn call_1(
		session: &Session,
		target: impl AsSendTarget,
		// Omit only a trailing suffix of these arguments.
		arg0: Option<bool>,
	) -> Result<Pending<bool>, Error> {
		let count = optional_argument_count(&[arg0.is_some()])?;
		let arguments = [
			// Fixed stack scratch; omitted slots are outside the sent prefix.
			arg0.map(Argument::from).unwrap_or(Argument::Void),
		];
		let raw = session.send(target, "bool_optional", &arguments[..count]);
		Ok(Pending::new(raw, boolean))
	}

	pub fn call_2(session: &Session, target: impl AsSendTarget, arg0: bool) -> Result<(), Error> {
		let result = session.tell(target, "bool_tell", &[arg0.into()]);
		result.map_err(Error::Runtime)
	}

	pub fn call_3(
		session: &Session,
		target: impl AsSendTarget,
		// Omit only a trailing suffix of these arguments.
		arg0: Option<bool>,
	) -> Result<(), Error> {
		let count = optional_argument_count(&[arg0.is_some()])?;
		let arguments = [
			// Fixed stack scratch; omitted slots are outside the sent prefix.
			arg0.map(Argument::from).unwrap_or(Argument::Void),
		];
		let result = session.tell(target, "bool_optional_tell", &arguments[..count]);
		result.map_err(Error::Runtime)
	}

	pub fn call_4(session: &Session, target: impl AsSendTarget, arg0: Vec<u8>) -> Pending<Vec<u8>> {
		let raw = session.send(target, "bytes_call", &[arg0.into()]);
		Pending::new(raw, bytes)
	}

	pub fn call_5(
		session: &Session,
		target: impl AsSendTarget,
		// Omit only a trailing suffix of these arguments.
		arg0: Option<Vec<u8>>,
	) -> Result<Pending<Vec<u8>>, Error> {
		let count = optional_argument_count(&[arg0.is_some()])?;
		let arguments = [
			// Fixed stack scratch; omitted slots are outside the sent prefix.
			arg0.map(Argument::Bytes).unwrap_or(Argument::Void),
		];
		let raw = session.send(target, "bytes_optional", &arguments[..count]);
		Ok(Pending::new(raw, bytes))
	}

	pub fn call_6(session: &Session, target: impl AsSendTarget, arg0: Vec<u8>) -> Result<(), Error> {
		let result = session.tell(target, "bytes_tell", &[arg0.into()]);
		result.map_err(Error::Runtime)
	}

	pub fn call_7(
		session: &Session,
		target: impl AsSendTarget,
		// Omit only a trailing suffix of these arguments.
		arg0: Option<Vec<u8>>,
	) -> Result<(), Error> {
		let count = optional_argument_count(&[arg0.is_some()])?;
		let arguments = [
			// Fixed stack scratch; omitted slots are outside the sent prefix.
			arg0.map(Argument::Bytes).unwrap_or(Argument::Void),
		];
		let result = session.tell(target, "bytes_optional_tell", &arguments[..count]);
		result.map_err(Error::Runtime)
	}

	pub fn call_8(session: &Session, target: impl AsSendTarget, arg0: Vec<u8>) -> Result<Pending<Vec<u8>>, Error> {
		if !(1u128..=4u128).contains(&(arg0.len() as u128)) {
			return Err(Error::InvalidArgument);
		}
		let raw = session.send(target, "bounded_call", &[arg0.into()]);
		Ok(Pending::new(raw, bytes_1_4))
	}

	pub fn call_9(
		session: &Session,
		target: impl AsSendTarget,
		// Omit only a trailing suffix of these arguments.
		arg0: Option<Vec<u8>>,
	) -> Result<Pending<Vec<u8>>, Error> {
		if let Some(value) = arg0.as_ref()
			&& !(1u128..=4u128).contains(&(value.len() as u128))
		{
			return Err(Error::InvalidArgument);
		}
		let count = optional_argument_count(&[arg0.is_some()])?;
		let arguments = [
			// Fixed stack scratch; omitted slots are outside the sent prefix.
			arg0.map(Argument::Bytes).unwrap_or(Argument::Void),
		];
		let raw = session.send(target, "bounded_optional", &arguments[..count]);
		Ok(Pending::new(raw, bytes_1_4))
	}

	pub fn call_10(session: &Session, target: impl AsSendTarget, arg0: Vec<u8>) -> Result<(), Error> {
		if !(1u128..=4u128).contains(&(arg0.len() as u128)) {
			return Err(Error::InvalidArgument);
		}
		let result = session.tell(target, "bounded_tell", &[arg0.into()]);
		result.map_err(Error::Runtime)
	}

	pub fn call_11(
		session: &Session,
		target: impl AsSendTarget,
		// Omit only a trailing suffix of these arguments.
		arg0: Option<Vec<u8>>,
	) -> Result<(), Error> {
		if let Some(value) = arg0.as_ref()
			&& !(1u128..=4u128).contains(&(value.len() as u128))
		{
			return Err(Error::InvalidArgument);
		}
		let count = optional_argument_count(&[arg0.is_some()])?;
		let arguments = [
			// Fixed stack scratch; omitted slots are outside the sent prefix.
			arg0.map(Argument::Bytes).unwrap_or(Argument::Void),
		];
		let result = session.tell(target, "bounded_optional_tell", &arguments[..count]);
		result.map_err(Error::Runtime)
	}

	pub fn call_12(session: &Session, target: impl AsSendTarget, arg0: String) -> Pending<String> {
		let raw = session.send(target, "symbol_call", &[Argument::Symbol(arg0)]);
		Pending::new(raw, symbol)
	}

	pub fn call_13(
		session: &Session,
		target: impl AsSendTarget,
		// Omit only a trailing suffix of these arguments.
		arg0: Option<String>,
	) -> Result<Pending<String>, Error> {
		let count = optional_argument_count(&[arg0.is_some()])?;
		let arguments = [
			// Fixed stack scratch; omitted slots are outside the sent prefix.
			arg0.map(Argument::Symbol).unwrap_or(Argument::Void),
		];
		let raw = session.send(target, "symbol_optional", &arguments[..count]);
		Ok(Pending::new(raw, symbol))
	}

	pub fn call_14(session: &Session, target: impl AsSendTarget, arg0: String) -> Result<(), Error> {
		let result = session.tell(target, "symbol_tell", &[Argument::Symbol(arg0)]);
		result.map_err(Error::Runtime)
	}

	pub fn call_15(
		session: &Session,
		target: impl AsSendTarget,
		// Omit only a trailing suffix of these arguments.
		arg0: Option<String>,
	) -> Result<(), Error> {
		let count = optional_argument_count(&[arg0.is_some()])?;
		let arguments = [
			// Fixed stack scratch; omitted slots are outside the sent prefix.
			arg0.map(Argument::Symbol).unwrap_or(Argument::Void),
		];
		let result = session.tell(target, "symbol_optional_tell", &arguments[..count]);
		result.map_err(Error::Runtime)
	}

	pub fn call_16(session: &Session, target: impl AsSendTarget, arg0: f64) -> Pending<f64> {
		let raw = session.send(target, "float_call", &[arg0.into()]);
		Pending::new(raw, float64)
	}

	pub fn call_17(
		session: &Session,
		target: impl AsSendTarget,
		// Omit only a trailing suffix of these arguments.
		arg0: Option<f64>,
	) -> Result<Pending<f64>, Error> {
		let count = optional_argument_count(&[arg0.is_some()])?;
		let arguments = [
			// Fixed stack scratch; omitted slots are outside the sent prefix.
			arg0.map(Argument::from).unwrap_or(Argument::Void),
		];
		let raw = session.send(target, "float_optional", &arguments[..count]);
		Ok(Pending::new(raw, float64))
	}

	pub fn call_18(session: &Session, target: impl AsSendTarget, arg0: f64) -> Result<(), Error> {
		let result = session.tell(target, "float_tell", &[arg0.into()]);
		result.map_err(Error::Runtime)
	}

	pub fn call_19(
		session: &Session,
		target: impl AsSendTarget,
		// Omit only a trailing suffix of these arguments.
		arg0: Option<f64>,
	) -> Result<(), Error> {
		let count = optional_argument_count(&[arg0.is_some()])?;
		let arguments = [
			// Fixed stack scratch; omitted slots are outside the sent prefix.
			arg0.map(Argument::from).unwrap_or(Argument::Void),
		];
		let result = session.tell(target, "float_optional_tell", &arguments[..count]);
		result.map_err(Error::Runtime)
	}

	pub fn call_20(session: &Session, target: impl AsSendTarget, arg0: String) -> Pending<String> {
		let raw = session.send(target, "error_call", &[Argument::Error(arg0)]);
		Pending::new(raw, error_value)
	}

	pub fn call_21(
		session: &Session,
		target: impl AsSendTarget,
		// Omit only a trailing suffix of these arguments.
		arg0: Option<String>,
	) -> Result<Pending<String>, Error> {
		let count = optional_argument_count(&[arg0.is_some()])?;
		let arguments = [
			// Fixed stack scratch; omitted slots are outside the sent prefix.
			arg0.map(Argument::Error).unwrap_or(Argument::Void),
		];
		let raw = session.send(target, "error_optional", &arguments[..count]);
		Ok(Pending::new(raw, error_value))
	}

	pub fn call_22(session: &Session, target: impl AsSendTarget, arg0: String) -> Result<(), Error> {
		let result = session.tell(target, "error_tell", &[Argument::Error(arg0)]);
		result.map_err(Error::Runtime)
	}

	pub fn call_23(
		session: &Session,
		target: impl AsSendTarget,
		// Omit only a trailing suffix of these arguments.
		arg0: Option<String>,
	) -> Result<(), Error> {
		let count = optional_argument_count(&[arg0.is_some()])?;
		let arguments = [
			// Fixed stack scratch; omitted slots are outside the sent prefix.
			arg0.map(Argument::Error).unwrap_or(Argument::Void),
		];
		let result = session.tell(target, "error_optional_tell", &arguments[..count]);
		result.map_err(Error::Runtime)
	}
}
