// Controlled time and a controlled pair of workspaces for the link between a
// page and a session a process elsewhere runs.
import { Committed } from "../../web/ui/session/managed/committed.ts";
import type { Sending } from "../../web/ui/session/managed/session.ts";
import type { RoomsManagedCommand, RoomsManagedWorkspace } from "../../../../zig-out/wasm/rooms/rooms_browser.js";
import { ManagedOperation } from "../../web/ui/session/managed/operation.ts";
import { backoff, type LinkClock, type ManagedLink } from "../../web/ui/session/managed/link.ts";
import { FIRST_LINK } from "../../web/ui/session/managed/link_port.ts";
import type { ObservationView } from "../../web/ui/session/managed/model.ts";
import { type LinkPort, linkPort } from "../../web/ui/session/managed/link_port.ts";
import type { ManagedRoomsSession } from "../../web/ui/session/managed/session.ts";
import type { AccessMove } from "../../web/ui/session/managed/control_reach.ts";
import type { ActionSession } from "../../web/ui/session/managed/actions.ts";
import type { ManagedNavigation } from "../../web/ui/session/managed/navigation.ts";
import { snapshot, viewer } from "./managed_viewer.ts";
import { browserFailure } from "./browser_failure.ts";
import { until } from "./wait.ts";

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

/** Wait until the page's link waits out a backoff before it dials again, as
 * one lost soon after it came back does, and let that wait pass. */
export async function backedOff(session: { readonly link: ManagedLink | null }, clock: FakeClock): Promise<void> {
	await until(() => session.link?.state.kind === "waiting", "the link to wait before it dials again");
	const state = session.link?.state;
	if (state?.kind === "waiting") clock.advance(backoff(state.attempt, clock.chance));
}

/** What a call through the attached session says when its connection closes:
 * Rust names the session unreachable and keeps the binding's words. */
export const closed = (): Error => browserFailure(null, "session closing", "session-unreachable");
/** A submit's outcome with `status`, as `submission` in
 * rust/browser/src/attached/managed/outcome.rs answers one with an error: its
 * text as `reason`, beside its projection as `failure`. A binding status
 * leads the text, as the binding's error prints it. */
export function failedOutcome(
	status: "refused" | "uncertain",
	failure: { status: number | null; reason: string; code: string | null; detail?: string },
) {
	return {
		status,
		reason: failure.status == null ? failure.reason : `glowcap error ${failure.status}: ${failure.reason}`,
		failure: { detail: failure.reason, retryAfterMs: null, scope: null, owner: null, ...failure },
	};
}
const outcomeFailing = (code: string, reason: string) => failedOutcome("uncertain", { status: null, reason, code });
/** What a submit resolves when its connection is closed, whether it closed
 * before the session answered or was already closed when the request was sent:
 * `uncertain`, carrying the closed connection as Rust projects it. A caller
 * attached to a session maps a closed connection to `Error::Unreached` through
 * `Caller::wait`, which `submission_status` reads as uncertain, so no closed
 * connection is `refused`. */
export const closedOutcome = () => outcomeFailing("session-unreachable", "session closing");
/** What a submit resolves when the session missed its deadline but still
 * answers: `uncertain`, with the connection standing. */
export const timedOutOutcome = () => outcomeFailing("session-request-timed-out", "no answer in time");

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
	/** Once the link breaks, a parked call and every later activity read on it
	 * fail the same way. Its other members keep answering. */
	let broken: Error | null = null;
	const park = <T>(): Promise<T> =>
		broken != null ? Promise.reject(broken) : new Promise<T>((_, reject) => waiting.add(reject));
	const state = { freed: 0, retired: 0, observations: 0, readers: 0, observationFreed: 0, readerFreed: 0 };
	const reads: string[] = [];
	const script: { reply(cursor: string): unknown }[] = [];
	let answerPoll = (): Promise<ObservationView> => Promise.resolve(update);
	const observation = {
		poll: () => {
			log.push(`${name}:poll`);
			return answerPoll();
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
			if (broken != null) return Promise.reject(broken);
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
		retire: () => {
			state.retired++;
			return Promise.resolve();
		},
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
		/** Answer every later poll, a probe's among them, with `answer`. */
		polling(answer: () => Promise<ObservationView>) {
			answerPoll = answer;
		},
		/** A submit that parks on the link and, when it breaks, resolves as one
		 * whose reply was lost. */
		submitLost: () => park().then(() => ({ status: "committed" }), () => closedOutcome()),
		/** Break the link: every call parked on it rejects as a closed connection does. */
		lose(error: Error = closed()) {
			broken = error;
			for (const reject of [...waiting]) reject(error);
			waiting.clear();
		},
	};
}

