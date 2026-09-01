import { OperatorRefreshQueue } from "../../web/ui/ops/operator_refresh.ts";
import { assertEquals } from "../assert.ts";

Deno.test("operator refreshes serialize and coalesce onto the newest explicit filter", async () => {
	const reads: Array<string | undefined> = [];
	const current: Array<() => boolean> = [];
	const gates: Array<PromiseWithResolvers<void>> = [];
	const started = [Promise.withResolvers<void>(), Promise.withResolvers<void>()];
	const queue = new OperatorRefreshQueue<string>((filter, isCurrent) => {
		reads.push(filter);
		current.push(isCurrent);
		const gate = Promise.withResolvers<void>();
		gates.push(gate);
		started[reads.length - 1]?.resolve();
		return gate.promise;
	});

	const first = queue.request("first");
	await started[0].promise;
	const superseded = queue.request("superseded");
	const notice = queue.request();
	const newest = queue.request("newest");
	assertEquals(reads, ["first"], "a read was started alongside the active one");
	assertEquals(current[0]?.(), false, "a superseded read still claimed to be current");

	gates[0].resolve();
	await first;
	await started[1].promise;
	assertEquals(reads, ["first", "newest"], "the queued filter did not coalesce to the newest request");
	assertEquals(current[1]?.(), true, "the newest read did not become current");

	gates[1].resolve();
	await Promise.all([superseded, notice, newest]);
});

Deno.test("a queued refresh caller receives its eventual read failure", async () => {
	const firstGate = Promise.withResolvers<void>();
	const secondStarted = Promise.withResolvers<void>();
	let reads = 0;
	const queue = new OperatorRefreshQueue<void>(() => {
		reads += 1;
		if (reads === 1) return firstGate.promise;
		secondStarted.resolve();
		return Promise.reject(new Error("queued read failed"));
	});

	const first = queue.request();
	const queued = queue.request();
	firstGate.resolve();
	await first;
	await secondStarted.promise;
	let reason = "";
	try {
		await queued;
	} catch (error) {
		reason = error instanceof Error ? error.message : String(error);
	}
	assertEquals(reason, "queued read failed");
});
