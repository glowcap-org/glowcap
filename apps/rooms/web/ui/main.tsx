// The Rooms page entry, bundled to /page.js by rooms-web. Rust Wasm
// admits durable startup choices. This module mounts their React projection.
//
// Rust owns local and attached session execution. React renders their shared
// presentation without opening a second Host or owning session state.
//
// One thing ends here. The screen page.html has been holding up since the first
// parse is handed over by `boot.ts`, and that call comes last, because reaching
// it is also how this module reports that the bundle arrived at all.

import { invariant } from "../../lib/invariant.ts";
import { errorMessage } from "../../lib/error_message.ts";
import { managedSessionText as managedText } from "../../lib/text/managed_session.ts";
import { type ReactNode, StrictMode, useLayoutEffect } from "react";
import { createRoot } from "react-dom/client";
import { addressOfActive, navigateTo } from "./routing_api.ts";
import {
	loadEstablished,
	loadOpsPage,
	loadSavedWorkspaces,
	loadServerOffer,
	loadSessionSetup,
	prefetch,
} from "./chunks.ts";
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
import { bindNetwork, bindTabVisibility, RoomsProjectionProvider } from "./hooks.ts";
import { dmFrom } from "./dm_transport.ts";
import {
	ManagedSessionStartupFailure,
	openManagedSession,
	type OpenOrigin,
	openOver,
	presentSession,
} from "./session/managed/open.ts";
import { ManagedSessionProvider } from "./session/managed/context.tsx";
import type { ManagedRoomsSession } from "./session/managed/session.ts";
import { ManagedProjection } from "./session/managed/projection.ts";
import { presentationFiles } from "./session/managed/files.ts";
import { createManagedController } from "./session/managed/controller.ts";
import { ManagedHistory } from "./session/managed/history.ts";
import * as application from "./application.ts";
import { RoomsBrowserProvider } from "./controller/browser.ts";
import { createRoomsBrowserController, setupRefusal } from "./controller/create_browser.ts";
import {
	coldWorkspace,
	markedWorkspaces,
	pinnedWorkspace,
	pinWorkspace,
	recordWorkspaceChoice,
	rememberOpenWorkspace,
	workspaceChosen,
} from "./workspace_choice.ts";
import { finishBrowserDataDeletion, reloadWhenAnotherTabDeletes } from "./controller/browser_data.ts";
import { ModalProvider } from "./modal.ts";
import type { RoomsSessionController } from "./controller/session.ts";
import { failureView, LocalRefusal, refusalText, renderFailure } from "../../lib/text/failure.ts";
import * as store from "./store.ts";
import { bindViewPreferences } from "./view_preferences.ts";
import { bindGroundToConnections } from "./mycelium/link.ts";
import { bindReloadToBuild, type BuildReload, pageReloadLoss } from "./build_reload.ts";
import { servedPageBuild } from "./served_build.ts";
import { pagePath, pathOffer } from "./page_base.ts";
import { chooseServer, serverOffer } from "./server_choice.ts";
import { sessionOffer } from "./session_offer.ts";
import { reachesLocalNetwork } from "./local_network.ts";
import { openServedDirectory, showServedDirectory, startLocalRooms } from "./served_directory.ts";
import { savedWorkspaceTitle, sessionDidNotOpen } from "../../lib/text/session.ts";
import { settingsServerOffer, settingsServerRefused } from "../../lib/text/settings.ts";
import { roomsErrorIn } from "../../lib/error_codes.ts";

const page = new RoomsPage();
function report(source: string, error: unknown): void {
	// A journal row is a diagnostic, not an action that failed. A failure the
	// reader's words explain keeps them. One nothing explains is kept as said,
	// without advice to try again.
	const view = failureView(error);
	const reason = view.code === "unexpected" ? view.detail : renderFailure(view);
	store.noteTrouble(page.projection, source, reason);
}
// The threads under the page dim while every connection is lost and grow
// back in when one returns. The binding lives as long as the page.
bindGroundToConnections(page.projection);
// A page whose server has moved to a new build reloads into it.
const build = servedPageBuild(document);
const reload: BuildReload | null = build == null
	? null
	: bindReloadToBuild(page.projection, build, pageReloadLoss(page));
