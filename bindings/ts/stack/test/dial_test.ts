import { acceptRemoteCandidate } from "../dial.ts";
import { SignalingSendOwner } from "../signaling.ts";

function assert(value: unknown, message: string): void {
	if (!value) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown): void {
	if (actual !== expected) {
		throw new Error(`expected ${String(expected)}, got ${String(actual)}`);
	}
}

Deno.test("candidate ownership converts synchronous send throws into dial failure", async () => {
	const failure = new Error("candidate send failed");
	const bringup = new AbortController();
	let observed: Error | null = null;
	const owner = new SignalingSendOwner("webrtc dial", (error) => {
		observed = error;
		bringup.abort(error);
	});

	owner.admit(() => {
		throw failure;
	});
	await owner.join();

	assertEquals(observed, failure);
	assertEquals(owner.failure, failure);
	assert(bringup.signal.aborted, "candidate failure did not abort bring-up");
	assertEquals(bringup.signal.reason, failure);
});

Deno.test("candidate ownership joins admitted sends and closes admission", async () => {
	let finish!: () => void;
	const pending = new Promise<void>((resolve) => finish = resolve);
	let admittedAfterStop = false;
	let joined = false;
	const owner = new SignalingSendOwner("webrtc dial", () => {
		throw new Error("unexpected candidate failure");
	});

	owner.admit(() => pending);
	owner.stopAdmission();
	owner.admit(() => {
		admittedAfterStop = true;
	});
	const joining = owner.join().then(() => joined = true);
	await Promise.resolve();
	assert(!joined, "join completed before the admitted send settled");
	assert(!admittedAfterStop, "a send was admitted after cleanup began");

	finish();
	await joining;
	assert(joined, "join did not complete after the admitted send settled");
});

Deno.test("candidate ownership converts rejected sends into dial failure", async () => {
	const failure = new Error("candidate promise rejected");
	let observed: Error | null = null;
	const owner = new SignalingSendOwner("webrtc dial", (error) => observed = error);

	owner.admit(() => Promise.reject(failure));
	await owner.join();

	assertEquals(observed, failure);
	assertEquals(owner.failure, failure);
});

Deno.test("candidate ownership bounds unresolved signaling sends", async () => {
	let finish!: () => void;
	const pending = new Promise<void>((resolve) => finish = resolve);
	let observed: Error | null = null;
	const owner = new SignalingSendOwner("webrtc dial", (error) => observed = error);
	for (let i = 0; i < SignalingSendOwner.maxPending; i++) {
		owner.admit(() => pending.then(() => {}));
	}
	owner.admit(() => pending.then(() => {}));
	assert(observed != null, "candidate pressure did not fail the dial");
	assert(
		String(observed).includes("too many pending signaling sends"),
		"candidate pressure reported the wrong failure",
	);
	finish();
	await owner.join();
});

Deno.test("late remote candidates tolerate parse and peer failures", async () => {
	let received = 0;
	acceptRemoteCandidate({
		addRemoteCandidate: () => {
			received++;
			return Promise.reject(new Error("peer already closed"));
		},
	}, "{}");
	acceptRemoteCandidate({
		addRemoteCandidate: () => {
			throw new Error("peer already closed");
		},
	}, "not-json");

	await Promise.resolve();
	assertEquals(received, 1);
});
