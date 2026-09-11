//! The method names a Rooms session facet answers. The browser's
//! `lib/session/verbs.ts` names the same methods for the attaching side; this
//! is the one Rust authority for them, shared by native and Wasm owners.

pub const SNAPSHOT: &str = "snapshot";
pub const WATCH: &str = "watch";
pub const REPLACE_CHECKPOINT: &str = "replaceCheckpoint";
pub const ADOPT_WORKSPACE: &str = "adoptWorkspace";
pub const COMMAND: &str = "command";
pub const TYPING: &str = "typing";
pub const SEND_FILES: &str = "sendFiles";
pub const REFILE_LINE: &str = "refileLine";
pub const ROOM_BRIDGE_FORM: &str = "roomBridgeForm";
pub const READ_HISTORY: &str = "readHistory";
pub const READ_HISTORY_VIEW: &str = "readHistoryView";
pub const ARCHIVED_ATTACHMENT: &str = "archivedAttachment";
pub const RESOLVE_EFFECT: &str = "resolveEffect";
pub const RESUME_EFFECT: &str = "resumeEffect";
pub const FACET: &str = "facet";
pub const REVOKE: &str = "revoke";
pub const OPERATOR_SNAPSHOT: &str = "operatorSnapshot";
pub const OPERATOR_PAGE: &str = "operatorPage";
pub const OPERATOR_RETIRE: &str = "operatorRetire";
pub const OPERATIONS_SNAPSHOT: &str = "operationsSnapshot";
pub const SHARE_ARCHIVE: &str = "shareArchive";
pub const OFFER_DURABLE_ARCHIVE: &str = "offerDurableArchive";
pub const READ_ARCHIVE_SHARE: &str = "readArchiveShare";
pub const DROP_ARCHIVE_SHARE: &str = "dropArchiveShare";
pub const LIST_ARCHIVE_SHARES: &str = "listArchiveShares";
pub const REVOKE_ARCHIVE_SHARE: &str = "revokeArchiveShare";

/// The method a shared attachment or archived file proxy answers.
pub const READ: &str = "read";
