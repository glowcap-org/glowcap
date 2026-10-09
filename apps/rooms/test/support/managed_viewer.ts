// Controlled product wrappers for managed viewer recovery scenarios.
import { ManagedRoomsSession } from "../../web/ui/session/managed/session.ts";
import type { WorkspaceSnapshot } from "../../web/ui/session/managed/model.ts";
import type { RoomsManagedApplication, RoomsManagedWorkspace } from "../../../../zig-out/wasm/rooms/rooms_browser.js";
export function deferred<T>() {
	let resolve!: (value: T) => void;
	const promise = new Promise<T>((done) => {
		resolve = done;
	});
	return { promise, resolve };
}
export function snapshot(): WorkspaceSnapshot {
	return {
		revision: "1",
		intent: {
			version: 1,
			directories: [],
			conversations: [],
			invitations: [],
			active: null,
			standing: "",
			ignored: [],
			keepHistory: false,
			connection: "relay",
			archive: null,
			archiveControl: null,
			operators: [],
			peering: [],
		},
	};
}
export function viewer(workspace: Record<string, unknown>, report = (_source: string, _error: unknown) => {}) {
	const application = { close: () => Promise.resolve(), free() {} } as unknown as RoomsManagedApplication;
	const held = { free() {}, ...workspace } as unknown as RoomsManagedWorkspace;
	return new ManagedRoomsSession(application, held, held, report);
}
