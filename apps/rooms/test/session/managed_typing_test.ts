// Typing is a level: a rate-limited flag is sent again after the room's stated
// delay, and any other refusal ends typing for that conversation. Typing waits
// for a line on its way: a line that lands is the stop, and one the room
// refuses is not. A line that lands ends what was said before it, so a member
// still typing is said again.
import { RoomsError } from "../../lib/error_codes.ts";
import { assert, assertEquals } from "../assert.ts";
import { viewer } from "../support/managed_viewer.ts";
import { initializeApplication } from "../support/application.ts";

await initializeApplication();

function sender(answers: Array<Error | null>) {
	const sent: boolean[] = [];
	const session = viewer({
		typingSender: () =>
			Promise.resolve({
				set: (on: boolean) => {
					sent.push(on);
					const refusal = answers.shift() ?? null;
					return refusal == null ? Promise.resolve() : Promise.reject(refusal);
				},
				free() {},
			}),
	});
	return { session, sent };
}

Deno.test("a rate-limited typing flag is sent again after the stated delay", async () => {
	const { session, sent } = sender([
		new RoomsError("rate-limited", "retry-after-ms=5; scope=room-transient; owner=directory"),
	]);
	await session.typing.set("room", "seat", true);
	assertEquals(sent, [true, true]);
	await session.typing.close();
});

Deno.test("a flag that changed during the delay sends only the latest level", async () => {
	const { session, sent } = sender([
		new RoomsError("rate-limited", "retry-after-ms=20; scope=room-transient; owner=directory"),
	]);
	const first = session.typing.set("room", "seat", true);
	await new Promise((resume) => setTimeout(resume, 1));
	void session.typing.set("room", "seat", false);
	await first;
	assertEquals(sent, [true, false]);
	await session.typing.close();
});

Deno.test("a line that landed is the stop for the draft it carried", async () => {
	const { session, sent } = sender([]);
	await session.typing.set("room", "seat", true);
	session.typing.lineLeft("room");
	await session.typing.set("room", "seat", false);
	await session.typing.lineSettled("room", true);
	assertEquals(sent, [true]);
	await session.typing.set("room", "seat", true);
	await session.typing.set("room", "seat", false);
	assertEquals(sent, [true, true, false], "the next draft's typing is its own");
	await session.typing.close();
});

Deno.test("typing for the next draft waits for the line and follows it", async () => {
	const { session, sent } = sender([]);
	await session.typing.set("room", "seat", true);
	session.typing.lineLeft("room");
	await session.typing.set("room", "seat", false);
	await session.typing.set("room", "seat", true);
	assertEquals(sent, [true], "a start that reached the room first would be ended by the line");
	await session.typing.lineSettled("room", true);
	assertEquals(sent, [true, true]);
	await session.typing.close();
});

Deno.test("a member typing past a queued line is said again when that line lands", async () => {
	const { session, sent } = sender([]);
	await session.typing.set("room", "seat", true);
	session.typing.lineLeft("room");
	// The next line queues, its draft clears, and the member types a third.
	await session.typing.set("room", "seat", false);
	await session.typing.set("room", "seat", true);
	await session.typing.lineSettled("room", true);
	assertEquals(sent, [true, true]);
	// The queued line leaves behind that start and ends it where it arrives.
	session.typing.lineLeft("room");
	await session.typing.lineSettled("room", true);
	assertEquals(sent, [true, true, true], "the start said before the queued line spoke for a newer draft");
	session.typing.lineLeft("room");
	await session.typing.set("room", "seat", false);
	await session.typing.lineSettled("room", true);
	assertEquals(sent, [true, true, true], "and the line that carries that draft is its stop");
	await session.typing.close();
});

Deno.test("a member typing when a line that typing did not wait for lands is said again", async () => {
	const { session, sent } = sender([]);
	await session.typing.lineLanded("room");
	assertEquals(sent, [], "nobody was typing");
	await session.typing.set("room", "seat", true);
	await session.typing.lineLanded("room");
	assertEquals(sent, [true, true], "the uploaded line ended the start said before it");
	await session.typing.set("room", "seat", false);
	await session.typing.lineLanded("room");
	assertEquals(sent, [true, true, false]);
	await session.typing.close();
});

