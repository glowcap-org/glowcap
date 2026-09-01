// Named durable documents for one Rooms session, independent of the host's
// storage. Checkpoint, effects, and grants stay three documents because they
// have three owners: workspace intent, the effect ledger, and host authority.

export type RoomsSessionDocument = "checkpoint" | "effects" | "grants";

export interface RoomsSessionDocumentStore {
	read(document: RoomsSessionDocument): Promise<Uint8Array | null>;
	write(document: RoomsSessionDocument, bytes: Uint8Array): Promise<void>;
}

/** Byte ceilings for the three session documents. Schema modules refuse a
 * larger encoding; the file adapter refuses a larger read. */
export const SESSION_DOCUMENT_CEILINGS: Record<RoomsSessionDocument, number> = {
	checkpoint: 768 * 1024,
	effects: 4 * 1024 * 1024,
	grants: 128 * 1024,
};

const decoder = new TextDecoder("utf-8", { fatal: true });

/** Decode one document the store returned. `null` from `read` is absence;
 * oversized or non-UTF-8 bytes are a corrupt document. */
export function decodeSessionDocument(bytes: Uint8Array, maxBytes: number, what: string): string {
	if (bytes.length > maxBytes) throw new Error(`${what} exceeds its ${maxBytes}-byte ceiling`);
	try {
		return decoder.decode(bytes);
	} catch {
		throw new Error(`${what} is not UTF-8 text`);
	}
}

/** In-process documents. Absence is a missing key, not a filesystem error. */
export function memorySessionDocuments(): RoomsSessionDocumentStore {
	const documents = new Map<RoomsSessionDocument, Uint8Array>();
	return {
		read: (document) => Promise.resolve(documents.get(document)?.slice() ?? null),
		write: (document, bytes) => {
			documents.set(document, bytes.slice());
			return Promise.resolve();
		},
	};
}
