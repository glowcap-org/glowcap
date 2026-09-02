// Parse and transfer custody of one durable-session line event.

import { type Argument, type Session } from "@glowcap/runtime";
import { releaseCapabilityArguments } from "../argument_custody.ts";
import { parseLineEvent, type RoomsSessionLineEvent } from "./messages.ts";

function releaseMalformedCapabilities(session: Session, args: readonly Argument[]): void {
	const failure = releaseCapabilityArguments(session, args);
	if (failure != null) throw failure;
}

/** Parse one observer call and transfer every attachment occurrence to its
 * callback. Null declines the event and releases those occurrences here. */
export function deliverRoomsSessionLine(
	session: Session,
	args: Argument[],
	deliver: ((event: RoomsSessionLineEvent) => void) | null,
): void {
	let event: RoomsSessionLineEvent;
	try {
		event = parseLineEvent(args);
	} catch (error) {
		releaseMalformedCapabilities(session, args);
		throw error;
	}
	if (deliver != null) {
		deliver(event);
		return;
	}
	const failure = releaseCapabilityArguments(session, event.attachments.map((attachment) => attachment.blob));
	if (failure != null) throw failure;
}
