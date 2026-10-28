use glowcap::{Argument, Ref, RemotePromise};
use std::{
	future::{Future, IntoFuture},
	pin::Pin,
	task::{Context, Poll},
};
#[derive(Debug)]
pub enum Error {
	InvalidArgument,
	InvalidSequence,
	InvalidReply,
	Runtime(glowcap::Error),
}
impl From<glowcap::Error> for Error {
	fn from(error: glowcap::Error) -> Self {
		Self::Runtime(error)
	}
}
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
fn capability(value: Argument) -> Result<Ref, Error> {
	Ref::try_from(&value).map_err(|_| Error::InvalidReply)
}
