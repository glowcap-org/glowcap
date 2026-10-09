// A proved conflict releases the candidate; uncertainty retains exact replay.
import { assert, assertEquals } from "../assert.ts";
import { snapshot, viewer } from "../support/managed_viewer.ts";
import { AcquisitionConflict } from "../../web/ui/session/managed/acquisition.ts";
import { ManagedOperation } from "../../web/ui/session/managed/operation.ts";
import type { RoomsManagedCommand } from "../../../../zig-out/wasm/rooms/rooms_browser.js";
import { OPEN_ROOM_POLICY } from "../../lib/room/policy.ts";

Deno.test("concurrent public room acquisition converges on the committed exact publication", async () => {
	const current = snapshot();
	current.intent.directories.push({
		id: "directory",
		access: "exact-access",
		source: "exact-source",
		home: true,
		nick: "ada",
		nickAllocation: "exact",
		standing: null,
	});
	let preparations = 0;
	let freed = 0;
	const session = viewer({
		snapshot: () => Promise.resolve(current),
		preparePublicRoom: (_revision: string, selection: string) => {
			preparations++;
			const selected = JSON.parse(selection);
			return Promise.resolve({
				submit: () => {
					if (current.intent.conversations.length !== 0) return Promise.resolve("conflict");
					current.intent.conversations.push({
						kind: "room",
						id: selected.id,
						directory: selected.directory,
						name: selected.name,
						publication: selected.publication,
						publicEntry: { access: "exact-access" },
						access: null,
						control: null,
						reconnect: "requested",
						standing: null,
						draft: "",
					});
					current.revision = "2";
					return Promise.resolve("committed");
				},
				free: () => freed++,
			});
		},
	});
	try {
		const ids = await Promise.all([
			session.actions.publicRoom("directory", "garden", "exact-publication"),
			session.actions.publicRoom("directory", "garden", "exact-publication"),
		]);
		assertEquals(ids[0], ids[1]);
		assertEquals(current.intent.conversations.length, 1);
		assertEquals(preparations, 2, "the losing candidate sees a definite revision conflict");
		assertEquals(freed, 2);
		assertEquals(session.actions.pending, []);
	} finally {
		await session.close();
	}
});

for (const refusal of ["conflict", "uncertain", "replaced"]) {
	Deno.test(`managed room creation ${refusal} preserves exact admission authority`, async () => {
		const current = snapshot();
		current.intent.directories.push({
			id: "directory",
			access: "original-access",
			source: "original-source",
			home: true,
			nick: "ada",
			nickAllocation: "exact",
			standing: null,
		});
		const preparations: unknown[][] = [];
		let submissions = 0;
		let freed = 0;
		const session = viewer({
			snapshot: () => Promise.resolve(current),
			prepareCommand: (operation: string, revision: string, name: string, args: string[]) => {
				preparations.push([operation, revision, name, args]);
				return Promise.resolve({
					submit: () => {
						if (submissions++ > 0) return Promise.resolve("pending");
						if (refusal === "uncertain") return Promise.reject(new Error("lost admission"));
						current.revision = "2";
						if (refusal === "replaced") current.intent.directories[0].access = "replacement";
						return Promise.resolve("conflict");
					},
					status: () => Promise.resolve("committed"),
					free: () => freed++,
				});
			},
		});
		session.completeResult = () => Promise.resolve(undefined);
		try {
			const result = await Promise.allSettled([
				session.actions.createRoom("directory", "garden", OPEN_ROOM_POLICY),
			]);
			assertEquals(result[0].status, refusal === "conflict" ? "fulfilled" : "rejected");
			assertEquals(preparations.length, refusal === "conflict" ? 2 : 1);
			if (refusal === "conflict") {
				assertEquals(
					preparations[1][0],
					preparations[0][0],
					"conflict retains the original operation identity",
				);
				assertEquals(preparations[1][3], preparations[0][3], "conflict retains the exact target and arguments");
				assertEquals(preparations[1][1], "2");
			}
			assertEquals(freed, refusal === "uncertain" ? 0 : 1, "uncertainty retains its request");
		} finally {
			await session.close();
		}
	});
}

