import type { LiveDirectory } from "../session/live.ts";
import { reconcileRuntimeDirectories, unresolvedRoomPublication } from "../session/runtime_directory_reconcile.ts";
import { assertEquals } from "./assert.ts";
import { DurableDirectoryView } from "../session/directory_view.ts";
import { workspaceFixture } from "./support/workspace.ts";

Deno.test("a superseded directory plan closes its late connection before insertion", async () => {
	const opened = Promise.withResolvers<LiveDirectory>();
	const live = new Map<string, LiveDirectory>();
	const closed: LiveDirectory[] = [];
	let current = true;
	const run = reconcileRuntimeDirectories({
		wanted: [{
			id: "directory",
			locator: "locator-a",
			home: true,
			nick: "ada",
			standing: null,
		}],
		live,
		current: () => current,
		release: async () => {},
		connect: () => opened.promise,
		close: (directory) => {
			closed.push(directory);
			return Promise.resolve();
		},
		changed: () => {},
		setIssue: () => false,
	});
	current = false;
	const stale = { id: "directory", topology: "stale" } as LiveDirectory;
	opened.resolve(stale);
	assertEquals(await run, false);
	assertEquals(live.size, 0);
	assertEquals(closed, [stale]);
});

Deno.test("a retired foreign room generation follows the current publication of its name", () => {
	const view = new DurableDirectoryView("ocapn://directory.id");
	view.replaceRooms([{
		id: "new-bridge-generation",
		name: "Libera/#room",
		kind: "bridge",
		count: 0,
		origin: "irc.libera.chat:6697",
		proof: "bridge",
		offers: "participant",
	}]);
	const held = { id: "ocapn://directory.id", view } as LiveDirectory;
	const conversation = {
		...(workspaceFixture().session.conversations[0] as Extract<
			ReturnType<typeof workspaceFixture>["session"]["conversations"][number],
			{ kind: "room" }
		>),
		name: "Libera/#room",
		publicationId: "retired-bridge-generation",
	};
	assertEquals(unresolvedRoomPublication([conversation], held), {
		type: "room-publication",
		conversationId: conversation.id,
		expectedPublicationId: "retired-bridge-generation",
		publicationId: "new-bridge-generation",
	});
});
