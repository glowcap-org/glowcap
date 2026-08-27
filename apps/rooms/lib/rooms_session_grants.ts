// Client protocol for live and durable Rooms session grants.

import type { Ref, Session } from "@pancake/runtime";
import * as z from "zod/mini";
import { ask } from "./ask.ts";
import { MAX_SESSION_GRANT_LABEL } from "./limits.ts";
import { boundedText } from "./schema.ts";

export const ROOMS_SESSION_ISSUE_GRANT = "issueGrant";
export const ROOMS_SESSION_REVOKE_GRANT = "revokeGrant";

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

export const RoomsSessionGrantViewSchema = z.strictObject({
	id: RoomsSessionGrantIdSchema,
	label: RoomsSessionGrantLabelSchema,
	rights: RoomsSessionFacetSchema,
	sturdyref: RoomsSessionGrantSturdyrefSchema,
});

export type RoomsSessionGrantView = z.infer<typeof RoomsSessionGrantViewSchema>;

export async function issueRoomsSessionGrant(
	session: Session,
	capability: Ref,
	id: string,
	rights: RoomsSessionFacet,
	label: string,
): Promise<RoomsSessionGrantView> {
	const sturdyref = await ask(
		session,
		capability,
		ROOMS_SESSION_ISSUE_GRANT,
		[id, rights, label],
		"the Rooms session did not issue the durable grant",
	);
	if (typeof sturdyref !== "string" || !sturdyref.startsWith("ocapn://") || !sturdyref.includes("/s/")) {
		throw new Error("the Rooms session answered an invalid durable grant sturdyref");
	}
	return { id, rights, label, sturdyref };
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
