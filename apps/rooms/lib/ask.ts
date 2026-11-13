// Ask a capability something and give up if it never answers.
//
// Every request this client makes crosses a session it does not own, so each
// one carries a deadline and a sentence for what did not answer. One helper
// keeps any call site from inventing a different wait or a vaguer reason.

import { type Argument, Ref, type Session } from "@glowcap/runtime";
import { refuseCapabilityArguments, releaseCapabilityArguments } from "./argument_custody.ts";
import { settleCapabilityCleanup } from "./capability_cleanup.ts";
import { answerWithin, claimWithin } from "./deadline.ts";
import { REQUEST_TIMEOUT_MS } from "./limits.ts";

/** One request to a room or directory, with a deadline on the answer.
 *
 * Every Rooms verb goes through this and not through `send` directly. A
 * partner that accepts a request and never answers leaves nothing an ordinary
 * failure path can see: the send is in flight, the session is open, and the
 * promise is pending. So the wait is what has to end. The two verbs that
 * are meant to wait, a blob read and the write behind it, are transfers and
 * carry a longer bound in `attachment.ts`.
 *
 * The message becomes the sentence a member sees when their line, their join,
 * or their edit does not land. */
export function ask(session: Session, target: Ref, verb: string, args: Argument[], what: string): Promise<Argument> {
	return answerWithin(session.send(target, verb, args) as Promise<Argument>, what, REQUEST_TIMEOUT_MS);
}

/** `ask` for a verb that answers with one capability. `what` is the sentence
 * for no answer and `wrong` the sentence for any other answer, which is
 * refused with whatever capabilities it carried released, so a peer's wrong
 * answer is never taken as a reference. An answer that arrives after the
 * deadline is released too, because nobody is left to claim it. */
export async function askRef(
	session: Session,
	target: Ref,
	verb: string,
	args: Argument[],
	what: string,
	wrong: string,
): Promise<Ref> {
	const answer = await claimWithin(
		session.send(target, verb, args) as Promise<Argument>,
		what,
		REQUEST_TIMEOUT_MS,
		(late) =>
			settleCapabilityCleanup(`${what}: late capability release failed`, () => {
				const failure = releaseCapabilityArguments(session, [late]);
				if (failure != null) throw failure;
			}),
	);
	if (answer instanceof Ref) return answer;
	return refuseCapabilityArguments(session, [answer], wrong);
}
