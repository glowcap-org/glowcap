// The Rooms page entry, bundled to /page.js by native rooms-web. Rust Wasm
// admits durable startup choices; this module mounts their React projection.
//
// Rust owns local and attached session execution. React renders their shared
// presentation without opening a second Host or owning session state.
//
// One thing ends here. The screen page.html has been holding up since the first
// parse is handed over by `boot.ts`, and that call comes last, because reaching
// it is also how this module reports that the bundle arrived at all.

import { type ReactNode, StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { addressOfActive, navigateTo } from "./routing_api.ts";
import { loadEstablished, loadOpsPage, loadSessionSetup, prefetch } from "./chunks.ts";
import {
	handOffNow,
	handOffWhenReady,
	pageDidNotOpen,
	standAtFrontOfPrivilegedAddress,
	startOpeningMark,
} from "./boot.ts";
import { noteBootDelay, noteBootPhase, startBootAsides } from "./boot_note.ts";
import { refusePageScaling } from "./gestures.ts";
import { reserveSelectionForAddress } from "./page_bootstrap.ts";
import { RoomsPage } from "./page.ts";
import { bindTabVisibility, RoomsProjectionProvider } from "./hooks.ts";
import * as prefs from "./prefs.ts";
import { installWorkspaceStatePersistence } from "./workspace_state.ts";
import { restoreWorkspaceState } from "./workspace/bundle.ts";
import { AttachedSessionProjection } from "./session/projection.ts";
import { createAttachedRoomsSession } from "./session/attached_session.ts";
import { AttachedSessionFiles } from "./session/attached_files.ts";
import { setWorkspaceControllerSelection, workspaceControllerSelection } from "./workspace_state.ts";
import * as application from "./application.ts";
import { RoomsBrowserProvider } from "./controller/browser.ts";
import { createRoomsBrowserController } from "./controller/create_browser.ts";
import { attachedSessionFailureText } from "./session/attached_failure.ts";
import { ModalProvider } from "./modal.ts";
import { CapabilitySetEvents } from "./ops/capability_set_events.ts";
import type { RoomsSessionController } from "./controller/session.ts";

const page = new RoomsPage();
// The stylesheet refuses page scaling everywhere the root's `touch-action` is
// honoured; this is WebKit's half, which arrives as its own gesture events.
refusePageScaling();
bindTabVisibility(page.projection);
const browser = createRoomsBrowserController(page, navigateTo, addressOfActive);

const mount = document.getElementById("root");
if (!mount) throw new Error("rooms: page.html is missing its #root element");

/** The retry rhythm while the wasm runtime is fetched and instantiated: a
 * lost build race resolves in one beat, a server mid-rebuild in a few, and
 * the ceiling keeps a long outage from hammering it. After the slow mark the
 * opening screen says what it is waiting on, in place and in its own voice,
 * because the screen is already the page's face for this exact wait. */
const RUNTIME_RETRY_FLOOR_MS = 500;
const RUNTIME_RETRY_CEILING_MS = 5_000;
const RUNTIME_SLOW_AFTER_MS = 4_000;

const root = createRoot(mount, {
	// React's own error reporting, rather than the console it would otherwise
	// write to unattended. `onCaughtError` is what a boundary below already
	// handled; `onUncaughtError` is one that reached the top; `onRecoverableError`
	// is React repairing itself and worth seeing while developing.
	onUncaughtError: (error: unknown, info: { componentStack?: string }) =>
		console.error("rooms: nothing caught this render error:", error, info.componentStack),
	onCaughtError: (error: unknown) => console.warn("rooms: a boundary caught a render error:", error),
	onRecoverableError: (error: unknown) => console.warn("rooms: React recovered from:", error),
});

/** Providers that live as long as this page, including establishment.
 * A session controller is not one of these: it exists only after a choice. */
function PageSurface({ children }: { children: ReactNode }) {
	return (
		<RoomsProjectionProvider value={page.projection}>
			<RoomsBrowserProvider value={browser}>
				{children}
			</RoomsBrowserProvider>
		</RoomsProjectionProvider>
	);
}

async function showSessionSetup(initialCapability = "", initialError = ""): Promise<void> {
	const { SessionSetup } = await loadSessionSetup();
	root.render(
		<StrictMode>
			<PageSurface>
				<ModalProvider key="session-setup">
					<SessionSetup initialCapability={initialCapability} initialError={initialError} />
				</ModalProvider>
			</PageSurface>
		</StrictMode>,
	);
	handOffNow();
}

async function awaitRuntime(boot: () => Promise<unknown>): Promise<void> {
	const slowAt = Date.now() + RUNTIME_SLOW_AFTER_MS;
	let backoff = RUNTIME_RETRY_FLOOR_MS;
	let ready = false;
	while (!ready) {
		try {
			await boot();
			ready = true;
		} catch (err) {
			console.error("rooms: the runtime did not come up, retrying:", err);
			if (Date.now() >= slowAt) {
				noteBootDelay(err instanceof Error ? err.message : String(err));
			}
			await new Promise((settle) => setTimeout(settle, backoff));
			backoff = Math.min(backoff * 2, RUNTIME_RETRY_CEILING_MS);
		}
	}
}

// Rust admits the workspace and selects the controller before a Host exists.
// Both local and attached sessions run on the Rust application Host.
async function start(): Promise<void> {
	noteBootPhase("peer");
	startBootAsides();
	await awaitRuntime(async () => {
		const path = document.documentElement.dataset.roomsWasm;
		if (path == null) throw new Error("the Rooms page has no application module");
		await application.loadApplication(fetch(path));
	});
	restoreWorkspaceState(
		page,
		application.directoryId,
		location.pathname === "/",
		application.readSavedWorkspace,
	);
	const controllerSelection = workspaceControllerSelection(page);
	const pageLocator = prefs.directoryLocator();
	if (controllerSelection.kind === "none") {
		standAtFrontOfPrivilegedAddress();
		await showSessionSetup();
		return;
	}
	// After the branch that has no wait left to name: a browser with no session
	// chosen goes straight to choosing one, and a line about looking for rooms
	// would be on screen for exactly as long as it was untrue.
	noteBootPhase(controllerSelection.kind === "attached" ? "session" : "rooms");
	const establishedUi = loadEstablished();
	prefetch(() => establishedUi);
	if (location.pathname.startsWith("/ops")) prefetch(loadOpsPage);
	const capabilityEvents = new CapabilitySetEvents();
	addEventListener("pagehide", () => {
		capabilityEvents.close();
	}, { once: true });
	const { connectAttachedRoomsSession, connectLocalRoomsSession } = await import("./session/attached_connection.ts");
	let controller: Awaited<ReturnType<typeof connectAttachedRoomsSession>>;
	try {
		if (controllerSelection.kind === "attached") {
			controller = await connectAttachedRoomsSession(page, controllerSelection.sturdyref);
		} else {
			const local = await connectLocalRoomsSession(page);
			controller = local.controller;
			page.hostedSession.bind(async () => {
				try {
					const sturdyref = await local.publish();
					if (!setWorkspaceControllerSelection(page, { kind: "hosted", sturdyref })) {
						return "This browser could not save the shared session selection.";
					}
					return "";
				} catch (error) {
					return attachedSessionFailureText(error);
				}
			});
		}
	} catch (error) {
		await showSessionSetup(
			controllerSelection.kind === "attached" ? controllerSelection.sturdyref : undefined,
			attachedSessionFailureText(error),
		);
		return;
	}
	page.attachedSession.hold(controller);
	const files = new AttachedSessionFiles(controller, page.projection);
	const projection = new AttachedSessionProjection(page, files, capabilityEvents);
	const stopProjection = projection.bind(controller);
	const session: RoomsSessionController = createAttachedRoomsSession(page, browser, controller, files, {
		defaultDirectoryLocator: await pageLocator,
		capabilityEvents,
		recoverSends: controllerSelection.kind === "local",
	});
	addEventListener("pagehide", () => {
		page.workspace.persistenceControl?.flush();
		page.attachedSession.release();
		stopProjection();
		files.close();
		void controller.close();
	}, { once: true });
	if (location.pathname !== "/") reserveSelectionForAddress(page);
	installWorkspaceStatePersistence(page);
	const { EstablishedSession, bindEstablishedRouting } = await establishedUi;
	bindEstablishedRouting(page);
	const renderEstablished = (current: RoomsSessionController, key: string) => {
		root.render(
			<StrictMode>
				<PageSurface>
					<ModalProvider key={key}>
						<EstablishedSession session={current} />
					</ModalProvider>
				</PageSurface>
			</StrictMode>,
		);
	};
	renderEstablished(session, "established-session");

	// The opening screen's mark starts here rather than at import, because
	// asking for a device is asynchronous and nothing may wait on it.
	startOpeningMark();

	handOffWhenReady(page.projection, "controller-snapshot");
}

void start().catch((error) => {
	pageDidNotOpen(error instanceof Error ? error.message : String(error));
});
