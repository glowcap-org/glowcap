// The page's address, and what standing at one means.
//
// The store stays the one authority for what the page shows; the address is
// its navigable projection, so a conversation can be shared as a link, a
// reload lands where it says, and the browser's back and forward walk the
// same history every other site's do. Two one-way flows keep that from
// becoming two authorities: a route element translates the address into the
// store's own idempotent intents (`showRoom`, `showDirectory`, `startDm`,
// `store.showConv`. Each already "show it, getting there if needed"), and one
// store subscription writes the active conversation back onto the address when
// they disagree.
// Each flow stops where the other one starts, so a change converges in one
// hop.
//
// Every route here files what it names as an act, with `link` for its source,
// so a surface that ends up standing in for the conversation (the join card,
// when the reader has no name on the directory yet) answers the link rather status-allow: pending state or quoted runtime label
// than whatever somebody typed last. The two routes that file nothing are the
// front page and the address nothing answers, and that is the same rule from
// the other side: landing there is where the application puts a reader when
// something closes, so treating it as a fresh act would let the card's own
// arrival wipe the act that raised it. See `intent.ts`.
//
// An address decides which conversation is open and nothing else. Whether
// the rail is open, whether the phone is on its list screen, whether the
// roster sheet is up. Those are the reader's, not the link's, so every verb
// used here is the selection-only half of its pair (`showRoom` beside
// `pickRoom`, `store.showConv` beside `switchTo`, `store.clearConv` beside
// `showJoinCard`). Following a link never rearranges the furniture.
//
// What an address says is only ever a place to stand, never authority: a
// room link names a room the way typing its name into the join card would,
// and a private room's unguessable key stays out of the address entirely.
// Its path carries the label under `?private=1`, which reopens the held
// conversation in this tab and degrades to the plain join card anywhere
// else. The `dm` page-configuration parameter rides along on every
// address the mirror writes, keeping `prefs.ts`'s bookmark contract.

import * as store from "./store.ts";
import { useEffect, useRef } from "react";
import { createBrowserRouter, Outlet, RouterProvider, useLocation, useParams, useRouteError } from "react-router";
import { App } from "./shell/App.tsx";
import { OpsRoute } from "./ops/OpsRoute.tsx";
import { coveringReload, handOffNow, reloadNow } from "./boot.ts";
import { installRouting } from "./routing_api.ts";
import { Button } from "./Button.tsx";
import { Said } from "./Said.tsx";
import * as net from "./page_navigation.ts";
import { useRoomsSession } from "./controller/session.ts";
import { implied, named } from "./intent.ts";
import { useRoomsState } from "./hooks.ts";
import type { DmConv } from "./types.ts";
import {
	directoryAddress,
	joinAddress,
	joinAddressOf,
	pageSearch,
	roomAddress,
	withPageSearch,
} from "./route_address.ts";
import type { RoomsPageContext } from "./page.ts";
import { crashReload, crashSessionKept, crashTitle } from "../../lib/text/page.ts";

let routingPage: RoomsPageContext | null = null;
let mirrored: string | null = null;
let mirroredHeld: boolean | null = null;
let stopAddressMirror: (() => void) | null = null;

function routing(): RoomsPageContext {
	if (routingPage === null) throw new Error("rooms: routing started before the page existed");
	return routingPage;
}

/** Bind the one page this tab's address mirror and route elements act on.
 * Called once the session UI loads, before anything navigates.
 *
 * The write-back half: when the active conversation *changes*, the address
 * follows. Only a transition writes: a deep link is an address standing
 * ahead of the conversation it names (the join it starts takes time), and a
 * mirror that wrote on every store tick would fold it back to the front
 * before the arrival could act. Opening somewhere new is a step the back
 * button can retrace, so it pushes. Standing back at the front is where
 * closures land, so it replaces rather than minting an entry that would only
 * lead forward to a conversation that just closed.
 *
 * A room's privacy is what its policy says, and a new room's policy arrives
 * after the room opens. When it settles the open room's address is replaced in
 * place, so a private room never keeps the address of a listed one. */
export function bindRoomsRouting(page: RoomsPageContext): void {
	routingPage = page;
	installRouting({ navigateTo, addressOfActive });
	const heldOf = (active: string | null): boolean | null => {
		const conv = active === null ? null : page.projection.get().convs.get(active) ?? null;
		return conv?.type === "room" ? conv.held : null;
	};
	mirrored = page.projection.get().activeKey;
	mirroredHeld = heldOf(mirrored);
	stopAddressMirror?.();
	stopAddressMirror = page.projection.subscribe(() => {
		const active = page.projection.get().activeKey;
		const held = heldOf(active);
		if (active === mirrored && held === mirroredHeld) return;
		const settled = active === mirrored;
		mirrored = active;
		mirroredHeld = held;
		// Standing on /ops is an explicit route, independent of whichever
		// conversation remains active behind the Operations surface. Background
		// restoration may select or retire a conversation; neither may overwrite a
		// deep link. Explicit room and join acts leave through the browser
		// controller, which navigates after changing the active conversation.
		if (router.state.location.pathname.startsWith("/ops")) return;
		const want = addressOfActive();
		const at = router.state.location;
		if (want === `${at.pathname}${at.search}`) return;
		void router.navigate(want, { replace: active === null || settled });
	});
}

