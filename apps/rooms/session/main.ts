// Standalone durable Rooms session peer.

import { retainCleanupFailures, TRANSPORT_IROH } from "@glowcap/runtime";
import { Reachability } from "@glowcap/iroh";
import { DirectoryCustody } from "../lib/directory_custody.ts";
import { atomicWrite, readBoundedText } from "../lib/durable_file.ts";
import { optionalEnv } from "../lib/env.ts";
import { roomsHost, roomsLocator } from "../lib/locator.ts";
import { listenStandalone, serveStandalone, standaloneIrohConfig } from "../lib/standalone_peer.ts";
import { openRoomsRuntime } from "../lib/runtime.ts";
import {
	MAX_WORKSPACE_DOCUMENT_CHARS,
	parseRoomsSessionState,
	parseWorkspaceState,
	type RoomsSessionState,
} from "../lib/rooms_state.ts";
import { FileArchiveBackend } from "../archive/storage.ts";
import { applyRoomsSessionResult, resumeRoomsSessionResult } from "./result_commands.ts";
import { bindDurableRoomsSession } from "./bind.ts";
import { fileSessionDocuments } from "./file_documents.ts";
import { DurableRoomsRuntime } from "./runtime.ts";
import { DurableRoomsSessionState } from "./state.ts";
import { sessionAdminPath } from "./readiness.ts";
import { reconcileRuntimeState, runtimeStateImpact } from "./state_sync.ts";

function option(name: string): string | undefined {
	return Deno.args.find((argument) => argument.startsWith(`--${name}=`))?.slice(name.length + 3);
}

function stateDirectory(): string {
	const directory = option("state") ?? optionalEnv("GLOWCAP_ROOMS_SESSION_STATE");
	if (directory == null || directory === "") {
		throw new Error("name durable storage with --state=<directory> or GLOWCAP_ROOMS_SESSION_STATE");
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
		// fail, then install the exact published sturdyref after the durable
		// owner, listener, grants, and first reconciliation attempt are admitted.
		await removeAdminMirror(adminPath);
		const documents = fileSessionDocuments(directory);
		const state = await DurableRoomsSessionState.open(
			documents,
			applyRoomsSessionResult,
			(checkpoint, kind, intent) => {
				resumeRoomsSessionResult(checkpoint, kind, intent);
			},
		);
		const checkpoint = await requestedCheckpoint();
		if (checkpoint != null) await state.replace("initial-checkpoint", 0, checkpoint);
		const host = roomsHost(state.identitySeed);
		const needsIroh = state.snapshot().checkpoint.directories.some((saved) =>
			roomsLocator(saved.locator).transport === TRANSPORT_IROH
		);
		const peerOptions = {
			args: Deno.args,
			envPrefix: "GLOWCAP_ROOMS_SESSION",
			label: "Rooms session",
		} as const;
		const listenerIroh = standaloneIrohConfig(peerOptions);
		const relayUrl = option("relay-url") ?? optionalEnv("GLOWCAP_ROOMS_SESSION_RELAY_URL");
		const listening = await listenStandalone(host, peerOptions).catch(async (error) => {
			throw await retainCleanupFailures(error, [() => host.close()]);
		});
		const runtime = await openRoomsRuntime({
			host,
			installedTransport: listening.transport,
			...(relayUrl == null ? {} : { relay: { relayUrl } }),
			...(listenerIroh != null
				? { iroh: listenerIroh }
				: needsIroh
				? { iroh: { reachability: Reachability.Discovery } }
				: {}),
		}).catch(
			async (error) => {
				listening.server.close();
				throw await retainCleanupFailures(error, [() => host.close()]);
			},
		);
		const archiveSource = [...state.identitySeed].map((byte) => byte.toString(16).padStart(2, "0")).join("");
		const archiveBackend = await FileArchiveBackend.open(`${directory}/archive`).catch(async (error) => {
			throw await retainCleanupFailures(error, [() => runtime.close()]);
		});
		const live = new DurableRoomsRuntime(
			runtime,
			archiveSource,
			async (change) => {
				await state.reconcile({
					impact: runtimeStateImpact(change),
					change: (current) => reconcileRuntimeState(current, change),
				});
			},
			archiveBackend,
		);
		try {
			const bound = await bindDurableRoomsSession({
				host,
				advertisedLocator: listening.locator,
				state,
				live,
				onReconciliationFailure: (error) => {
					console.error(
						`rooms session: checkpoint reconciliation failed: ${
							error instanceof Error ? error.message : error
						}`,
					);
				},
			});
			await atomicWrite(adminPath, new TextEncoder().encode(`${bound.sturdyref}\n`));
			console.log(`ROOMS-SESSION-LISTENING ${bound.sturdyref}`);
			console.error(`rooms session: ${listening.transport} peer ready; the sturdyref is session administration`);
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
