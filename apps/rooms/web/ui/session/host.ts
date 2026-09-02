// Bind this tab's wasm Host as the durable Rooms session listener.
//
// The Host already exists for directory membership and DMs. Sharing publishes
// the session actor onto it and names the same locator DMs already advertise,
// with this page's directory as the WebRTC signaling route so another browser
// can Attach even from a different Rooms page.
// Memory documents are enough: reload mints a new Host, so sharing cannot
// outlive the tab.

import { retainCleanupFailures, TRANSPORT_NOISE_RELAY } from "@glowcap/runtime";
import * as store from "../store.ts";
import { homeLocator } from "../net/bootstrap.ts";
import { iceServers } from "../net/ice.ts";
import { bootRuntime } from "../net/runtime_boot.ts";
import { dmTransport } from "../prefs.ts";
import { ensureHostRendezvous, ensureInbox, sessionHostLocator } from "../net/reachable.ts";
import { reconnectHeldDirectories, stealHeldDirectories } from "../net/held_directories.ts";
import { workspaceStateOf } from "../workspace_state.ts";
import type { RoomsPageContext } from "../page.ts";
import { dirId } from "../types.ts";
import { roomsLocator } from "../../../lib/locator.ts";
import { roomsPeerAuthority } from "../../../lib/routes.ts";
import { adoptDirectories, type AdoptedDirectory } from "../../../session/directory_adopt.ts";
import { bindDurableRoomsSession, type BoundDurableRoomsSession } from "../../../session/bind.ts";
import { memorySessionDocuments } from "../../../session/documents.ts";
import { applyRoomsSessionResult, resumeRoomsSessionResult } from "../../../session/result_commands.ts";
import { DurableRoomsRuntime } from "../../../session/runtime.ts";
import { DurableRoomsSessionState } from "../../../session/state.ts";
import { reconcileRuntimeState, runtimeStateImpact } from "../../../session/state_sync.ts";
import { InProcessAttachedRemote } from "./local_remote.ts";
import { webrtcHomeShareReady } from "./host_reach.ts";

export interface HostedRoomsSession {
	readonly bound: BoundDurableRoomsSession;
	readonly live: DurableRoomsRuntime;
	readonly remote: InProcessAttachedRemote;
	readonly sturdyref: string;
	close(): Promise<void>;
}

export async function hostRoomsSession(page: RoomsPageContext): Promise<HostedRoomsSession> {
	const runtime = await bootRuntime(page);
	ensureInbox(page, runtime, iceServers);
	if (dmTransport() === TRANSPORT_NOISE_RELAY) await ensureHostRendezvous(page);
	await homeLocator(page);
	const advertisedLocator = sessionHostLocator(page);
	if (advertisedLocator === null) {
		throw new Error("this tab has no direct-message locator to publish as the session door");
	}
	let live: DurableRoomsRuntime | null = null;
	let bound: BoundDurableRoomsSession | null = null;
	let stolen = new Map<string, AdoptedDirectory>();
	try {
		stolen = stealHeldDirectories(page);
		adoptDirectories(stolen);
		const state = await DurableRoomsSessionState.open(
			memorySessionDocuments(),
			applyRoomsSessionResult,
			(checkpoint, kind, intent) => {
				resumeRoomsSessionResult(checkpoint, kind, intent);
			},
		);
		if (state.workspaceAdoption === "available") {
			await state.adoptWorkspace(
				crypto.randomUUID(),
				0,
				workspaceStateOf(page, page.projection.get()).session,
			);
		}
		live = new DurableRoomsRuntime(
			runtime.runtime,
			await page.archive.source(),
			async (change) => {
				await state.reconcile({
					impact: runtimeStateImpact(change),
					change: (current) => reconcileRuntimeState(current, change),
				});
			},
			page.archive,
			{ ownsRuntime: false },
		);
		bound = await bindDurableRoomsSession({
			host: runtime.host,
			advertisedLocator,
			state,
			live,
			onReconciliationFailure: (error) => {
				store.noteTrouble(
					page.projection,
					"hosted session",
					error instanceof Error ? error.message : String(error),
				);
			},
		});
		await live.settled();
		const home = roomsPeerAuthority(roomsLocator(await homeLocator(page)));
		const local = page.projection.get().dirs.get(dirId(home));
		const nick = local?.nick || local?.requestedNick || "";
		const refusal = webrtcHomeShareReady(
			roomsLocator(advertisedLocator).transport,
			home,
			live.connectedDirectories(),
			nick,
		);
		if (refusal !== "") throw new Error(refusal);
		const remote = new InProcessAttachedRemote(bound, live, state);
		const hosted = live;
		const published = bound;
		return {
			bound: published,
			live: hosted,
			remote,
			sturdyref: published.sturdyref,
			close: async () => {
				await remote.close();
				try {
					published.release();
				} finally {
					await hosted.close();
				}
			},
		};
	} catch (error) {
		// Local net and DurableRoomsRuntime share this Host. Close first.
		let failure = error;
		const closing = live;
		const releasing = bound;
		try {
			failure = await retainCleanupFailures(failure, [
				...(releasing != null
					? [() => {
						releasing.release();
						return Promise.resolve();
					}]
					: []),
				...(closing != null ? [() => closing.close()] : []),
				...[...stolen.values()].map((row) => () => row.directory.close()),
			]);
			stolen.clear();
		} finally {
			reconnectHeldDirectories(page);
		}
		throw failure;
	}
}
