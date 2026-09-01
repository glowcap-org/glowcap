// Operations on one live room seat. The capability identifies the membership;
// no nickname, account, or calling-session lookup authorizes an act.

import { type Argument, type Behavior, currentSession, type Session } from "@pancake/runtime";
import { attachmentRefusal } from "../lib/attachment.ts";
import {
	ATTACH,
	AWAY,
	HISTORY,
	LEAVE,
	LINE,
	MEMBERSHIP_KIND,
	MINT_INVITATION,
	POST,
	POST_FILES,
	TYPING,
} from "../lib/protocol.ts";
import {
	ATTACHMENT_REFUSED,
	BAD_ATTACHMENT,
	NOT_ROOM_MEMBER,
	READ_ONLY_MEMBERSHIP,
	RoomError,
	UPLOAD_INCOMPLETE,
} from "../lib/errors.ts";
import { lineCost, MAX_AWAY, MAX_IMAGE_DIM, MAX_LINE, MAX_MESSAGE_FILES } from "../lib/limits.ts";
import { hasCapabilityArguments, throwAfterReleasingCapabilities } from "../lib/argument_custody.ts";
import {
	HELD_LINE_REFS,
	type Member,
	type PendingUpload,
	type PostedFile,
	roomDurableIdentity,
	type RoomState,
} from "./registry.ts";
import { lineBehavior } from "./lines.ts";
import { liveKeptLine, type RoomHistory } from "./history.ts";
import type { RoomServerContext } from "./context.ts";
import { broadcast, broadcastTyping, leaveMember } from "./presence.ts";
import { isRoomMembershipKind } from "../lib/room/membership.ts";
import type { RoomInvitationIssuer } from "./invitation.ts";

function callerFor(state: RoomState, member: Member, verb: string, args: Argument[]): Session {
	const session = currentSession();
	if (session === null) throw new Error("a room membership is reachable only over a session");
	if (hasCapabilityArguments(args)) {
		throwAfterReleasingCapabilities(
			session,
			args,
			new Error(`room membership ${verb} does not take capability arguments`),
		);
	}
	if (!state.members.includes(member)) {
		throw new RoomError(NOT_ROOM_MEMBER, "this room membership has ended");
	}
	return session;
}

function requireParticipant(member: Member): void {
	if (member.kind !== "participant") {
		throw new RoomError(READ_ONLY_MEMBERSHIP, "this observer membership cannot speak in the room");
	}
}

function retainLine(
	ctx: RoomServerContext,
	member: Member,
	session: Session,
	ref: import("@pancake/runtime").Ref,
): void {
	member.lines.push({ session, ref });
	ctx.operator.noteChange();
	while (member.lines.length > HELD_LINE_REFS) {
		const retired = member.lines.shift()!;
		retired.session.release(retired.ref);
	}
}

