// A giftable `dm` behavior that records each incoming message into `inbox` and
// replies to the caller over the connection the call arrived on — the ADR-0088
// receiver primitive: `currentSession()` names that connection, so a caller that
// opened no listener (a browser, a NAT'd peer) is answered without a dial back.
// Shared by the receiver-reply demos so they assert against one spine instead of
// four hand-rolled copies. This is not the app's own path: the browser UI's
// Rust receiver captures the reply capability and answers on a
// later user send rather than inline, so this helper models the inline-reply
// demos, not what the app ships.

import { type Behavior } from "@glowcap/runtime";
import { settleCapabilityCleanup } from "./capability_cleanup.ts";
import { directMessageReceiverBehavior } from "./direct_message.ts";
import { DM } from "./protocol.ts";

/** Build a `dm` giftable that pushes each received text to `inbox` and answers
 * the caller with `replyText(received)`, over the arriving connection. The reply
 * is a fresh eventual-send on a later turn (the host refuses a driving verb
 * inside the callback frame); `currentSession()` is read synchronously because it
 * is null once the turn returns. */
export function recordingReplyDm(
	inbox: string[],
	replyText: (received: string) => string,
): Behavior {
	return directMessageReceiverBehavior({
		message: (text, attachments, session, reply) => {
			inbox.push(text);
			for (const attachment of attachments) {
				settleCapabilityCleanup("inline DM attachment release failed", () => session.release(attachment.blob));
			}
			if (reply == null) return null;
			queueMicrotask(() => {
				void session.send(reply, DM, [replyText(text)]).catch((error) => {
					console.error(`rooms inline DM reply failed: ${error instanceof Error ? error.message : error}`);
				}).finally(() =>
					settleCapabilityCleanup("inline DM reply route release failed", () => session.release(reply))
				);
			});
			return null;
		},
	});
}
