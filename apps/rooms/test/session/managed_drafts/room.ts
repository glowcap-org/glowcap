// A staged draft follows the same room across membership and entrance changes.
import { assertEquals } from "../../assert.ts";
import { snapshot, viewer } from "../../support/managed_viewer.ts";
import type { RoomIntent } from "../../../web/ui/session/managed/model.ts";

function stagedDraft(entrance: Partial<RoomIntent>) {
	const before = snapshot();
	const room: RoomIntent = {
		kind: "room",
		id: "room",
		directory: "home",
		name: "garden",
		source: "original source",
		access: "original entrance",
		publication: "original publication",
		seat: "original seat",
		control: null,
		reconnect: "requested",
		standing: null,
		draft: "",
		...entrance,
	};
	before.intent.conversations.push(room, { ...room, id: "other" });
	let current = before;
	const written: string[] = [];
	const session = viewer({
		snapshot: () => Promise.resolve(current),
		prepareCommand: (_id: string, _rev: string, _cmd: string, args: string[]) => {
			written.push(args[1]);
			return Promise.resolve({
				submit: () => Promise.resolve({ status: "committed" }),
				status: () => Promise.resolve("committed"),
				result: () => Promise.resolve(null),
				free() {},
			});
		},
	});
	const stage = async () => {
		await session.readNow();
		session.drafts.stage("room", "words held by this tab");
	};
	const observe = async (change: Partial<RoomIntent>) => {
		const next = structuredClone(current);
		Object.assign(next.intent.conversations[0], change);
		next.revision = String(Number(current.revision) + 1);
		current = next;
		await session.readNow();
	};
	const check = async (same: boolean) => {
		const [write] = await Promise.allSettled([session.drafts.flush("room")]);
		assertEquals(write.status, same ? "fulfilled" : "rejected");
		assertEquals(written, same ? ["words held by this tab"] : []);
		await session.close();
	};
	return { stage, observe, check, session, written };
}

for (const changed of ["seat", "source", "access", "publication", "name", "directory"] as const) {
	Deno.test(`a room draft follows a rejoin only to its original destination: changed ${changed}`, async () => {
		const draft = stagedDraft({});
		await draft.stage();
		await draft.observe({ seat: "new seat", [changed]: "replacement" });
		await draft.check(changed === "seat");
	});
}

for (const move of ["linked", "linked then rejoined", "both at once", "retargeted", "competing edit"] as const) {
	Deno.test(`a staged public room draft follows an observed link acquisition: ${move}`, async () => {
		const draft = stagedDraft({ access: null, publicEntry: { access: "public directory" } });
		await draft.stage();
		await draft.observe({
			access: "new room link",
			publicEntry: undefined,
			...(move === "both at once" ? { seat: "new seat" } : {}),
			...(move === "retargeted" ? { publication: undefined } : {}),
			...(move === "competing edit" ? { draft: "another tab's words" } : {}),
		});
		if (move === "linked then rejoined") await draft.observe({ seat: "new seat" });
		await draft.check(move === "linked" || move === "linked then rejoined");
	});
}

Deno.test("a new entrance alone cannot move a staged draft to another linked room", async () => {
	const draft = stagedDraft({});
	await draft.stage();
	await draft.observe({ access: "replacement entrance" });
	await draft.check(false);
});

Deno.test("adopting the draft of a retargeted room keeps other drafts and writes nothing", async () => {
	const { stage, observe, session, written } = stagedDraft({});
	await stage();
	session.drafts.stage("other", "another local draft");
	await observe({ access: "replacement entrance", draft: "session words" });
	const [write] = await Promise.allSettled([session.drafts.flush("room")]);
	assertEquals(write.status, "rejected");
	assertEquals(session.drafts.failure("room")?.conflict, true);
	assertEquals(session.drafts.value("room", "session words"), "words held by this tab");
	assertEquals(session.drafts.useSessionDraft("other"), undefined);
	assertEquals(session.drafts.useSessionDraft("room"), "session words");
	assertEquals(session.drafts.value("room", "session words"), "session words");
	assertEquals(session.drafts.value("other", ""), "another local draft");
	assertEquals(written, []);
	session.drafts.stage("room", "fresh words for the new room");
	await session.drafts.flush("room");
	assertEquals(written, ["fresh words for the new room"]);
	await session.close();
});
