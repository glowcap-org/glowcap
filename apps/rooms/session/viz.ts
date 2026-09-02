// Timeline capability custody for one durable Rooms session runtime.

import { enableTrace, retainSecondaryFailure, type TraceEvent } from "@glowcap/runtime";
import { publishViz, type VizPublisher } from "../lib/viz_publish.ts";
import type { RoomsSessionState } from "../lib/rooms_state.ts";
import { ReconciliationBlocked } from "./reconnect.ts";

export interface DurableVizSnapshot {
	capability: "viz";
	url: string;
	connected: boolean;
	/** Why the endpoint refused this swiss, or null while the socket still redials. */
	refusal: string | null;
}

type StartPublisher = (
	url: string,
	hooks: {
		cap: string;
		onError: (error: unknown) => void;
		onRefused: (reason: string) => void;
		onStatus: (connected: boolean) => void;
	},
) => VizPublisher;

type InstallTrace = (sink: (event: TraceEvent) => void) => () => void;

interface HeldViz {
	readonly scope: string;
	readonly swiss: string;
	readonly publisher: VizPublisher;
	readonly uninstall: () => void;
	connected: boolean;
	retired: boolean;
	refusal: string | null;
}

function retirePublisher(publisher: VizPublisher, uninstall?: () => void): unknown | null {
	let failure: unknown | null = null;
	try {
		publisher.stop();
	} catch (error) {
		failure = error;
	}
	if (uninstall != null) {
		try {
			uninstall();
		} catch (error) {
			failure = failure == null ? error : retainSecondaryFailure(failure, error);
		}
	}
	return failure;
}

export class DurableRoomsViz {
	readonly #setIssue: (subject: string, error: unknown | null) => boolean;
	readonly #invalidated: (scope: string) => void;
	readonly #start: StartPublisher;
	readonly #install: InstallTrace;
	#held: HeldViz | null = null;

	constructor(
		setIssue: (subject: string, error: unknown | null) => boolean,
		invalidated: (scope: string) => void,
		start: StartPublisher = publishViz,
		install: InstallTrace = (sink) => enableTrace(sink, { payloadCap: 0 }),
	) {
		this.#setIssue = setIssue;
		this.#invalidated = invalidated;
		this.#start = start;
		this.#install = install;
	}

	reconcile(checkpoint: RoomsSessionState): void {
		const wanted = checkpoint.capabilities.operations.find((entry) => entry.capability === "viz") ?? null;
		if (wanted != null && this.#held?.scope === wanted.scope && this.#held.swiss === wanted.swiss) return;
		this.#drop();
		if (wanted == null) return;

		let held: HeldViz | null = null;
		const publisher = this.#start(wanted.scope, {
			cap: wanted.swiss,
			onError: (error) => {
				if (held == null || this.#held !== held || held.retired) return;
				this.#note(held.scope, error);
			},
			onRefused: (reason) => {
				if (held == null || this.#held !== held || held.retired) return;
				held.connected = false;
				held.retired = true;
				held.refusal = reason;
				const failure = retirePublisher(held.publisher, held.uninstall);
				this.#note(
					held.scope,
					failure == null
						? new ReconciliationBlocked(reason)
						: retainSecondaryFailure(new ReconciliationBlocked(reason), failure),
				);
				this.#invalidated(held.scope);
			},
			onStatus: (connected) => {
				if (held == null || this.#held !== held || held.retired || held.connected === connected) return;
				held.connected = connected;
				if (connected) this.#note(held.scope, null);
				this.#invalidated(held.scope);
			},
		});
		let uninstall: () => void;
		try {
			uninstall = this.#install(publisher.sink);
		} catch (error) {
			const cleanup = retirePublisher(publisher);
			this.#note(wanted.scope, cleanup == null ? error : retainSecondaryFailure(error, cleanup));
			this.#invalidated(wanted.scope);
			return;
		}
		held = {
			scope: wanted.scope,
			swiss: wanted.swiss,
			publisher,
			uninstall,
			connected: false,
			retired: false,
			refusal: null,
		};
		this.#held = held;
		this.#invalidated(held.scope);
	}

	snapshot(scope: string): DurableVizSnapshot {
		const held = this.#held;
		if (held == null || held.scope !== scope) {
			throw new Error("that visualizer capability is not active in this session");
		}
		return { capability: "viz", url: held.scope, connected: held.connected, refusal: held.refusal };
	}

	close(): void {
		this.#drop();
	}

	#drop(): void {
		const held = this.#held;
		if (held == null) return;
		this.#held = null;
		const failure = held.retired ? null : retirePublisher(held.publisher, held.uninstall);
		held.retired = true;
		this.#note(held.scope, failure);
		this.#invalidated(held.scope);
		if (failure != null) throw failure;
	}

	#note(scope: string, error: unknown | null): void {
		this.#setIssue(`capability:viz\u0000${scope}`, error);
	}
}
