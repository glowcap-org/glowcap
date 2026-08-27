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

import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { addressOfActive, navigateTo, RoomsRouter } from "./router.tsx";
import { ErrorBoundary } from "./ErrorBoundary.tsx";
import { handOffNow, handOffWhenReady, type RoomsOpeningReadiness } from "./boot.ts";
import * as net from "./net.ts";
import * as store from "./store.ts";
import * as prefs from "./prefs.ts";
import { hydrateConversation, installHistoryRecorder } from "./net/history.ts";
import { restoreHistoryPreference } from "./history.ts";
import { createLocalRoomsSession } from "./session/local.ts";
import { installWorkspaceStatePersistence, restoreWorkspaceState } from "./workspace_state.ts";
import { CapabilitySetProvider } from "./settings/CapabilitySetModel.tsx";
import { connectAttachedRoomsSession } from "./session/attached_connection.ts";
import { AttachedSessionProjection } from "./session/projection.ts";
import { createAttachedRoomsSession } from "./session/attached_session.ts";
import { AttachedSessionFiles } from "./session/attached_files.ts";
import { workspaceControllerSelection } from "./workspace_state.ts";
import { SessionSetup } from "./SessionSetup.tsx";
import { RoomsBrowserProvider } from "./controller/browser.ts";
import { RoomsSessionProvider } from "./controller/session.ts";
import { createRoomsBrowserController } from "./controller/create_browser.ts";
import { attachedSessionFailureText } from "./session/attached_failure.ts";

const browser = createRoomsBrowserController(navigateTo, addressOfActive);
const localSession = createLocalRoomsSession();
let session = localSession;

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
			await net.openDirectory(locator, net.FIRST_BACKOFF_MS);
		}
	};
	await Promise.all(
		Array.from({ length: Math.min(RESTORE_DIRECTORY_CONCURRENCY, locators.length) }, worker),
	);
}

/** Say on the opening screen why it is still up. The screen is page.html's
 * own markup, so this speaks to it directly: the note line turns patient,
 * and one detail line carries the newest reason. Recovery needs no undoing —
 * the screen comes down through the ordinary handoff once the peer answers. */
function noteBootDelay(why: string): void {
	const note = document.querySelector("#boot .boot-note");
	if (note !== null) {
		note.textContent = "Still opening — the server may be rebuilding this page's runtime…";
	}
	const wait = document.querySelector("#boot .boot-wait");
	if (wait === null) return;
	let detail = wait.querySelector(".boot-why");
	if (detail === null) {
		detail = document.createElement("p");
		detail.className = "boot-why";
		wait.append(detail);
	}
	detail.textContent = why;
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

function showSessionSetup(initialCapability = "", initialError = ""): void {
	root.render(
		<StrictMode>
			<RoomsBrowserProvider value={browser}>
				<SessionSetup initialCapability={initialCapability} initialError={initialError} />
			</RoomsBrowserProvider>
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
	const slowAt = Date.now() + RUNTIME_SLOW_AFTER_MS;
	let backoff = RUNTIME_RETRY_FLOOR_MS;
	let ready = false;
	while (!ready) {
		try {
			await net.bootRuntime();
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
	const pageLocator = prefs.directoryLocator();
	const restored = restoreWorkspaceState(
		net.directoryId,
		location.pathname === "/",
	);
	const controllerSelection = workspaceControllerSelection();
	if (controllerSelection.kind === "none") {
		showSessionSetup();
		return;
	}
	let openingReadiness: RoomsOpeningReadiness;
	if (controllerSelection.kind === "attached") {
		let attached: Awaited<ReturnType<typeof connectAttachedRoomsSession>>;
		try {
			attached = await connectAttachedRoomsSession(controllerSelection.sturdyref);
		} catch (error) {
			showSessionSetup(controllerSelection.sturdyref, attachedSessionFailureText(error));
			return;
		}
		const files = new AttachedSessionFiles(attached);
		const projection = new AttachedSessionProjection(files);
		const stopProjection = projection.bind(attached);
		session = createAttachedRoomsSession(browser, attached, files, {
			defaultDirectoryLocator: await pageLocator,
		});
		addEventListener("pagehide", () => {
			stopProjection();
			files.close();
			void attached.close();
		}, { once: true });
		openingReadiness = "controller-snapshot";
	} else {
		// A local controller owns this browser's archive writes. Attached views
		// receive lines already recorded by the durable session owner.
		installHistoryRecorder();
		await net.restoreArchivePeer();
		for (const conversation of store.get().convs.values()) hydrateConversation(conversation);
		openingReadiness = "directory-attempt";
	}
	restoreHistoryPreference(store.get().keepHistory);
	if (location.pathname !== "/") net.reserveSelectionForAddress();
	installWorkspaceStatePersistence();
	root.render(
		<StrictMode>
			<RoomsBrowserProvider value={browser}>
				<RoomsSessionProvider value={session}>
					<CapabilitySetProvider>
						<ErrorBoundary part="page">
							<RoomsRouter />
						</ErrorBoundary>
					</CapabilitySetProvider>
				</RoomsSessionProvider>
			</RoomsBrowserProvider>
		</StrictMode>,
	);

	if (controllerSelection.kind === "local") {
		net.connect();
		void restoreDirectories(restored.foreignLocators);
		void pageLocator.then((current) => {
			if (current === null || restored.savedHomeLocator === null) return;
			if (net.directoryId(current) === net.directoryId(restored.savedHomeLocator)) return;
			void net.openDirectory(restored.savedHomeLocator, net.FIRST_BACKOFF_MS);
		});
	}

	handOffWhenReady(openingReadiness);
}

void start();
