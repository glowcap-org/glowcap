import { Ref, type Session } from "@pancake/runtime";
import { READ } from "../lib/protocol.ts";
import { ROOMS_SESSION_CHANGED, ROOMS_SESSION_EVENT } from "../lib/rooms_session.ts";
import {
	attachedFileProxyBehavior,
	AttachedViewDelivery,
	MAX_QUEUED_VIEW_EVENTS,
} from "../session/attached_view_delivery.ts";
import type { RuntimeAttachment } from "../session/room_files.ts";
import { assertEquals } from "./assert.ts";

function ref(): Ref {
	return Object.create(Ref.prototype) as Ref;
}

function message(text: string) {
	return {
		from: "bo",
		text,
		system: false,
		attachments: [],
	};
}

function settle(): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, 0));
}

Deno.test("an attached file proxy returns malformed capability arguments", async () => {
	const released: Ref[] = [];
	const session = { release: (capability: Ref) => released.push(capability) } as unknown as Session;
	const file = {
		read: (offset: number, length: number) => Promise.resolve(new Uint8Array([offset, length])),
	} as RuntimeAttachment;
	const proxy = attachedFileProxyBehavior(file, () => session);
	const unexpected = ref();
	let refused = false;
	try {
		proxy(READ, [unexpected]);
	} catch {
		refused = true;
	}
	assertEquals(refused, true);
	assertEquals(released, [unexpected]);
	assertEquals(await proxy(READ, [0n, 1n]), new Uint8Array([0, 1]));
});

Deno.test("attached view delivery bounds events and exposes its exact sequence gap", async () => {
	const observer = ref();
	const blocked = Promise.withResolvers<void>();
	let blockFirstEvent = true;
	const tells: Array<{ verb: string; args: unknown[] }> = [];
	const released: Ref[] = [];
	const session = {
		spawn: () => ref(),
		release: (proxy: Ref) => released.push(proxy),
		tell: (_target: Ref, verb: string, args: unknown[]) => {
			tells.push({ verb, args });
			if (verb === ROOMS_SESSION_EVENT && blockFirstEvent) {
				blockFirstEvent = false;
				return blocked.promise;
			}
			return Promise.resolve();
		},
	} as unknown as Session;
	let current = true;
	const failures: unknown[] = [];
	const file = {
		name: "note.txt",
		mime: "text/plain",
		size: 1,
		width: 0,
		height: 0,
		read: () => Promise.resolve(new Uint8Array([1])),
	} as RuntimeAttachment;
	const delivery = new AttachedViewDelivery({
		session,
		observer,
		rights: "observe",
		current: () => current,
		gapSnapshot: () => ["gap"],
		failed: (error) => failures.push(error),
	});
	delivery.queueEvent("room", message("1"), true, [file], null);
	for (let at = 2; at <= MAX_QUEUED_VIEW_EVENTS + 1; at += 1) {
		delivery.queueEvent("room", message(String(at)), true, [], null);
	}
	await settle();
	assertEquals(tells.filter((call) => call.verb === ROOMS_SESSION_CHANGED).length, 1);
	assertEquals(tells.filter((call) => call.verb === ROOMS_SESSION_EVENT).length, 1);
	blocked.resolve();
	for (let at = 0; at < 10 && tells.filter((call) => call.verb === ROOMS_SESSION_EVENT).length < 32; at += 1) {
		await settle();
	}
	delivery.queueEvent("room", message("34"), true, [], null);
	await settle();
	const events = tells.filter((call) => call.verb === ROOMS_SESSION_EVENT);
	assertEquals(events.map((call) => Number(call.args[1])), [
		...Array.from({ length: MAX_QUEUED_VIEW_EVENTS }, (_, at) => at + 1),
		34,
	]);
	assertEquals(events.every((call) => call.args[8] === false), true);
	assertEquals(released.length, 1);
	assertEquals(failures, []);
	current = false;
});

Deno.test("attached view delivery coalesces snapshots to the latest pending state", async () => {
	const blocked = Promise.withResolvers<void>();
	let first = true;
	const snapshots: unknown[][] = [];
	const session = {
		tell: (_target: Ref, verb: string, args: unknown[]) => {
			if (verb === ROOMS_SESSION_CHANGED) snapshots.push(args);
			if (first) {
				first = false;
				return blocked.promise;
			}
			return Promise.resolve();
		},
	} as unknown as Session;
	const delivery = new AttachedViewDelivery({
		session,
		observer: ref(),
		rights: "admin",
		current: () => true,
		gapSnapshot: () => [],
		failed: () => {},
	});
	delivery.queueSnapshot(["first"]);
	delivery.queueSnapshot(["second"]);
	delivery.queueSnapshot(["latest"]);
	assertEquals(snapshots, [["first"]]);
	blocked.resolve();
	await settle();
	assertEquals(snapshots, [["first"], ["latest"]]);
});

Deno.test("attached view delivery surfaces event failure after releasing its proxies", async () => {
	const released: Ref[] = [];
	const failures: string[] = [];
	let tells = 0;
	const session = {
		spawn: () => ref(),
		release: (proxy: Ref) => released.push(proxy),
		tell: () => {
			tells += 1;
			return Promise.reject(new Error("observer refused"));
		},
	} as unknown as Session;
	const delivery = new AttachedViewDelivery({
		session,
		observer: ref(),
		rights: "admin",
		current: () => true,
		gapSnapshot: () => [],
		failed: (error) => failures.push(error instanceof Error ? error.message : String(error)),
	});
	delivery.queueEvent("room", message("file"), false, [{
		name: "note.txt",
		mime: "text/plain",
		size: 1,
		width: 0,
		height: 0,
		read: () => Promise.resolve(new Uint8Array([1])),
	}], null);
	await settle();
	assertEquals(released.length, 1);
	assertEquals(failures, ["observer refused"]);
	delivery.queueEvent("room", message("after failure"), false, [], null);
	await settle();
	assertEquals(failures, ["observer refused"]);
	assertEquals(tells, 1);
});
