// Admission and ownership for calls to one room membership inbox.

import { type Behavior, type Session } from "@glowcap/runtime";
import { attachmentCapabilities, readAttachments } from "../attachment.ts";
import {
	refuseCapabilityArguments,
	releaseUnclaimedCapabilityArguments,
	releaseUnexpectedCapabilityArguments,
} from "../argument_custody.ts";
import { type Message, readLineChange, readLineId, readPresence, readRoomFacts, roomRecordAt } from "./message.ts";
import { MEMBERSHIP_ENDED, NOTIFY, ROOM_AUTHORITY_CHANGED, ROOM_POLICY_CHANGED } from "../protocol.ts";
import { parseRoomPolicy, type RoomPolicy } from "./policy.ts";
import type { RoomAuthorityChange } from "./authority.ts";
import { lineCost, MAX_LINE, MAX_NICK, nickRefusal } from "../limits.ts";

export interface RoomInboxReceiver {
	typing(name: string, on: boolean): void;
	listed(value: boolean): void;
	line(message: Message): void;
	arrived(): void;
	ended(reason: string): void;
	authorityChanged(change: RoomAuthorityChange): void;
	authorityStatus(claimable: boolean): void;
	policyChanged?(policy: RoomPolicy): void;
}

export function roomInboxBehavior(session: Session, receiver: RoomInboxReceiver): Behavior {
	return (verb, args) => {
		if (verb !== NOTIFY) refuseCapabilityArguments(session, args, `inbox has no method ${verb}`);
		if (args[2] === MEMBERSHIP_ENDED) {
			releaseUnclaimedCapabilityArguments(
				session,
				args,
				"a room inbox could not return an unexpected membership-end capability",
			);
			if (
				args.length !== 3 || args[0] !== "room" || typeof args[1] !== "string" || args[1] === ""
			) {
				throw new Error("membership-ended notify takes one reason");
			}
			receiver.ended(args[1]);
			return null;
		}
		if (args[2] === ROOM_AUTHORITY_CHANGED) {
			releaseUnclaimedCapabilityArguments(
				session,
				args,
				"a room inbox could not return an unexpected authority-change capability",
			);
			if (
				args.length !== 6 || args[0] !== "room" || args[1] !== "" ||
				(args[3] !== "manager" && args[3] !== "steward" && args[3] !== "room") ||
				typeof args[4] !== "string" || args[4] === "" || typeof args[5] !== "boolean"
			) throw new Error("room-authority-changed notify takes an authority kind, identity, and claimability");
			receiver.authorityChanged({ kind: args[3], token: args[4], claimable: args[5] });
			return null;
		}
		if (args[2] === ROOM_POLICY_CHANGED) {
			releaseUnclaimedCapabilityArguments(session, args, "room-policy notify takes no capabilities");
			const policy = parseRoomPolicy(args.slice(3));
			if (args.length !== 6 || args[0] !== "room" || args[1] !== "" || policy === null) {
				throw new Error("room-policy notify takes three policy modes");
			}
			receiver.policyChanged?.(policy);
			return null;
		}
		if (args[2] === "typing") {
			releaseUnclaimedCapabilityArguments(
				session,
				args,
				"a room inbox could not return an unexpected typing capability",
			);
			if (
				args.length !== 5 || args[0] !== "room" || args[1] !== "" || typeof args[3] !== "string" ||
				nickRefusal(args[3]) !== null || typeof args[4] !== "boolean"
			) throw new Error("typing notify takes a valid member name and one boolean");
			receiver.typing(args[3], args[4]);
			return null;
		}
		const from = args[0];
		const text = args[1];
		if (
			typeof from !== "string" || (from !== "room" && (from.length > MAX_NICK || nickRefusal(from) !== null)) ||
			typeof text !== "string" || lineCost(text) > MAX_LINE
		) {
			releaseUnclaimedCapabilityArguments(
				session,
				args,
				`a room line needs a valid sender and text of at most ${MAX_LINE} bytes`,
			);
			throw new Error(`a room line needs a valid sender and text of at most ${MAX_LINE} bytes`);
		}
		const facts = readRoomFacts(args);
		const presence = readPresence(args);
		if (facts?.listed != null) receiver.listed(facts.listed);
		if (facts?.listed != null && typeof args[3] === "boolean") receiver.authorityStatus(args[3]);
		if (facts?.listed != null && text === "" && presence == null) {
			releaseUnclaimedCapabilityArguments(
				session,
				args,
				"a room inbox could not return an unexpected occupancy capability",
			);
			receiver.arrived();
			return null;
		}
		const attachments = readAttachments(args, roomRecordAt(args));
		releaseUnexpectedCapabilityArguments(
			session,
			args,
			attachmentCapabilities(attachments),
			"a room inbox could not return an unexpected line capability",
		);
		const lineId = readLineId(args);
		const change = readLineChange(args);
		receiver.line({
			from,
			text,
			system: from === "room",
			...(presence == null ? {} : { presence }),
			attachments,
			...(facts == null ? {} : { facts }),
			...(lineId == null ? {} : { lineId }),
			...(change == null ? {} : { change }),
		});
		if (facts?.listed != null || presence?.kind === "roster") receiver.arrived();
		return null;
	};
}
