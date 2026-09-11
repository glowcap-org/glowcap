// Display affordances for an admitted session access projection.
// The Rust session independently authorizes every command and observation.
import type { RoomsSessionAccess } from "./grants.ts";

/** Whether this access may act at all: post, change a line, set a topic.
 *
 * Asked positively, and never as "is it observing?". A tier ladder read by
 * comparing against its second rung says that anything which is not that rung is
 * above it, so the moment a rung was added below — a suspended link, carrying
 * nothing — three separate places quietly decided it could do more than an
 * observer. Name the authority and adding a rung cannot rewrite what the
 * existing ones mean. */
export function mayInteract(access: RoomsSessionAccess): boolean {
	return access === "interact" || access === "admin";
}

/** Whether an access is entitled to be told what the session is doing.
 *
 * Named the same way and for the same reason, and it matters more here. Every
 * fan-out the session has is gated on this one answer, so the question has to
 * be which accesses hear rather than which access does not: an exclusion list
 * answers yes for every rung nobody has considered yet, and answering yes here
 * is a reader who was never given the room receiving all of it. Written
 * positively, a rung added to the ladder hears nothing until somebody says it
 * should. */
export function mayObserve(access: RoomsSessionAccess): boolean {
	return access === "observe" || access === "interact" || access === "admin";
}
