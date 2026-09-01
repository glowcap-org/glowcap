import { MAX_WORKSPACE_CONVERSATIONS } from "../lib/rooms_state.ts";
import { ScrollMemory } from "../web/ui/scroll_memory.ts";

function assert(condition: unknown, message: string): asserts condition {
	if (!condition) throw new Error(message);
}

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
