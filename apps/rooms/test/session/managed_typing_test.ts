// Typing is a level: a rate-limited flag is sent again after the room's stated
// delay, and any other refusal ends typing for that conversation.
import { assertEquals } from "../assert.ts";
import { viewer } from "../support/managed_viewer.ts";
import { initializeApplication } from "../support/application.ts";

await initializeApplication();

function sender(answers: Array<string | null>) {
	const sent: boolean[] = [];
	const session = viewer({
		typingSender: () =>
			Promise.resolve({
				set: (on: boolean) => {
					sent.push(on);
					const refusal = answers.shift() ?? null;
					return refusal == null ? Promise.resolve() : Promise.reject(new Error(refusal));
				},
				free() {},
			}),
	});
	return { session, sent };
}

Deno.test("a rate-limited typing flag is sent again after the stated delay", async () => {
	const { session, sent } = sender(["rate-limited: retry-after-ms=5; scope=room-transient; owner=directory"]);
	await session.typing.set("room", "seat", true);
	assertEquals(sent, [true, true]);
	await session.typing.close();
});

Deno.test("a flag that changed during the delay sends only the latest level", async () => {
	const { session, sent } = sender(["rate-limited: retry-after-ms=20; scope=room-transient; owner=directory"]);
	const first = session.typing.set("room", "seat", true);
	await new Promise((resume) => setTimeout(resume, 1));
	void session.typing.set("room", "seat", false);
	await first;
	assertEquals(sent, [true, false]);
	await session.typing.close();
});

Deno.test("any other refusal ends typing for that conversation", async () => {
	const { session, sent } = sender(["glowcap error -12: ApplicationRefused"]);
	let refused = false;
	await session.typing.set("room", "seat", true).catch(() => {
		refused = true;
	});
	await session.typing.set("room", "seat", true);
	assertEquals([refused, sent], [true, [true]]);
	await session.typing.close();
});
