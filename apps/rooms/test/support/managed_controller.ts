import { snapshot } from "../support/managed_viewer.ts";
import { ManagedOpenings } from "../../web/ui/session/managed/openings.ts";
import { ManagedNavigation } from "../../web/ui/session/managed/navigation.ts";
import { initializeApplication } from "../support/application.ts";
import type { ManagedRoomsSession } from "../../web/ui/session/managed/session.ts";
import type { ManagedHistory } from "../../web/ui/session/managed/history.ts";
import type { RoomInfo } from "../../lib/directory_publications.ts";
Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});
const { RoomsPage } = await import("../../web/ui/page.ts");
const { createManagedController } = await import("../../web/ui/session/managed/controller.ts");
const { presentationFiles } = await import("../../web/ui/session/managed/files.ts");
const { directoryId } = await import("../../web/ui/application.ts");
const store = await import("../../web/ui/store.ts");
await initializeApplication();
export function fixture(listed: RoomInfo[] = [], duringRead: () => void = () => {}) {
	const page = new RoomsPage();
	const current = snapshot();
	const route = "127.0.0.1:1234";
	const id = directoryId(route)!;
	current.intent.directories.push({
		id,
		access: "exact-directory",
		home: true,
		nick: "ada",
		nickAllocation: "exact",
		standing: null,
	});
	const calls: unknown[][] = [];
	const session = {
		current,
		refresh: () => Promise.resolve(current),
		directoryRegistered: () => Promise.resolve(),
		permits: () => true,
		command: (name: string, args: string[]) => {
			calls.push([name, args]);
			return Promise.resolve({});
		},
		completeResult: () => Promise.resolve(),
		workspace: {
			directoryReader: (directory: string) => {
				calls.push(["directoryReader", directory]);
				return Promise.resolve({
					namedRooms: () => {
						duringRead();
						return Promise.resolve(listed);
					},
					free: () => calls.push(["freeReader"]),
				});
			},
		},
		actions: {
			publicRoom: (...args: unknown[]) => {
				calls.push(["publicRoom", ...args.slice(0, 3)]);
				return Promise.resolve("room");
			},
			directory: (...args: unknown[]) => {
				calls.push(["directory", ...args.slice(0, 4)]);
				return Promise.resolve();
			},
			run: (...args: unknown[]) => {
				calls.push(args);
				return Promise.resolve();
			},
			roomLink: (...args: unknown[]) => {
				calls.push(["roomLink", ...args.slice(0, 4)]);
				return Promise.resolve("room");
			},
			createRoom: (...args: unknown[]) => {
				calls.push(["createRoom", ...args.slice(0, 3)]);
				return Promise.resolve("room");
			},
		},
	} as unknown as ManagedRoomsSession;
	Object.assign(session, { navigation: new ManagedNavigation(session), openings: new ManagedOpenings(session) });
	session.navigation.select = (id: string) => {
		calls.push(["select", [id]]);
		return Promise.resolve();
	};
	page.managedSession = session;
	const files = presentationFiles(page.projection, () => null);
	const controller = createManagedController(
		page,
		{ setTheme() {}, showRoster() {}, aboutConversation() {} },
		session,
		files,
		route,
		{ refresh: () => Promise.resolve() } as unknown as ManagedHistory,
	);
	return {
		page,
		id,
		route,
		calls,
		current,
		controller,
		close: () => {
			files.close();
			for (const key of [...page.projection.get().convs.keys()]) store.forgetConv(page.projection, key);
		},
	};
}
