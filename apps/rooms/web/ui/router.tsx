// The page's address, and what standing at one means.
//
// The store stays the one authority for what the page shows; the address is
// its navigable projection, so a conversation can be shared as a link, a
// reload lands where it says, and the browser's back and forward walk the
// same history every other site's do. Two one-way flows keep that from
// becoming two authorities: a route element translates the address into the
// store's own idempotent intents (`showRoom`, `showDirectory`, `startDm`,
// `store.showConv` — each already "show it, getting there if needed"), and one
// store subscription writes the active conversation back onto the address when
// they disagree.
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
// `pickRoom`, `store.showConv` beside `switchTo`, `store.clearConv` beside
// `showJoinCard`). Following a link never rearranges the furniture.
//
// What an address says is only ever a place to stand, never authority: a
// room link names a room the way typing its name into the join card would,
// and a private room's unguessable key stays out of the address entirely —
// its path carries the label under `?private=1`, which reopens the held
// conversation in this tab and degrades to the plain join card anywhere
// else. The `dm` and `viz` page-configuration parameters ride along on every
// address the mirror writes, keeping `prefs.ts`'s bookmark contract.

import * as store from "./store.ts";
import { useEffect, useRef } from "react";
import { createBrowserRouter, Outlet, RouterProvider, useLocation, useParams, useRouteError } from "react-router";
import { App } from "./App.tsx";
import { OpsRoute } from "./ops/OpsRoute.tsx";
import { coveringReload, handOffNow, reloadNow } from "./boot.ts";
import { installRouting } from "./routing_api.ts";
import { Button } from "./Button.tsx";
import { Said } from "./Said.tsx";
import * as net from "./net.ts";
import { implied, named } from "./intent.ts";
import { useRoomsState } from "./hooks.ts";
import type { DmConv } from "./types.ts";
import { directoryAddress, pageSearch, roomAddress, withPageSearch } from "./route_address.ts";
import type { RoomsPageContext } from "./page.ts";

let routingPage: RoomsPageContext | null = null;
let mirrored: string | null = null;
let stopAddressMirror: (() => void) | null = null;

function routing(): RoomsPageContext {
	if (routingPage === null) throw new Error("rooms: routing started before the page existed");
	return routingPage;
}

/** Bind the one page this tab's address mirror and route elements act on.
 * Called once the session UI loads, before anything navigates.
 *
 * The write-back half: when the active conversation *changes*, the address
 * follows. Only a transition writes — a deep link is an address standing
 * ahead of the conversation it names (the join it starts takes time), and a
 * mirror that wrote on every store tick would fold it back to the front
 * before the arrival could act. Opening somewhere new is a step the back
 * button can retrace, so it pushes; standing back at the front is where
 * closures land, so it replaces rather than minting an entry that would only
 * lead forward to a conversation that just closed. */
export function bindRoomsRouting(page: RoomsPageContext): void {
	routingPage = page;
	installRouting({ navigateTo, addressOfActive });
	mirrored = page.projection.get().activeKey;
	stopAddressMirror?.();
	stopAddressMirror = page.projection.subscribe(() => {
		const active = page.projection.get().activeKey;
		if (active === mirrored) return;
		mirrored = active;
		// Standing on /ops is an explicit route, independent of whichever
		// conversation remains active behind the Operations surface. Background
		// restoration may select or retire a conversation; neither may overwrite a
		// deep link. Explicit room and join acts leave through the browser
		// controller, which navigates after changing the active conversation.
		if (router.state.location.pathname.startsWith("/ops")) return;
		const want = addressOfActive();
		const at = router.state.location;
		if (want === `${at.pathname}${at.search}`) return;
		void router.navigate(want, { replace: active === null });
	});
}

