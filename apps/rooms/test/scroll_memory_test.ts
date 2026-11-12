// Scroll memory remains bounded to the most recently visited workspace positions.
import { SESSION_CONTENT } from "../lib/session_content_data.ts";
import { ScrollMemory } from "../web/ui/scroll_memory.ts";
import { assert } from "./assert.ts";
import { initializeApplication } from "./support/application.ts";

// The ceiling is the Rust workspace's, which the page asks the application for.
await initializeApplication();

const MAX_WORKSPACE_CONVERSATIONS = SESSION_CONTENT.limits.conversations;

Deno.test("scroll memory keeps only the most recently visited workspace", () => {
	const memory = new ScrollMemory();
	for (let at = 0; at < MAX_WORKSPACE_CONVERSATIONS; at += 1) {
		memory.remember(`conversation-${at}`, at);
	}
	memory.remember("conversation-0", 700);
	memory.remember("one-more", 800);
	assert(memory.size === MAX_WORKSPACE_CONVERSATIONS, "scroll memory grew past the workspace ceiling");
	assert(memory.recall("conversation-0") === 700, "an active conversation lost its latest scroll offset");
	assert(memory.recall("conversation-1") === undefined, "scroll memory retained its least-recently used row");
	assert(memory.recall("one-more") === 800, "scroll memory lost the newly admitted row");
});