/** An object of class `T`, faked by the members its test reads. Each is typed
 * as the class declares it. A class keeps private state no object literal can
 * hold, so this is the one place a fake stands in for one. */
export function fakeHandle<T>(fields: Partial<T>): T;
export function fakeHandle(fields: object): unknown {
	return fields;
}

/** `fields` as a binding handle, which refuses every call once freed, a
 * second free among them, as a wasm-bindgen handle does: its pointer is null
 * by then, and Rust refuses a null pointer. `misuse` hears each such call by
 * name, for a test whose page would swallow the refusal. */
export function bindingHandle<T extends { free(): void }>(
	fields: Partial<T>,
	misuse: (member: string) => void = () => {},
): T {
	let freed = false;
	const refuseFreed = (key: string | symbol) => {
		if (!freed) return;
		misuse(String(key));
		throw new Error("null pointer passed to rust");
	};
	return fakeHandle<T>(
		new Proxy(fields, {
			get(target, key, receiver) {
				const value: unknown = Reflect.get(target, key, receiver);
				if (typeof value !== "function") return value;
				return (...args: unknown[]) => {
					refuseFreed(key);
					if (key === "free") freed = true;
					return Reflect.apply(value, target, args);
				};
			},
		}),
	);
}

/** A link to `workspace` that is never replaced, for actions built beside a
 * session. */
export function oneLink(workspace: Partial<RoomsManagedWorkspace>): LinkPort {
	const handle = fakeHandle<RoomsManagedWorkspace>(workspace);
	return linkPort({
		current: () => ({ workspace: handle, generation: FIRST_LINK }),
		lost() {},
		available: () => Promise.resolve(false),
		ready: () => Promise.resolve(),
	});
}

/** A command request over a link that has `submit` and `status` answer as given,
 * and that remembers `intent` as the session's own record of the command. Every
 * other call refuses, so a test that reaches one fails by name. */
export function request(
	submit: () => Promise<unknown>,
	status: () => Promise<string>,
	intent: unknown = null,
): RoomsManagedCommand {
	const unexpected = (call: string) => () => Promise.reject(new Error(`this fake command does not answer ${call}`));
	return {
		submit,
		status,
		originalIntent: () => intent,
		adopted: unexpected("adopted"),
		prepareCreatedRoomAcquisition: unexpected("prepareCreatedRoomAcquisition"),
		prepareResultAcquisition: unexpected("prepareResultAcquisition"),
		receive: unexpected("receive"),
		release: unexpected("release"),
		result: unexpected("result"),
		free() {},
		[Symbol.dispose]() {},
	};
}

/** A receipt the new link recovers by operation id, whose record says `status`. */
export function recovered(status: string, log: string[]) {
	return {
		recoverEffect: (id: string) => {
			log.push(id);
			return Promise.resolve({
				status: () => Promise.resolve(status),
				resume: () => Promise.resolve(status),
				result: () =>
					status === "committed" ? Promise.resolve(null) : Promise.reject(browserFailure(-12, "refused")),
				free() {},
			});
		},
	};
}

