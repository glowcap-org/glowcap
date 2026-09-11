// Wire names the session client re-exports, kept apart from the modules that
// ask them so neither has to import the client back.

export const ROOMS_SESSION_OPERATOR_SNAPSHOT = "operatorSnapshot";
export const ROOMS_SESSION_OPERATOR_PAGE = "operatorPage";
export const ROOMS_SESSION_OPERATOR_RETIRE = "operatorRetire";

export const ROOMS_SESSION_FACET = "facet";
export const ROOMS_SESSION_REVOKE = "revoke";

export const ROOMS_SESSION_RESOLVE_EFFECT = "resolveEffect";
export const ROOMS_SESSION_RESUME_EFFECT = "resumeEffect";

export const ROOMS_SESSION_SNAPSHOT = "snapshot";
export const ROOMS_SESSION_WATCH = "watch";
export const ROOMS_SESSION_REPLACE = "replaceCheckpoint";
export const ROOMS_SESSION_ADOPT_WORKSPACE = "adoptWorkspace";
export const ROOMS_SESSION_COMMAND = "command";
export const ROOMS_SESSION_CHANGED = "changed";
export const ROOMS_SESSION_EVENT = "event";
export const ROOMS_SESSION_FILES = "sendFiles";
export const ROOMS_SESSION_REFILE = "refileLine";
export const ROOMS_SESSION_BRIDGE_FORM = "roomBridgeForm";
export const ROOMS_SESSION_HISTORY = "readHistory";
export const ROOMS_SESSION_HISTORY_VIEW = "readHistoryView";
export const ROOMS_SESSION_ARCHIVED_ATTACHMENT = "archivedAttachment";
export const ROOMS_SESSION_OPERATIONS_CHANGED = "operationsChanged";
export const ROOMS_SESSION_HISTORY_CHANGED = "historyChanged";
export const ROOMS_SESSION_OPERATIONS_SNAPSHOT = "operationsSnapshot";
export const ROOMS_SESSION_TYPING = "typing";
