// The wire contract shared by the tasks server and every tasks client, in every
// language. A capability name and the method verbs the board and a watcher
// answer to — object-capability messages over OCapN, no RPC framework.
//
// A board is the server's published capability. A client fetches it by name and
// eventual-sends `add`, `done`, `list`, and `watch`. When watching, the client
// hands the board a capability to its own `watcher` actor; the board keeps it and
// calls back with `update` whenever the task list changes.

/** The name the server publishes the board under and clients fetch it by. */
export const BOARD = "board";

/** Board methods a client sends. */
export const ADD = "add"; // add(text) → id
export const DONE = "done"; // done(id) → "ok"
export const LIST = "list"; // list() → [[id, text, completed], ...]
export const WATCH = "watch"; // watch(watcherCap) → "watching"

/** The method the board calls back on a watcher: `update([[id, text, completed], ...])`. */
export const UPDATE = "update";
