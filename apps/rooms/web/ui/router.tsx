// The page's address, and what standing at one means.
//
// The store stays the one authority for what the page shows; the address is
// its navigable projection, so a conversation can be shared as a link, a
// reload lands where it says, and the browser's back and forward walk the
// same history every other site's do. Two one-way flows keep that from
// becoming two authorities: a route element translates the address into the
// store's own idempotent intents (`showRoom`, `startDm`, `showConv` — each
// already "show it, getting there if needed"), and one store subscription
// writes the active conversation back onto the address when they disagree.
// Each flow stops where the other one starts, so a change converges in one
// hop.
//
// Every route here files what it names as an act, with `link` for its source,
// so a surface that ends up standing in for the conversation — the join card,
// when the reader has no name on the directory yet — answers the link rather
// than whatever somebody typed last. The two routes that file nothing are the
// front page and the address nothing answers, and that is the same rule from
// the other side: landing there is where the application puts a reader when
// something closes, so treating it as a fresh act would let the card's own
// arrival wipe the act that raised it. See `intent.ts`.
//
// An address decides which conversation is open and nothing else. Whether
// the rail is open, whether the phone is on its list screen, whether the
// roster sheet is up — those are the reader's, not the link's, so every verb
// used here is the selection-only half of its pair (`showRoom` beside
// `pickRoom`, `showConv` beside `switchTo`, `clearConv` beside
// `showJoinCard`). Following a link never rearranges the furniture.
//
// What an address says is only ever a place to stand, never authority: a
// room link names a room the way typing its name into the join card would,
// and a private room's unguessable key stays out of the address entirely —
// its path carries the label under `?private=1`, which reopens the held
// conversation in this tab and degrades to the plain join card anywhere
// else. The `dm` and `viz` page-configuration parameters ride along on every
// address the mirror writes, keeping `prefs.ts`'s bookmark contract.

import { useEffect, useRef } from "react";
import { createBrowserRouter, Outlet, RouterProvider, useLocation, useParams, useRouteError } from "react-router";
import { App } from "./App.tsx";
import { OpsRoute } from "./ops/OpsPage.tsx";
import { handOffNow } from "./boot.ts";
import { Button } from "./Button.tsx";
import { Said } from "./Said.tsx";
import * as store from "./store.ts";
import * as net from "./net.ts";
import { implied, named } from "./intent.ts";
import { useRoomsState } from "./hooks.ts";
import type { DmConv } from "./types.ts";

/** The page-configuration parameters `prefs.ts` reads at open, carried onto
 * every address so a bookmark or reload keeps them. */
function pageSearch(): URLSearchParams {
	const here = new URLSearchParams(location.search);
	const kept = new URLSearchParams();
	for (const name of ["dm", "viz"]) {
		const value = here.get(name);
		if (value !== null) kept.set(name, value);
	}
	return kept;
}

function withSearch(path: string, search: URLSearchParams): string {
	const text = search.toString();
	return text === "" ? path : `${path}?${text}`;
}

/** The address the active conversation should stand at. */
export function addressOfActive(): string {
	const s = store.get();
	const search = pageSearch();
	const conv = s.activeKey === null ? null : s.convs.get(s.activeKey) ?? null;
	if (conv === null) return withSearch("/", search);
	if (conv.type === "dm") return withSearch(`/dm/${encodeURIComponent(conv.id)}`, search);
	if (conv.held) {
		// The label is on screen already; the key is the reference and stays
		// out of the address.
		search.set("private", "1");
		return withSearch(`/room/${encodeURIComponent(conv.id)}`, search);
	}
	if (conv.dir !== s.homeDir) search.set("dir", net.dirAddress(conv.dir));
	return withSearch(`/room/${encodeURIComponent(conv.id)}`, search);
}

/** One dispatch per arrival at an address. A route's intent may have to wait
 * (the directory is still connecting), so "fired" is recorded only when an
 * actionable branch ran, and the effect retries as the store changes until
 * one does. React's strict double-mount reuses the same record, so a waiting
 * intent never dispatches twice. */
function useArrival(location: { key: string }): { done: boolean; mark: () => void } {
	const fired = useRef<{ at: string; done: boolean }>({ at: "", done: false });
	if (fired.current.at !== location.key) {
		fired.current = { at: location.key, done: false };
	}
	return {
		done: fired.current.done,
		mark: () => {
			fired.current.done = true;
		},
	};
}

function RoomRoute() {
	const { name = "" } = useParams();
	const routed = useLocation();
	const homeDir = useRoomsState((state) => state.homeDir);
	const dirs = useRoomsState((state) => state.dirs);
	const arrival = useArrival(routed);
	const search = new URLSearchParams(routed.search);
	const dirParam = search.get("dir") ?? "";
	const isPrivate = search.get("private") === "1";
	useEffect(() => {
		if (arrival.done || name === "") return;
		if (isPrivate) {
			// Only a conversation this tab already holds: a private room cannot
			// be reached by name, and prefixing the join card with its label
			// would create a public room wearing it. So the card that stands in
			// names no room, and says only the one thing this link does imply,
			// which is that it was about somewhere on this page's directory.
			const held = [...store.get().convs.values()]
				.find((conv) => conv.type === "room" && conv.held && conv.id === name);
			if (held !== undefined) {
				store.showConv(held.key);
				arrival.mark();
				return;
			}
			const home = store.get().homeDir;
			if (home === null) return; // the effect refires when the directory lands
			net.reachFor({ source: "link", locator: implied(net.dirAddress(home)) });
			arrival.mark();
			return;
		}
		if (dirParam !== "") {
			const known = net.directoryId(dirParam);
			if (known !== null && store.get().dirs.has(known)) net.showRoom(known, name, "link");
			else net.reachFor({ source: "link", room: named(name), locator: named(dirParam) });
			arrival.mark();
			return;
		}
		const home = store.get().homeDir;
		if (home === null) return; // the effect refires when the directory lands
		net.showRoom(home, name, "link");
		arrival.mark();
	}, [arrival, name, dirParam, isPrivate, homeDir, dirs]);
	return null;
}

