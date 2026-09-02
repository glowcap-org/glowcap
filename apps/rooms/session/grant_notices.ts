// Telling the views attached under one grant that what it carries has changed,
// or has gone.
//
// Both are the same act with different endings. A change re-projects: the view
// stays attached, because a narrowed or paused link is still a link, and a
// suspended view has to stay to be told why. A revocation drops: there is
// nothing left to be attached to.
//
// This lives apart from the behavior because it is about the views rather than
// about the verbs, and because a facet that answers the ledger on every verb is
// only half the promise. The other half is that a change reaches whoever is
// already holding the link, which is the person it was about.

import type { Argument, Ref, Session } from "@glowcap/runtime";
import { accessOf, narrows, ROOMS_SESSION_CHANGED, type RoomsSessionAccess } from "../lib/session/client.ts";
import { cleanupSettledBySessionClose } from "../lib/capability_cleanup.ts";
import type { RoomsSessionGrantAuthority } from "./grants.ts";
import type { AttachedViewDelivery } from "./attached_view_delivery.ts";

/** One attached view, as these two need to see it. */
export interface NoticedObserver {
	observer: Ref;
	grant: symbol;
	rights: RoomsSessionAccess;
	history: boolean;
	note: string;
	delivery: AttachedViewDelivery;
}

/** What telling a view needs from the session it is attached to. */
export interface GrantNoticeOwner {
	readonly observers: Map<Session, NoticedObserver>;
	readonly tokens: Map<string, symbol>;
	readonly grants: RoomsSessionGrantAuthority;
	snapshotFor(
		rights: RoomsSessionAccess,
		session: Session,
		issues: readonly { subject: string; reason: string }[],
		note: string,
	): Argument[];
	drop(session: Session): unknown | null;
}

/** Tell whoever is attached under one grant that what it carries has changed.
 *
 * Without this a narrowing reaches nobody who is using the link, which is
 * precisely who it was meant for: an attached view captured its access when
 * it attached, so it would go on administering until it happened to
 * reconnect. They are re-projected rather than dropped, because a change of
 * access is not the link going away — a suspended view stays attached to be
 * told why. */
export function reprojectGrantViews(id: string, owner: GrantNoticeOwner): void {
	const token = owner.tokens.get(id);
	if (token == null) return;
	const policy = owner.grants.policy(id);
	if (policy == null) return;
	const access = accessOf(policy);
	for (const [session, held] of owner.observers) {
		if (held.grant !== token) continue;
		// Read before it is overwritten: whether this view just lost something
		// is the difference between telling it and interrupting it.
		const lost = policy.suspended || narrows(held.rights, access);
		held.rights = access;
		held.history = policy.history;
		held.note = policy.note;
		// The delivery decides for itself whether a line it hands over may be
		// changed, so it has to hear this too.
		held.delivery.retier(access);
		session.tell(
			held.observer,
			ROOMS_SESSION_CHANGED,
			// An issue only where something was taken away. A view that just
			// gained authority needs the snapshot, not an interruption saying
			// something went wrong.
			owner.snapshotFor(
				access,
				session,
				lost
					? [{
						subject: "session-access",
						reason: policy.suspended
							? policy.note === ""
								? "Your access to this shared session is paused."
								: `Your access to this shared session is paused: ${policy.note}`
							: "Your access to this shared session was narrowed.",
					}]
					: [],
				policy.note,
			),
		).catch((error) => {
			if (!cleanupSettledBySessionClose(error)) {
				console.error(
					`rooms session: attached-view access notice failed: ${
						error instanceof Error ? error.message : error
					}`,
				);
			}
		});
	}
}

export async function revokeGrantViews(id: string, owner: GrantNoticeOwner): Promise<void> {
	const token = owner.tokens.get(id);
	if (token == null) return;
	const deliveries: Promise<void>[] = [];
	for (const [session, held] of owner.observers) {
		if (held.grant !== token) continue;
		deliveries.push(
			session.tell(
				held.observer,
				ROOMS_SESSION_CHANGED,
				owner.snapshotFor(held.rights, session, [{
					subject: "session-access",
					reason: "This session capability was revoked. Detach it or attach with another capability.",
				}], ""),
			).catch((error) => {
				if (!cleanupSettledBySessionClose(error)) {
					console.error(
						`rooms session: attached-view revocation notice failed: ${
							error instanceof Error ? error.message : error
						}`,
					);
				}
			}).finally(() => {
				owner.drop(session);
			}),
		);
	}
	await Promise.all(deliveries);
	owner.tokens.delete(id);
}
