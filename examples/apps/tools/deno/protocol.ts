// The wire contract for the tools showcase: a coordinator that hands an agent
// capabilities to tools, and the verbs those tools answer. Object-capability
// messages over OCapN — no RPC framework, no auth tokens.
//
// The whole point: a coordinator holds tools and grants an agent exactly the
// authority a task needs — attenuated to read-only where appropriate, revocable
// when the task is done. The agent calls what it was handed, and there is no
// ambient authority to escalate through — no global directory of tools to
// enumerate. AI agent harnesses typically approximate this with API keys and
// allowlists.

/** The name the coordinator publishes itself under and the agent fetches it by. */
export const TOOLS = "tools";

/** Coordinator methods the agent sends. */
export const GRANT = "grant"; // grant(toolName) returns a capability to the tool
export const GRANT_REVOCABLE = "grant-revocable"; // returns a revocable capability
export const REVOKE_LAST = "revoke-last"; // revoke the last revocable grant

/** Tool method verbs. */
export const NOW = "now"; // clock.now() returns integer timestamp
export const READ = "read"; // files.read(path) returns contents
export const WRITE = "write"; // files.write(path, data) returns "ok"
