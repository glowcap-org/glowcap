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

import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App.tsx";
import { ErrorBoundary } from "./ErrorBoundary.tsx";
import * as net from "./net.ts";
import * as store from "./store.ts";
import { type Peer, PeerProvider } from "./peer.ts";

// The one binding of what the interface can ask for to what performs it. Built
// here and never rebuilt, so no component below re-renders on account of it, and
// no component below imports the peer.
const peer: Peer = {
	directoryReady: net.directoryReady,
	showRail: store.showRail,
	pickRoom: net.pickRoom,
	leaveRoom: net.leaveRoom,
	openConv: store.switchTo,
	closeDm: net.closeDm,
	banner: store.setBanner,
	showRoster: store.showRoster,
	endConv: net.endConversation,
	toggleTheme: () => store.setTheme(store.get().theme === "dark" ? "light" : "dark"),
	toggleNotify: net.toggleNotify,
	startDm: net.startDm,
	retry: net.retrySend,
	mention: net.mention,
	setDraft: net.setDraft,
	send: net.send,
	setTyping: net.setTyping,
	setJoinDraft: store.setDrafts,
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
	onCaughtError: (error: unknown) =>
		console.warn("rooms: a boundary caught a render error:", error),
	onRecoverableError: (error: unknown) => console.warn("rooms: React recovered from:", error),
}).render(
	<StrictMode>
		<ErrorBoundary part="page">
			<PeerProvider value={peer}>
				<App />
			</PeerProvider>
		</ErrorBoundary>
	</StrictMode>,
);

net.connect();
