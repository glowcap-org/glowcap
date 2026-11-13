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
import { type ReactNode, StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { addressOfActive, navigateTo } from "./routing_api.ts";
import { loadEstablished, loadOpsPage, loadServerOffer, loadSessionSetup, prefetch } from "./chunks.ts";
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
import { ManagedSessionStartupFailure, openManagedSession } from "./session/managed/open.ts";
import { attachedSessionFailureText } from "./session/attached_failure.ts";
import { ManagedSessionProvider } from "./session/managed/context.tsx";
import { ManagedProjection } from "./session/managed/projection.ts";
import { presentationFiles } from "./session/managed/files.ts";
import { createManagedController } from "./session/managed/controller.ts";
import { ManagedHistory } from "./session/managed/history.ts";
import * as application from "./application.ts";
import { RoomsBrowserProvider } from "./controller/browser.ts";
import { createRoomsBrowserController, forgetWorkspaceChoice, workspaceChosen } from "./controller/create_browser.ts";
import { finishBrowserDataDeletion, reloadWhenAnotherTabDeletes } from "./controller/browser_data.ts";
import { ModalProvider } from "./modal.ts";
import type { RoomsSessionController } from "./controller/session.ts";
import { failureView, LocalRefusal, refusalText, renderFailure } from "../../lib/text/failure.ts";
import { membershipStatus } from "./session/managed/membership_status.ts";
import * as store from "./store.ts";
import { relayAway } from "./store/projection.ts";
import { bindViewPreferences } from "./view_preferences.ts";
import { bindGroundToConnections } from "./mycelium/link.ts";
import { bindReloadToBuild, servedPageBuild } from "./build_link.ts";
import { pagePath, pathOffer } from "./page_base.ts";
import {
	chooseServer,
	PROBE_TIMEOUT_MS,
	reachesLocalNetwork,
	serverInUse,
	serverOffer,
	sessionOffer,
} from "./server_choice.ts";
import { sessionDidNotOpen } from "../../lib/text/session.ts";
import { settingsServerOffer, settingsServerRefused } from "../../lib/text/settings.ts";
import { NO_SERVER, roomsErrorIn } from "../../lib/error_codes.ts";

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
if (build != null) bindReloadToBuild(page.projection, build);
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
		handOffNow();
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
		await showSessionSetup(attach?.capability ?? "", deleted ?? "");
		return;
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
		await showSessionSetup("", attachedSessionFailureText(error, serverInUse()));
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
	if (pagePath().startsWith("/ops")) prefetch(loadOpsPage);
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
	// The Rooms server this browser uses names the directory a blank address
	// means: the one this device chose, else the one that sent this page. A
	// static host is no server, so with no choice there is none.
	const server = serverInUse();
	const directoryOf = (base: string) =>
		prefs.servedDirectory(
			application.namesDirectory,
			(address) => fetch(address, { signal: AbortSignal.timeout(PROBE_TIMEOUT_MS) }),
			new URL("locator", base),
		);
	const servedDirectory = server == null ? null : await directoryOf(server.base);
	page.projection.set({ server: server == null ? null : { ...server, directory: servedDirectory } });
	// A server that was not answering when the page opened names its directory
	// once it is reached, so a blank address finds it without a reload.
	const readServedDirectory = async () => {
		const held = page.projection.get().server;
		if (held == null || held.directory != null) return;
		const directory = await directoryOf(held.base);
		if (directory != null) page.projection.set({ server: { ...held, directory } });
	};
	const session: RoomsSessionController = createManagedController(
		page,
		browser,
		managed,
		files,
		history,
		() => selfLocator,
	);
	if (local) {
		try {
			selfLocator = await managed.application.startRooms(membershipStatus(page.projection, report));
		} catch (error) {
			// Relay-only messages keep this browser's address off WebRTC, so a
			// page with no Rooms server has no address to give. That is the page's
			// state, not trouble: it stays open, and Settings is where a server is
			// chosen. Anything else is the failure it is.
			if (server != null || roomsErrorIn(error)?.code !== NO_SERVER) throw error;
		}
		// The session opens whether or not the relay answers. Its state is a
		// fact on the page, and its reasons go to the trouble journal.
		// A page with no Rooms server registers nowhere, so it has no relay
		// state to show.
		if (server != null) {
			page.projection.set({ relay: "connecting" });
			await managed.application.observeRelay((reason: string | null) => {
				// Every seat retries on its own, so the journal records a change of
				// reason once rather than every attempt.
				const was = page.projection.get().relay;
				if (reason == null ? was === "reached" : relayAway(was) && was.away === reason) return;
				if (reason != null) report(managedText.roomsServer, reason);
				page.projection.set({ relay: reason == null ? "reached" : { away: reason } });
				if (reason == null) void readServedDirectory();
			});
		}
		// A session that holds no directory opens in the served one, without
		// claiming a nickname, and takes it as home. A session that holds any
		// keeps its own, and the join card offers the served one.
		if (servedDirectory != null && managed.current?.intent.directories.length === 0) {
			page.projection.set({ openingDirectory: true });
			const reason = await session.reachDirectory("", { kind: "exact", name: "" });
			page.projection.set({ openingDirectory: false });
			if (reason !== "") report(managedText.roomsConnection, reason);
		}
	}
	history.start();
	managed.bindPresentation(async () => {
		stopProjection();
		files.close();
		await history.close();
	});
	if (pagePath() !== "/") reserveSelectionForAddress(page);
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
				const refused = forgetWorkspaceChoice();
				return refused == null ? null : refusalText(refused);
			}
			: null,
	);
});
