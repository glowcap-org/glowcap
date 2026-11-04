// Generated from checked interface descriptions.
pub use __glowcap_2::Error;
pub use __glowcap_2::Observation;
pub use __glowcap_2::Pending;
pub use __glowcap_2::Reference;
pub use __glowcap_2::call_0 as text;
pub use __glowcap_2::call_1 as __glowcap;
pub use __glowcap_2::call_2 as __glowcap_1;
pub use __glowcap_2::call_3 as call_0;
pub use __glowcap_2::call_4 as Session;
pub use __glowcap_2::call_5 as Ref;
pub use __glowcap_2::call_6 as capability;
pub use __glowcap_2::call_7 as nothing;
pub use __glowcap_2::call_8 as text_1_4096;
pub use __glowcap_2::call_9 as integer_p0_p256;

mod __glowcap_2 {
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
	/// A borrowed reference argument, lowered synchronously before the send returns.
	/// It never owns an independent pending reference across a suspension.
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
	fn nothing(value: Argument) -> Result<(), Error> {
		if matches!(value, Argument::Void) {
			Ok(())
		} else {
			Err(Error::InvalidReply)
		}
	}
	fn integer(value: Argument) -> Result<i64, Error> {
		value.as_i64().ok_or(Error::InvalidReply)
	}
	fn text_1_4096(value: Argument) -> Result<String, Error> {
		let value = text(value)?;
		if !(1u128..=4096u128).contains(&(value.len() as u128)) {
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

	pub fn call_0(session: &Session, target: impl AsSendTarget) -> Pending<String> {
		let raw = session.send(target, "read", &[]);
		Pending::new(raw, text)
	}

	pub fn call_1(session: &Session, target: impl AsSendTarget) -> Pending<String> {
		let raw = session.send(target, "read", &[]);
		Pending::new(raw, text)
	}

	pub fn call_2(session: &Session, target: impl AsSendTarget) -> Pending<String> {
		let raw = session.send(target, "read", &[]);
		Pending::new(raw, text)
	}

	pub fn call_3(session: &Session, target: impl AsSendTarget) -> Pending<String> {
		let raw = session.send(target, "read", &[]);
		Pending::new(raw, text)
	}

	pub fn call_4(session: &Session, target: impl AsSendTarget) -> Pending<String> {
		let raw = session.send(target, "read", &[]);
		Pending::new(raw, text)
	}

	pub fn call_5(session: &Session, target: impl AsSendTarget) -> Pending<String> {
		let raw = session.send(target, "read", &[]);
		Pending::new(raw, text)
	}

	pub fn call_6<'a>(session: &Session, target: impl AsSendTarget, arg0: impl Into<Reference<'a>>) -> Pending<Ref> {
		let raw = session.send(target, "open", &[arg0.into().argument()]);
		Pending::new(raw, capability)
	}

	pub fn call_7<'a>(session: &Session, target: impl AsSendTarget, arg0: impl Into<Reference<'a>>) -> Pending<()> {
		let raw = session.send(target, "push", &[arg0.into().argument()]);
		Pending::new(raw, nothing)
	}

	pub fn call_8(session: &Session, target: impl AsSendTarget) -> Pending<String> {
		let raw = session.send(target, "text", &[]);
		Pending::new(raw, text_1_4096)
	}

	pub fn call_9(session: &Session, target: impl AsSendTarget) -> Pending<i64> {
		let raw = session.send(target, "count", &[]);
		Pending::new(raw, integer_p0_p256)
	}
}
