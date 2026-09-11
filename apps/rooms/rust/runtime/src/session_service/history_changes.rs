//! Archive commitment invalidates history independently of live membership or
//! receipt observers. Subscribe before exposing the session's watch capability.
use super::{error::Error, facet::Facet, Platform, Stop};
use rooms_application::archive::change::Change;
use tokio::sync::broadcast::{error::RecvError, Receiver};

pub(super) async fn forward<P: Platform>(
	facet: Facet<P>,
	mut changes: Receiver<Change>,
	mut stop: Stop,
) -> Result<(), Error> {
	loop {
		if *stop.borrow() {
			return Ok(());
		}
		let change = tokio::select! {
			_ = stop.changed() => return Ok(()),
			change = changes.recv() => match change {
				Ok(change) => change,
				Err(RecvError::Lagged(_)) => Change::All,
				Err(RecvError::Closed) => return Ok(()),
			},
		};
		facet.views().history_changed(&change);
		facet
			.0
			.local_views
			.deliver(&facet.0.report, |view| view.history_changed(&change));
	}
}