// The stylesheet refuses page scaling everywhere the root's `touch-action` is
// honoured. This is WebKit's half, which arrives as its own gesture events.
refusePageScaling();
bindTabVisibility(page.projection);
bindNetwork(page.projection);
const browser = createRoomsBrowserController(page, navigateTo, addressOfActive, () => openWorkspace("local"));
let openingWorkspace: ReturnType<typeof openManagedSession> | null = null;
function openWorkspace(selection: "saved" | "local" = "saved"): ReturnType<typeof openManagedSession> {
	const failed = (error: unknown, origin: OpenOrigin) => store.noteSessionOpenFailure(page.projection, error, origin);
	return openingWorkspace ??= openManagedSession(report, selection, failed).then((opened) => {
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
invariant(mount, "rooms: page.html is missing its #root element");

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
function PageSurface({ children, established = false }: { children: ReactNode; established?: boolean }) {
	useLayoutEffect(() => {
		if (established) handOffWhenReady(page.projection, "controller-snapshot");
		else handOffNow();
	}, [established]);
	return (
		<RoomsProjectionProvider value={page.projection}>
			<RoomsBrowserProvider value={browser}>
				{children}
			</RoomsBrowserProvider>
		</RoomsProjectionProvider>
	);
}

async function showSessionSetup({ capability = "", error = "", recoveryError = "" } = {}): Promise<void> {
	const { SessionSetup } = await loadSessionSetup();
	const { RoomsBrowserData } = application.applicationModule();
	let saved: string[] = [];
	try {
		saved = await RoomsBrowserData.savedWorkspaces();
	} catch (error) {
		report(savedWorkspaceTitle, error);
		saved = markedWorkspaces();
		try {
			const owners = await RoomsBrowserData.savedWorkspaceOwners();
			saved = [...new Set([...saved, ...owners])].sort();
		} catch (error) {
			// Setup still offers marked workspaces when storage itself is blocked.
			report(savedWorkspaceTitle, error);
		}
	}
	const pin = pinnedWorkspace();
	if (pin && !saved.includes(pin)) saved = [pin, ...saved];
	const Recovery = saved.length || recoveryError ? (await loadSavedWorkspaces()).SavedWorkspaces : null;
	root.render(
		<StrictMode>
			<PageSurface>
				<ModalProvider key="session-setup">
					<SessionSetup
						initialCapability={capability}
						initialError={error}
						renderSavedWorkspaces={Recovery
							? (disabled, primary) => (
								<Recovery
									choices={saved}
									pin={pin}
									initialError={recoveryError}
									primary={primary}
									disabled={disabled}
								/>
							)
							: undefined}
					/>
				</ModalProvider>
			</PageSurface>
		</StrictMode>,
	);
}

/** Ask about a Rooms server this page's link offers, and take the offer out of
 * the address whatever the answer. A link never changes the server by itself. */
async function answerServerOffer(): Promise<void> {
	const offer = serverOffer(new URL(location.href));
	if (offer == null) return;
	globalThis.history.replaceState(globalThis.history.state, "", offer.rest);
	// An offer that is no server address is the link's defect, kept where
	// whoever is debugging the link looks, and the page opens as it would.
	if (offer.unreadable != null) {
		store.noteTrouble(page.projection, settingsServerOffer, `${settingsServerRefused} (${offer.unreadable})`);
	}
	const base = offer.base;
	if (base == null) return;
	const { ServerOffer } = await loadServerOffer();
	const use = await new Promise<boolean>((answer) => {
		root.render(
			<StrictMode>
				<PageSurface>
					<ServerOffer
						host={new URL(base).host}
						local={reachesLocalNetwork(new URL(base))}
						onAnswer={answer}
					/>
				</PageSurface>
			</StrictMode>,
		);
	});
	// A choice this browser cannot keep would leave the page on another server.
	const refused = use ? chooseServer(base) : null;
	if (refused != null) throw refused;
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
				noteBootDelay(errorMessage(err));
			}
			await new Promise((settle) => setTimeout(settle, backoff));
			backoff = Math.min(backoff * 2, RUNTIME_RETRY_CEILING_MS);
		}
	}
}