/** A started attached session over workspace `first`, and the workspaces a dial returns in turn. */
export async function attached(rest: ReturnType<typeof linkedWorkspace>[], incarnation = "run") {
	const log: string[] = [];
	const first = linkedWorkspace("first", log, {}, incarnation);
	const later = rest.map((workspace) => workspace);
	const clock = new FakeClock();
	const reported: unknown[] = [];
	const dials: { id: string; stale: unknown }[] = [];
	const session = viewer(
		first.workspace,
		(_source, error) => reported.push(error),
		{
			relink: (id: string, stale: unknown) => {
				dials.push({ id, stale });
				log.push("relink");
				const next = later.shift();
				return next == null ? Promise.reject(closed()) : Promise.resolve(next.workspace);
			},
		},
		false,
		clock,
	);
	await session.start();
	return { session, first, clock, log, reported, dials };
}

/** A page attached over `first`, not yet started, whose first dial reaches
 * `second` and every later one `third`, or `second` again without it. `report`
 * hears what the page reports, and `application` adds to what the browser
 * application answers. `dials` counts the dials so far, `relinked` waits for
 * the first dial's link to be live, and `clock` paces the dials after it. */
export function relinking(
	first: Record<string, unknown>,
	second: Record<string, unknown>,
	options: {
		report?: (source: string, error: unknown) => void;
		application?: Record<string, unknown>;
		third?: Record<string, unknown>;
	} = {},
) {
	let dials = 0;
	const relink = () => {
		dials++;
		return Promise.resolve(dials > 1 && options.third != null ? options.third : second);
	};
	const clock = new FakeClock();
	const session = viewer(first, options.report, { ...options.application, relink }, false, clock);
	return {
		session,
		clock,
		dials: () => dials,
		relinked: () => until(() => dials === 1 && session.link?.live === true, "the new link"),
	};
}

/** A held operation on the page's first link, over a fake `request`. A fake
 * answers only what its test calls, so it stands in for the binding's type. */
export function operationOf(id: string, request: Partial<RoomsManagedCommand>, status?: string): ManagedOperation {
	return new ManagedOperation(id, fakeHandle<RoomsManagedCommand>(request), { generation: FIRST_LINK }, status);
}

/** A saved access or control handle named `name`, as a restore or a share
 * answers it: available at revision 1, with its release recorded in `freed`.
 * `extra` adds what the test calls on it. */
export function savedHandle(freed: string[], name: string, extra: Record<string, unknown> = {}) {
	return {
		name,
		describe: () => Promise.resolve({ available: true, revision: "1" }),
		free: () => freed.push(name),
		...extra,
	};
}

/** What a member a test does not give answers: it refuses by name, so a test
 * that reaches one fails saying which. */
export function unread(name: string): () => never {
	return () => {
		throw new Error(`the test gave no ${name}`);
	};
}

/** The door of a session whose link is never replaced: each request runs over
 * `workspace`, no lost connection is one the link tells, and no new link comes. */
export function oneLinkDoor(
	workspace: Partial<RoomsManagedWorkspace> = {},
): Pick<ManagedRoomsSession, "request" | "requestNow" | "linkTells" | "onRelink"> {
	const handle = fakeHandle<RoomsManagedWorkspace>(workspace);
	return {
		request: (call) => call(handle),
		requestNow: (call) => call(handle),
		linkTells: () => false,
		onRelink: () => () => {},
	};
}

/** What a test may give `actionSession` in place of the real session's
 * `press` and `committed`: the older pieces they are built from. */
export interface ActionPieces {
	execute?: (
		id: string,
		prepare: () => Promise<ManagedOperation>,
		complete: (command: ManagedOperation) => Promise<unknown>,
	) => Promise<unknown>;
	command?: ManagedRoomsSession["command"];
	completeResult?: ManagedRoomsSession["completeResult"];
	readNow?: ManagedRoomsSession["readNow"];
	candidateNow?: ManagedRoomsSession["candidateNow"];
	/** What the second change of a follow-up reaches. */
	actions?: ManagedRoomsSession["actions"];
	/** Collects the notices a follow-up reports. */
	notices?: { source: string; error: unknown }[];
}

/** The default owner of a press: it sends the change and completes it once. */
const completing: NonNullable<ActionPieces["execute"]> = async (_id, send, complete) => {
	await complete(await send());
};

/** The environment a page's session gives what runs on its clock: the
 * notices it reports are kept in `notices`. */
