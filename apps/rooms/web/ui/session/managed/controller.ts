// Presentation gestures act through one managed viewer and its exact receipts.
import { conversationById } from "./conversation_lookup.ts";
import * as store from "../../store.ts";
import type { RoomsPageContext } from "../../page.ts";
import type { RoomsBrowserController } from "../../controller/browser.ts";
import type { JoinNicknameIntent, JoinOutcome, RoomsSessionController } from "../../controller/session.ts";
import type { ConversationOpening } from "./openings.ts";
import type { ManagedRoomsSession } from "./session.ts";
import type { AttachedSessionFiles } from "../attached_files.ts";
import type { PresentedFile } from "./files.ts";
import { browserDoors, directoryId } from "../../application.ts";
import { dirAddress } from "../../page_bootstrap.ts";
import { type DirId, dirId } from "../../directory.ts";
import { relayAway } from "../../store/projection.ts";
import { planJoinDestination, type RoomDestination, roomLinkDestination, typedRoomLink } from "../../joining.ts";
import {
	directoryUnreachable,
	doorBlocked,
	doorUnreachable,
	type FailureNames,
	type FailureView,
	failureView,
	LocalRefusal,
	namedFailure,
	refusalText,
	relayUnreachable,
	renderFailure,
	transportBreak,
} from "../../../../lib/text/failure.ts";
import { localNetworkBlock } from "../../server_choice.ts";
import { NO_SERVER, ROOM_EXISTS, RoomsError, roomsErrorIn } from "../../../../lib/error_codes.ts";
import { dmAddress, joinAddress, roomAddress } from "../../route_address.ts";
import {
	activeRefusal,
	admissionRefusal,
	clearRefusal,
	joinRefusalKeys,
	remaining,
	rememberJoinRefusal,
} from "../../admission_feedback.ts";
import { managedComposer } from "./composer.ts";
import { managedRoomActions } from "./rooms.ts";
import { managedWorkspaceActions } from "./workspace.ts";
import { managedOperations } from "./operations.ts";
import { managedCommandPowers } from "./commands.ts";
import { coordinate } from "./model.ts";
import type { ManagedHistory } from "./history.ts";
import { managedArchiveReading } from "./archive_shares.ts";
import type { RoomInfo } from "../../../../lib/directory_publications.ts";
import { notRegisteredForDirect } from "../../../../lib/text/commands.ts";
import { directDirectoryUnavailable, directNoRegistration } from "../../../../lib/text/conversation.ts";
import {
	serverAskAfterDirect,
	serverAskAfterDoor,
	serverAskFor,
	serverNeedAddress,
	serverNeedDm,
	serverNeedHome,
} from "../../../../lib/text/session.ts";
import { policyForRoomPreset, type RoomPolicy } from "../../room_policy.ts";

/** Where an act picks up after the reload a newly chosen Rooms server takes:
 * a page address, built only when the act is refused for want of one, or null
 * to reload where the page stands. */
type Resume = (() => string) | null;

/** What a refused reach needed a Rooms server for: a blank address carries
 * the home directory's sentence as its detail, and any other address is one
 * this browser cannot open on its own. */
const serverNeedOf = (view: FailureView): string => view.detail === serverNeedHome ? serverNeedHome : serverNeedAddress;

