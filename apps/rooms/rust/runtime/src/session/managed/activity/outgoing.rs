//! Reserve the sender event before remote dispatch. Publish after settlement.
use super::*;
use rooms_application::{content::session::outgoing, room::message::ChangeKind};
use serde_json::json;

impl<P: Tasks + Deadline + Clone + 'static> Activity<P> {
	/// One immutable event reserves encoded presentation, file actors and the
	/// journal's byte charge before dispatch. Capture lends this same source and
	/// file vector to recording. No second attachment population is retained.
	/// After private settlement the journal owns it, under its existing count and
	/// byte limits. Queued reads recheck the original source and line custody.
	pub(in crate::session::managed) fn prepare_outgoing(
		self: &Rc<Self>,
		source: Ref,
		origin: &outgoing::Origin,
		text: &str,
		change: ChangeKind,
		files: Vec<Attachment<Ref>>,
		operation: Option<&str>,
	) -> Result<PreparedEvent<P>> {
		self.reserve(
			Event {
				data: json!({"target":{"kind":"direct","id":origin.conversation},"notice":{
					"kind":"line","from":origin.from,"text":text,"metadata":{"operation":operation},
					"marker":{"id":origin.id.get(),"change":change.event_change()},
					"previewUrls":origin.previews.urls()
				}})
				.to_string(),
				history: History::Reserved.into(),
				origin: Origin::Outgoing {
					source,
					line: origin.line,
				},
				files,
				incoming: None,
				line: None,
				charge: None,
			},
			true,
		)
		.map_err(loam::refusal)
	}
}
impl<P: Tasks> PreparedEvent<P> {
	pub(in crate::session::managed) fn record(&self, history: Option<rooms_application::archive::Coordinates>) {
		*self.event.history.borrow_mut() = history.map_or(History::None, History::Recorded);
	}
	pub(in crate::session::managed) fn publish(self) {
		self.commit();
	}
}
