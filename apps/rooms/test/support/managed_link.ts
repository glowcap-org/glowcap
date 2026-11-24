// Controlled time and a controlled pair of workspaces for the link between a
// page and a session a process elsewhere runs.
import type { RoomsManagedCommand } from "../../../../zig-out/wasm/rooms/rooms_browser.js";
import type { LinkClock } from "../../web/ui/session/managed/link.ts";
import type { ObservationView } from "../../web/ui/session/managed/model.ts";
import { snapshot } from "./managed_viewer.ts";

/** A clock that moves only when a test advances it. */
export class FakeClock implements LinkClock {
	time = 0;
	chance = 0;
	readonly #timers = new Map<number, { at: number; run: () => void }>();
	#next = 0;
	now(): number {
		return this.time;
	}
	random(): number {
		return this.chance;
	}
	after(ms: number, run: () => void): () => void {
		const id = this.#next++;
		this.#timers.set(id, { at: this.time + ms, run });
		return () => this.#timers.delete(id);
	}
	/** How many timers wait to fire. */
	get waiting(): number {
		return this.#timers.size;
	}
	/** The wait until the next timer fires, or null with none. */
	get next(): number | null {
		const times = [...this.#timers.values()].map((timer) => timer.at - this.time);
		return times.length === 0 ? null : Math.min(...times);
	}
	#due(target: number) {
		let due: [number, { at: number; run: () => void }] | null = null;
		for (const entry of this.#timers) {
			if (entry[1].at <= target && (due == null || entry[1].at < due[1].at)) due = entry;
		}
		return due;
	}
	/** Move time forward, running each timer that falls due in order. */
	advance(ms: number): void {
		const target = this.time + ms;
		let due = this.#due(target);
		while (due != null) {
			this.#timers.delete(due[0]);
			this.time = Math.max(this.time, due[1].at);
			due[1].run();
			due = this.#due(target);
		}
		this.time = target;
	}
}

/** Let every promise that can settle without time settle. The fakes answer
 * with promises alone, and one macrotask turn runs every microtask they chain. */
export function settle(): Promise<void> {
	return new Promise<void>((done) => setTimeout(done, 0));
}

export function failure(status: number, reason: string, code: string | null = null): Error {
	return Object.assign(new Error(`glowcap error ${status}: ${reason}`), { status, reason, code, detail: reason });
}
/** What a broken connection says. */
export const closed = (): Error => failure(-7, "session closing");

export const update: ObservationView = {
	cursor: new Uint8Array(56),
	source: { status: "active", effective: { permissions: ["observeWorkspace", "resolvePending"] } },
	changed: true,
	resync: false,
};

/** One workspace over one link. Its observation and activity reader answer from
 * script, and park until `lose` breaks the link under them. */
export function linkedWorkspace(
	name: string,
	log: string[],
	extra: Record<string, unknown> = {},
	/** The run of the session this workspace reaches. */
	incarnation = "run",
) {
	const waiting = new Set<(error: Error) => void>();
	/** Once the link breaks, every later call on it fails the same way. */
	let broken: Error | null = null;
	const park = <T>(): Promise<T> =>
		broken != null ? Promise.reject(broken) : new Promise<T>((_, reject) => waiting.add(reject));
	const state = { freed: 0, observations: 0, readers: 0, observationFreed: 0, readerFreed: 0 };
	const reads: string[] = [];
	const script: { reply(cursor: string): unknown }[] = [];
	const observation = {
		poll: () => {
			log.push(`${name}:poll`);
			return Promise.resolve(update);
		},
		receive: () => {
			log.push(`${name}:receive`);
			return park<ObservationView>();
		},
		cancel: () => {
			log.push(`${name}:cancel`);
			// Cancelling ends the read parked on the observation, as it does for a real one.
			for (const reject of [...waiting]) reject(new Error("observation cancelled"));
			waiting.clear();
			return Promise.resolve();
		},
		free() {
			state.observationFreed++;
		},
	};
	const reader = {
		read: (cursor: string, wait = true) => {
			reads.push(cursor);
			const next = script.shift();
			// A read that does not wait answers at once with the journal's head.
			if (next == null && !wait) {
				const head = cursor.startsWith(`${incarnation}:`) ? cursor : `${incarnation}:0`;
				return Promise.resolve({ cursor: head, head, gap: false, event: null });
			}
			return next == null ? park() : Promise.resolve(next.reply(cursor)).then((reply) => {
				if (reply instanceof Error) throw reply;
				return reply;
			});
		},
		free() {
			state.readerFreed++;
		},
	};
	const workspace = {
		snapshot: () => Promise.resolve(snapshot()),
		prepareObservation: () => {
			state.observations++;
			log.push(`${name}:register`);
			return Promise.resolve({ submit: () => Promise.resolve(observation), free() {} });
		},
		activityReader: () => {
			state.readers++;
			return Promise.resolve(reader);
		},
		resynchronizeDiscovery: () => Promise.resolve(),
		effects: () => Promise.resolve([]),
		free() {
			state.freed++;
		},
		...extra,
	};
	return {
		workspace,
		state,
		reads,
		script,
		/** A call that parks on the link and fails when it breaks. */
		park,
		/** Break the link: every call parked on it rejects as a closed connection does. */
		lose(error: Error = closed()) {
			broken = error;
			for (const reject of [...waiting]) reject(error);
			waiting.clear();
		},
	};
}

/** A command request over a link that has `submit` and `status` answer as given,
 * and that remembers `intent` as the session's own record of the command. */
export function request(
	submit: () => Promise<unknown>,
	status: () => Promise<string>,
	intent: unknown = null,
): RoomsManagedCommand {
	return { submit, status, originalIntent: () => intent, free() {} } as unknown as RoomsManagedCommand;
}

/** A receipt the new link recovers by operation id, whose record says `status`. */
export function recovered(status: string, log: string[]) {
	return {
		recoverEffect: (id: string) => {
			log.push(id);
			return Promise.resolve({
				status: () => Promise.resolve(status),
				resume: () => Promise.resolve(status),
				result: () => status === "committed" ? Promise.resolve(null) : Promise.reject(failure(-12, "refused")),
				free() {},
			});
		},
	};
}
