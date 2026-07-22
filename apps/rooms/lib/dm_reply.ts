// A giftable `dm` behavior that records each incoming message into `inbox` and
// replies to the caller over the connection the call arrived on — the ADR-0088
// receiver primitive: `currentSession()` names that connection, so a caller that
// opened no listener (a browser, a NAT'd peer) is answered without a dial back.
// Shared by the receiver-reply demos so they assert against one spine instead of
// four hand-rolled copies. This is not the app's own path: the browser UI's
// receiver (`ui/net.ts` `inboxDm`) captures the reply capability and answers on a
// later user send rather than inline, so this helper models the inline-reply
// demos, not what the app ships.

import { type AppValue, type Behavior, currentSession, Ref } from "@pancake/stack";
import { DM } from "./protocol.ts";

/** Build a `dm` giftable that pushes each received text to `inbox` and answers
 * the caller as `responder` with `replyText(received)`, over the arriving
 * connection. The reply is a fresh eventual-send on a later turn (the host
 * refuses a driving verb inside the callback frame); `currentSession()` is read
 * synchronously because it is null once the turn returns. */
export function recordingReplyDm(
	inbox: string[],
	responder: string,
	replyText: (received: string) => string,
): Behavior {
	return (verb: string, args: AppValue[]): null => {
		if (verb !== DM) throw new Error(`dm has no method ${verb}`);
		const text = String(args[1]);
		inbox.push(text);
		const reply = args[2];
		const session = currentSession();
		if (session !== null && reply instanceof Ref) {
			queueMicrotask(() => {
				session.send(reply, DM, [responder, replyText(text)]).catch(() => {});
			});
		}
		return null;
	};
}
