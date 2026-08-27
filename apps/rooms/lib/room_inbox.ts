// Admission and custody for calls to one room membership inbox.

import { type Behavior, type Session } from "@pancake/runtime";
import { attachmentCapabilities, readAttachments } from "./attachment.ts";
import {
	refuseCapabilityArguments,
	releaseUnclaimedCapabilityArguments,
	releaseUnexpectedCapabilityArguments,
} from "./argument_custody.ts";
import { type Message, readLineChange, readLineId, readPresence, readRoomFacts, roomRecordAt } from "./room_message.ts";
import { NOTIFY } from "./protocol.ts";

export interface RoomInboxReceiver {
	typing(name: string, on: boolean): void;
	listed(value: boolean): void;
	line(message: Message): void;
	arrived(): void;
}

export function roomInboxBehavior(session: Session, receiver: RoomInboxReceiver): Behavior {
	return (verb, args) => {
		if (verb !== NOTIFY) refuseCapabilityArguments(session, args, `inbox has no method ${verb}`);
		if (args[2] === "typing" && typeof args[3] === "string") {
			releaseUnclaimedCapabilityArguments(
				session,
				args,
				"a room inbox could not return an unexpected typing capability",
			);
			receiver.typing(args[3], args[4] === true);
			return null;
		}
		const from = typeof args[0] === "string" ? args[0] : "?";
		const text = typeof args[1] === "string" ? args[1] : "";
		const facts = readRoomFacts(args);
		const presence = readPresence(args);
		if (facts?.listed != null) receiver.listed(facts.listed);
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
