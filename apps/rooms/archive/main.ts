// Standalone member-owned archive peer (ADR-0129).
//
// It publishes exactly the same two-verb object a browser tab can host, under
// a durable swiss on a durable Host identity, plus independently revocable
// share publications from its own ledger (ADR-0140). Discovery-backed iroh is
// the deployable default; loopback TCP exists for hermetic tests and local
// inspection and is announced plainly as cleartext.

import { archiveBehavior, archiveFilterRow, parseArchiveFilter } from "../lib/archive/protocol.ts";
import { archiveFacetIssuer, WHOLE_ARCHIVE } from "../lib/archive/facet.ts";
import { optionalEnv } from "../lib/env.ts";
import { formatRoomsSturdyref, roomsHost, roomsLocator } from "../lib/locator.ts";
import { listenStandalone, serveStandalone } from "../lib/standalone_peer.ts";
import { FileArchiveBackend } from "./storage.ts";
import { ArchivePeerState } from "./state.ts";
import { ArchiveDirectoryCustody } from "./file_io.ts";
import { DurableArchiveShares } from "./shares.ts";

function option(name: string): string | undefined {
	return Deno.args.find((arg) => arg.startsWith(`--${name}=`))?.slice(name.length + 3);
}

function stateDirectory(): string {
	const directory = option("state") ?? optionalEnv("GLOWCAP_ARCHIVE_STATE");
	if (directory === undefined || directory.length === 0) {
		throw new Error("name durable storage with --state=<directory> or GLOWCAP_ARCHIVE_STATE");
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
		const host = roomsHost(state.identitySeed, "interop");
		try {
			const published = { locator: null as ReturnType<typeof roomsLocator> | null };
			const shares = await DurableArchiveShares.open(directory, state.archiveEntropy, {
				publish: (share, entropy, active) =>
					host.publishDurable((verb, args) => {
						if (!active()) throw new Error("that archive share has been revoked");
						return archiveBehavior(backend, {
							scope: parseArchiveFilter(archiveFilterRow(share.filter)),
							access: "read",
						})(verb, args);
					}, entropy),
				unpublish: (swiss) => host.unpublishDurable(swiss),
				sturdyref: (swiss) => {
					if (published.locator == null) throw new Error("archive peer is not listening");
					return formatRoomsSturdyref(published.locator, swiss);
				},
			});
			const swiss = host.publishDurable(
				archiveBehavior(backend, WHOLE_ARCHIVE, archiveFacetIssuer(null, shares.issuer())),
				state.archiveEntropy,
			);
			const listening = await listenStandalone(host, {
				args: Deno.args,
				envPrefix: "GLOWCAP_ARCHIVE",
				label: "archive",
			});
			published.locator = roomsLocator(listening.locator);
			await shares.restore();
			const sturdyref = formatRoomsSturdyref(published.locator, swiss);
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
