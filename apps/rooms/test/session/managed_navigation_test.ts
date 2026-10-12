// Immediate conversation selection survives delayed admission and exact target retirement.
import { assertEquals } from "../assert.ts";
import { deferred, snapshot } from "../support/managed_viewer.ts";
import { ManagedOpenings } from "../../web/ui/session/managed/openings.ts";
import { ManagedNavigation } from "../../web/ui/session/managed/navigation.ts";
import { WorkspaceConflict } from "../../web/ui/session/managed/operation.ts";
import type { ManagedRoomsSession } from "../../web/ui/session/managed/session.ts";

for (const cancelAt of ["handoff", "selection"] as const) {
	Deno.test(`opening cancellation at ${cancelAt} owns membership independently of form and selection`, async () => {
		const reached = deferred<void>();
		const release = deferred<void>();
		const cancel = new AbortController();
		const current = snapshot();
		current.intent.conversations.push({
			kind: "room",
			id: "new",
			directory: "dir",
			name: "new",
			access: "entry",
			control: null,
			reconnect: "requested",
			standing: null,
			draft: "",
		});
		const selected: string[] = [];
		const departed: string[] = [];
		const session = {
			pending: [],
			refresh: () => Promise.resolve(current),
			command: (_name: string, args: string[]) => {
				departed.push(args[0]);
				return Promise.resolve({});
			},
			completeResult: () => Promise.resolve(),
			navigation: {
				select: async (id: string) => {
					selected.push(id);
					if (cancelAt === "selection") {
						reached.resolve();
						await release.promise;
					}
				},
			},
		} as unknown as ManagedRoomsSession;
		const openings = new ManagedOpenings(session);
		const outcome = Promise.allSettled([openings.run(
			async (attempt) => {
				await attempt.acquired("new");
				if (cancelAt === "handoff") {
					reached.resolve();
					await release.promise;
				}
				await attempt.select("new");
			},
			null,
			cancel.signal,
		)]);
		await reached.promise;
		cancel.abort();
		release.resolve();
		assertEquals((await outcome)[0].status, cancelAt === "handoff" ? "rejected" : "fulfilled");
		await openings.close();
		assertEquals(selected, cancelAt === "handoff" ? [] : ["new"]);
		assertEquals(departed, cancelAt === "handoff" ? ["new"] : []);
	});
}

Deno.test("an opening refusal reaches its form unchanged", async () => {
	const refusal = new Error("directory refused admission");
	const openings = new ManagedOpenings({} as ManagedRoomsSession);
	const [outcome] = await Promise.allSettled([openings.run(() => Promise.reject(refusal))]);
	assertEquals(outcome.status, "rejected");
	if (outcome.status === "rejected") assertEquals(outcome.reason, refusal);
	assertEquals(openings.destination, null);
	await openings.close();
});

for (const stop of ["button", "signal"] as const) {
	Deno.test(`cancel ${stop} releases room acquisition before its worker settles and drains the original`, async () => {
		const release = deferred<void>();
		const reports: unknown[] = [];
		const navigation = new ManagedOpenings({} as ManagedRoomsSession, () => {}, (error) => reports.push(error));
		const signal = new AbortController();
		let lateSelection = false;
		const opening = navigation.run(
			async (attempt) => {
				const signal = attempt.signal;
				await release.promise;
				lateSelection = !signal.aborted;
			},
			{ kind: "room", directory: "directory", name: "slow-room" },
			signal.signal,
		);
		assertEquals(navigation.destination, { kind: "room", directory: "directory", name: "slow-room" });
		const outcome = Promise.allSettled([opening]);
		if (stop === "button") navigation.dismiss();
		else signal.abort();
		assertEquals((await outcome)[0].status, "rejected");
		assertEquals(navigation.destination, null);
		let drained = false;
		const closing = navigation.close().then(() => {
			drained = true;
		});
		await Promise.resolve();
		assertEquals(drained, false);
		release.resolve();
		await closing;
		assertEquals([lateSelection, reports.length], [false, 0]);
	});
}

Deno.test("a late acquisition refusal remains owned after cancellation and cannot clear the newer target", async () => {
	const first = deferred<void>();
	const second = deferred<void>();
	const reports: unknown[] = [];
	const navigation = new ManagedOpenings({} as ManagedRoomsSession, () => {}, (error) => reports.push(error));
	const refusal = new Error("original admission refused");
	const old = Promise.allSettled([navigation.run(async () => {
		await first.promise;
		throw refusal;
	}, { kind: "room", directory: "dir", name: "old" })]);
	const next = navigation.run(() => second.promise, { kind: "room", directory: "dir", name: "new" });
	assertEquals((await old)[0].status, "rejected");
	first.resolve();
	await Promise.resolve();
	await Promise.resolve();
	assertEquals(navigation.destination, { kind: "room", directory: "dir", name: "new" });
	second.resolve();
	await next;
	await navigation.close();
	assertEquals(reports, [refusal]);
});

Deno.test("a form unmount after selecting its acquired room preserves the selection receipt", async () => {
	const cancel = new AbortController();
	const entered = deferred<void>();
	const release = deferred<void>();
	const current = snapshot();
	current.intent.conversations.push({
		kind: "room",
		id: "room",
		directory: "directory",
		name: "garden",
		access: "entry",
		control: null,
		reconnect: "requested",
		standing: null,
		draft: "",
	});
	const session = {
		current,
		execute: async (_id: string, prepare: () => Promise<unknown>, complete: (command: unknown) => Promise<void>) =>
			complete(await prepare()),
		command: async () => {
			entered.resolve();
			await release.promise;
			current.intent.active = "room";
			return {};
		},
		completeResult: () => Promise.resolve(),
	} as unknown as ManagedRoomsSession;
	const navigation = new ManagedNavigation(session);
	Object.assign(session, { navigation });
	const openings = new ManagedOpenings(session);
	let aborted = false;
	const opening = openings.run(
		async (attempt) => {
			await attempt.select("room");
			aborted = attempt.signal.aborted;
		},
		null,
		cancel.signal,
	);
	await entered.promise;
	cancel.abort();
	release.resolve();
	await opening;
	assertEquals(aborted, false, "selection consumes the form gesture before unmount");
	assertEquals(current.intent.active, "room");
	await openings.close();
	await navigation.close();
});

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
		Object.assign(session, { navigation });
		const openings = new ManagedOpenings(session);
		const opening = openings.run(async (attempt) => {
			const id = await session.actions.direct("directory", "bo", false);
			await attempt.select(id);
		}, { kind: "direct", peer: "bo" });
		assertEquals(openings.destination, { kind: "direct", peer: "bo" });
		const outcome = Promise.allSettled([opening]);
		if (superseded === "room") {
			openings.dismiss();
			await navigation.select("room");
		} else if (superseded === "view") openings.dismiss();
		acquired.resolve("direct");
		const [result] = await outcome;
		assertEquals(result.status, superseded === "none" ? "fulfilled" : "rejected");
		assertEquals(openings.destination, null);
		assertEquals(selected, superseded === "view" ? [] : [superseded === "room" ? "room" : "direct"]);
		await openings.close();
		await navigation.close();
	});
}
