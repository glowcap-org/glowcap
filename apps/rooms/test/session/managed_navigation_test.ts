// Immediate conversation selection survives delayed admission and exact target retirement.
import { assertEquals } from "../assert.ts";
import { deferred, snapshot } from "../support/managed_viewer.ts";
import { ManagedNavigation } from "../../web/ui/session/managed/navigation.ts";
import { WorkspaceConflict } from "../../web/ui/session/managed/operation.ts";
import type { ManagedRoomsSession } from "../../web/ui/session/managed/session.ts";

for (const conflict of [false, true]) {
	Deno.test(`navigation keeps the newest visible room across delayed admission, conflict=${conflict}`, async () => {
		const current = snapshot();
		for (const id of ["first", "second"]) {
			current.intent.conversations.push({
				kind: "room",
				id,
				directory: "directory",
				name: id,
				source: "source",
				access: "entry",
				control: "manager",
				reconnect: "manual",
				standing: null,
				draft: "",
			});
		}
		const entered = deferred<void>();
		const release = deferred<void>();
		const admitted: string[] = [];
		let attempts = 0;
		const session = {
			current,
			execute: async (
				_id: string,
				prepare: () => Promise<unknown>,
				complete: (command: unknown) => Promise<void>,
			) => {
				await complete(await prepare());
			},
			command: async (_name: string, args: string[], _id: string, validate: (value: typeof current) => void) => {
				validate(current);
				if (++attempts === 1) {
					entered.resolve();
					await release.promise;
					if (conflict) throw new WorkspaceConflict();
				}
				admitted.push(args[0]);
				current.intent.active = args[0];
				return {};
			},
			completeResult: () => Promise.resolve(),
		} as unknown as ManagedRoomsSession;
		const navigation = new ManagedNavigation(session);
		const first = navigation.select("first");
		await entered.promise;
		const second = navigation.select("second");
		assertEquals(navigation.selected, "second");
		release.resolve();
		await Promise.all([first, second]);
		assertEquals(admitted, ["first", "second"]);
		assertEquals(current.intent.active, "second");
		assertEquals(navigation.selected, undefined);
		await navigation.close();
	});
}

Deno.test("navigation revision contention preserves the visible room and permits another save", async () => {
	const current = snapshot();
	current.intent.conversations.push({
		kind: "room",
		id: "room",
		directory: "directory",
		name: "garden",
		source: "source",
		access: "entry",
		control: "manager",
		reconnect: "manual",
		standing: null,
		draft: "",
	});
	let conflicts = true;
	let attempts = 0;
	const session = {
		current,
		pending: [],
		execute: async (_id: string, prepare: () => Promise<unknown>, complete: (command: unknown) => Promise<void>) =>
			complete(await prepare()),
		command: (_name: string, _args: string[], _id: string, validate: (value: typeof current) => void) => {
			validate(current);
			attempts++;
			if (conflicts) return Promise.reject(new WorkspaceConflict());
			current.intent.active = "room";
			return Promise.resolve({});
		},
		completeResult: () => Promise.resolve(),
	} as unknown as ManagedRoomsSession;
	const navigation = new ManagedNavigation(session);
	const [outcome] = await Promise.allSettled([navigation.select("room")]);
	assertEquals(outcome.status, "rejected");
	assertEquals(attempts, 4);
	assertEquals(navigation.selected, "room");
	conflicts = false;
	await navigation.select("room");
	assertEquals(current.intent.active, "room");
	assertEquals(navigation.selected, undefined);
	await navigation.close();
});

Deno.test("known navigation refusal releases its visible selection after the room is removed", async () => {
	const current = snapshot();
	current.intent.conversations.push({
		kind: "room",
		id: "room",
		directory: "directory",
		name: "garden",
		source: "source",
		access: "entry",
		control: "manager",
		reconnect: "manual",
		standing: null,
		draft: "",
	});
	const session = {
		current,
		pending: [],
		execute: async (_id: string, prepare: () => Promise<unknown>) => {
			await prepare();
		},
		command: (_name: string, _args: string[], _id: string, validate: (value: typeof current) => void) => {
			validate(current);
			current.intent.conversations = [];
			return Promise.reject(new WorkspaceConflict());
		},
	} as unknown as ManagedRoomsSession;
	const navigation = new ManagedNavigation(session);
	const [outcome] = await Promise.allSettled([navigation.select("room")]);
	assertEquals(outcome.status, "rejected");
	assertEquals(navigation.selected, undefined);
	await navigation.close();
});

for (const superseded of ["none", "room", "view"] as const) {
	Deno.test(`direct acquisition owns pending destination and respects later navigation, superseded=${superseded}`, async () => {
		const current = snapshot();
		for (const id of ["room", "direct"]) {
			current.intent.conversations.push({
				kind: "room",
				id,
				directory: "directory",
				name: id,
				source: "source",
				access: "entry",
				control: null,
				reconnect: "manual",
				standing: null,
				draft: "",
			});
		}
		const acquired = deferred<string>();
		const selected: string[] = [];
		const session = {
			current,
			pending: [],
			actions: { direct: () => acquired.promise },
			execute: async (
				_id: string,
				prepare: () => Promise<unknown>,
				complete: (operation: unknown) => Promise<void>,
			) => complete(await prepare()),
			command: (_name: string, args: string[]) => {
				selected.push(args[0]);
				return Promise.resolve({});
			},
			completeResult: () => Promise.resolve(),
		} as unknown as ManagedRoomsSession;
		const navigation = new ManagedNavigation(session);
		const opening = navigation.openDirect("directory", "bo");
		assertEquals(navigation.destination, "bo");
		if (superseded === "room") await navigation.select("room");
		else if (superseded === "view") navigation.dismissAcquisition();
		acquired.resolve("direct");
		await opening;
		assertEquals(navigation.destination, null);
		assertEquals(selected, superseded === "view" ? [] : [superseded === "room" ? "room" : "direct"]);
		await navigation.close();
	});
}
