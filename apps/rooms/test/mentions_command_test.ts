// Automatic mentions change one room's private selection and reject stale or partial writes.
import "./support/match_media.ts";
import { LocalRefusal } from "../lib/text/failure.ts";
import { setRoomMentions } from "../web/ui/session/managed/mentions.ts";
// A room member changes saved mentions privately against the current roster.
import { type CommandPowers, known } from "../web/ui/commands.ts";
import { dirId } from "../web/ui/directory.ts";
import { ensureRoom, PageProjection, setRoomMembership } from "../web/ui/store.ts";
import { initializeApplication } from "./support/application.ts";
import { quietCommandPowers as QUIET } from "./support/command_powers.ts";
import { fail } from "./support/fail.ts";

await initializeApplication();

Deno.test("/mentions reports privately and changes only the named room selection", async () => {
	const mentions = known().find((command) => command.name === "mentions");
	if (!mentions) fail("the command catalog omitted /mentions");
	const room = { ...ensureRoom(new PageProjection(), dirId("local"), "test"), audience: ["Saved"] };
	const said: string[] = [];
	const writes: string[][] = [];
	const powers: CommandPowers = {
		...QUIET,
		you: () => "Me",
		say: (message, key) => {
			if (key !== room.key) fail("the private response followed another conversation");
			said.push(message);
		},
		setRoomAudience: (key, names) => {
			if (key !== room.key) fail("the command wrote another room");
			writes.push([...names]);
			return Promise.resolve(names);
		},
	};
	for (const input of ["", "@off @Sky", "off"]) {
		const result = mentions.run(input, powers, room);
		if (result.kind !== "done") fail("a preference change produced a public message or refusal");
		await result.completion;
	}
	if (JSON.stringify(writes) !== JSON.stringify([["off", "Sky"], []])) {
		fail("the room selection was not replaced atomically");
	}
	if (said.join("|") !== "Automatic mentions: @Saved|Automatic mentions: @off @Sky|Automatic mentions are off.") {
		fail("the private command response lost the selected names");
	}
	for (const input of ["@all", "@me", "@Sky @SKY", "somebody", "@Sky @!"]) {
		if (mentions.run(input, powers, room).kind !== "refused") fail(`/mentions accepted ${input}`);
	}
	if (writes.length !== 2) fail("a rejected command changed the saved names");
});

Deno.test("a partial or newly offline mention selection cannot overwrite the room checkpoint", async () => {
	const projection = new PageProjection();
	const row = ensureRoom(projection, dirId("local"), "room");
	setRoomMembership(projection, row.key, "joined");
	const roster = (online: boolean) =>
		projection.set({
			members: new Map([[row.key, new Map([["Ana", { online: true, away: "" }], ["Bo", { online, away: "" }]])]]),
		});
	roster(true);
	const written: string[][] = [];
	const write = (id: string, names: string[], validate: () => void) => {
		if (id !== row.persistId) fail("wrong room checkpoint");
		validate();
		written.push(names);
		return Promise.resolve();
	};
	async function refused(task: Promise<unknown>, reason: "mentions-offline" | "mentions-room") {
		try {
			await task;
		} catch (error) {
			if (LocalRefusal.is(error, reason)) return;
			throw error;
		}
		fail("an invalid selection reached the room checkpoint");
	}
	await setRoomMentions(projection, row.key, ["ana"], write);
	await refused(setRoomMentions(projection, row.key, ["Bo", "missing"], write), "mentions-offline");
	await refused(
		setRoomMentions(projection, row.key, ["Ana", "Bo"], (id, names, validate) => {
			roster(false);
			return write(id, names, validate);
		}),
		"mentions-offline",
	);
	setRoomMembership(projection, row.key, "unavailable");
	await refused(setRoomMentions(projection, row.key, ["Ana"], write), "mentions-room");
	await setRoomMentions(projection, row.key, [], write);
	if (JSON.stringify(written) !== JSON.stringify([["Ana"], []])) fail("a refusal partly replaced the old mentions");
});
