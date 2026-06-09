// The wire contract for the tools showcase: a coordinator that hands an agent
// capabilities to tools, and the verbs those tools answer. Object-capability
// messages over OCapN — no RPC framework, no auth tokens.
//
// The whole point: a coordinator holds tools and grants an agent exactly the
// authority a task needs — attenuated to read-only where appropriate, revocable
// when the task is done. The agent can call what it was handed and nothing else,
// because there is no ambient authority to escalate to. This is the model AI
// agent harnesses need and currently fake with API keys and allowlists.

/** The name the coordinator publishes itself under and the agent fetches it by. */
export const TOOLS = "tools";

/** Coordinator methods the agent sends. */
export const GRANT = "grant"; // grant(toolName) → a capability to the tool
export const GRANT_REVOCABLE = "grant-revocable"; // → a revocable capability
export const REVOKE_LAST = "revoke-last"; // revoke the last revocable grant

/** Tool method verbs. */
export const NOW = "now"; // clock.now() → integer timestamp
export const READ = "read"; // files.read(path) → contents
export const WRITE = "write"; // files.write(path, data) → "ok"
