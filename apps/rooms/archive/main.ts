// Standalone member-owned archive peer (ADR-0129).
//
// It publishes exactly the same two-verb object a browser tab can host, under
// a durable swiss on a durable Host identity. Discovery-backed iroh is the
// deployable default;
// loopback TCP exists for hermetic tests and local inspection and is announced
// plainly as cleartext.

import { archiveBehavior } from "../lib/archive.ts";
import { optionalEnv } from "../lib/env.ts";
import { formatRoomsSturdyref, roomsHost, roomsLocator } from "../lib/locator.ts";
import { listenStandalone, serveStandalone } from "../lib/standalone_peer.ts";
import { FileArchiveBackend } from "./storage.ts";
import { ArchivePeerState } from "./state.ts";
import { ArchiveDirectoryCustody } from "./file_io.ts";

function option(name: string): string | undefined {
	return Deno.args.find((arg) => arg.startsWith(`--${name}=`))?.slice(name.length + 3);
}

function stateDirectory(): string {
	const directory = option("state") ?? optionalEnv("PANCAKE_ARCHIVE_STATE");
	if (directory === undefined || directory.length === 0) {
		throw new Error("name durable storage with --state=<directory> or PANCAKE_ARCHIVE_STATE");
	}
	return directory;
}

export async function start(): Promise<void> {
	const directory = stateDirectory();
	const custody = await ArchiveDirectoryCustody.acquire(directory);
	try {
		const [state, backend] = await Promise.all([
			ArchivePeerState.open(directory),
			FileArchiveBackend.open(directory),
		]);
		// The archive contract deliberately fits the Goblins-compatible floor. It
		// should not make a member opt into Rooms-next just to retain their lines.
		const host = roomsHost(state.identitySeed, "v1-syrup");
		try {
			const swiss = host.publishDurable(archiveBehavior(backend), state.archiveEntropy);
			const listening = await listenStandalone(host, {
				args: Deno.args,
				envPrefix: "PANCAKE_ARCHIVE",
				label: "archive",
			});
			const sturdyref = formatRoomsSturdyref(roomsLocator(listening.locator), swiss);
			console.log(`ROOMS-ARCHIVE-LISTENING ${sturdyref}`);
			console.error(`rooms archive: ${listening.transport} peer ready; the sturdyref is the archive authority`);
			await serveStandalone(listening.server, "rooms archive");
		} finally {
			await host.close();
		}
	} finally {
		custody.close();
	}
}

if (import.meta.main) {
	try {
		await start();
	} catch (error) {
		console.error(`rooms archive: could not start: ${error instanceof Error ? error.message : error}`);
		Deno.exit(1);
	}
}
