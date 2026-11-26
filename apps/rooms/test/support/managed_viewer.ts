// Controlled product wrappers for managed viewer recovery scenarios.
import { ManagedRoomsSession } from "../../web/ui/session/managed/session.ts";
import type { WorkspaceSnapshot } from "../../web/ui/session/managed/model.ts";
import type { LinkClock } from "../../web/ui/session/managed/link.ts";
import { bindingHandle, fakeHandle } from "./managed_link.ts";
import type { RoomsManagedApplication, RoomsManagedWorkspace } from "../../../../zig-out/wasm/rooms/rooms_browser.js";
export function deferred<T>() {
	return Promise.withResolvers<T>();
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
		addresses: [],
	};
}
export function viewer(
	workspace: Record<string, unknown>,
	report = (_source: string, _error: unknown) => {},
	applicationMethods: Record<string, unknown> = {},
	local = true,
	clock?: LinkClock,
) {
	// Each workspace a dial returns is a handle of its own, freed on its own.
	const relink = applicationMethods.relink;
	const application = fakeHandle<RoomsManagedApplication>({
		close: () => Promise.resolve(),
		free() {},
		...applicationMethods,
		...(typeof relink === "function"
			? {
				relink: async (...args: unknown[]) =>
					bindingHandle<RoomsManagedWorkspace>(await Reflect.apply(relink, applicationMethods, args)),
			}
			: {}),
	});
	// The page's workspace and its custody are two handles over one session.
	const fields = { free() {}, ...workspace };
	return new ManagedRoomsSession(
		application,
		bindingHandle<RoomsManagedWorkspace>(fields),
		bindingHandle<RoomsManagedWorkspace>(fields),
		report,
		local,
		clock,
	);
}
