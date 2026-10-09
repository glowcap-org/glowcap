// A refused result candidate can be recomposed; its receipt and selections stay
// fixed. Keep scalar witnesses, never a workspace snapshot or capability mirror.
import { type ConversationIntent, type DirectoryIntent, fieldKey, type WorkspaceSnapshot } from "./model.ts";

export class ResultRecipe {
	readonly #destinations = new Map<string, string>();
	readonly #targets = new Map<string, string>();
	#source: string | null = null;
	destination(role: string, result: string): string {
		const identity = JSON.stringify([role, result]);
		let destination = this.#destinations.get(identity);
		if (destination == null) {
			destination = fieldKey();
			this.#destinations.set(identity, destination);
		}
		return destination;
	}
	source(): string {
		return this.#source ??= fieldKey();
	}
	check(identity: string, selection: unknown): void {
		const signature = JSON.stringify(selection);
		const previous = this.#targets.get(identity);
		if (previous != null && previous !== signature) {
			throw new Error("The original result target changed. Its receipt remains held for review.");
		}
		this.#targets.set(identity, signature);
	}
	directory(snapshot: WorkspaceSnapshot, id: string): DirectoryIntent {
		const row = snapshot.intent.directories.find((row) => row.id === id);
		if (row == null) throw new Error("The initiating directory was removed");
		this.check(`directory:${id}`, [row.access, row.source]);
		return row;
	}
	conversation(snapshot: WorkspaceSnapshot, id: string): ConversationIntent {
		const row = snapshot.intent.conversations.find((row) => row.id === id);
		if (row == null) throw new Error("The initiating conversation was removed. Its original receipt remains held.");
		this.check(`conversation:${id}`, [
			row.kind,
			row.directory,
			row.source,
			row.access,
			...(row.kind === "room"
				? [row.accepted, row.publicEntry, row.publication, row.control, row.moderator]
				: [row.peer]),
		]);
		return row;
	}
}
