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
import { RoomsRouter } from "./router.tsx";
import { ErrorBoundary } from "./ErrorBoundary.tsx";
import { handOffWhenReady } from "./boot.ts";
import * as net from "./net.ts";
import * as store from "./store.ts";
import * as prefs from "./prefs.ts";
import { type Peer, PeerProvider } from "./peer.ts";

// The one binding of what the interface can ask for to what performs it. Built
// here and never rebuilt, so no component below re-renders on account of it, and
// no component below imports the peer.
const peer: Peer = {
	directoryReady: net.directoryReady,
	showRail: store.showRail,
	pickRoom: net.pickRoom,
	leaveRoom: net.leaveRoom,
	reachFor: net.reachFor,
	showJoinCard: store.showJoinCard,
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
	openOperations: store.openOperations,
	closeOperations: store.closeOperations,
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

createRoot(mount, {
	// React's own error reporting, rather than the console it would otherwise
	// write to unattended. `onCaughtError` is what a boundary below already
	// handled; `onUncaughtError` is one that reached the top; `onRecoverableError`
	// is React repairing itself and worth seeing while developing.
	onUncaughtError: (error: unknown, info: { componentStack?: string }) =>
		console.error("rooms: nothing caught this render error:", error, info.componentStack),
	onCaughtError: (error: unknown) => console.warn("rooms: a boundary caught a render error:", error),
	onRecoverableError: (error: unknown) => console.warn("rooms: React recovered from:", error),
}).render(
	<StrictMode>
		<ErrorBoundary part="page">
			<PeerProvider value={peer}>
				<RoomsRouter />
			</PeerProvider>
		</ErrorBoundary>
	</StrictMode>,
);

net.connect();

handOffWhenReady();
