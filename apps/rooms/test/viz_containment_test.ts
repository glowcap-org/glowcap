import type { Ref } from "@pancake/runtime";
import { observeCloseFailure, observeSettledFailures, releaseRefusedCapability } from "../server/viz/lifecycle.ts";
import { MAX_REMOTE_PRODUCERS, MAX_REPLAY_ROWS, ProducerBudget } from "../server/viz/policy.ts";

Deno.test("viz subscriber close failures stay observed by the subscriber owner", async () => {
	const failures: unknown[] = [];
	observeCloseFailure(() => Promise.reject(new Error("close failed")), (error) => failures.push(error));
	await Promise.resolve();
	await Promise.resolve();
	if (failures.length !== 1) throw new Error("subscriber close rejection was not observed");
});

Deno.test("viz close observation handles synchronous close failure", () => {
	const failures: unknown[] = [];
	observeCloseFailure(() => {
		throw new Error("close failed before returning a promise");
	}, (error) => failures.push(error));
	if (failures.length !== 1) throw new Error("synchronous subscriber close failure was not observed");
});

Deno.test("viz shutdown results retain operation ownership for every rejection", async () => {
	const first = new Error("session close failed");
	const second = new Error("viewer task failed");
	const failures: Array<{ operation: string; error: unknown }> = [];
	await observeSettledFailures(
		[
			{ operation: "accepted viewer session 1 close", promise: Promise.reject(first) },
			{ operation: "viewer task 1", promise: Promise.reject(second) },
		],
		(operation, error) => failures.push({ operation, error }),
	);
	if (failures.length !== 2) throw new Error("not every shutdown rejection was observed");
	if (failures[0].operation !== "accepted viewer session 1 close" || failures[0].error !== first) {
		throw new Error("session shutdown failure lost its operation context");
	}
	if (failures[1].operation !== "viewer task 1" || failures[1].error !== second) {
		throw new Error("viewer task failure lost its operation context");
	}
});

Deno.test("a refused viz callback capability is released without replacing refusal", () => {
	const inbox = "inbox" as unknown as Ref;
	const releases: Ref[] = [];
	const releaseFailure = new Error("release failed");
	const failures: unknown[] = [];
	releaseRefusedCapability(
		{
			release(ref: Ref) {
				releases.push(ref);
				throw releaseFailure;
			},
		},
		inbox,
		(error) => failures.push(error),
	);
	if (releases.length !== 1 || releases[0] !== inbox) throw new Error("refused capability was not released");
	if (failures.length !== 1 || failures[0] !== releaseFailure) throw new Error("release failure was not observed");
});

Deno.test("viz producer and replay budgets bound the whole endpoint", () => {
	const budget = new ProducerBudget();
	for (let i = 0; i < MAX_REMOTE_PRODUCERS; i += 1) {
		if (!budget.admitRemote()) throw new Error(`producer ${i} was refused below the limit`);
	}
	if (budget.admitRemote()) throw new Error("producer limit did not bound the endpoint");
	budget.retireRemote();
	if (!budget.admitRemote()) throw new Error("retiring a producer did not restore capacity");

	for (let i = 0; i < MAX_REPLAY_ROWS; i += 1) {
		if (!budget.retainRow()) throw new Error(`replay row ${i} was refused below the limit`);
	}
	if (budget.retainRow()) throw new Error("replay limit did not bound the endpoint");
	budget.retireRow();
	if (!budget.retainRow()) throw new Error("retiring a row did not restore capacity");
});
