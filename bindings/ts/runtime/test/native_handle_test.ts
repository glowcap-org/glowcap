import {
	consumedReleaseFailure,
	NativeHandle,
	NativeParent,
	type NativeRetirement,
	SingleFlight,
} from "../transport/native_handle.ts";
import { assertDeepEquals } from "../../dogfood/assert.ts";

async function assertRejects(promise: Promise<unknown>, expected: unknown): Promise<void> {
	let rejected = false;
	try {
		await promise;
	} catch (error) {
		rejected = true;
		assertDeepEquals(error, expected);
	}
	if (!rejected) throw new Error("expected promise to reject");
}

class TestChild {
	readonly native: NativeHandle;
	readonly admitted: boolean;

	constructor(
		parent: NativeParent<TestChild>,
		shutdown: () => void,
		release: () => void | Promise<void>,
	) {
		this.native = new NativeHandle(
			"child",
			2n,
			shutdown,
			release,
			(retirement: NativeRetirement) => parent.retire(this, retirement),
		);
		this.admitted = parent.adopt(this);
	}

	close(): void {
		this.native.close();
	}
}

Deno.test("SingleFlight refuses concurrent native operations without retaining them", async () => {
	let finish!: () => void;
	const blocked = new Promise<void>((resolve) => finish = resolve);
	const gate = new SingleFlight("test read");
	const first = gate.run(() => blocked);
	await assertRejects(
		gate.run(() => Promise.resolve()),
		new Error("test read already has an operation in flight"),
	);
	finish();
	await first;
	await gate.run(() => Promise.resolve());
});

Deno.test("NativeHandle waits for leases before releasing", async () => {
	let finishUse!: () => void;
	const useFinished = new Promise<void>((resolve) => {
		finishUse = resolve;
	});
	const events: string[] = [];
	const handle = new NativeHandle(
		"test",
		1n,
		() => events.push("shutdown"),
		() => {
			events.push("release");
		},
		() => events.push("released"),
	);

	const using = handle.use(async () => await useFinished);
	handle.close();
	assertDeepEquals(events, ["shutdown"]);
	finishUse();
	await using;
	await handle.waitClosed();
	assertDeepEquals(events, ["shutdown", "release", "released"]);
});

Deno.test("NativeHandle exposes asynchronous release completion", async () => {
	let finishRelease!: () => void;
	const releaseFinished = new Promise<void>((resolve) => {
		finishRelease = resolve;
	});
	const events: string[] = [];
	const handle = new NativeHandle(
		"test",
		1n,
		() => events.push("shutdown"),
		() => {
			events.push("release");
			return releaseFinished;
		},
		() => events.push("released"),
	);

	handle.close();
	assertDeepEquals(events, ["shutdown", "release"]);
	finishRelease();
	await handle.waitClosed();
	assertDeepEquals(events, ["shutdown", "release", "released"]);
});

Deno.test("NativeHandle continues release after shutdown throws", async () => {
	const failure = new Error("shutdown failed");
	const events: string[] = [];
	const retirements: NativeRetirement[] = [];
	const handle = new NativeHandle(
		"test",
		1n,
		() => {
			events.push("shutdown");
			throw failure;
		},
		() => {
			events.push("release");
		},
		(retirement) => retirements.push(retirement),
	);

	await assertRejects(handle.waitClosed(), failure);
	assertDeepEquals(events, ["shutdown", "release"]);
	assertDeepEquals(retirements, [{ released: true, outcome: { ok: false, error: failure } }]);
});

Deno.test("NativeHandle reports failed release to its owner", async () => {
	const failure = new Error("release failed");
	const retirements: NativeRetirement[] = [];
	const handle = new NativeHandle(
		"test",
		1n,
		undefined,
		() => Promise.reject(failure),
		(retirement) => retirements.push(retirement),
	);

	await assertRejects(handle.waitClosed(), failure);
	assertDeepEquals(retirements, [{ released: false, outcome: { ok: false, error: failure } }]);
});

Deno.test("NativeHandle distinguishes consumed release failures", async () => {
	const failure = new Error("released with cleanup failure");
	const retirements: NativeRetirement[] = [];
	const handle = new NativeHandle(
		"test",
		1n,
		undefined,
		() => Promise.resolve().then(() => consumedReleaseFailure(failure)),
		(retirement) => retirements.push(retirement),
	);

	await assertRejects(handle.waitClosed(), failure);
	assertDeepEquals(retirements, [{ released: true, outcome: { ok: false, error: failure } }]);
});

Deno.test("NativeParent retains a rejected late child through release", async () => {
	let constructChild!: () => void;
	const construct = new Promise<void>((resolve) => {
		constructChild = resolve;
	});
	let finishChildRelease!: () => void;
	const childRelease = new Promise<void>((resolve) => {
		finishChildRelease = resolve;
	});
	const events: string[] = [];
	const parent = new NativeParent<TestChild>(
		"parent",
		1n,
		() => events.push("parent shutdown"),
		() => {
			events.push("parent release");
		},
	);

	let child!: TestChild;
	const operation = parent.use(async () => {
		await construct;
		child = new TestChild(
			parent,
			() => events.push("child shutdown"),
			() => {
				events.push("child release");
				return childRelease;
			},
		);
	});
	parent.close();
	constructChild();
	await operation;
	assertDeepEquals(child.admitted, false);
	assertDeepEquals(events, ["parent shutdown", "child shutdown", "child release"]);

	finishChildRelease();
	await parent.waitClosed();
	assertDeepEquals(events, [
		"parent shutdown",
		"child shutdown",
		"child release",
		"parent release",
	]);
});

Deno.test("NativeParent pins its backend when child release fails", async () => {
	const failure = new Error("child release failed");
	const events: string[] = [];
	const parent = new NativeParent<TestChild>(
		"parent",
		1n,
		() => events.push("parent shutdown"),
		() => {
			events.push("parent release");
		},
	);
	const child = new TestChild(
		parent,
		() => events.push("child shutdown"),
		() => Promise.reject(failure),
	);
	assertDeepEquals(child.admitted, true);

	await assertRejects(parent.waitClosed(), failure);
	assertDeepEquals(events, ["child shutdown", "parent shutdown"]);
});

Deno.test("NativeParent retires a child whose failed release consumed it", async () => {
	const failure = new Error("child cleanup failed after release");
	const events: string[] = [];
	const parent = new NativeParent<TestChild>(
		"parent",
		1n,
		() => events.push("parent shutdown"),
		() => {
			events.push("parent release");
		},
	);
	const child = new TestChild(
		parent,
		() => events.push("child shutdown"),
		() => Promise.resolve().then(() => consumedReleaseFailure(failure)),
	);
	assertDeepEquals(child.admitted, true);

	await assertRejects(parent.waitClosed(), failure);
	assertDeepEquals(events, ["child shutdown", "parent shutdown", "parent release"]);
});
