// Standalone durable Rooms session peer.

import { TRANSPORT_IROH } from "@pancake/runtime";
import { Reachability } from "@pancake/iroh";
import { DirectoryCustody } from "../lib/directory_custody.ts";
import { atomicWrite, readBoundedText } from "../lib/durable_file.ts";
import { optionalEnv } from "../lib/env.ts";
import { formatRoomsSturdyref, roomsHost, roomsLocator } from "../lib/locator.ts";
import { listenStandalone, serveStandalone, standaloneIrohConfig } from "../lib/standalone_peer.ts";
import { openRoomsRuntime } from "../lib/runtime.ts";
import { DurableRoomsSessionBehavior } from "./behavior.ts";
import { DurableRoomsSessionState } from "./state.ts";
import { DurableRoomsRuntime } from "./runtime.ts";
import {
	MAX_WORKSPACE_DOCUMENT_CHARS,
	parseRoomsSessionState,
	parseWorkspaceState,
	type RoomsSessionState,
} from "../lib/rooms_state.ts";
import { FileArchiveBackend } from "../archive/storage.ts";
import { applyRoomsSessionResult, resumeRoomsSessionResult } from "./commands.ts";
import { DurableRoomsSessionGrants } from "./grants.ts";
import { sessionAdminPath } from "./readiness.ts";

function option(name: string): string | undefined {
	return Deno.args.find((argument) => argument.startsWith(`--${name}=`))?.slice(name.length + 3);
}

function stateDirectory(): string {
	const directory = option("state") ?? optionalEnv("PANCAKE_ROOMS_SESSION_STATE");
	if (directory == null || directory === "") {
		throw new Error("name durable storage with --state=<directory> or PANCAKE_ROOMS_SESSION_STATE");
	}
	return directory;
}

function readinessFile(directory: string): string {
	return option("readiness-file") ?? sessionAdminPath(directory);
}

async function requestedCheckpoint(): Promise<RoomsSessionState | null> {
	const path = option("checkpoint");
	if (path == null) return null;
	const raw = await readBoundedText(path, MAX_WORKSPACE_DOCUMENT_CHARS, "Rooms checkpoint import");
	const workspace = parseWorkspaceState(raw);
	const checkpoint = workspace?.session ?? parseRoomsSessionState(raw);
	if (checkpoint == null) throw new Error(`checkpoint ${path} is not a complete Rooms workspace or session state`);
	return checkpoint;
}

async function removeAdminMirror(path: string): Promise<void> {
	try {
		await Deno.remove(path);
	} catch (error) {
		if (!(error instanceof Deno.errors.NotFound)) throw error;
	}
}

export async function start(): Promise<void> {
	const directory = stateDirectory();
	const custody = await DirectoryCustody.acquire(directory, "session.lock", "Rooms session");
	const adminPath = readinessFile(directory);
	try {
		// This file is readiness evidence and an operator convenience, not a
		// second authority. Clear a prior incarnation before any work that can
		// fail, then install the exact published sturdyref only after the durable
		// owner has reconciled its checkpoint.
		await removeAdminMirror(adminPath);
		const state = await DurableRoomsSessionState.open(
			directory,
			applyRoomsSessionResult,
			(checkpoint, kind, intent) => {
				resumeRoomsSessionResult(checkpoint, kind, intent);
			},
		);
		const checkpoint = await requestedCheckpoint();
		if (checkpoint != null) await state.replace("initial-checkpoint", 0, checkpoint);
		const host = roomsHost(state.identitySeed, "v1-syrup");
		const needsIroh = state.snapshot().checkpoint.directories.some((saved) =>
			roomsLocator(saved.locator).transport === TRANSPORT_IROH
		);
		const peerOptions = {
			args: Deno.args,
			envPrefix: "PANCAKE_ROOMS_SESSION",
			label: "Rooms session",
		} as const;
		const listenerIroh = standaloneIrohConfig(peerOptions);
		const relayUrl = option("relay-url") ?? optionalEnv("PANCAKE_ROOMS_SESSION_RELAY_URL");
		const runtime = await openRoomsRuntime({
			host,
			...(relayUrl == null ? {} : { relay: { relayUrl } }),
			...(listenerIroh != null
				? { iroh: listenerIroh }
				: needsIroh
				? { iroh: { reachability: Reachability.Discovery } }
				: {}),
		}).catch(
			async (error) => {
				await host.close();
				throw error;
			},
		);
		const archiveSource = [...state.identitySeed].map((byte) => byte.toString(16).padStart(2, "0")).join("");
		const archiveBackend = await FileArchiveBackend.open(`${directory}/archive`);
		const live = new DurableRoomsRuntime(runtime, archiveSource, archiveBackend);
		try {
			let listeningLocator = "";
			// Opening loads the grant ledger but publishes nothing. These callbacks
			// first run from restore or issue, after the behavior binding below exists.
			const grants = await DurableRoomsSessionGrants.open(directory, state.sessionEntropy, {
				publish: (grant, entropy, active) =>
					host.publishDurable(behavior.durableFacet(grant.rights, grant.id, active), entropy),
				unpublish: (swiss) => host.unpublishDurable(swiss),
				sturdyref: (_session, swiss) => {
					if (listeningLocator === "") throw new Error("Rooms session grant publication is not listening");
					return formatRoomsSturdyref(roomsLocator(listeningLocator), swiss);
				},
				revokeLive: (id) => behavior.revokeDurableFacet(id),
			});
			const behavior = new DurableRoomsSessionBehavior(state, live, grants);
			const swiss = host.publishDurable(behavior.root(), state.sessionEntropy);
			const listening = await listenStandalone(host, peerOptions);
			listeningLocator = listening.locator;
			live.setMemberLocator(listening.locator);
			const sturdyref = formatRoomsSturdyref(roomsLocator(listening.locator), swiss);
			await grants.restore();
			await live.reconcile(state.snapshot().checkpoint);
			await atomicWrite(adminPath, new TextEncoder().encode(`${sturdyref}\n`));
			console.log(`ROOMS-SESSION-LISTENING ${sturdyref}`);
			console.error(`rooms session: ${listening.transport} peer ready; the sturdyref is session administration`);
			state.onCheckpointChange((_revision, checkpoint, impact) => {
				void live.reconcile(checkpoint, impact).catch((error) => {
					console.error(
						`rooms session: checkpoint reconciliation failed: ${
							error instanceof Error ? error.message : error
						}`,
					);
				});
			});
			await serveStandalone(listening.server, "rooms session");
		} finally {
			await live.close();
		}
	} finally {
		await removeAdminMirror(adminPath).catch((error) => {
			console.error(
				`rooms session: could not clear its administrator readiness file: ${
					error instanceof Error ? error.message : error
				}`,
			);
		});
		custody.close();
	}
}

if (import.meta.main) {
	try {
		await start();
	} catch (error) {
		console.error(`rooms session: could not start: ${error instanceof Error ? error.message : error}`);
		Deno.exit(1);
	}
}
