// Draft writes preserve newer edits, original receipts and exact authority across contention.
import { assertEquals } from "../assert.ts";
import { deferred, snapshot, viewer } from "../support/managed_viewer.ts";
import type { ManagedOperation } from "../../web/ui/session/managed/operation.ts";

Deno.test("managed draft acknowledgment cannot erase a newer local edit", async () => {
	const accepted = snapshot();
	accepted.intent.conversations.push({
		kind: "direct",
		id: "dm",
		directory: "dir",
		peer: "peer",
		access: null,
		closed: false,
		draft: "old",
	});
	const session = viewer({ snapshot: () => Promise.resolve(accepted) });
	await session.refresh();
	const first = deferred<void>();
	const entered = deferred<void>();
	const values: string[] = [];
	session.command = async (_name, args = []) => {
		values.push(args[1]);
		entered.resolve();
		if (values.length === 1) await first.promise;
		return { result: () => Promise.resolve(null) } as unknown as ManagedOperation;
	};
	session.finish = () => {};
	session.drafts.stage("dm", "first");
	const writing = session.drafts.flush("dm");
	await entered.promise;
	session.drafts.stage("dm", "latest");
	assertEquals(session.drafts.value("dm", "old"), "latest");
	first.resolve();
	await writing;
	assertEquals(values, ["first", "latest"]);
	assertEquals(session.drafts.value("dm", "accepted"), "accepted");
	await session.close();
});

Deno.test("managed draft completion needs no recovery permission before sending a newer edit", async () => {
	const accepted = snapshot();
	accepted.intent.conversations.push({
		kind: "direct",
		id: "dm",
		directory: "dir",
		peer: "peer",
		access: null,
		closed: false,
		draft: "old",
	});
	const writes: string[] = [];
	let submissions = 0;
	let recovered = 0;
	const session = viewer({
		snapshot: () => Promise.resolve(accepted),
		prepareCommand: (_operation: string, _revision: string, name: string, args: string[]) => {
			assertEquals(name, "setDraft");
			writes.push(args[1]);
			return Promise.resolve({
				submit: () =>
					++submissions === 1
						? Promise.reject(new Error("commit acknowledgment missing"))
						: Promise.resolve("committed"),
				status: () => Promise.resolve("committed"),
				result: () => Promise.resolve(null),
				free() {},
			});
		},
		recoverEffect: () => {
			recovered++;
			return Promise.reject(new Error("glowcap error -12: Denied"));
		},
	});
	await session.refresh();
	session.drafts.stage("dm", "first");
	const refused = await Promise.allSettled([session.drafts.flush("dm")]);
	assertEquals(refused[0].status, "rejected");
	assertEquals(session.pending.length, 1);
	session.drafts.stage("dm", "latest");
	await session.drafts.flush("dm");
	assertEquals(recovered, 0);
	assertEquals(writes, ["first", "latest"], "lost acknowledgment cannot prepare the first write again");
	assertEquals(session.pending, []);
	await session.close();
});

for (const changed of ["unrelated", "draft", "authority", "repeated"] as const) {
	Deno.test(`managed draft conflict rebases only unchanged intent: ${changed}`, async () => {
		const accepted = snapshot();
		const conversation = {
			kind: "direct" as const,
			id: "dm",
			directory: "dir",
			peer: "peer",
			access: "original",
			closed: false,
			draft: "old",
		};
		accepted.intent.conversations.push(conversation);
		let submissions = 0;
		const session = viewer({
			snapshot: () => Promise.resolve(accepted),
			prepareCommand: () =>
				Promise.resolve({
					submit: () => {
						submissions++;
						if (submissions === 1 || changed === "repeated") {
							accepted.revision = String(Number(accepted.revision) + 1);
							if (changed === "draft") conversation.draft = "another viewer's edit";
							if (changed === "authority") conversation.access = "replacement";
							return Promise.resolve("conflict");
						}
						return Promise.resolve("committed");
					},
					status: () => Promise.resolve("committed"),
					result: () => Promise.resolve(null),
					free() {},
				}),
		});
		await session.refresh();
		session.drafts.stage("dm", "my edit");
		const [outcome] = await Promise.allSettled([session.drafts.flush("dm")]);
		assertEquals(outcome.status, changed === "unrelated" ? "fulfilled" : "rejected");
		assertEquals(submissions, changed === "unrelated" || changed === "repeated" ? 2 : 1);
		assertEquals(session.pending, [], "a conflict proves absence of admission");
		assertEquals(session.drafts.value("dm", "accepted"), changed === "unrelated" ? "accepted" : "my edit");
		await session.close();
	});
}

Deno.test("a slow draft leaves another conversation free to settle", async () => {
	const accepted = snapshot();
	for (const id of ["a", "b"]) {
		accepted.intent.conversations.push({
			kind: "direct",
			id,
			directory: "dir",
			peer: id,
			access: null,
			closed: false,
			draft: "",
		});
	}
	const first = deferred<void>();
	const entered = deferred<void>();
	const completed: string[] = [];
	const session = viewer({ snapshot: () => Promise.resolve(accepted) });
	await session.refresh();
	session.command = async (_name, args = []) => {
		if (args[0] === "a") {
			entered.resolve();
			await first.promise;
		}
		completed.push(args[0]);
		return { result: () => Promise.resolve(null) } as unknown as ManagedOperation;
	};
	session.finish = () => {};
	session.drafts.stage("a", "slow");
	const a = session.drafts.flush("a");
	await entered.promise;
	session.drafts.stage("b", "independent");
	await session.drafts.flush("b");
	assertEquals(completed, ["b"]);
	first.resolve();
	await a;
	await session.close();
});

Deno.test("background draft failure keeps newer text and one persistent notice until retry", async () => {
	const accepted = snapshot();
	accepted.intent.conversations.push({
		kind: "direct",
		id: "dm",
		directory: "dir",
		peer: "bo",
		access: null,
		closed: false,
		draft: "",
	});
	const session = viewer({ snapshot: () => Promise.resolve(accepted) });
	await session.refresh();
	let attempts = 0;
	session.command = () => {
		attempts++;
		return Promise.reject(new Error("storage unavailable"));
	};
	session.drafts.stage("dm", "first");
	await Promise.allSettled([session.drafts.flush("dm")]);
	for (let i = 0; i < 50; i++) {
		session.drafts.stage("dm", `latest ${i}`);
		session.drafts.sync("dm");
	}
	assertEquals(attempts, 1);
	assertEquals(session.drafts.value("dm", ""), "latest 49");
	assertEquals(session.drafts.failure("dm").includes("storage unavailable"), true);
	session.command = () => Promise.resolve({ result: () => Promise.resolve(null) } as unknown as ManagedOperation);
	session.finish = () => {};
	await session.drafts.flush("dm");
	assertEquals(session.drafts.failure("dm"), "");
	await session.close();
});
