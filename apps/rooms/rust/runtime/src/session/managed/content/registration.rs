//! The managed session's complete method and graph declaration.
use super::*;

pub(in crate::session::managed) fn registration<P: Tasks + Deadline + Clone + 'static>(
	owner: Weak<State<P>>,
) -> Registration {
	Registration {
		schema: session::records::WORKSPACE.id,
		version: u32::from(session::VERSION),
		methods: [
			("initialize", Retry::Receipt),
			("retire-host-registrations", Retry::Receipt),
			("snapshot", Retry::ReadOnly),
			("activity-reader", Retry::ReadOnly),
			("activity-file", Retry::ReadOnly),
			("activity-recipe", Retry::ReadOnly),
			("retain-incoming", Retry::Idempotent),
			("acquire-activity", Retry::Receipt),
			("resource-key", Retry::ReadOnly),
			("bridge-witnesses", Retry::ReadOnly),
			("submit-bridge", Retry::Idempotent),
			("bridge-reapplication", Retry::ReadOnly),
			("forget-bridge", Retry::Receipt),
			("check-inbox", Retry::ReadOnly),
			("observe-direct-connection", Retry::ReadOnly),
			("observe-archive-connection", Retry::ReadOnly),
			("record-inbox", Retry::ReadOnly),
			("retire-room-authority", Retry::Idempotent),
			("check-outgoing-line", Retry::ReadOnly),
			("accept-direct-introduction", Retry::Idempotent),
			("adopt-direct-route", Retry::Idempotent),
			("restore-custody", Retry::ReadOnly),
			("archive-reader", Retry::ReadOnly),
			("custody-recipe", Retry::ReadOnly),
			("export-configuration", Retry::ReadOnly),
			("archive-issuer-reader", Retry::ReadOnly),
			("operations-reader", Retry::ReadOnly),
			("trace-snapshot", Retry::ReadOnly),
			("room-identity-reader", Retry::ReadOnly),
			("room-publication-identity", Retry::ReadOnly),
			("workspace-history-reader", Retry::ReadOnly),
			("history-reader", Retry::ReadOnly),
			("bridge-form-reader", Retry::ReadOnly),
			("file-reader", Retry::ReadOnly),
			("directory-reader", Retry::ReadOnly),
			("resynchronize-discovery", Retry::ReadOnly),
			("check-discovery", Retry::ReadOnly),
			("discovery-selected", Retry::ReadOnly),
			("typing-sender", Retry::ReadOnly),
			("signaling-route", Retry::ReadOnly),
			("signaling-selected", Retry::ReadOnly),
			("import", Retry::Idempotent),
			("import-bundle", Retry::Idempotent),
			("acquire-workspace", Retry::Idempotent),
			("import-result", Retry::Idempotent),
			("acquire-result-workspace", Retry::Idempotent),
			("acquire-created-room", Retry::Idempotent),
			("release", Retry::Receipt),
			("replaceWorkspace", Retry::Receipt),
			// Command IDs, exact source and canonical intent select atomic
			// application receipts. A second endpoint sequence both duplicates
			// that custody and races independent membership and UI preparations.
			("command", Retry::Idempotent),
			// Upload receipts retain their exact live sources and original base.
			// A generic mutation receipt only captures durable input capabilities.
			("sendFiles", Retry::Idempotent),
			("refileLine", Retry::Idempotent),
			("effect-status", Retry::ReadOnly),
			("effect-inventory", Retry::ReadOnly),
			("effect-intent", Retry::ReadOnly),
			("effect-adopted", Retry::ReadOnly),
			("resume-effect", Retry::Idempotent),
			// A retried release finds its receipt already gone and answers done.
			("release-effect", Retry::Idempotent),
			("effect-result", Retry::ReadOnly),
			("effect-reader", Retry::ReadOnly),
			("settle-effect", Retry::Idempotent),
			("settle-history-erasure", Retry::Idempotent),
			("retention-intent", Retry::ReadOnly),
		]
		.into_iter()
		.map(|(verb, retry)| Method {
			verb: verb.into(),
			retry,
		})
		.collect(),
		graph: Some(Graph {
			requirement_verbs: vec![
				"typing-sender".into(),
				"signaling-route".into(),
				"effect-intent".into(),
				"effect-adopted".into(),
			],
			schemas: session::records::SCHEMAS
				.iter()
				.map(|schema| PageSchema {
					id: schema.id,
					version: schema.version,
				})
				.collect(),
			max_pages: session::records::MAX_PAGES - 1,
			max_payload_bytes: custody::MAX_AUTHORITY_BYTES,
			max_edges: session::records::MAX_PAGES * 2
				+ custody::MAX_CUSTODY_FIELDS
				+ custody::MAX_EFFECTS * (1 + custody::MAX_TARGET_FIELDS + custody::MAX_RESULT_FIELDS),
		}),
		content: Box::new(SessionContent(owner)),
	}
}
