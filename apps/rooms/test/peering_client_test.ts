import type { Argument, Session } from "@glowcap/runtime";
import { refFromId } from "../../../bindings/ts/runtime/value.ts";
import type { Directory } from "../lib/directory.ts";
import { DirectoryPeering, type DurableRoom, RoomPublication } from "../lib/peering.ts";
import { PUBLISH_DURABLE_ROOM, REVOKE } from "../lib/protocol.ts";

function assert(condition: unknown, message: string): asserts condition {
	if (!condition) throw new Error(message);
}

function deferred<T>(): {
	promise: Promise<T>;
	resolve: (value: T) => void;
	reject: (reason: unknown) => void;
} {
	let resolve!: (value: T) => void;
	let reject!: (reason: unknown) => void;
	const promise = new Promise<T>((yes, no) => {
		resolve = yes;
		reject = no;
	});
	return { promise, resolve, reject };
}

Deno.test("a publication keeps its lease when deterministic release refuses", () => {
	const lease = refFromId(1n);
	let attempts = 0;
	const session = {
		release(ref: typeof lease): void {
			assert(ref === lease, "release changed the lease occurrence");
			attempts += 1;
			if (attempts === 1) throw new Error("injected release refusal");
		},
	} as unknown as Session;
	const publication = new RoomPublication(session, lease);

	let refused = false;
	try {
		publication.release();
	} catch {
		refused = true;
	}
	assert(refused, "the injected release refusal did not surface");
	publication.release();
	assert(attempts === 2, `release was attempted ${attempts} times, wanted one retry`);
});

Deno.test("release requested during revoke runs exactly once after success", async () => {
	const lease = refFromId(2n);
	const answer = deferred<Argument>();
	let releases = 0;
	const session = {
		send(): Promise<Argument> {
			return answer.promise;
		},
		release(ref: typeof lease): void {
			assert(ref === lease, "release changed the lease occurrence");
			releases += 1;
		},
	} as unknown as Session;
	const publication = new RoomPublication(session, lease);

	const revoking = publication.revoke();
	publication.release();
	answer.resolve(null);
	await revoking;
	assert(releases === 1, `release ran ${releases} times, wanted exactly once`);
	publication.release();
	assert(releases === 1, "a spent publication released its lease again");
});

Deno.test("release requested during a refused revoke still retires the local lease", async () => {
	const lease = refFromId(3n);
	const answer = deferred<Argument>();
	let releases = 0;
	const session = {
		send(): Promise<Argument> {
			return answer.promise;
		},
		release(): void {
			releases += 1;
		},
	} as unknown as Session;
	const publication = new RoomPublication(session, lease);

	const revoking = publication.revoke();
	publication.release();
	answer.reject(new Error("injected revoke refusal"));
	let refused = false;
	try {
		await revoking;
	} catch {
		refused = true;
	}
	assert(refused, "the injected revoke refusal did not surface");
	assert(releases === 1, "the local lease was discarded after the revoke refusal");
});

Deno.test("closing peering revokes a publication lease that answers late", async () => {
	const authority = refFromId(10n);
	const durable = refFromId(11n);
	const lease = refFromId(12n);
	const answer = deferred<Argument>();
	const admitted = deferred<void>();
	const released: bigint[] = [];
	let sourceReleases = 0;
	let revokes = 0;
	const destination = {
		fetch(): Promise<typeof authority> {
			return Promise.resolve(authority);
		},
		send(target: typeof authority, verb: string, args: Argument[]): Promise<Argument> {
			if (target === authority && verb === PUBLISH_DURABLE_ROOM) {
				assert(args[1] === durable, "publish changed the durable room occurrence");
				admitted.resolve();
				return answer.promise;
			}
			assert(target === lease && verb === REVOKE, `unexpected late-publication call ${verb}`);
			revokes += 1;
			return Promise.resolve(null);
		},
		release(ref: typeof authority): void {
			released.push(ref.id);
		},
	} as unknown as Session;
	const sourceSession = {
		profile: { captpVersion: "v1_0", codec: "syrup", features: 0 },
		host: { enliven: (): Promise<typeof durable> => Promise.resolve(durable) },
		release(ref: typeof durable): void {
			assert(ref === durable, "source release changed the durable occurrence");
			sourceReleases += 1;
		},
	} as unknown as Session;
	const source = { session: sourceSession } as Directory;
	const room: DurableRoom = {
		reference: durable,
		link: () => Promise.resolve("ocapn://source.example/s/room"),
	};
	const peering = await DirectoryPeering.fetch({ session: destination } as Directory, "swiss");
	const pending = peering.publish("late", room, source);
	const cancelled = pending.then(
		() => false,
		() => true,
	);
	await admitted.promise;
	const closing = peering.close();
	answer.resolve(lease);

	await closing;
	assert(await cancelled, "close let the late publication become live");
	assert(revokes === 1, `the late lease was revoked ${revokes} times, wanted exactly once`);
	assert(sourceReleases === 1, `the source occurrence was released ${sourceReleases} times`);
	assert(released.includes(authority.id), "close did not release the peering authority");
	assert(released.includes(lease.id), "late revocation did not release its lease");
});