export function fakeEnvironment() {
	const clock = new FakeClock();
	const notices: { source: string; error: unknown }[] = [];
	return {
		clock,
		notices,
		effects: fakeHandle<ManagedRoomsSession["effects"]>({
			environment: fakeHandle<ManagedRoomsSession["effects"]["environment"]>({
				clock,
				stopped: () => false,
				report: (source: string, error: unknown) => notices.push({ source, error }),
			}),
		}),
	};
}

/** The owner entry a press runs through: `press` and `committed` over the
 * older pieces they are built from, with `committed` the real `Committed`, so
 * a test meets the owner's rules: a lost link throws and any other failure is
 * a notice. `current` and `requestNow` answer what a follow-up reads. */
export function ownerEntry(
	pieces: ActionPieces & {
		current?: ManagedRoomsSession["current"];
		requestNow?: ManagedRoomsSession["requestNow"];
	},
): Pick<ManagedRoomsSession, "press" | "committed"> {
	// The pieces are read when they are used, so a test may replace one after
	// the session is built.
	const owner = fakeHandle<ConstructorParameters<typeof Committed>[0]>({
		get current() {
			return pieces.current ?? null;
		},
		readNow: (...args: []) => (pieces.readNow ?? unread("readNow"))(...args),
		candidateNow: (...args: []) => (pieces.candidateNow ?? unread("candidateNow"))(...args),
		requestNow: (call) => (pieces.requestNow ?? unread("requestNow"))(call),
		get actions() {
			return pieces.actions as ManagedRoomsSession["actions"];
		},
		completeResult: (operation) => (pieces.completeResult ?? unread("completeResult"))(operation),
	});
	const report = (source: string, error: unknown) => pieces.notices?.push({ source, error });
	// Each press has a `Committed` of its own, as the owner builds one per press.
	const committed = new Committed(owner, report);
	return {
		committed,
		press: async <T>(
			id: string,
			prepare: (sending: Sending) => Promise<ManagedOperation>,
			then: (command: ManagedOperation, after: Committed) => Promise<T>,
		) => {
			let value: T | undefined;
			const after = new Committed(owner, report);
			await (pieces.execute ?? completing)(
				id,
				() =>
					prepare({
						command: (...args) => (pieces.command ?? unread("command"))(...args),
						perform: unread("perform"),
					}),
				async (operation) => {
					value = await then(operation, after);
				},
			);
			return value as T;
		},
	};
}

/** What actions read of a session, as `fields` answers it, over a link to
 * `workspace` that is never replaced. Opening a room or a direct conversation
 * reads part of the same. `press` and `committed` run over the pieces given. */
export function actionSession(
	workspace: Partial<RoomsManagedWorkspace>,
	fields: Partial<ActionSession> & ActionPieces,
): ActionSession {
	const {
		execute: _execute,
		command: _command,
		completeResult: _result,
		readNow: _read,
		candidateNow: _candidate,
		notices: _notices,
		actions: _actions,
		...rest
	} = fields;
	const door = oneLinkDoor(workspace);
	const current = fields.current ?? null;
	return {
		current,
		acquisitionChanged: unread("acquisitionChanged"),
		whenReady: unread("whenReady"),
		readBeforeSending: unread("readBeforeSending"),
		...ownerEntry({ ...fields, current, requestNow: door.requestNow }),
		candidateBeforeSending: unread("candidateBeforeSending"),
		navigation: fakeHandle<ManagedNavigation>({}),
		request: door.request,
		...rest,
	};
}

/** A restore at page open that fails the test on any control it cannot reach. */
export const everyReached: AccessMove = {
	current: () => true,
	report: (_id, error) => {
		throw error;
	},
	probe() {},
};

/** No ceiling on what a new access may edit or share. */
export const noCeilings = { editCeiling: null, issueCeiling: null };
/** How `edit` stands, in one word: its phase, or how it ended. */
export function editSaid(edit: { readonly phase: string; readonly outcome?: string } | undefined): string | undefined {
	return edit?.phase === "ended" ? edit.outcome : edit?.phase;
}
