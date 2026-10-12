// Presentation gestures act through one managed viewer and its exact receipts.
import * as store from "../../store.ts";
import type { RoomsPageContext } from "../../page.ts";
import type { RoomsBrowserController } from "../../controller/browser.ts";
import type { JoinNicknameIntent, JoinOutcome, RoomsSessionController } from "../../controller/session.ts";
import type { ConversationOpening } from "./openings.ts";
import type { ManagedRoomsSession } from "./session.ts";
import type { AttachedSessionFiles } from "../attached_files.ts";
import type { PresentedFile } from "./files.ts";
import { directoryId } from "../../application.ts";
import { type DirId, dirId, type RoomDestination } from "../../types.ts";
import { refusalText } from "../../../../lib/text/failure.ts";
import { roomsErrorInMessage } from "../../../../lib/error_codes.ts";
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
import { planJoinDestination } from "../../joining.ts";
import { coordinate } from "./model.ts";
import type { ManagedHistory } from "./history.ts";
import { managedArchiveReading } from "./archive_shares.ts";
import type { RoomInfo } from "../../../../lib/directory_publications.ts";
import { directDirectoryUnavailable, directNoRegistration } from "../../../../lib/text/conversation.ts";
import { policyForRoomPreset, type RoomPolicy } from "../../room_policy.ts";

