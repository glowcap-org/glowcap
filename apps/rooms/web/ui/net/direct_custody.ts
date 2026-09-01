// Cleanup for capabilities received on a direct connection.

import { type Argument, Ref, type Session } from "@pancake/runtime";
import type { Attachment } from "../../../lib/attachment.ts";
import { trouble } from "./common.ts";
import { releaseCapabilityArguments } from "../../../lib/argument_custody.ts";
import type { PageProjection } from "../store/core.ts";

/** Return one unadopted occurrence through the session that projected it. */
export function releaseIncomingRef(
	projection: PageProjection,
	session: Session,
	ref: Ref,
	what: string,
): void {
	try {
		session.release(ref);
	} catch (error) {
		trouble(projection, `${what} could not release its capability`, error);
	}
}

export function releaseIncomingAttachments(
	projection: PageProjection,
	session: Session,
	attachments: readonly Attachment[],
	what: string,
): void {
	for (const attachment of attachments) {
		releaseIncomingRef(projection, session, attachment.blob, what);
	}
}

export function releaseIncomingArguments(
	projection: PageProjection,
	session: Session,
	args: readonly Argument[],
	what: string,
): void {
	const failure = releaseCapabilityArguments(session, args);
	if (failure != null) trouble(projection, `${what} could not release its capabilities`, failure);
}