/** The address the active conversation should stand at. */
export function addressOfActive(): string {
	const s = routing().projection.get();
	const search = pageSearch();
	const conv = s.activeKey === null ? null : s.convs.get(s.activeKey) ?? null;
	if (conv === null) return withPageSearch("/", search);
	if (conv.type === "directory") {
		return directoryAddress(conv.dir === s.homeDir ? {} : { directory: net.dirAddress(routing(), conv.dir) });
	}
	if (conv.type === "dm") return withPageSearch(`/dm/${encodeURIComponent(conv.id)}`, search);
	if (conv.held) {
		// The label is on screen already; the key is the reference and stays
		// out of the address.
		return roomAddress(conv.id, { private: true });
	}
	return roomAddress(conv.id, conv.dir === s.homeDir ? {} : { directory: net.dirAddress(routing(), conv.dir) });
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
		// The store-to-address mirror may have brought us here because a rail
		// press already selected this conversation. In that direction the address
		// is an acknowledgement, not a second lookup. Looking the name up again
		// can select a different key once rich directory discovery learns an exact
		// publication id (especially for a bridge retained by an older shared
		// session), and the shared session then projects its real selection back.
		// Comparing the complete canonical address preserves the one-way flow
		// without pretending the human-readable path is publication identity.
		if (addressOfActive() === `${routed.pathname}${routed.search}`) {
			arrival.mark();
			return;
		}
		if (isPrivate) {
			// Only a conversation this tab already holds: a private room cannot
			// be reached by name, and prefixing the join card with its label
			// would create a public room wearing it. So the card that stands in
			// names no room, and says only the one thing this link does imply,
			// which is that it was about somewhere on this page's directory.
			const held = [...routing().projection.get().convs.values()]
				.find((conv) => conv.type === "room" && conv.held && conv.id === name);
			if (held !== undefined) {
				store.showConv(routing().projection, held.key);
				arrival.mark();
				return;
			}
			const home = routing().projection.get().homeDir;
			if (home === null) return; // the effect refires when the directory lands
			net.reachFor(routing(), { source: "link", locator: implied(net.dirAddress(routing(), home)) });
			arrival.mark();
			return;
		}
		if (dirParam !== "") {
			const known = net.directoryId(dirParam);
			if (known !== null && routing().projection.get().dirs.has(known)) {
				net.showRoom(routing(), known, name, "link");
			} else net.reachFor(routing(), { source: "link", room: named(name), locator: named(dirParam) });
			arrival.mark();
			return;
		}
		const home = routing().projection.get().homeDir;
		if (home === null) return; // the effect refires when the directory lands
		net.showRoom(routing(), home, name, "link");
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
		const state = routing().projection.get();
		// A line with that person, already open here, is what this address asks
		// for. Two introductions to one nick are two conversations and the
		// address can name only the person, so the newest is the best it can do
		// for a reader arriving cold — but it is the wrong answer for a reader
		// who just chose the older one. Standing on it and reading the newest
		// back off the address would take them off the conversation they opened,
		// and the mirror writes this address whenever a line with them is shown.
		const standing = state.activeKey === null ? null : state.convs.get(state.activeKey) ?? null;
		if (standing?.type === "dm" && standing.id.toLowerCase() === nick.toLowerCase()) {
			arrival.mark();
			return;
		}
		// The newest open line to that nick, because a nick is a directory's
		// grant rather than an identity: two introductions are two
		// conversations, and the address can only name the person as granted
		// now.
		const open = [...state.convs.values()]
			.filter((conv): conv is DmConv => conv.type === "dm" && conv.id.toLowerCase() === nick.toLowerCase())
			.at(-1);
		if (open !== undefined) {
			store.showConv(routing().projection, open.key);
			arrival.mark();
			return;
		}
		if (store.actingDir(routing().projection, state) === null) return; // wait for a directory
		net.startDm(routing(), nick);
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
		net.reachFor(routing(), {
			source: "link",
			room: room === null ? undefined : named(room),
			locator: locator === null ? undefined : named(locator),
		});
		arrival.mark();
	}, [arrival, routed.search]);
	return null;
}

/** A directory conversation's address: `/directory` for this page's directory,
 * `/directory?dir=` for any other, the same locator query a room on another
 * directory uses. The view is not a workspace row; the address names which
 * one to recreate. */
function DirectoryRoute() {
	const routed = useLocation();
	const homeDir = useRoomsState((state) => state.homeDir);
	const dirs = useRoomsState((state) => state.dirs);
	const arrival = useArrival(routed);
	const dirParam = new URLSearchParams(routed.search).get("dir") ?? "";
	useEffect(() => {
		if (arrival.done) return;
		if (addressOfActive() === `${routed.pathname}${routed.search}`) {
			arrival.mark();
			return;
		}
		if (dirParam !== "") {
			const known = net.directoryId(dirParam);
			if (known !== null && routing().projection.get().dirs.has(known)) {
				net.showDirectory(routing(), known);
			} else net.reachFor(routing(), { source: "link", locator: named(dirParam) });
			arrival.mark();
			return;
		}
		const home = routing().projection.get().homeDir;
		if (home === null) return;
		net.showDirectory(routing(), home);
		arrival.mark();
	}, [arrival, dirParam, homeDir, dirs]);
	return null;
}

/** The front page, which a reader reaches two ways that mean opposite things.
 *
 * Going there closes what was open, and that is the act this clears. Loading
 * there is not an act at all: it is the address every tab starts at before
 * anything has said what is open, and what says so arrives after. A workspace
 * restores the conversation it was left on, and an attached session states the
 * one it is on for every tab sharing it — so clearing on the first arrival
 * closes the conversation the page was in the middle of opening.
 *
 * `key` tells the two apart. Every navigation gets its own, and the entry a tab
 * loads with is the router's `default`. */
function IndexRoute() {
	const routed = useLocation();
	const arrival = useArrival(routed);
	useEffect(() => {
		if (arrival.done) return;
		arrival.mark();
		if (routed.key === "default") return;
		if (routing().projection.get().activeKey !== null) store.clearConv(routing().projection);
	}, [arrival, routed.key]);
	return null;
}

/** An address nothing answers folds back to the front, replacing itself so
 * the dead entry does not linger in history. */
function ElsewhereRoute() {
	useEffect(() => {
		void router.navigate(withPageSearch("/", pageSearch()), { replace: true });
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
	const leaving = coveringReload();
	useEffect(() => {
		if (!leaving) handOffNow();
	}, [leaving]);
	if (leaving) return null;
	const message = failed instanceof Error ? failed.message : String(failed);
	return (
		<div className="crash" role="alert">
			<h2>The page ran into a problem</h2>
			<Said kind="failure">{message}</Said>
			<p>Your session is not lost. The peer keeps running under this screen.</p>
			<Button variant="quiet" onClick={() => reloadNow()}>Reload</Button>
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
					{ path: "directory", element: <DirectoryRoute /> },
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

export function RoomsRouter() {
	// Browser history is synchronous and observable before a transition commits.
	// Keep its matched route in the same update so an immediate Back cannot arrive
	// while the router still believes it is standing on the previous entry.
	return <RouterProvider router={router} useTransitions={false} />;
}