export function createManagedController(
	page: RoomsPageContext,
	browser: Pick<RoomsBrowserController, "setTheme" | "showRoster" | "aboutConversation">,
	session: ManagedRoomsSession,
	files: AttachedSessionFiles<PresentedFile>,
	defaultDirectory: string,
	history: ManagedHistory,
	selfLocator: () => string | null = () => null,
): RoomsSessionController {
	const projection = page.projection;
	const failure = (error: unknown) => store.toast(projection, "failure", refusalText(error));
	// A verb settles when its work does and never rejects: the toast is where
	// its failure is told, so a control awaiting it only learns it is done.
	const act = (work: Promise<unknown>, inlineJoin = false): Promise<void> =>
		work.then(() => undefined, (error: unknown) => {
			if (error instanceof DOMException && error.name === "AbortError") return;
			if (inlineJoin && admissionRefusal(error) != null) return;
			failure(error);
		});
	const current = () => store.activeConv(projection);
	const run = (name: string, ...args: string[]) => session.actions.run(name, args);
	const directory = () =>
		current()?.dir ?? dirId(session.current?.intent.directories.find((row) => row.home)?.id ?? "");
	const roomActions = managedRoomActions(page, session);
	const powers = managedCommandPowers(page, browser, session, roomActions, (id, name) => pick(id, name), select);
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
				throw new Error("This name matches several saved rooms. Select the conversation from the sidebar.");
			}
			saved = row.id;
		}
		if (saved != null) return await selected(saved);
		// New public selections read through held directory authority. A delayed
		// discovery projection cannot establish absence or select a publication.
		const original = session.current?.intent.directories.find((row) => row.id === id);
		const reader = await session.workspace.directoryReader(id);
		let matches: RoomInfo[];
		try {
			if (signal.aborted) return;
			matches = await reader.namedRooms(name);
		} finally {
			reader.free();
		}
		if (signal.aborted) return;
		const snapshot = await session.refresh();
		if (signal.aborted) return;
		const current = snapshot.intent.directories.find((row) => row.id === id);
		if (original == null || current?.access !== original.access || current.source !== original.source) {
			throw new Error("The selected directory authority changed. Review it before joining.");
		}
		if (matches.length > 1) throw new Error("This room name is ambiguous. Select an exact publication.");
		const listed = matches[0];
		if (listed == null) await selected(await session.actions.createRoom(id, name, policy, opening));
		else {
			const held = snapshot.intent.conversations.find((row) =>
				row.kind === "room" && row.directory === id && row.publication === listed.id
			);
			if (held != null) return await selected(held.id);
			if (listed.offers == null) throw new Error("This room needs an invitation.");
			await selected(await session.actions.publicRoom(id, listed.name, listed.id, opening));
		}
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
	async function reach(locator: string, nick: JoinNicknameIntent, signal?: AbortSignal): Promise<DirId> {
		const route = locator || defaultDirectory;
		const id = directoryId(route);
		if (id == null) throw new Error("This address does not name a directory");
		const name = nick.kind === "exact" ? nick.name : nick.base;
		const allocation = nick.kind === "exact" ? "exact" : "automatic";
		const row = session.current?.intent.directories.find((row) => row.id === id);
		if (row == null) await session.actions.directory(id, route, nick, route === defaultDirectory, signal);
		else if (row.nick !== name || row.nickAllocation !== allocation) {
			await run("chooseDirectoryNickname", id, name, allocation);
		}
		if (signal?.aborted) return id;
		store.openDir(projection, id, route);
		if (name !== "" && !signal?.aborted) {
			const selected = (await session.refresh()).intent.directories.find((row) => row.id === id);
			if (signal?.aborted) return id;
			if (selected == null) throw new Error("The original directory was removed");
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
			return act(row != null && row.type !== "directory" ? select(row.persistId) : pick(id, name), row == null);
		},
		openManagedRoom: (id, name, policy) =>
			act(session.openings.run(async (opening) => {
				const room = await session.actions.createRoom(id, name, policy, opening);
				await opening.select(room);
			}, { kind: "room", directory: id, name })),
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
		selfLocator,
		directoryLocator: () => defaultDirectory,
		dirAddress: (id) => projection.get().dirs.get(id)?.locator || id,
		directoryId,
		join: (destination: RoomDestination, nick, signal) =>
			session.openings.run(
				async (opening): Promise<JoinOutcome> => {
					const signal = opening.signal;
					if (signal?.aborted) return { ok: true };
					const plan = planJoinDestination(destination);
					const id = plan.kind === "room-link" ? plan.directory : await reach(plan.locator, nick, signal);
					if (!signal?.aborted) {
						if (plan.kind === "room-link") {
							const room = await session.actions.roomLink(id, plan.link, plan.label, {
								route: plan.address,
								nick,
								home: plan.address === defaultDirectory,
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
								locator: plan.locator,
								nick: nick.kind === "exact" ? nick.name : nick.base,
							});
						}
					}
					return { ok: true };
				},
				null,
				signal,
			).catch((error): JoinOutcome => {
				if (signal?.aborted || (error instanceof DOMException && error.name === "AbortError")) {
					return { ok: true };
				}
				const plan = planJoinDestination(destination);
				const id = plan.kind === "room-link"
					? plan.directory
					: directoryId(plan.locator || defaultDirectory) ?? "";
				rememberJoinRefusal(projection, id, destination.room, error);
				return {
					ok: false,
					code: roomsErrorInMessage(error)?.code ?? null,
					failure: roomsErrorInMessage(error) ?? undefined,
					text: refusalText(error),
				};
			}),
		reachDirectory: async (locator, nick, signal) => {
			if (signal?.aborted) return "";
			try {
				await session.openings.run((opening) => reach(locator, nick, opening.signal), null, signal);
				return "";
			} catch (error) {
				rememberJoinRefusal(projection, directoryId(locator || defaultDirectory) ?? "", "", error);
				return refusalText(error);
			}
		},
		startDm: (peer) =>
			act(session.openings.run(async (opening) => {
				const id = await session.actions.direct(directory(), peer, false, undefined, opening);
				await opening.select(id);
			}, { kind: "direct", peer })),
		recoverDm: (key) =>
			session.openings.run(async (opening) => {
				try {
					const row = store.getConv(projection, key);
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
					return refusalText(error);
				}
			}).catch((error) => error instanceof DOMException && error.name === "AbortError" ? "" : refusalText(error)),
		openFile: (key, id) => files.open(key, id),
		openViewer: (key, id) => files.openViewer(key, id),
		stepViewer: (direction) => files.stepViewer(direction),
		setTyping: (on) => {
			const row = current();
			if (row == null || row.type === "directory") return;
			const intent = session.current?.intent.conversations.find((entry) => entry.id === row.persistId);
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