export function createManagedController(
	page: RoomsPageContext,
	browser: Pick<RoomsBrowserController, "setTheme" | "showRoster" | "aboutConversation">,
	session: ManagedRoomsSession,
	files: AttachedSessionFiles<PresentedFile>,
	history: ManagedHistory,
	selfLocator: () => string | null = () => null,
): RoomsSessionController {
	const projection = page.projection;
	// The Rooms server this page uses is a fact on the page, held with the
	// directory it hosts, so an act reads what the page holds now. Its host is
	// what a person knows it by when it does not answer.
	const served = () => projection.get().server;
	const servedHost = () => {
		const server = served();
		return server == null ? null : new URL(server.base).host;
	};
	// An empty address means the home directory, else the served one, which a
	// page from a static host does not have. The join card's labels read the
	// same rule through `directoryDestinationContext`.
	const homeRow = () => session.current?.intent.directories.find((row) => row.home);
	const destinationOf = (address: string): { id: DirId | null; route: string } => {
		if (address !== "") return { id: directoryId(address), route: address };
		const home = homeRow();
		if (home == null) {
			const route = served()?.directory ?? "";
			return { id: directoryId(route), route };
		}
		// Home is held, so its identity is known even before its view is.
		const id = dirId(home.id);
		return { id, route: projection.get().dirs.get(id)?.address || home.id };
	};
	// A newly held directory becomes home only in a session with none, so neither
	// the served directory nor an offer takes the mark from a chosen one. The
	// served directory is home by default. On a page with no server, the first
	// directory reached is, since a blank address and a route that waits on a
	// directory would otherwise have nowhere to go. Anything else is by request.
	const takesHome = (route: string, requested: boolean): boolean =>
		(requested || route === (served()?.directory ?? route)) &&
		!(session.current?.intent.directories.some((row) => row.home) ?? false);
	// A reach refused for want of a Rooms server is not said at all: the page
	// asks for one, and `resume` names the address the act picks up at after
	// the reload a chosen server takes, read only then. Any other failure Rooms
	// cannot name is said by its likeliest cause: the relay while it is not
	// answering, otherwise whatever the act was reaching for.
	const explainedAs =
		(otherwise: (view: FailureView) => string) => (error: unknown, resume: Resume): string | null => {
			const view = failureView(error);
			if (view.code === NO_SERVER) {
				store.askServer(projection, resume?.() ?? null, serverAskFor(serverNeedOf(view)));
				return null;
			}
			if (view.code !== "unexpected") return renderFailure(view);
			const host = servedHost();
			return relayAway(projection.get().relay) && host != null
				? relayUnreachable(host, view.detail)
				: otherwise(view);
		};
	const explained = explainedAs(renderFailure);
	// A reach for a directory that broke on the way. Through a Rooms server,
	// the server or the directory is the cause. With none, the page dialed the
	// doors the address names, this browser's own first, and the dial reports
	// whichever door failed last, so the doors say what happened: this browser
	// standing between the page and the relay, else the relay not answering.
	// An address with doors only a server reaches asks for one, with the
	// relay's failure as the reason, since a server is the other way in.
	const unreached = async (error: unknown, resume: Resume, address: string): Promise<string | null> => {
		const view = failureView(error);
		const host = servedHost();
		if (host != null) {
			// A route that broke on the way is said with the server it broke at.
			if (view.code !== "unexpected" && transportBreak(error) == null) return renderFailure(view);
			return relayAway(projection.get().relay)
				? relayUnreachable(host, view.detail)
				: directoryUnreachable(host, view.detail);
		}
		const broke = transportBreak(error);
		if (view.code !== NO_SERVER && broke == null) return renderFailure(view);
		// A blank address on a page with no server is refused before any dial
		// and names no door, so a server is the only way.
		const doors = browserDoors(destinationOf(address).route);
		const relay = doors?.relay ?? null;
		const throughServer = doors?.throughServer ?? true;
		const blocked = relay == null ? null : await localNetworkBlock(relay);
		if (blocked === "prompt" || blocked === "denied") return doorBlocked(blocked, view.detail);
		const door = relay == null ? null : doorUnreachable("directory", relay.host, broke ?? "");
		if (throughServer) {
			store.askServer(
				projection,
				resume?.() ?? null,
				door == null ? serverAskFor(serverNeedOf(view)) : serverAskAfterDoor(door),
			);
			return null;
		}
		return door ?? renderFailure(view);
	};
	type Explain = (error: unknown, resume: Resume) => string | null;
	// A direct line reaches for a member.
	const DIRECT: FailureNames = new Map([["peer-unreachable", "member-unreachable"]]);
	// What a direct line that did not open says, whoever asked for it. A name
	// nobody holds is said with the name. An introduction that was redeemed
	// and reached nobody, on a page with no Rooms server, has a route through
	// a server as the other way to that person, so the page asks for one, with
	// the conversation to come back to. With a server the Host already tried
	// every route it was given, so the failure is said as it is.
	const dmExplained = (peer: string): Explain => (error, resume) => {
		const view = failureView(error);
		if (view.code === "peer-offline") return notRegisteredForDirect(peer);
		if (view.code !== "peer-unreachable") return explained(error, resume);
		if (projection.get().server != null) return renderFailure(namedFailure(view, DIRECT));
		store.askServer(projection, resume?.() ?? null, serverAskAfterDirect(peer));
		return null;
	};
	const failure = (error: unknown, resume: Resume) => {
		const said = explained(error, resume);
		if (said != null) store.toast(projection, "failure", said);
	};
	// A verb settles when its work does and never rejects: the toast is where
	// its failure is told, so a control awaiting it only learns it is done.
	const act = (
		work: Promise<unknown>,
		{ resume = null, inlineJoin = false }: { resume?: Resume; inlineJoin?: boolean } = {},
	): Promise<void> =>
		work.then(() => undefined, (error: unknown) => {
			if (error instanceof DOMException && error.name === "AbortError") return;
			if (inlineJoin && admissionRefusal(error) != null) return;
			failure(error, resume);
		});
	// A direct message needs this browser to have an address of its own.
	// Browser to browser, it has one with or without a Rooms server. Through
	// the Rooms server, the server is the address, so a page with none asks
	// for one before anything opens, with the conversation to come back to.
	const reachableForDm = (resume: () => string | null): boolean => {
		if (projection.get().server != null || (selfLocator() ?? "") !== "") return true;
		store.askServer(projection, resume(), serverAskFor(serverNeedDm));
		return false;
	};
	// Opening a direct line by name, for a press and for `/msg` alike. Settles
	// to what a failure says, or "" once the line is open or the page has
	// asked for a Rooms server.
	const openDm = (peer: string): Promise<string> => {
		const resume = () => dmAddress(peer);
		if (!reachableForDm(resume)) return Promise.resolve("");
		return session.openings.run(async (opening) => {
			const id = await session.actions.direct(directory(), peer, false, undefined, opening);
			await opening.select(id);
		}, { kind: "direct", peer }).then(() => "", (error: unknown) => {
			if (error instanceof DOMException && error.name === "AbortError") return "";
			return dmExplained(peer)(error, resume) ?? "";
		});
	};
	const dirAddressOf = (id: DirId) => dirAddress(projection.get().dirs, id);
	const current = () => store.activeConv(projection);
	const run = (name: string, ...args: string[]) => session.actions.run(name, args);
	const directory = () => current()?.dir ?? dirId(homeRow()?.id ?? "");
	const roomActions = managedRoomActions(page, session);
	const powers = managedCommandPowers(
		page,
		browser,
		session,
		roomActions,
		(id, name) => pick(id, name),
		select,
		(peer) => openDm(peer),
	);
	const composer = managedComposer(page, session, powers);
	async function select(id: string): Promise<void> {
		session.openings.dismiss();
		const row = store.convByPersistId(projection, id);
		if (row != null) store.switchTo(projection, row.key);
		if (session.permits("interactWorkspace")) await session.navigation.select(id);
	}
	async function pick(id: DirId, name: string): Promise<void> {
		await session.openings.run((opening) => namedRoom(id, name, policyForRoomPreset("open"), opening), {
			kind: "room",
			directory: id,
			name,
		});
	}
	async function enterNamedRoom(
		id: DirId,
		name: string,
		policy: RoomPolicy,
		opening: ConversationOpening,
	): Promise<void> {
		const signal = opening.signal;
		const selected = (id: string) => opening.select(id);
		// A created or imported entrance already names exact held authority. Open
		// that saved conversation; public discovery cannot replace its entrance
		// or require another admission. Public memberships still match their
		// exact publication below, rather than following a reused display name.
		let saved: string | null = null;
		for (const row of session.current?.intent.conversations ?? []) {
			if (
				row.kind !== "room" || row.directory !== id || row.name !== name ||
				row.publication != null || row.access == null
			) continue;
			if (saved != null) {
				throw new LocalRefusal("several-saved");
			}
			saved = row.id;
		}
		if (saved != null) return await selected(saved);
		// New public selections read through held directory authority. A delayed
		// discovery projection cannot establish absence or select a publication.
		const original = session.current?.intent.directories.find((row) => row.id === id);
		// Naming a room is the first act on a directory this tab holds, so the
		// field is offered while the directory is still connecting or, after a
		// reload, reconnecting. A read through a session that is still opening
		// answers broken, so wait for the registration `reach` waits for.
		if (original != null && original.nick !== "") await session.directoryRegistered(original, signal);
		if (signal.aborted) return;
		const read = async () => {
			const reader = await session.workspace.directoryReader(id);
			let matches: RoomInfo[];
			try {
				if (signal.aborted) return null;
				matches = await reader.namedRooms(name);
			} finally {
				reader.free();
			}
			if (signal.aborted) return null;
			const snapshot = await session.refresh();
			if (signal.aborted) return null;
			const current = snapshot.intent.directories.find((row) => row.id === id);
			if (original == null || current?.access !== original.access || current.source !== original.source) {
				throw new LocalRefusal("directory-changed");
			}
			if (matches.length > 1) throw new LocalRefusal("name-ambiguous");
			return { listed: matches[0], snapshot };
		};
		let found = await read();
		if (found == null) return;
		if (found.listed == null) {
			try {
				return await selected(await session.actions.createRoom(id, name, policy, opening));
			} catch (error) {
				// Another member opened the name between the read and the create.
				// Somebody else's room is one to enter, not an error, as every
				// Rooms client treats this race; the refused create committed nothing.
				if (roomsErrorIn(error)?.code !== ROOM_EXISTS) throw error;
			}
			found = await read();
			if (found == null) return;
			// The room closed again before it could be entered.
			if (found.listed == null) throw new LocalRefusal("room-not-listed");
		}
		const { listed, snapshot } = found;
		const held = snapshot.intent.conversations.find((row) =>
			row.kind === "room" && row.directory === id && row.publication === listed.id
		);
		if (held != null) return await selected(held.id);
		if (listed.offers == null) throw new LocalRefusal("needs-invitation");
		await selected(await session.actions.publicRoom(id, listed.name, listed.id, opening));
	}
	async function namedRoom(id: DirId, name: string, policy: RoomPolicy, opening: ConversationOpening): Promise<void> {
		const keys = joinRefusalKeys(id, name);
		const refusal = activeRefusal(projection.get().actionRefusals, keys);
		if (remaining(refusal) > 0) throw refusal!.failure;
		for (const key of keys) clearRefusal(projection, key);
		try {
			await enterNamedRoom(id, name, policy, opening);
		} catch (error) {
			rememberJoinRefusal(projection, id, name, error);
			throw error;
		}
	}
	async function reach(
		address: string,
		nick: JoinNicknameIntent,
		home: boolean,
		signal?: AbortSignal,
	): Promise<DirId> {
		const { id, route } = destinationOf(address);
		if (id == null) {
			// A blank address means the served directory, which a page with no
			// Rooms server has none of. The refusal carries the catalog's sentence
			// for that as its detail, so the ask it raises leads with it.
			if (address === "" && served() == null) throw new RoomsError(NO_SERVER, serverNeedHome);
			throw new LocalRefusal("not-directory");
		}
		const name = nick.kind === "exact" ? nick.name : nick.base;
		const allocation = nick.kind === "exact" ? "exact" : "automatic";
		const row = session.current?.intent.directories.find((row) => row.id === id);
		if (row == null) await session.actions.directory(id, route, nick, takesHome(route, home), signal);
		else {
			// A typed address re-routes a held directory when it is not the route
			// the directory is held through: the capability is fetched through the
			// typed doors and replaces the held one, which keeps its home mark and
			// takes it under the one rule a new directory does. A blank address,
			// or the held route again, changes the nickname at most.
			const reroute = address !== "" && !(await session.workspace.directoryRouteHeld(id, route));
			if (signal?.aborted) return id;
			if (reroute) await session.actions.directory(id, route, nick, takesHome(route, home), signal);
			else if (row.nick !== name || row.nickAllocation !== allocation) {
				await run("chooseDirectoryNickname", id, name, allocation);
			}
		}
		if (signal?.aborted) return id;
		store.openDir(projection, id, route);
		if (name !== "" && !signal?.aborted) {
			const selected = (await session.refresh()).intent.directories.find((row) => row.id === id);
			if (signal?.aborted) return id;
			if (selected == null) throw new LocalRefusal("directory-gone");
			await session.directoryRegistered(selected, signal);
		}
		return id;
	}
	return {
		...composer,
		...roomActions,
		...managedWorkspaceActions(page, session, () => history.refresh()),
		...managedOperations(page, session),
		...managedArchiveReading(page, session, files),
		directoryReady: Promise.resolve(),
		pickRoom: (id, name, key) => {
			const row = key == null ? null : store.getConv(projection, key);
			return act(row != null && row.type !== "directory" ? select(row.persistId) : pick(id, name), {
				resume: () => roomAddress(name, { directory: dirAddressOf(id) }),
				inlineJoin: row == null,
			});
		},
		openManagedRoom: (id, name, policy) =>
			act(
				session.openings.run(async (opening) => {
					const room = await session.actions.createRoom(id, name, policy, opening);
					await opening.select(room);
				}, { kind: "room", directory: id, name }),
				{
					resume: () =>
						roomAddress(name, { directory: dirAddressOf(id), private: policy.visibility === "secret" }),
				},
			),
		acceptInvite: (id) => act(session.actions.acceptInvitation(id)),
		declineInvite: (id) => act(run("dismissInvitation", id)),
		leaveRoom: (key) => {
			const row = store.getConv(projection, key);
			return row?.type === "room"
				? run("leaveConversation", row.persistId).then(() => undefined)
				: Promise.resolve();
		},
		leaveDirectory: (id) => run("leaveDirectory", id).then(() => undefined),
		openConv: (key) => {
			const row = store.getConv(projection, key);
			if (row?.type === "directory") store.switchTo(projection, key);
			return row != null && row.type !== "directory" ? select(row.persistId) : Promise.resolve();
		},
		closeDm: (row) =>
			run(row.line === "closed" ? "leaveConversation" : "closeDirect", row.persistId).then(() => undefined),
		endConv: () => {
			const row = current();
			if (row?.type === "directory") store.dismissDirectoryView(projection, row.key);
			return row != null && row.type !== "directory"
				? act(run("leaveConversation", row.persistId))
				: Promise.resolve();
		},
		releaseNick: async (id) => {
			try {
				await run("chooseDirectoryNickname", id, "", "exact");
				return "";
			} catch (error) {
				return refusalText(error);
			}
		},
		chooseHomeDirectory: async (id) => {
			try {
				await run("chooseHomeDirectory", id ?? "");
				return "";
			} catch (error) {
				return refusalText(error);
			}
		},
		dirAddress: dirAddressOf,
		directoryId,
		join: (destination: RoomDestination, nick, signal) => {
			// Where the act picks up after a reload, read from what was typed
			// rather than the plan, which refuses a link that is not a room's.
			const linked = typedRoomLink(destination.address, destination.room);
			const resume = () =>
				linked === null
					? joinAddress({ room: destination.room, address: destination.address || undefined })
					: joinAddress({ address: linked.link, room: linked.label || undefined });
			return session.openings.run(
				async (opening): Promise<JoinOutcome> => {
					const signal = opening.signal;
					if (signal?.aborted) return { ok: true };
					const plan = planJoinDestination(destination);
					const id = plan.kind === "room-link"
						? plan.directory
						: await reach(plan.address, nick, false, signal);
					if (!signal?.aborted) {
						if (plan.kind === "room-link") {
							const room = await session.actions.roomLink(id, plan.link, plan.label, {
								route: plan.address,
								nick,
								home: takesHome(plan.address, false),
							}, opening);
							await opening.select(room);
							if (signal.aborted) return { ok: true };
							store.openDir(projection, id, plan.address);
						} else {
							await namedRoom(id, plan.room, plan.policy, opening);
							if (signal?.aborted) return { ok: true };
						}
						if (plan.kind !== "room-link") {
							store.remember(projection, {
								room: plan.room,
								address: plan.address,
								nick: nick.kind === "exact" ? nick.name : nick.base,
							});
						}
					}
					return { ok: true };
				},
				null,
				signal,
			).catch(async (error): Promise<JoinOutcome> => {
				if (signal?.aborted || (error instanceof DOMException && error.name === "AbortError")) {
					return { ok: true };
				}
				const id = linked === null
					? destinationOf(destination.address).id ?? ""
					: roomLinkDestination(linked.link, linked.label)?.directory ?? "";
				// A typed address was dialed on the way to its room, so a break is
				// said by the door it took. A room link names its directory itself.
				const said = linked === null
					? await unreached(error, resume, destination.address)
					: explained(error, resume);
				if (said != null) rememberJoinRefusal(projection, id, destination.room, error);
				return {
					ok: false,
					code: roomsErrorIn(error)?.code ?? null,
					failure: roomsErrorIn(error) ?? undefined,
					text: said ?? "",
				};
			});
		},
		reachDirectory: async (address, nick, { home = false, signal } = {}) => {
			if (signal?.aborted) return "";
			const resume = () => joinAddress({ address: address || undefined });
			try {
				await session.openings.run((opening) => reach(address, nick, home, opening.signal), null, signal);
				return "";
			} catch (error) {
				const said = await unreached(error, resume, address);
				if (said == null) return "";
				rememberJoinRefusal(projection, destinationOf(address).id ?? "", "", error);
				return said;
			}
		},
		startDm: (peer) =>
			openDm(peer).then((said) => {
				if (said !== "") store.toast(projection, "failure", said);
			}),
		recoverDm: (key) => {
			const row = store.getConv(projection, key);
			const resume = row?.type === "dm" ? () => dmAddress(row.id) : null;
			const explain = row?.type === "dm" ? dmExplained(row.id) : explained;
			if (!reachableForDm(() => resume?.() ?? null)) return Promise.resolve("");
			return session.openings.run(async (opening) => {
				try {
					if (row?.type !== "dm" || row.peerRegistrationId === "") {
						return directNoRegistration;
					}
					const { dir, id: peer, peerRegistrationId: registration } = row;
					const directory = session.current?.intent.directories.find((held) => held.id === dir);
					if (directory == null) return directDirectoryUnavailable;
					await session.directoryRegistered(directory, opening.signal);
					opening.signal.throwIfAborted();
					const next = await session.actions.direct(dir, peer, false, registration, opening);
					await opening.select(next);
					return "";
				} catch (error) {
					return explain(error, resume) ?? "";
				}
			}).catch((error) =>
				error instanceof DOMException && error.name === "AbortError" ? "" : explain(error, resume) ?? ""
			);
		},
		openFile: (key, id) => files.open(key, id),
		openViewer: (key, id) => files.openViewer(key, id),
		stepViewer: (direction) => files.stepViewer(direction),
		setTyping: (on) => {
			const row = current();
			if (row == null || row.type === "directory") return;
			const intent = conversationById(session.current, row.persistId);
			const selected = intent?.kind === "room" && intent.seat != null
				? coordinate("roomSeat", intent.seat)
				: intent?.kind === "direct" && intent.access != null
				? coordinate("directAccess", intent.access)
				: null;
			if (selected == null) return;
			void session.typing.set(row.persistId, selected, on).catch((error: unknown) => {
				store.noteTrouble(projection, "typing", refusalText(error));
			});
		},
		setStanding: (value) => run("setStanding", value).then(() => undefined),
		setDirStanding: (id, value) =>
			(value == null ? run("setDirectoryStanding", id) : run("setDirectoryStanding", id, value)).then(() =>
				undefined
			),
		setRoomStanding: (key, value) => {
			const row = store.getConv(projection, key);
			if (row?.type !== "room") return Promise.resolve();
			return (value == null
				? run("setRoomStanding", row.persistId)
				: run("setRoomStanding", row.persistId, value)).then(() => undefined);
		},
	};
}
