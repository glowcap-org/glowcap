import { PageHostedSession } from "../../web/ui/session/hosted_hold.ts";
import { assertEquals } from "../assert.ts";

Deno.test("a second Share while the first is still running joins it", async () => {
	const hosted = new PageHostedSession();
	let calls = 0;
	let release!: () => void;
	hosted.bind(() => {
		calls += 1;
		return new Promise((resolve) => {
			release = () => resolve("");
		});
	});
	const first = hosted.share();
	const second = hosted.share();
	assertEquals(first === second, true);
	assertEquals(calls, 1);
	release();
	assertEquals(await first, "");
	assertEquals(await second, "");
});

Deno.test("a later Share after the first settles is a new attempt", async () => {
	const hosted = new PageHostedSession();
	let calls = 0;
	hosted.bind(() => {
		calls += 1;
		return Promise.resolve("");
	});
	assertEquals(await hosted.share(), "");
	assertEquals(await hosted.share(), "");
	assertEquals(calls, 2);
});

Deno.test("a refused Share still lets the next attempt run", async () => {
	const hosted = new PageHostedSession();
	let calls = 0;
	hosted.bind(() => {
		calls += 1;
		return Promise.reject(new Error("no"));
	});
	assertEquals(await hosted.share().then(() => "", (error) => String(error)), "Error: no");
	assertEquals(await hosted.share().then(() => "", (error) => String(error)), "Error: no");
	assertEquals(calls, 2);
});
