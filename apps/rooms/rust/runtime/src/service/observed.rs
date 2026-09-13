use super::{Platform, facet::Facet};
use crate::{session::commands::SessionEvents, session::state::SessionView};
use rooms_application::session::{
	checkpoint::{commands::Facts, reconciliation::Fact},
	state::Change,
};
use std::future::Future;
/// Session events widened with the facet's attached views: every committed
/// boundary the runtime learns of is also a snapshot the views receive.
pub(super) struct Observed<E, P: Platform> {
	pub(super) runtime: E,
	pub(super) facet: Facet<P>,
}
impl<E: SessionEvents, P: Platform> SessionEvents for Observed<E, P> {
	fn preparing(
		&mut self,
		checkpoint: &rooms_application::session::checkpoint::Checkpoint,
	) -> impl Future<Output = Result<impl Sized + 'static, crate::Error>> {
		self.runtime.preparing(checkpoint)
	}

	fn facts(&self) -> impl Facts + '_ {
		self.runtime.facts()
	}
	fn changed(&mut self, change: Change, view: &SessionView) {
		self.runtime.changed(change, view);
		self.facet.notify_now();
	}
	fn settled(&mut self, view: &SessionView) -> impl Future<Output = Result<(), crate::Error>> {
		let checkpoint = view
			.read(|state| state.checkpoint_handle())
			.map_err(crate::Error::from)
			.and_then(|result| result.map_err(crate::Error::from));
		let settled = self.runtime.settled(view);
		let custody = self.facet.0.bridge_secrets.clone();
		async move {
			settled.await?;
			custody.retain(checkpoint?.as_ref()).await
		}
	}
	fn reconciliation_issue(&mut self, fact: &Fact, error: Option<&str>) {
		self.runtime.reconciliation_issue(fact, error);
		self.facet.notify_now();
	}
}