/** The address the active conversation should stand at. */
export function addressOfActive(): string {
	const s = routing().projection.get();
	const search = pageSearch();
	const conv = s.activeKey === null ? null : s.convs.get(s.activeKey) ?? null;
	// Nothing open, and a link put the card up: the card is what is showing,
	// and its address is the act's. Without this the mirror, which runs when the
	// selection clears, would fold a `/join?room=…` a route had just landed on
	// back to `/`, and the address would be wrong twice in one arrival. A card
	// nobody linked to, reached by a press or by the page opening, is the front.
	if (conv === null) {
		return s.reaching.source === "link" ? joinAddressOf(s.reaching) : withPageSearch("/", search);
	}
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

/** Say where the reader ended up, when it is not where they asked to go.
 *
 * Replacing rather than pushing, because this is the same arrival corrected
 * and not a second one: a Back that returned them to the address that could
 * not be honored would send them straight here again, which is a loop instead
 * of a way out. Silent when the address is already right, so a route that did
 * what it said costs nothing.
 *
 * `router` is declared below and read only when this runs, which is after the
 * module has finished loading. */
function replaceWith(path: string): void {
	const at = router.state.location;
	if (path === `${at.pathname}${at.search}`) return;
	void router.navigate(path, { replace: true });
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
	const session = useRoomsSession();
	const { name = "" } = useParams();
	const routed = useLocation();
	const homeDir = useRoomsState((state) => state.homeDir);
	const dirs = useRoomsState((state) => state.dirs);
	const heldRoomKey = useRoomsState((state) =>
		[...state.convs.values()].find((conv) => conv.type === "room" && conv.held && conv.id === name)?.key
	);
	const policyPending = useRoomsState((state) => store.roomPolicyPending(state, name));
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
			if (heldRoomKey !== undefined) {
				store.showConv(routing().projection, heldRoomKey);
				arrival.mark();
				return;
			}
			if (routing().projection.get().homeDir === null) return; // the effect refires when the directory lands
			if (policyPending) return; // the effect refires when its policy lands
			// The card names no room, so neither does its address; what it keeps
			// is that this was about somewhere on this page's directory, which
			// an empty `dir=` says. `/join` files the act.
			replaceWith(joinAddress({ directory: "" }));
			arrival.mark();
			return;
		}
		if (dirParam !== "") {
			const known = net.directoryId(dirParam);
			if (known !== null && routing().projection.get().dirs.has(known)) {
				if (!net.showRoom(routing(), session, known, name)) {
					replaceWith(joinAddress({ room: name, directory: net.dirAddress(routing(), known) }));
				}
			} else {
				replaceWith(joinAddress({ room: name, locator: dirParam }));
			}
			arrival.mark();
			return;
		}
		const home = routing().projection.get().homeDir;
		if (home === null) return; // the effect refires when the directory lands
		// A room the page's own directory does not hold yet, with no name to status-allow: pending state or quoted runtime label
		// enter it under, is the card asking for one: the room named, the
		// directory implied.
		if (!net.showRoom(routing(), session, home, name)) replaceWith(joinAddress({ room: name, directory: "" }));
		arrival.mark();
		// The address this route names, and the directory state it is waiting on.
		// The session and the parsed location are read as they stand: arriving
		// somewhere is a thing that happens once per address, and re-running it
		// because a session was re-established would navigate a reader who is
		// already where this sent them.
		// eslint-disable-next-line react-hooks/exhaustive-deps -- runs on the address, reads the session as it stands
	}, [arrival, name, dirParam, isPrivate, homeDir, dirs, heldRoomKey, policyPending]);
	return null;
}

function DmRoute() {
	const session = useRoomsSession();
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
		// for a reader arriving cold, but it is the wrong answer for a reader
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
		session.startDm(nick);
		arrival.mark();
		// As the room route above: on the address, reading the session as it
		// stands.
		// eslint-disable-next-line react-hooks/exhaustive-deps -- runs on the address, reads the session as it stands
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
		// `dir=` is the directory the address stands on rather than one the link
		// named: a room route that could not open its room lands here with that
		// much still true. Named outranks implied when an address carries both.
		const directory = search.get("dir");
		// A bare /join is a reader asking for the card and naming nothing, so
		// every field falls through to what this browser last used. Naming a
		// room or a locator is a deep link, and each part it names is named
		// outright: a link that says where is answered there whatever was used
		// last, and one that says only which room leaves the where alone.
		net.reachFor(routing(), {
			source: "link",
			room: room === null ? undefined : named(room),
			locator: locator !== null ? named(locator) : directory !== null ? implied(directory) : undefined,
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
			} else replaceWith(joinAddress({ locator: dirParam }));
			arrival.mark();
			return;
		}
		const home = routing().projection.get().homeDir;
		if (home === null) return;
		net.showDirectory(routing(), home);
		arrival.mark();
		// As the routes above. `routed` is compared against where this already
		// sent the reader, so depending on it would re-enter the check that
		// exists to stop exactly that.
		// eslint-disable-next-line react-hooks/exhaustive-deps -- runs on the address, reads the location as it stands
	}, [arrival, dirParam, homeDir, dirs]);
	return null;
}

/** The front page, which a reader reaches two ways that mean opposite things.
 *
 * Going there closes what was open, and that is the act this clears. Loading
 * there is not an act at all: it is the address every tab starts at before
 * anything has said what is open, and what says so arrives after. A workspace
 * restores the conversation it was left on, and an attached session states the
 * one it is on for every tab sharing it. So clearing on the first arrival
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
		routing().managedSession?.openings.dismiss();
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

/** The one screen, mounted once for every address. The matched child is
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
			<h2>{crashTitle}</h2>
			<Said kind="failure">{message}</Said>
			<p>{crashSessionKept}</p>
			<Button variant="quiet" onClick={() => reloadNow()}>{crashReload}</Button>
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
