// A Host publication `dm` behavior that records each incoming message into `inbox` and
// replies to the caller over the connection the call arrived on. This is the
// ADR-0088 receiver primitive: `currentSession()` names that connection, so a
// caller that opened no listener (a browser, a NAT'd peer) is answered without
// a dial back. Shared by the receiver-reply demos so they assert against one
// helper instead of hand-rolled copies. This is not the app's own path. The
// browser UI's Rust receiver captures the reply capability and answers on a
// later user send instead of inline, so this helper models the inline-reply
// demos, not what the app ships.

import { type Behavior, type Ref, type Session } from "@glowcap/runtime";
import { settleCapabilityCleanup } from "./capability_cleanup.ts";
import { directMessageReceiverBehavior } from "./direct_message.ts";
import { DM } from "./protocol.ts";

/** Build a `dm` Host publication that pushes each received text to `inbox` and answers
 * the caller with `replyText(received)`, over the arriving connection. The reply
 * is a fresh eventual-send on a later turn (the host refuses a driving verb
 * inside the callback frame). `currentSession()` is read synchronously because it
 * is null once the turn returns. */
export function recordingReplyDm(
	inbox: string[],
	replyText: (received: string) => string,
): Behavior {
	let route: { session: Session; reply: Ref; stop: () => void } | null = null;
	const retire = () => {
		const held = route;
		route = null;
		if (held == null) return;
		held.stop();
		settleCapabilityCleanup("inline DM readiness route release failed", () => held.session.release(held.reply));
	};
	return directMessageReceiverBehavior({
		// Managed senders deliver the route once at readiness. Each per-peer
		// receiver retains one occurrence until replacement or transport end.
		ready: (session, reply) => {
			retire();
			const next = { session, reply, stop: () => {} };
			route = next;
			next.stop = session.onClose(() => {
				if (route === next) retire();
			});
		},
		message: (text, attachments, session, reply) => {
			inbox.push(text);
			for (const attachment of attachments) {
				settleCapabilityCleanup("inline DM attachment release failed", () => session.release(attachment.blob));
			}
			const target = reply ?? route?.reply;
			const sending = reply == null ? route?.session : session;
			if (target == null || sending == null) return null;
			queueMicrotask(() => {
				void sending.send(target, DM, [replyText(text)]).catch((error) => {
					console.error(`rooms inline DM reply failed: ${error instanceof Error ? error.message : error}`);
				}).finally(() => {
					if (reply != null) {
						settleCapabilityCleanup("inline DM reply route release failed", () => session.release(reply));
					}
				});
			});
			return null;
		},
	});
}
