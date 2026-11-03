// A session indexes accepted reads without caching editable candidates.
import { assert, assertEquals } from "../assert.ts";
import { snapshot, viewer } from "../support/managed_viewer.ts";
import { conversationById } from "../../web/ui/session/managed/conversation_lookup.ts";

Deno.test("accepted conversation lookups reuse one index and retain their snapshot identity", async () => {
	let idReads = 0;
	const original = snapshot();
	original.intent.conversations = Array.from({ length: 128 }, (_, index) => ({
		kind: "direct",
		get id() {
			idReads++;
			return `direct-${index}`;
		},
		directory: "directory",
		peer: "peer",
		access: "access",
		closed: false,
		draft: "original",
	}));
	let current = original;
	const session = viewer({ snapshot: () => Promise.resolve(current) });
	try {
		await session.refresh();
		assertEquals(idReads, 128);
		for (let pass = 0; pass < 4; pass++) {
			for (let index = 0; index < 128; index++) {
				assert(
					conversationById(session.current, `direct-${index}`) === original.intent.conversations[index],
					"lookup did not borrow the exact accepted row",
				);
			}
		}
		assertEquals(idReads, 128, "accepted lookups rewalked the conversation list");
		current = { ...snapshot(), revision: "2" };
		current.intent.conversations = [{ ...original.intent.conversations[0], draft: "replacement" }];
		await session.refresh();
		assertEquals(conversationById(session.current, "direct-0")?.draft, "replacement");
		assertEquals(conversationById(original, "direct-0")?.draft, "original");
		assertEquals(conversationById(session.current, "direct-1"), undefined);
		current = original;
		await session.refresh();
		assertEquals(conversationById(session.current, "direct-0")?.draft, "replacement");
	} finally {
		await session.close();
	}
});

Deno.test("candidate lookup observes insertion and removal after an earlier lookup", async () => {
	const current = snapshot();
	const session = viewer({ snapshot: () => Promise.resolve(current) });
	try {
		const candidate = await session.candidate();
		assertEquals(conversationById(candidate, "direct"), undefined);
		candidate.intent.conversations.push({
			kind: "direct",
			id: "direct",
			directory: "directory",
			peer: "peer",
			access: "access",
			closed: false,
			draft: "",
		});
		assert(
			conversationById(candidate, "direct") === candidate.intent.conversations[0],
			"candidate insertion was hidden",
		);
		current.intent.conversations.push({ ...candidate.intent.conversations[0] });
		await session.refresh();
		assert(
			conversationById(session.current, "direct") === current.intent.conversations[0],
			"accepting a reused array kept its earlier index",
		);
		current.intent.conversations.splice(0, 1);
		await session.refresh();
		assertEquals(conversationById(session.current, "direct"), undefined);
		candidate.intent.conversations.splice(0, 1);
		assertEquals(conversationById(candidate, "direct"), undefined);
		assertEquals(conversationById(session.current, "direct"), undefined);
		assertEquals(conversationById(null, "direct"), undefined);
	} finally {
		await session.close();
	}
});
