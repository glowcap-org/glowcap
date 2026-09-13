//! Prepared application work has no transport dependency. A wire caller lends
//! a resolver; a local caller observes the same supervised operation directly.
use super::{Platform, error::Error, facet::Facet};
use std::{future::Future, pin::Pin};

pub struct Prepared<T>(Pin<Box<dyn Future<Output = Result<T, Error>>>>);
pub type Revision = Prepared<u64>;
impl<T: 'static> Prepared<T> {
	pub(super) fn new(work: impl Future<Output = Result<T, Error>> + 'static) -> Self {
		Self(Box::pin(work))
	}
	pub(super) fn ready(revision: T) -> Self {
		Self::new(async move { Ok(revision) })
	}
	pub(super) fn wire_with<P: Platform>(
		self,
		facet: &Facet<P>,
		verb: &'static str,
		encode: impl FnOnce(T) -> Result<glowcap::Argument, Error> + 'static,
	) -> Result<glowcap::Argument, Error> {
		facet.answer(verb, async move { encode(self.0.await?) })
	}
	pub(super) fn start<P: Platform>(self, facet: &Facet<P>) -> Result<Completion<T>, Error> {
		facet.require_live()?;
		let (send, receive) = tokio::sync::oneshot::channel();
		let report = facet.0.report.clone();
		facet.0.answers.spawn(async move {
			if let Err(Err(cause)) = send.send(self.0.await) {
				report(super::notice::Notice::AnswerUndeliverable {
					verb: "local-session",
					cause,
				});
			}
		})?;
		Ok(Completion(receive))
	}
}
/// Dropping observation leaves the admitted command with the session owner.
pub struct Completion<T = u64>(tokio::sync::oneshot::Receiver<Result<T, Error>>);
impl<T> Completion<T> {
	pub async fn wait(self) -> Result<T, Error> {
		self.0
			.await
			.map_err(|_| Error::closed("Rooms session retired before command completion"))?
	}
}

impl Prepared<u64> {
	pub(super) fn admitted(admission: crate::session::commands::Admission<u64>) -> Self {
		Self::new(async move { admission.send()?.wait().await })
	}
	pub(super) fn wire<P: Platform>(self, facet: &Facet<P>, verb: &'static str) -> Result<glowcap::Argument, Error> {
		facet.answer(
			verb,
			async move { Ok(glowcap::Argument::Integer(self.0.await? as i64)) },
		)
	}
}
