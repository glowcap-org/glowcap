//! The method names a Rooms session facet answers. The browser's
//! `lib/session/verbs.ts` names the same methods for the attaching side. This
//! is the one Rust authority for them, shared by host and Wasm owners.

macro_rules! methods {
	($($variant:ident => $constant:ident = $name:literal;)*) => {
		$(pub const $constant: &str = $name;)*
		#[derive(Clone, Copy, Debug, PartialEq, Eq)]
		pub enum Method { $($variant,)* }
		impl Method {
			pub const ALL: &'static [Self] = &[$(Self::$variant,)*];
			pub const fn name(self) -> &'static str { match self { $(Self::$variant => $constant,)* } }
			pub fn parse(name: &str) -> Option<Self> { match name { $($constant => Some(Self::$variant),)* _ => None } }
		}
	};
}
methods! {
	Snapshot => SNAPSHOT = "snapshot";
	Watch => WATCH = "watch";
	ReplaceCheckpoint => REPLACE_CHECKPOINT = "replaceCheckpoint";
	AdoptWorkspace => ADOPT_WORKSPACE = "adoptWorkspace";
	Command => COMMAND = "command";
	Typing => TYPING = "typing";
	SendFiles => SEND_FILES = "sendFiles";
	RefileLine => REFILE_LINE = "refileLine";
	RoomBridgeForm => ROOM_BRIDGE_FORM = "roomBridgeForm";
	ReadHistory => READ_HISTORY = "readHistory";
	ReadHistoryView => READ_HISTORY_VIEW = "readHistoryView";
	ArchivedAttachment => ARCHIVED_ATTACHMENT = "archivedAttachment";
	ResolveEffect => RESOLVE_EFFECT = "resolveEffect";
	ResumeEffect => RESUME_EFFECT = "resumeEffect";
	Facet => FACET = "facet";
	Revoke => REVOKE = "revoke";
	OperatorSnapshot => OPERATOR_SNAPSHOT = "operatorSnapshot";
	OperatorPage => OPERATOR_PAGE = "operatorPage";
	OperatorRetire => OPERATOR_RETIRE = "operatorRetire";
	OperationsSnapshot => OPERATIONS_SNAPSHOT = "operationsSnapshot";
	ShareArchive => SHARE_ARCHIVE = "shareArchive";
	OfferDurableArchive => OFFER_DURABLE_ARCHIVE = "offerDurableArchive";
	ReadArchiveShare => READ_ARCHIVE_SHARE = "readArchiveShare";
	DropArchiveShare => DROP_ARCHIVE_SHARE = "dropArchiveShare";
	ListArchiveShares => LIST_ARCHIVE_SHARES = "listArchiveShares";
	RevokeArchiveShare => REVOKE_ARCHIVE_SHARE = "revokeArchiveShare";
}

/// The method a shared attachment or archived file proxy answers.
pub const READ: &str = "read";