Deno.test("a line that leaves while the typing sender is opening holds that level", async () => {
	const sent: boolean[] = [];
	const opened = Promise.withResolvers<void>();
	const session = viewer({
		typingSender: async () => {
			await opened.promise;
			return {
				set: (on: boolean) => {
					sent.push(on);
					return Promise.resolve();
				},
				free() {},
			};
		},
	});
	const start = session.typing.set("room", "seat", true);
	session.typing.lineLeft("room");
	opened.resolve();
	await start;
	assertEquals(sent, [], "a start that reached the room first would be ended by the line");
	await session.typing.lineSettled("room", true);
	assertEquals(sent, [true]);
	await session.typing.close();
});

Deno.test("a start the room asks to hear later while its line is out waits for the line", async () => {
	const sent: boolean[] = [];
	const answered = Promise.withResolvers<void>();
	const session = viewer({
		typingSender: () =>
			Promise.resolve({
				set: (on: boolean) => {
					sent.push(on);
					return sent.length === 1 ? answered.promise : Promise.resolve();
				},
				free() {},
			}),
	});
	const start = session.typing.set("room", "seat", true);
	await new Promise((resume) => setTimeout(resume, 1));
	session.typing.lineLeft("room");
	answered.reject(new RoomsError("rate-limited", "retry-after-ms=5; scope=room-transient; owner=directory"));
	await start;
	await new Promise((resume) => setTimeout(resume, 20));
	assertEquals(sent, [true], "the delay passed with the line still out");
	await session.typing.lineSettled("room", true);
	assertEquals(sent, [true, true], "the member is still typing, and nobody heard the first start");
	await session.typing.close();
});

Deno.test("a stop that arrives while the typing sender is opening replaces the start", async () => {
	const { session, sent } = sender([]);
	const start = session.typing.set("room", "seat", true);
	await session.typing.set("room", "seat", false);
	await start;
	assertEquals(sent, [false]);
	await session.typing.close();
});

Deno.test("a start waiting out the room's delay is not sent to a conversation that is gone", async () => {
	const { session, sent } = sender([
		new RoomsError("rate-limited", "retry-after-ms=200; scope=room-transient; owner=directory"),
	]);
	const start = session.typing.set("room", "seat", true);
	await new Promise((resume) => setTimeout(resume, 1));
	session.typing.forget("room");
	await start;
	assertEquals(sent, [true]);
	await session.typing.close();
});

Deno.test("nothing on its way reaches a conversation that is gone", async () => {
	const sent: boolean[] = [];
	const answered = Promise.withResolvers<void>();
	const session = viewer({
		typingSender: () =>
			Promise.resolve({
				set: (on: boolean) => {
					sent.push(on);
					return answered.promise;
				},
				free() {},
			}),
	});
	const unopened = session.typing.set("room", "seat", true);
	session.typing.forget("room");
	await unopened;
	assertEquals(sent, [], "its sender was still opening");
	const start = session.typing.set("room", "seat", true);
	await new Promise((resume) => setTimeout(resume, 1));
	session.typing.forget("room");
	answered.reject(new RoomsError("rate-limited", "retry-after-ms=5; scope=room-transient; owner=directory"));
	await start;
	await new Promise((resume) => setTimeout(resume, 20));
	assertEquals(sent, [true], "the room asked to hear again a start nobody is owed");
	await session.typing.close();
});

Deno.test("a conversation that is gone is owed nothing", async () => {
	const { session, sent } = sender([]);
	await session.typing.set("room", "seat", true);
	session.typing.lineLeft("room");
	await session.typing.set("room", "seat", false);
	session.typing.forget("room");
	await session.typing.lineSettled("room", false);
	assertEquals(sent, [true]);
	await session.typing.close();
});

