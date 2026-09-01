// Directory-backed Rooms session documents. The process host's `--state`
// spelling: `session.json`, `effects.json`, `grants.json`.

import { atomicWrite, readBoundedText } from "../lib/durable_file.ts";
import { type RoomsSessionDocument, type RoomsSessionDocumentStore, SESSION_DOCUMENT_CEILINGS } from "./documents.ts";

const FILES: Record<RoomsSessionDocument, string> = {
	checkpoint: "session.json",
	effects: "effects.json",
	grants: "grants.json",
};

const encoder = new TextEncoder();

export function fileSessionDocuments(directory: string): RoomsSessionDocumentStore {
	return new FileSessionDocuments(directory);
}

class FileSessionDocuments implements RoomsSessionDocumentStore {
	readonly #directory: string;

	constructor(directory: string) {
		this.#directory = directory;
	}

	async read(document: RoomsSessionDocument): Promise<Uint8Array | null> {
		try {
			return encoder.encode(
				await readBoundedText(
					this.#path(document),
					SESSION_DOCUMENT_CEILINGS[document],
					`Rooms session ${document}`,
				),
			);
		} catch (error) {
			if (!(error instanceof Deno.errors.NotFound)) throw error;
			return null;
		}
	}

	async write(document: RoomsSessionDocument, bytes: Uint8Array): Promise<void> {
		await this.#ensureDirectory();
		await atomicWrite(this.#path(document), bytes);
	}

	#path(document: RoomsSessionDocument): string {
		return `${this.#directory}/${FILES[document]}`;
	}

	async #ensureDirectory(): Promise<void> {
		await Deno.mkdir(this.#directory, { recursive: true, mode: 0o700 });
	}
}