/** One observer or participant facet for one exact membership. */
export function membershipBehavior(
	ctx: RoomServerContext,
	state: RoomState,
	member: Member,
	options: {
		readonly history: RoomHistory;
		readonly invitations: RoomInvitationIssuer;
	},
): Behavior {
	const { history, invitations } = options;
	return (verb, args) => {
		const session = callerFor(state, member, verb, args);
		if (verb === MEMBERSHIP_KIND) {
			if (args.length !== 0) throw new Error("membershipKind takes no arguments");
			return member.kind;
		}
		if (verb === MINT_INVITATION) {
			requireParticipant(member);
			if (args.length !== 1 || !isRoomMembershipKind(args[0])) {
				throw new Error("mintInvitation takes one observer or participant membership kind");
			}
			return invitations.mint(session, args[0]);
		}
		if (verb === POST) {
			requireParticipant(member);
			if (args.length > 1) {
				throw new RoomError(BAD_ATTACHMENT, "post carries trailing args; attach a file with attach()");
			}
			if (args.length !== 1 || typeof args[0] !== "string") {
				throw new Error("post needs exactly one text line");
			}
			const said = args[0];
			if (lineCost(said) > MAX_LINE) throw new Error(`a line may be at most ${MAX_LINE} bytes`);
			const id = state.nextLine++;
			const kept = history.enabled ? liveKeptLine(member.nick, said, Date.now()) : null;
			const line = session.spawn(lineBehavior(ctx, state, history, member.nick, id, [], kept));
			broadcast(ctx, state, member.nick, said, LINE, BigInt(id));
			if (kept !== null) history.record(roomDurableIdentity(state), kept);
			retainLine(ctx, member, session, line);
			return line;
		}
		if (verb === POST_FILES) {
			requireParticipant(member);
			if (args.length !== 1 || typeof args[0] !== "string") {
				throw new RoomError(BAD_ATTACHMENT, "postFiles needs one caption");
			}
			const staged = [...state.uploads.get(member) ?? []].find((upload) => !upload.posted);
			if (staged === undefined) throw new RoomError(UPLOAD_INCOMPLETE, "no files are staged");
			const files: PostedFile[] = [];
			const id = state.nextLine++;
			const caption = args[0] !== "" ? args[0] : staged.file.name;
			const kept = history.enabled ? liveKeptLine(member.nick, caption, Date.now()) : null;
			const line = session.spawn(lineBehavior(ctx, state, history, member.nick, id, files, kept));
			ctx.files.postStaged(state, member, files);
			ctx.files.broadcastFiles(state, member.nick, caption, files, LINE, id);
			if (kept !== null) history.record(roomDurableIdentity(state), kept);
			retainLine(ctx, member, session, line);
			return line;
		}
		if (verb === ATTACH) {
			requireParticipant(member);
			if (
				(args.length !== 3 && args.length !== 5) || typeof args[0] !== "string" ||
				typeof args[1] !== "string" || typeof args[2] !== "bigint" ||
				(args.length === 5 && (typeof args[3] !== "bigint" || typeof args[4] !== "bigint"))
			) throw new Error("attach needs a name, mime type, size, and optional image dimensions");
			const name = args[0];
			const mime = args[1];
			const size = Number(args[2]);
			const pixelCount = (value: Argument | undefined): number =>
				typeof value === "bigint" && value > 0n && value <= BigInt(MAX_IMAGE_DIM) ? Number(value) : 0;
			const width = pixelCount(args[3]);
			const height = pixelCount(args[4]);
			const refused = attachmentRefusal(name, mime, size);
			if (refused !== null) throw new RoomError(ATTACHMENT_REFUSED, refused);
			let pending = state.uploads.get(member);
			if (pending === undefined) {
				pending = new Set();
				state.uploads.set(member, pending);
			}
			if (
				[...pending].filter((upload) => !upload.posted && upload.member === member).length >= MAX_MESSAGE_FILES
			) {
				throw new RoomError(
					ATTACHMENT_REFUSED,
					`post or abandon an upload first; ${MAX_MESSAGE_FILES} are already open`,
				);
			}
			const bytes = ctx.files.allocateUpload(size);
			if (bytes === null) {
				throw new RoomError(
					ATTACHMENT_REFUSED,
					"the server is holding all the uploads it can; try again shortly",
				);
			}
			const file: PostedFile = {
				room: state,
				name,
				mime,
				size,
				width,
				height,
				bytes,
				written: 0,
				failure: null,
				waiters: new Set(),
			};
			const upload: PendingUpload = {
				size,
				file,
				posted: false,
				spent: false,
				ref: null,
				member,
				session,
				expires: null,
			};
			pending.add(upload);
			ctx.files.armUploadTimer(state, upload);
			try {
				upload.ref = session.spawn(ctx.files.uploadBehavior(state, upload));
			} catch (error) {
				ctx.files.dropUpload(state, upload);
				throw error;
			}
			return upload.ref;
		}
		if (verb === TYPING) {
			requireParticipant(member);
			if (args.length !== 1 || typeof args[0] !== "boolean") throw new Error("typing needs one boolean");
			broadcastTyping(ctx, state, member.nick, args[0], member.session);
			return null;
		}
		if (verb === HISTORY) {
			if (args.length !== 0) throw new Error("history takes no arguments");
			if (!history.enabled) throw new Error("room membership has no method history");
			return history.read(roomDurableIdentity(state), 100).then((lines) =>
				lines.map((line) => [line.from, line.text, line.at] as Argument)
			) as ReturnType<Behavior>;
		}
		if (verb === AWAY) {
			if (args.length !== 1 || typeof args[0] !== "string") throw new Error("away needs one reason");
			const why = args[0];
			if (why.length > MAX_AWAY) throw new Error(`an away reason may be at most ${MAX_AWAY} characters`);
			if (why === member.away) return null;
			member.away = why;
			ctx.operator.noteChange();
			broadcast(
				ctx,
				state,
				"room",
				why === "" ? `${member.nick} is back` : `${member.nick} is away: ${why}`,
				AWAY,
				member.nick,
				why,
			);
			return null;
		}
		if (verb === LEAVE) {
			if (args.length !== 0) throw new Error("leave takes no arguments");
			leaveMember(ctx, state, member);
			return null;
		}
		throw new Error(`room membership has no method ${verb}`);
	};
}