Deno.test("a start still on its way when its draft leaves is followed by its stop", async () => {
	const sent: boolean[] = [];
	const arrived = Promise.withResolvers<void>();
	const session = viewer({
		typingSender: () =>
			Promise.resolve({
				set: (on: boolean) => {
					sent.push(on);
					return on ? arrived.promise : Promise.resolve();
				},
				free() {},
			}),
	});
	const start = session.typing.set("room", "seat", true);
	await new Promise((resume) => setTimeout(resume, 1));
	session.typing.lineLeft("room");
	void session.typing.set("room", "seat", false);
	void session.typing.lineSettled("room", true);
	assertEquals(sent, [true]);
	arrived.resolve();
	await start;
	assertEquals(sent, [true, false], "the room may hear that start after the line, so the line is not its stop");
	await session.typing.close();
});

Deno.test("a start the room refused while its draft left owes no stop", async () => {
	const sent: boolean[] = [];
	const answered = Promise.withResolvers<void>();
	const session = viewer({
		typingSender: () =>
			Promise.resolve({
				set: (on: boolean) => {
					sent.push(on);
					return answered.promise;
				},
				free() {},
			}),
	});
	const start = session.typing.set("room", "seat", true);
	await new Promise((resume) => setTimeout(resume, 1));
	session.typing.lineLeft("room");
	void session.typing.set("room", "seat", false);
	answered.reject(new RoomsError("no-such-room", "the room is gone"));
	assert(await start.then(() => false, () => true), "the refused start reports its refusal");
	await session.typing.lineSettled("room", true);
	assertEquals(sent, [true], "nobody heard that start, so the line owes it no stop");
	await session.typing.close();
});

Deno.test("a stop that waited for a line is sent when the room refuses the line", async () => {
	const { session, sent } = sender([]);
	await session.typing.lineSettled("room", false);
	assertEquals(sent, [], "nothing waited");
	await session.typing.set("room", "seat", true);
	session.typing.lineLeft("room");
	await session.typing.set("room", "seat", false);
	assertEquals(sent, [true], "the line is the stop while the room may still accept it");
	await session.typing.lineSettled("room", false);
	assertEquals(sent, [true, false]);
	await session.typing.lineSettled("room", false);
	assertEquals(sent, [true, false], "one refusal owes one stop");
	await session.typing.close();
});

Deno.test("a stop owed to one conversation is sent before a start in another", async () => {
	const sent: string[] = [];
	const arrived = Promise.withResolvers<void>();
	const session = viewer({
		typingSender: (id: string) =>
			Promise.resolve({
				set: (on: boolean) => {
					sent.push(`${id} ${on}`);
					return sent.length === 1 ? arrived.promise : Promise.resolve();
				},
				free() {},
			}),
	});
	const start = session.typing.set("left", "seat", true);
	await new Promise((resume) => setTimeout(resume, 1));
	void session.typing.set("left", "seat", false);
	void session.typing.set("joined", "seat", true);
	arrived.resolve();
	await start;
	assertEquals(sent, ["left true", "left false", "joined true"]);
	await session.typing.close();
});

Deno.test("a line leaving one conversation keeps the stop owed to another", async () => {
	const { session, sent } = sender([]);
	await session.typing.set("other", "seat", true);
	session.typing.lineLeft("room");
	await session.typing.set("other", "seat", false);
	assertEquals(sent, [true, false]);
	await session.typing.close();
});

Deno.test("a start the room asked to hear later is dropped once its draft left as a line", async () => {
	const { session, sent } = sender([
		new RoomsError("rate-limited", "retry-after-ms=20; scope=room-transient; owner=directory"),
	]);
	const first = session.typing.set("room", "seat", true);
	await new Promise((resume) => setTimeout(resume, 1));
	session.typing.lineLeft("room");
	void session.typing.set("room", "seat", false);
	await first;
	await session.typing.lineSettled("room", true);
	assertEquals(sent, [true]);
	await session.typing.close();
});

Deno.test("any other refusal ends typing for that conversation", async () => {
	const { session, sent } = sender([new Error("glowcap error -12: ApplicationRefused")]);
	let refused = false;
	await session.typing.set("room", "seat", true).catch(() => {
		refused = true;
	});
	await session.typing.set("room", "seat", true);
	assertEquals([refused, sent], [true, [true]]);
	await session.typing.close();
});
