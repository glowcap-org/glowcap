import { managedSessionText as managedText } from "../../lib/text/managed_session.ts";
// The Rooms page entry, bundled to /page.js by rooms-web. Rust Wasm
// admits durable startup choices. This module mounts their React projection.
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
import { bindTabVisibility, RoomsPageProvider, RoomsProjectionProvider } from "./hooks.ts";
import * as prefs from "./prefs.ts";
import { ManagedSessionStartupFailure, openManagedSession } from "./session/managed/open.ts";
import { attachedSessionFailureText } from "./session/attached_failure.ts";
import { ManagedSessionProvider } from "./session/managed/context.tsx";
import { ManagedProjection } from "./session/managed/projection.ts";
import { presentationFiles } from "./session/managed/files.ts";
import { createManagedController } from "./session/managed/controller.ts";
import { ManagedHistory } from "./session/managed/history.ts";
import * as application from "./application.ts";
import { RoomsBrowserProvider } from "./controller/browser.ts";
import { chosenKey, createRoomsBrowserController } from "./controller/create_browser.ts";
import { finishBrowserDataDeletion } from "./controller/browser_data.ts";
import { ModalProvider } from "./modal.ts";
import type { RoomsSessionController } from "./controller/session.ts";
import { refusalText } from "../../lib/text/failure.ts";
import { membershipStatus } from "./session/managed/membership_status.ts";
import * as store from "./store.ts";
import { bindViewPreferences } from "./view_preferences.ts";

const page = new RoomsPage();
function report(source: string, error: unknown): void {
	const reason = refusalText(error);
	store.noteTrouble(page.projection, source, reason);
}
const stopPreferences = bindViewPreferences(page.projection);
addEventListener("pagehide", stopPreferences, { once: true });
// The stylesheet refuses page scaling everywhere the root's `touch-action` is
// honoured. This is WebKit's half, which arrives as its own gesture events.
refusePageScaling();
bindTabVisibility(page.projection);
const browser = createRoomsBrowserController(page, navigateTo, addressOfActive, () => openWorkspace("local"));
let openingWorkspace: ReturnType<typeof openManagedSession> | null = null;
function openWorkspace(selection: "saved" | "local" = "saved"): ReturnType<typeof openManagedSession> {
	return openingWorkspace ??= openManagedSession(report, selection).then((opened) => {
		page.managedSession = opened.session;
		addEventListener("pagehide", () => {
			void opened.session.close().catch((error) =>
				store.noteTrouble(page.projection, managedText.workspaceShutdown, refusalText(error))
			);
		}, { once: true });
		return opened;
	}).catch((error) => {
		// A failed opening can be retried after its owner has retired. Failed
		// cleanup keeps the rejection so another Store cannot take its lock.
		if (!(error instanceof ManagedSessionStartupFailure)) openingWorkspace = null;
		throw error;
	});
}

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
			<RoomsPageProvider value={page}>
				<RoomsBrowserProvider value={browser}>
					{children}
				</RoomsBrowserProvider>
			</RoomsPageProvider>
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
	startOpeningMark();
	noteBootPhase("peer");
	startBootAsides();
	await awaitRuntime(async () => {
		const path = document.documentElement.dataset.roomsWasm;
		if (path == null) throw new Error("the Rooms page has no application module");
		await application.loadApplication(fetch(path));
	});
	// Session choice and explicit data deletion must remain reachable before
	// opening storage, including when an obsolete schema refuses startup.
	const deleted = await finishBrowserDataDeletion(chosenKey());
	if (deleted != null) {
		standAtFrontOfPrivilegedAddress();
		await showSessionSetup("", deleted);
		return;
	}
	if (localStorage.getItem(chosenKey()) !== "yes") {
		standAtFrontOfPrivilegedAddress();
		await showSessionSetup();
		return;
	}
	let opened: Awaited<ReturnType<typeof openManagedSession>>;
	try {
		opened = await openWorkspace();
	} catch (error) {
		standAtFrontOfPrivilegedAddress();
		await showSessionSetup("", attachedSessionFailureText(error));
		return;
	}
	const { session: managed, local } = opened;
	if (local && managed.current != null) {
		const search = new URLSearchParams(location.search);
		const current = managed.current.intent;
		const connection = prefs.dmFrom(search, current.connection);
		if (connection !== current.connection) {
			await managed.actions.run("chooseConnection", [connection]);
		}
	}
	page.controllerSelection.set(
		local ? { kind: "local" } : { kind: "attached", sturdyref: await managed.workspace.publish() },
	);
	noteBootPhase(local ? "rooms" : "session");
	const establishedUi = loadEstablished();
	prefetch(() => establishedUi);
	if (location.pathname.startsWith("/ops")) prefetch(loadOpsPage);
	const history = new ManagedHistory(page, managed, report);
	const files = presentationFiles(page.projection, () => history.source);
	history.bindFiles(files);
	const projection = new ManagedProjection(
		page,
		managed,
		files,
		() => history.refresh(),
		(key) => history.unavailable(key),
	);
	const stopProjection = projection.bind();
	let selfLocator: string | null = null;
	const session: RoomsSessionController = createManagedController(
		page,
		browser,
		managed,
		files,
		await prefs.directoryLocator() ?? "",
		history,
		() => selfLocator,
	);
	if (local) {
		selfLocator = await managed.application.startRooms(membershipStatus(page.projection, report));
		// Opening the page observes its directory without claiming a nickname.
		// Existing holdings keep their exact saved authority and user intent.
		if (!managed.current?.intent.directories.some((row) => row.home)) {
			const reason = await session.reachDirectory("", { kind: "exact", name: "" });
			if (reason !== "") report(managedText.roomsConnection, reason);
		}
	}
	history.start();
	managed.bindPresentation(async () => {
		stopProjection();
		files.close();
		await history.close();
	});
	if (location.pathname !== "/") reserveSelectionForAddress(page);
	const { EstablishedSession, bindEstablishedRouting } = await establishedUi;
	bindEstablishedRouting(page);
	root.render(
		<StrictMode>
			<PageSurface>
				<ManagedSessionProvider value={managed}>
					<ModalProvider key="established-session">
						<EstablishedSession session={session} />
					</ModalProvider>
				</ManagedSessionProvider>
			</PageSurface>
		</StrictMode>,
	);

	handOffWhenReady(page.projection, "controller-snapshot");
}

void start().catch((error) => {
	pageDidNotOpen(refusalText(error));
});
