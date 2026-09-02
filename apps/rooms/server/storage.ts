// Where this server keeps what it keeps: the one place a storage destination
// is read, and the only file that knows which backends exist.
//
// Storage is a capability the operator grants the server, off by default.
// The destination is one value — `--storage=` or GLOWCAP_ROOMS_STORAGE —
// and its shape picks the implementation: a `postgres://` URL is a managed
// database, anything else is a directory for the file backend, and naming
// nothing keeps today's posture (the state directory when one exists,
// memory for the life of the process otherwise). Consumers upstream —
// history today, whatever the server keeps next — see the seam in
// `history.ts` and never the choice made here. That is the boundary the
// module exists to hold: no scheme name belongs anywhere above this file.

import type { HistoryBackend } from "./history.ts";
import { FileHistoryBackend } from "./storage/files.ts";
import { PgHistoryBackend } from "./storage/postgres.ts";

/** Compose the history backend for a destination. Throws when a named
 * destination cannot be opened — a stated storage policy that cannot be
 * honored is a startup refusal, never a silent fall back — and the caller
 * owns turning that into the operator's exit. */
export async function openHistoryStorage(
	destination: string | undefined,
	stateDirectory: string | null,
): Promise<HistoryBackend | null> {
	if (destination === undefined) {
		return stateDirectory === null ? null : new FileHistoryBackend(stateDirectory);
	}
	if (destination.startsWith("postgres://") || destination.startsWith("postgresql://")) {
		return await PgHistoryBackend.open(destination);
	}
	// A destination wearing any other scheme is a mistake to say out loud,
	// not a directory to fail toward: quietly treating a typo as a path
	// would degrade a stated retention policy to memory.
	const scheme = destination.match(/^([a-z][a-z0-9+.-]*):\/\//i)?.[1];
	if (scheme !== undefined) {
		throw new Error(
			`unknown storage scheme "${scheme}://": postgres:// is the one URL form, and anything else names a directory`,
		);
	}
	return new FileHistoryBackend(destination);
}