function DmRoute() {
	const { nick = "" } = useParams();
	const routed = useLocation();
	const homeDir = useRoomsState((state) => state.homeDir);
	const dirs = useRoomsState((state) => state.dirs);
	const conversations = useRoomsState((state) => state.convs);
	const arrival = useArrival(routed);
	useEffect(() => {
		if (arrival.done || nick === "") return;
		const state = store.get();
		// The newest open line to that nick, because a nick is a directory's
		// grant rather than an identity: two introductions are two
		// conversations, and the address can only name the person as granted
		// now.
		const open = [...state.convs.values()]
			.filter((conv): conv is DmConv => conv.type === "dm" && conv.id.toLowerCase() === nick.toLowerCase())
			.at(-1);
		if (open !== undefined) {
			store.showConv(open.key);
			arrival.mark();
			return;
		}
		if (store.actingDir(state) === null) return; // wait for a directory
		net.startDm(nick);
		arrival.mark();
	}, [arrival, nick, homeDir, dirs, conversations]);
	return null;
}

function JoinRoute() {
	const routed = useLocation();
	const arrival = useArrival(routed);
	useEffect(() => {
		if (arrival.done) return;
		const search = new URLSearchParams(routed.search);
		const room = search.get("room");
		const locator = search.get("locator");
		// A bare /join is a reader asking for the card and naming nothing, so
		// every field falls through to what this browser last used. Naming a
		// room or a locator is a deep link, and each part it names is named
		// outright: a link that says where is answered there whatever was used
		// last, and one that says only which room leaves the where alone.
		net.reachFor({
			source: "link",
			room: room === null ? undefined : named(room),
			locator: locator === null ? undefined : named(locator),
		});
		arrival.mark();
	}, [arrival, routed.search]);
	return null;
}

function IndexRoute() {
	const routed = useLocation();
	const arrival = useArrival(routed);
	useEffect(() => {
		if (arrival.done) return;
		if (store.get().activeKey !== null) store.clearConv();
		arrival.mark();
	}, [arrival]);
	return null;
}

/** An address nothing answers folds back to the front, replacing itself so
 * the dead entry does not linger in history. */
function ElsewhereRoute() {
	useEffect(() => {
		void router.navigate(withSearch("/", pageSearch()), { replace: true });
	}, []);
	return null;
}

/** The one screen, mounted once for every address; the matched child is
 * navigation logic with nothing to draw. */
function Shell() {
	return (
		<>
			<App />
			<Outlet />
		</>
	);
}

/** What a reader sees when a route element throws: the crash card in the
 * page's own voice, in place of react-router's developer screen. The opening
 * screen comes down first, because a card explaining a crash to a reader who
 * cannot see it is not an explanation. */
function RouteCrash() {
	const failed = useRouteError();
	useEffect(() => {
		handOffNow();
	}, []);
	const message = failed instanceof Error ? failed.message : String(failed);
	return (
		<div className="crash" role="alert">
			<h2>The page ran into a problem</h2>
			<Said kind="failure">{message}</Said>
			<p>Your session is not lost. The peer keeps running under this screen.</p>
			<Button variant="quiet" onClick={() => location.reload()}>Reload</Button>
		</div>
	);
}

const router = createBrowserRouter([
	{
		errorElement: <RouteCrash />,
		children: [
			{
				element: <Shell />,
				children: [
					{ index: true, element: <IndexRoute /> },
					{ path: "join", element: <JoinRoute /> },
					{ path: "room/:name", element: <RoomRoute /> },
					{ path: "dm/:nick", element: <DmRoute /> },
					// The operations namespace: /ops lands on the held panes,
					// /ops/<pane> stands on one, and a pane this tab does not
					// hold is a gate asking for its capability. The shell stays
					// up and App swaps the content cell, so these too are
					// navigation logic with nothing to draw.
					{ path: "ops", element: <OpsRoute /> },
					{ path: "ops/:pane", element: <OpsRoute /> },
					{ path: "*", element: <ElsewhereRoute /> },
				],
			},
		],
	},
]);

/** Navigate imperatively from outside the tree: the peer table's verbs run
 * in module scope, where no hook is available. */
export function navigateTo(path: string): void {
	void router.navigate(path);
}

// The write-back half: when the active conversation *changes*, the address
// follows. Only a transition writes — a deep link is an address standing
// ahead of the conversation it names (the join it starts takes time), and a
// mirror that wrote on every store tick would fold it back to the front
// before the arrival could act. Opening somewhere new is a step the back
// button can retrace, so it pushes; standing back at the front is where
// closures land, so it replaces rather than minting an entry that would only
// lead forward to a conversation that just closed.
let mirrored = store.get().activeKey;
store.subscribe(() => {
	const active = store.get().activeKey;
	if (active === mirrored) return;
	mirrored = active;
	// Standing on /ops the shell is still the rooms one and the address is
	// deliberately elsewhere. Picking a conversation is an act that leaves
	// the namespace, so a transition to one navigates; a closure, to
	// nothing, does not yank the reader off the operations surface.
	if (router.state.location.pathname.startsWith("/ops") && active === null) return;
	const want = addressOfActive();
	const at = router.state.location;
	if (want === `${at.pathname}${at.search}`) return;
	void router.navigate(want, { replace: active === null });
});

export function RoomsRouter() {
	return <RouterProvider router={router} />;
}
