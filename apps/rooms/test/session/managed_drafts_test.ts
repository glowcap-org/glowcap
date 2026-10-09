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

Deno.test("managed draft recovery completes the original write before sending a newer edit", async () => {
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
		recoverEffect: () =>
			Promise.resolve({
				status: () => Promise.resolve("pending"),
				resume: () => {
					recovered++;
					return Promise.resolve("committed");
				},
				free() {},
			}),
	});
	await session.refresh();
	session.drafts.stage("dm", "first");
	const refused = await Promise.allSettled([session.drafts.flush("dm")]);
	assertEquals(refused[0].status, "rejected");
	assertEquals(session.pending.length, 1);
	session.drafts.stage("dm", "latest");
	await session.drafts.flush("dm");
	assertEquals(recovered, 1);
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