Deno.test("managed custody conflict releases its candidate and permits a reviewed preparation", async () => {
	let preparations = 0;
	let freed = 0;
	const session = viewer({
		snapshot: () => Promise.resolve(snapshot()),
		prepareAcquisition: () => {
			const outcome = preparations++ === 0 ? "conflict" : "committed";
			return Promise.resolve({ submit: () => Promise.resolve(outcome), free: () => freed++ });
		},
	});
	try {
		const first = await Promise.allSettled([
			session.actions.replace(snapshot()),
		]);
		assert(
			first[0].status === "rejected" && first[0].reason instanceof AcquisitionConflict,
			"a conflict is definite refusal",
		);
		assertEquals(session.actions.pending, []);
		assertEquals(freed, 1);
		await session.actions.replace(snapshot());
		assertEquals(preparations, 2);
		assertEquals(freed, 2);
	} finally {
		await session.close();
	}
});

for (const initial of ["conflict", "uncertain"]) {
	Deno.test(`directory ${initial} keeps acquired authority through conflict recovery`, async () => {
		let fetched = 0;
		let submitted = 0;
		let reprepared = 0;
		const freed: string[] = [];
		const candidate = (id: string) => ({
			submit: () => {
				if (id === "replacement") return Promise.resolve("committed");
				if (initial === "uncertain" && submitted++ === 0) return Promise.reject(new Error("lost reply"));
				return Promise.resolve("conflict");
			},
			reprepare: () => {
				reprepared++;
				assertEquals(freed, [], "original stays held through replacement admission");
				return Promise.resolve(candidate("replacement"));
			},
			free: () => freed.push(id),
		});
		const session = viewer({
			snapshot: () => Promise.resolve(snapshot()),
			prepareDirectory: () => {
				fetched++;
				return Promise.resolve(candidate("original"));
			},
		});
		try {
			const result = await Promise.allSettled([
				session.actions.directory("original", "route", { kind: "exact", name: "ada" }, true),
			]);
			if (initial === "uncertain") {
				assertEquals(result[0].status, "rejected");
				assertEquals(reprepared, 0);
				assertEquals(freed, []);
				assertEquals(session.actions.pending, ["directory:original"]);
				await session.actions.recoverAcquisition("directory:original");
			} else assertEquals(result[0].status, "fulfilled");
			assertEquals(fetched, 1, "recovery never fetches the display route again");
			assertEquals(reprepared, 1);
			assertEquals(freed, ["original", "replacement"]);
			assertEquals(session.actions.pending, []);
		} finally {
			await session.close();
		}
	});
}

for (const first of ["conflict", "uncertain"]) {
	Deno.test(`managed result ${first} preserves the committed receipt and exact recovery ownership`, async () => {
		let preparations = 0;
		let attempts = 0;
		let candidatesFreed = 0;
		let receiptsFreed = 0;
		const operation = new ManagedOperation("original", {
			prepareResultAcquisition: () => {
				preparations++;
				return Promise.resolve({
					submit: () => {
						if (attempts++ === 0) {
							return first === "conflict"
								? Promise.resolve("conflict")
								: Promise.reject(new Error("lost acknowledgement"));
						}
						return Promise.resolve("committed");
					},
					free: () => candidatesFreed++,
				});
			},
			free: () => receiptsFreed++,
		} as unknown as RoomsManagedCommand);
		try {
			const result = await Promise.allSettled([operation.acquire(snapshot(), [])]);
			assertEquals(result[0].status, "rejected");
			assertEquals(receiptsFreed, 0, "the upstream receipt remains held");
			assert(!operation.acquired, "failed acquisition cannot report committed access");
			if (first === "conflict") {
				assert(!operation.acquiring, "a proved conflict releases the stale candidate");
				assertEquals(candidatesFreed, 1);
				await operation.acquire({ ...snapshot(), revision: "2" }, []);
				assertEquals(preparations, 2);
			} else {
				assert(operation.acquiring, "uncertainty retains exact candidate custody");
				assertEquals(candidatesFreed, 0);
				await operation.retryAcquisition();
				assertEquals(preparations, 1);
			}
			assert(operation.acquired, "recovery confirms adoption of the original result");
			assertEquals(candidatesFreed, preparations);
		} finally {
			await operation.close();
		}
		assertEquals(receiptsFreed, 1);
	});
}
