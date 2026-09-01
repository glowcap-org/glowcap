// The rooms browser client's entry module. Authored in TypeScript and JSX
// against the DOM libs (see the ui/deno.json lib setting) and bundled to
// /page.js by serve.ts at startup, so there is no committed build artifact.
//
// Two things start here, and they are deliberately not the same thing. React
// mounts a view of the store. `createLocalRoomsSession` selects the in-tab
// session controller, whose CapTP connections outlive every render. A later
// attached controller can stand behind the same view boundary.
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
	type RoomsOpeningReadiness,
	standAtFrontOfPrivilegedAddress,
} from "./boot.ts";
import { noteBootDelay, noteBootPhase, startBootAsides } from "./boot_note.ts";
import { refusePageScaling } from "./gestures.ts";
import * as net from "./net.ts";
import { RoomsPage } from "./page.ts";
import { bindTabVisibility, RoomsProjectionProvider } from "./hooks.ts";
import * as prefs from "./prefs.ts";
import { hydrateConversation, installHistoryRecorder } from "./net/history.ts";
import { isSessionConv } from "./types.ts";
import { restoreHistoryPreference } from "./history.ts";
import { createLocalRoomsSession } from "./session/local.ts";
import { installWorkspaceStatePersistence } from "./workspace_state.ts";
import { restoreWorkspaceState } from "./workspace/bundle.ts";
import { connectAttachedRoomsSession } from "./session/attached_connection.ts";
import { AttachedSessionProjection } from "./session/projection.ts";
import { createAttachedRoomsSession } from "./session/attached_session.ts";
import { AttachedSessionFiles } from "./session/attached_files.ts";
import { workspaceControllerSelection } from "./workspace_state.ts";
import { RoomsBrowserProvider } from "./controller/browser.ts";
import { createRoomsBrowserController } from "./controller/create_browser.ts";
import { attachedSessionFailureText } from "./session/attached_failure.ts";
import { ModalProvider } from "./modal.ts";
import { CapabilitySetEvents } from "./ops/capability_set_events.ts";
import { ArchiveTargetController, openArchivePeer } from "./net/archive_target.ts";
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
const RESTORE_DIRECTORY_CONCURRENCY = 4;

async function restoreDirectories(locators: readonly string[]): Promise<void> {
	let next = 0;
	const worker = async () => {
		while (next < locators.length) {
			const locator = locators[next];
			next += 1;
			await net.openDirectory(page, locator, net.FIRST_BACKOFF_MS);
		}
	};
	await Promise.all(
		Array.from({ length: Math.min(RESTORE_DIRECTORY_CONCURRENCY, locators.length) }, worker),
	);
}

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

// The opening screen is already up — page.html draws it on first parse — so
// the wasm runtime boots behind it, and nothing renders until the FFI
// adapter exists: locator parsing is native-backed, and a component that
// rendered before the adapter took the whole interface down. The same
// memoized attempt then carries `connect()`, so the screen's wait and the
// dial's wait are one instantiation.
async function start(): Promise<void> {
	noteBootPhase("peer");
	startBootAsides();
	const slowAt = Date.now() + RUNTIME_SLOW_AFTER_MS;
	let backoff = RUNTIME_RETRY_FLOOR_MS;
	let ready = false;
	while (!ready) {
		try {
			await net.bootRuntime(page);
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
	net.installOpsInvalidation(page);
	const pageLocator = prefs.directoryLocator();
	const restored = restoreWorkspaceState(
		page,
		net.directoryId,
		location.pathname === "/",
	);
	const controllerSelection = workspaceControllerSelection(page);
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
	// Local capability memory is now authoritative and no session has opened yet,
	// so a remembered visualizer observes the Runtime Host's first connection.
	if (controllerSelection.kind === "local") await net.ensureVizPublisher(page);
	let session: RoomsSessionController;
	addEventListener("pagehide", () => {
		capabilityEvents.close();
		page.reachable.stopRendezvous();
	}, { once: true });
	let openingReadiness: RoomsOpeningReadiness;
	let stopLocal: (() => Promise<void>) | null = null;
	if (controllerSelection.kind === "attached") {
		let attached: Awaited<ReturnType<typeof connectAttachedRoomsSession>>;
		try {
			attached = await connectAttachedRoomsSession(page, controllerSelection.sturdyref);
		} catch (error) {
			await showSessionSetup(controllerSelection.sturdyref, attachedSessionFailureText(error));
			return;
		}
		// The page acts that need this exact session rather than a new one find
		// it here; a Host keeps one session per peer, so there is no second one
		// for them to open.
		page.attachedSession.hold(attached);
		const files = new AttachedSessionFiles(attached, page.projection);
		const projection = new AttachedSessionProjection(page, files, capabilityEvents);
		const stopProjection = projection.bind(attached);
		session = createAttachedRoomsSession(page, browser, attached, files, {
			defaultDirectoryLocator: await pageLocator,
			capabilityEvents,
		});
		addEventListener("pagehide", () => {
			page.attachedSession.release();
			stopProjection();
			files.close();
			void attached.close();
		}, { once: true });
		openingReadiness = "controller-snapshot";
	} else {
		// A local controller owns this browser's archive writes. Attached views
		// receive lines already recorded by the durable session owner.
		const archives = new ArchiveTargetController(page, openArchivePeer(page));
		session = createLocalRoomsSession(page, capabilityEvents, archives);
		addEventListener("pagehide", () => void archives.close(), { once: true });
		installHistoryRecorder(page);
		await archives.restoreArchivePeer();
		for (const conversation of page.projection.get().convs.values()) {
			if (isSessionConv(conversation)) hydrateConversation(page, conversation);
		}
		openingReadiness = "directory-attempt";
		stopLocal = async () => {
			page.projection.setLineRecorder(null);
			await archives.close();
		};
	}
	restoreHistoryPreference(page, page.projection.get().keepHistory);
	if (location.pathname !== "/") net.reserveSelectionForAddress(page);
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
	if (stopLocal != null) {
		const endLocal = stopLocal;
		page.hostedSession.bind(async () => {
			const { promoteLocalSessionToHosted } = await import("./session/promote.ts");
			return await promoteLocalSessionToHosted({
				page,
				browser,
				capabilityEvents,
				stopLocal: endLocal,
				remount: (next) => renderEstablished(next, "hosted-session"),
			});
		});
	}
	renderEstablished(session, "established-session");

	if (controllerSelection.kind === "local") {
		net.connect(page);
		void restoreDirectories(restored.foreignLocators);
		void pageLocator.then((current) => {
			if (current === null || restored.savedHomeLocator === null) return;
			if (net.directoryId(current) === net.directoryId(restored.savedHomeLocator)) return;
			void net.openDirectory(page, restored.savedHomeLocator, net.FIRST_BACKOFF_MS);
		});
	}

	handOffWhenReady(page.projection, openingReadiness);
}

void start().catch((error) => {
	pageDidNotOpen(error instanceof Error ? error.message : String(error));
});
