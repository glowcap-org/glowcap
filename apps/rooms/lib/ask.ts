// Ask a capability something and give up if it never answers.
//
// Every request this client makes crosses a session it does not own, so each
// one carries its own deadline and its own sentence for what did not answer.
// One helper, so no call site invents a different wait or a vaguer reason.

import type { Argument, Ref, Session } from "@glowcap/runtime";
import { answerWithin } from "./deadline.ts";
import { REQUEST_TIMEOUT_MS } from "./limits.ts";

/** One request to a room or directory, with a deadline on the answer.
 *
 * Every verb below goes through this rather than through `send` directly. A
 * partner that accepts a request and never answers it leaves nothing an ordinary
 * failure path can see — the send is in flight, the session is open, the promise
 * is pending — so the wait is what has to end. The two verbs that legitimately
 * wait, a blob read and the write behind it, are transfers and carry their own
 * longer bound in `attachment.ts`.
 *
 * Named for a reader: the message becomes the sentence a member sees when their
 * line, their join, or their edit does not land. */
export function ask(session: Session, target: Ref, verb: string, args: Argument[], what: string): Promise<Argument> {
	return answerWithin(session.send(target, verb, args) as Promise<Argument>, what, REQUEST_TIMEOUT_MS);
}