// Rust admits the workspace and selects the controller before a Host exists.
// Both local and attached sessions run on the Rust application Host.
async function start(): Promise<void> {
	// A host that serves one file per address hands a deep link over through
	// its 404 page. Standing at that path comes before anything reads the address.
	const at = pathOffer(new URL(location.href));
	if (at != null) globalThis.history.replaceState(globalThis.history.state, "", at);
	startOpeningMark();
	noteBootPhase("peer");
	startBootAsides();
	await awaitRuntime(async () => {
		const path = document.documentElement.dataset.roomsWasm;
		invariant(path != null, "the Rooms page has no application module");
		await application.loadApplication(fetch(path));
	});
	// A deletion asked for before this load finishes before anything opens
	// storage, and before the address is read, so what a link offers is kept
	// while everything this browser saved is gone.
	const deleted = await finishBrowserDataDeletion();
	// Preferences bind after the deletion, so a deleting tab reads the empty
	// storage and nothing it held in memory is written back.
	const stopPreferences = bindViewPreferences(page.projection);
	addEventListener("pagehide", stopPreferences, { once: true });
	reloadWhenAnotherTabDeletes();
	// A shared session a link offers leaves the address before anything else
	// runs, and opens session choice with it filled in, whatever this browser
	// used last. Attach is the answer, so a link never attaches by itself, and
	// the session in use stays until it is pressed.
	const attach = sessionOffer(new URL(location.href));
	if (attach != null) globalThis.history.replaceState(globalThis.history.state, "", attach.rest);
	// The server is fixed when the session opens, so a link's offer of one is
	// answered before session choice.
	await answerServerOffer();
	// Session choice must remain reachable before opening storage, including
	// when an obsolete schema refuses startup.
	if (attach != null || deleted != null) {
		standAtFrontOfPrivilegedAddress();
		await showSessionSetup({ capability: attach?.capability, error: deleted ?? "" });
		return;
	}
	const cold = coldWorkspace();
	if (cold !== null) {
		const refused = pinWorkspace(cold);
		if (refused) throw refused;
	}
	if (!workspaceChosen()) {
		standAtFrontOfPrivilegedAddress();
		await showSessionSetup();
		return;
	}
	let opened: Awaited<ReturnType<typeof openManagedSession>>;
	try {
		opened = await openWorkspace();
	} catch (error) {
		standAtFrontOfPrivilegedAddress();
		await showSessionSetup({ recoveryError: setupRefusal(page.projection, error) });
		return;
	}
	const rememberFailure = rememberOpenWorkspace();
	if (rememberFailure) store.toast(page.projection, "failure", refusalText(rememberFailure));
	const { session: managed, local } = opened;
	// A page that does not open closes its session, so nothing dials behind it.
	let stopOnFailure = () => {};
	await openOver(
		managed,
		() => stopOnFailure(),
		() => showEstablishedPage(managed, local, (stop) => stopOnFailure = stop),
	);
}

/** Present the session `managed` opened and render the page over it.
 * `presenting` hears how to stop the presentation as soon as it starts, so a
 * page that fails to open after that stops it. */
async function showEstablishedPage(
	managed: ManagedRoomsSession,
	local: boolean,
	presenting: (stop: () => void) => void,
): Promise<void> {
	if (local && managed.current != null) {
		const search = new URLSearchParams(location.search);
		const current = managed.current.intent;
		const connection = dmFrom(search, current.connection);
		if (connection !== current.connection) {
			await managed.actions.run("chooseConnection", [connection]);
		}
	}
	const stopPresenting = presentSession(page, managed, report);
	presenting(stopPresenting);
	noteBootPhase(local ? "rooms" : "session");
	const establishedUi = loadEstablished();
	prefetch(() => establishedUi);
	if (pagePath().startsWith("/ops")) prefetch(loadOpsPage);
	const history = new ManagedHistory(page, managed, report);
	if (managed.link != null) {
		managed.onRelink(() => history.relink());
		// A link that returns may return to a server with a new build.
		if (reload != null) managed.onRelink(() => reload.check());
	}
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
	const servedDirectory = await showServedDirectory(page);
	const session: RoomsSessionController = createManagedController(
		page,
		browser,
		managed,
		files,
		history,
		() => selfLocator,
	);
	if (local) {
		selfLocator = await startLocalRooms(page, managed, report);
		await openServedDirectory(page, managed, session, servedDirectory, report);
	}
	history.start();
	managed.bindPresentation(async () => {
		stopPresenting();
		stopProjection();
		files.close();
		await history.close();
	});
	if (pagePath() !== "/") reserveSelectionForAddress(page);
	const { EstablishedSession, bindEstablishedRouting } = await establishedUi;
	bindEstablishedRouting(page);
	root.render(
		<StrictMode>
			<PageSurface established>
				<ManagedSessionProvider value={managed}>
					<ModalProvider key="established-session">
						<EstablishedSession session={session} />
					</ModalProvider>
				</ManagedSessionProvider>
			</PageSurface>
		</StrictMode>,
	);
}

void start().catch((error) => {
	console.error("rooms: opening failed:", error);
	// A Rooms refusal says what to do. Anything else gives a person nothing to
	// act on, so the page says so plainly and the console keeps the cause.
	const said = error instanceof LocalRefusal || roomsErrorIn(error) != null;
	const reason = said ? refusalText(error) : sessionDidNotOpen;
	// Forgetting this tab's session choice keeps its data and shows setup. A
	// tab that has chosen none has only the page to reload.
	pageDidNotOpen(
		reason,
		workspaceChosen()
			? () => {
				const refused = recordWorkspaceChoice(false);
				return refused == null ? null : refusalText(refused);
			}
			: null,
	);
});
