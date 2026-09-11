// Client protocol for live and durable Rooms session grants.

import type { Ref, Session } from "@glowcap/runtime";
import * as z from "zod/mini";
import { ask } from "../ask.ts";
import { MAX_SESSION_GRANT_LABEL, MAX_SESSION_GRANT_NOTE } from "../limits.ts";
import { boundedText } from "../schema.ts";

export const ROOMS_SESSION_ISSUE_GRANT = "issueGrant";
export const ROOMS_SESSION_REVOKE_GRANT = "revokeGrant";
export const ROOMS_SESSION_SET_GRANT_POLICY = "setGrantPolicy";

export const RoomsSessionGrantIdSchema = z.string().check(
	z.regex(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/),
);
export const RoomsSessionFacetSchema = z.enum(["observe", "interact", "admin"]);
export const RoomsSessionGrantLabelSchema = boundedText(MAX_SESSION_GRANT_LABEL).check(
	z.refine((label) => label.trim() !== ""),
);
export const RoomsSessionGrantSturdyrefSchema = boundedText(16 * 1024).check(
	z.startsWith("ocapn://"),
	z.includes("/s/"),
);

export type RoomsSessionFacet = z.infer<typeof RoomsSessionFacetSchema>;

/** What a holder may actually do right now: the grant's intended facet, or
 * nothing at all while it is suspended. A suspension is not a revocation — the
 * link stays live so it can say why, and the facet behind it is remembered. */
export const RoomsSessionAccessSchema = z.enum(["none", "observe", "interact", "admin"]);
export type RoomsSessionAccess = z.infer<typeof RoomsSessionAccessSchema>;

export const RoomsSessionGrantNoteSchema = boundedText(MAX_SESSION_GRANT_NOTE);

export const RoomsSessionGrantViewSchema = z.strictObject({
	id: RoomsSessionGrantIdSchema,
	label: RoomsSessionGrantLabelSchema,
	rights: RoomsSessionFacetSchema,
	/** Whether this grant may read what was recorded before it arrived. Its own
	 * answer rather than a rung on the facet ladder, because reading the past and
	 * administering the session are different authorities that happened to be
	 * spelled the same way. */
	history: z.boolean(),
	suspended: z.boolean(),
	/** Said to whoever holds a suspended grant, so a link that has gone quiet
	 * can account for itself. */
	note: RoomsSessionGrantNoteSchema,
	sturdyref: RoomsSessionGrantSturdyrefSchema,
});

export { mayInteract, mayObserve } from "./access_view.ts";

/** The accesses in order, least first. Used only to tell a narrowing from a
 * widening, so a view losing authority is told and a view gaining it is not
 * handed a failure. */
const ACCESS_ORDER: readonly RoomsSessionAccess[] = ["none", "observe", "interact", "admin"];

/** Whether `next` carries less than `prior` did. */
export function narrows(prior: RoomsSessionAccess, next: RoomsSessionAccess): boolean {
	return ACCESS_ORDER.indexOf(next) < ACCESS_ORDER.indexOf(prior);
}

/** What a grant carries now, once a suspension is taken into account. */
export function accessOf(grant: { rights: RoomsSessionFacet; suspended: boolean }): RoomsSessionAccess {
	return grant.suspended ? "none" : grant.rights;
}

export type RoomsSessionGrantView = z.infer<typeof RoomsSessionGrantViewSchema>;

export async function issueRoomsSessionGrant(
	session: Session,
	capability: Ref,
	id: string,
	rights: RoomsSessionFacet,
	label: string,
	history: boolean,
): Promise<RoomsSessionGrantView> {
	return readGrantView(
		await ask(
			session,
			capability,
			ROOMS_SESSION_ISSUE_GRANT,
			[id, rights, label, history],
			"the Rooms session did not issue the durable grant",
		),
	);
}

/** Change what a live grant carries. A null leaves that answer alone; the link
 * is a function of the grant's id, so none of this moves it. */
export async function setRoomsSessionGrantPolicy(
	session: Session,
	capability: Ref,
	id: string,
	patch: {
		rights?: RoomsSessionFacet | null;
		history?: boolean | null;
		suspended?: boolean | null;
		note?: string | null;
	},
): Promise<RoomsSessionGrantView> {
	return readGrantView(
		await ask(
			session,
			capability,
			ROOMS_SESSION_SET_GRANT_POLICY,
			[id, patch.rights ?? null, patch.history ?? null, patch.suspended ?? null, patch.note ?? null],
			"the Rooms session did not change the durable grant",
		),
	);
}

/** The grant as the session answered it. Read rather than reconstructed from
 * what was asked for: a caller that rebuilt it would be describing its own
 * request, and would miss everything the session decided. */
function readGrantView(answer: unknown): RoomsSessionGrantView {
	if (typeof answer !== "string") throw new Error("the Rooms session answered an invalid durable grant");
	let decoded: unknown;
	try {
		decoded = JSON.parse(answer);
	} catch {
		throw new Error("the Rooms session answered an unreadable durable grant");
	}
	const parsed = z.safeParse(RoomsSessionGrantViewSchema, decoded);
	if (!parsed.success) throw new Error("the Rooms session answered an invalid durable grant");
	return parsed.data;
}

export function revokeRoomsSessionGrant(session: Session, capability: Ref, id: string): Promise<void> {
	return ask(
		session,
		capability,
		ROOMS_SESSION_REVOKE_GRANT,
		[id],
		"the Rooms session did not revoke the durable grant",
	).then(() => {});
}
