// The rooms browser client's entry module. Authored in TypeScript and JSX
// against the DOM libs (see the ui/deno.json lib setting) and bundled to
// /page.js by serve.ts at startup, so there is no committed build artifact.
//
// Two things start here, and they are deliberately not the same thing. React
// mounts the interface, which is a function of the store. `connect()` opens the
// CapTP session, which is owned by `net.ts` at module scope and outlives every
// render — so a remount, StrictMode's double pass, or an error boundary catching
// a crash never disturbs a live conversation. Nothing below reaches into the
// tree, and nothing in the tree reaches into the session.
//
// One thing ends here. The screen page.html has been holding up since the first
// parse is handed over by `boot.ts`, and that call comes last, because reaching
// it is also how this module reports that the bundle arrived at all.

import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { addressOfActive, navigateTo, RoomsRouter } from "./router.tsx";
import { ErrorBoundary } from "./ErrorBoundary.tsx";
import { handOffWhenReady } from "./boot.ts";
import * as net from "./net.ts";
import * as store from "./store.ts";
import * as prefs from "./prefs.ts";
import { type Peer, PeerProvider } from "./peer.ts";
import { installHistoryRecorder } from "./net/history.ts";
import { setHistoryKept } from "./history.ts";

// The one binding of what the interface can ask for to what performs it. Built
// here and never rebuilt, so no component below re-renders on account of it, and
// no component below imports the peer.
// Standing on /ops nothing is selected, so picking a conversation is always
// a transition the router's mirror answers by leaving the namespace. The one
// act the mirror cannot see is opening the join card, which changes no
// selection; these two verbs carry their own step out. Deferred, because the
// rail commits the join-card act inside flushSync, where a synchronous
// navigation is at the renderer's mercy.
function backToRooms<A extends unknown[]>(act: (...args: A) => void): (...args: A) => void {
	return (...args: A): void => {
		act(...args);
		if (location.pathname.startsWith("/ops")) {
			queueMicrotask(() => navigateTo(addressOfActive()));
		}
	};
}

const peer: Peer = {
	directoryReady: net.directoryReady,
	showRail: store.showRail,
	pickRoom: net.pickRoom,
	leaveRoom: net.leaveRoom,
	reachFor: backToRooms(net.reachFor),
	showJoinCard: backToRooms(store.showJoinCard),
	openPrivateRoom: (dir, label) => {
		void net.openPrivateRoom(dir, label).then((why) => {
			if (why !== "") store.toast("failure", why);
		});
	},
	acceptInvite: (id) => {
		void net.acceptInvite(id).then((why) => {
			if (why !== "") store.toast("failure", why);
		});
	},
	declineInvite: net.declineInvite,
	setStanding: net.setStanding,
	setDirStanding: net.setDirStanding,
	setRoomStanding: net.setRoomStanding,
	aboutDirectory: net.aboutDirectory,
	aboutConversation: store.showAboutConv,
	closeAboutConversation: store.closeAboutConv,
	showError: store.showErrorDetail,
	closeError: store.closeErrorDetail,
	leaveDirectory: net.leaveDirectory,
	openConv: store.switchTo,
	closeDm: net.closeDm,
	toast: store.toast,
	showRoster: store.showRoster,
	endConv: net.endConversation,
	setTheme: store.setTheme,
	toggleNotify: net.toggleNotify,
	openSettings: store.openSettings,
	closeSettings: store.closeSettings,
	setSettingsTab: store.setSettingsTab,
	applySettings: prefs.apply,
	selfLocator: net.selfLocator,
	directoryLocator: net.directoryLocator,
	dirAddress: net.dirAddress,
	directoryId: net.directoryId,
	openHelp: store.openHelp,
	closeHelp: store.closeHelp,
	joinIrc: net.joinIrcBridge,
	partIrc: net.partIrcBridge,
	setKeepHistory: (keep) => {
		store.setKeepHistory(keep);
		setHistoryKept(keep);
	},
	openOperations: () => {
		store.closeSettings();
		navigateTo("/ops");
	},
	openOpsTake: store.openOpsTake,
	closeOpsTake: store.closeOpsTake,
	// Each capability's take, drop, and refresh live in one table below the
	// page, so these three are the whole of what the page asks. The drop
	// clears that capability's rows, and possession is derived from the rows,
	// so the toggle falls off in the same store change.
	takeOpsCap: net.takeOpsCap,
	dropOpsCap: net.dropOpsCap,
	refreshOpsCap: net.refreshOpsCap,
	setOpsTab: store.setOpsTab,
	listenerUp: net.requestListenerUp,
	listenerDown: net.requestListenerDown,
	publishPeeredRoom: net.publishPeeredRoom,
	revokePeeredPublication: net.revokePeeredPublication,
	startDm: net.startDm,
	retry: net.retrySend,
	stopSend: net.stopSend,
	withdraw: net.withdraw,
	changeLine: store.startChange,
	changeFiles: store.startRefile,
	dropKeptFile: store.dropKeptFile,
	cancelChange: store.cancelChange,
	mention: net.mention,
	setDraft: net.setDraft,
	recallLastSent: net.recallLastSent,
	send: net.send,
	addFiles: net.addFiles,
	removeFile: store.removeDraftFile,
	openFile: net.openAttachment,
	openViewer: store.openViewer,
	stepViewer: net.stepViewer,
	closeViewer: store.closeViewer,
	setTyping: net.setTyping,
	editJoin: store.editJoin,
	join: net.joinRoom,
};

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

// History records through the store's one deliver seam; the store stays
// sync, this side owns the writing.
installHistoryRecorder();

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

// The opening screen is already up — page.html draws it on first parse — so
// the wasm runtime boots behind it, and nothing renders until the FFI
// adapter exists: locator parsing is native-backed, and a component that
// rendered before the adapter took the whole interface down. The same
// memoized attempt then carries `connect()`, so the screen's wait and the
// dial's wait are one instantiation.
async function start(): Promise<void> {
	const slowAt = Date.now() + RUNTIME_SLOW_AFTER_MS;
	let backoff = RUNTIME_RETRY_FLOOR_MS;
	for (;;) {
		try {
			await net.bootRuntime();
			break;
		} catch (err) {
			console.error("rooms: the runtime did not come up, retrying:", err);
			if (Date.now() >= slowAt) {
				noteBootDelay(err instanceof Error ? err.message : String(err));
			}
			await new Promise((settle) => setTimeout(settle, backoff));
			backoff = Math.min(backoff * 2, RUNTIME_RETRY_CEILING_MS);
		}
	}
	root.render(
		<StrictMode>
			<PeerProvider value={peer}>
				<ErrorBoundary part="page">
					<RoomsRouter />
				</ErrorBoundary>
			</PeerProvider>
		</StrictMode>,
	);

	net.connect();

	handOffWhenReady();
}

void start();
