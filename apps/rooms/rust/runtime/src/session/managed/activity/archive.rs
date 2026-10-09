//! Archive status follows exact selected custody, independently of chat writes.
use super::*;
use serde_json::json;

impl<P: Tasks + Deadline + Clone + 'static> Activity<P> {
	pub(in crate::session::managed) fn archive_ended(
		self: &Rc<Self>,
		source: Ref,
		archive: custody::FieldKey<custody::ArchiveAccess>,
	) -> Result<()> {
		self.push(Event {
			data: json!({"target":{"kind":"archive","id":archive},"notice":{"kind":"unavailable"}}).to_string(),
			history: History::None.into(),
			origin: Origin::Archive { source, archive },
			files: Vec::new(),
			incoming: None,
			line: None,
			charge: None,
		})
		.map_err(loam::refusal)
	}
}
