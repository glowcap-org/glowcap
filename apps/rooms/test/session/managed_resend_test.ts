// A command sent as the link broke has no trace in the session when the new link
// asks for it. It goes out again under its own operation id and original base,
// and the session lands it once or refuses it as stale.
import { assertEquals } from "../assert.ts";
import { until, within } from "../support/wait.ts";
import { viewer } from "../support/managed_viewer.ts";
import { FakeClock, linkedWorkspace, request, settle } from "../support/managed_link.ts";
import type { RoomsManagedCommand } from "../../../../zig-out/wasm/rooms/rooms_browser.js";

/** A page whose first link dies with a command cut off on the wire, over a
 * new link whose session holds no record of it and prepares what it is given. */
async function lostOnTheWire(intent: unknown, submitted: () => Promise<unknown>) {
	const first = linkedWorkspace("first", []);
	const second = linkedWorkspace("second", []);
	const prepared: { id: string; base: string; name: string; args: string[] }[] = [];
	let freedOld = 0;
	Object.assign(second.workspace, {
		recoverEffect: () => Promise.resolve(null),
		prepareCommand: (id: string, base: string, name: string, args: string[]) => {
			prepared.push({ id, base, name, args });
			return Promise.resolve(request(submitted, () => Promise.resolve("committed"), intent));
		},
	});
	const session = viewer(
		first.workspace,
		undefined,
		{ relink: () => Promise.resolve(second.workspace) },
		false,
		new FakeClock(),
	);
	await session.start();
	const cutOff = {
		submit: () => first.park(),
		status: () => first.park<string>(),
		originalIntent: () => intent,
		free() {
			freedOld++;
		},
	} as unknown as RoomsManagedCommand;
	let preparations = 0;
	const sending = session.perform("gesture", () => {
		// The first preparation is cut off; asked again, it prepares over the new link.
		return Promise.resolve(
			preparations++ === 0 ? cutOff : request(submitted, () => Promise.resolve("committed"), intent),
		);
	}).then(
		() => null,
		(error: unknown) => error,
	);
	await settle();
	first.lose();
	return { session, sending, prepared, freedOld: () => freedOld, preparations: () => preparations };
}

Deno.test("a send with no trace in the session goes out again under its id and base, and lands once", async () => {
	const intent = ["gesture", 7, "say", ["dm", "hello"]];
	const { session, sending, prepared, freedOld } = await lostOnTheWire(
		intent,
		() => Promise.resolve({ status: "committed" }),
	);
	assertEquals(await within(sending, "the lost send to land"), null);
	assertEquals(prepared, [{ id: "gesture", base: "7", name: "say", args: ["dm", "hello"] }]);
	assertEquals(freedOld(), 1, "the request that never arrived is released once");
	await session.close();
});

Deno.test("a send the session refuses as stale after the break is not sent, never finished elsewhere", async () => {
	const { session, sending, prepared } = await lostOnTheWire(
		["gesture", 7, "say", ["dm", "hello"]],
		() => Promise.resolve({ status: "conflict" }),
	);
	const refused = await within(sending, "the stale send to settle");
	assertEquals((refused as { code?: unknown }).code, "local-not-sent");
	assertEquals(prepared.length, 1, "it went out again exactly once");
	await session.close();
});

Deno.test("a change that is not a plain command goes out again as it was first prepared", async () => {
	const { session, sending, prepared, preparations } = await lostOnTheWire(
		{ conversation: "dm" },
		() => Promise.resolve({ status: "committed" }),
	);
	assertEquals(await within(sending, "the change to land"), null);
	assertEquals([prepared, preparations()], [[], 2], "the original preparation ran again, not a recorded tuple");
	await session.close();
});

Deno.test("a send cut off again by the next break goes out again once more", async () => {
	const first = linkedWorkspace("first", []);
	const second = linkedWorkspace("second", []);
	const third = linkedWorkspace("third", []);
	const intent = ["gesture", 3, "say", ["dm", "hi"]];
	const prepared: string[] = [];
	Object.assign(second.workspace, {
		recoverEffect: () => Promise.resolve(null),
		prepareCommand: () => {
			prepared.push("second");
			return Promise.resolve(request(() => second.park(), () => second.park<string>(), intent));
		},
	});
	Object.assign(third.workspace, {
		recoverEffect: () => Promise.resolve(null),
		prepareCommand: () => {
			prepared.push("third");
			return Promise.resolve(
				request(() => Promise.resolve({ status: "committed" }), () => Promise.resolve("committed"), intent),
			);
		},
	});
	const links = [second, third];
	const session = viewer(
		first.workspace,
		undefined,
		{ relink: () => Promise.resolve(links.shift()!.workspace) },
		false,
		new FakeClock(),
	);
	await session.start();
	const sending = session.perform(
		"gesture",
		() => Promise.resolve(request(() => first.park(), () => first.park<string>(), intent)),
	).then(() => null, (error: unknown) => error);
	await settle();
	first.lose();
	await until(() => prepared.length === 1, "the first resend");
	await settle();
	second.lose();
	assertEquals(await within(sending, "the twice cut off send to land"), null);
	assertEquals(prepared, ["second", "third"]);
	await session.close();
});

Deno.test("a send whose preparation the break cuts off is prepared again over the new link", async () => {
	const first = linkedWorkspace("first", []);
	const second = linkedWorkspace("second", []);
	const session = viewer(
		first.workspace,
		undefined,
		{ relink: () => Promise.resolve(second.workspace) },
		false,
		new FakeClock(),
	);
	await session.start();
	const intent = ["gesture", 1, "say", ["dm", "hi"]];
	let preparations = 0;
	const sending = session.perform("gesture", () => {
		// Nothing was sent: the first preparation is still reading when the link breaks.
		if (preparations++ === 0) return first.park<RoomsManagedCommand>();
		return Promise.resolve(
			request(() => Promise.resolve({ status: "committed" }), () => Promise.resolve("committed"), intent),
		);
	}).then(() => null, (error: unknown) => error);
	await settle();
	first.lose();
	assertEquals(await within(sending, "the unsent line to land"), null);
	assertEquals(preparations, 2);
	await session.close();
});
