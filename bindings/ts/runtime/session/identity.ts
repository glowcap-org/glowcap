// Partner identity vocabulary shared by Session and trace projection. This
// leaf is internal module structure; session.ts re-exports only
// the consumer-facing declarations.

import { DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT, DURABLE_PROVENANCE_UNAUTHENTICATED, INTERNAL } from "@glowcap/abi";
import { GlowcapError } from "../errors.ts";

/** What a CapTP handshake reports about its partner, as
 * {@link Session.partnerIdentity} returns it.
 *
 * The verified hello signature proves control of the fresh session key and
 * binds that key to the locator the partner claimed. It does not by itself
 * prove control of the locator's durable designator; `provenance` reports
 * whether the realized channel supplied that proof. */
export interface PartnerIdentity {
	/** The partner's session public key. Always present. */
	readonly sessionKey: Uint8Array;
	/** The designator the partner claimed under its session signature, as text:
	 * its key in hex on a
	 * key-designator transport, a `host:port` on an address transport. It is
	 * `""` when the signed location carried no designator. */
	readonly designator: string;
	/** The verbatim location record the key and the designator were read from,
	 * empty when the handshake captured none. */
	readonly locatorRecord: Uint8Array;
	/** How the durable identity in {@link PartnerIdentity.designator} was
	 * authenticated, if at all. Session identity, durable identity, and this
	 * provenance are three separate facts (ADR-0097, ADR-0105): a caller that
	 * requires a proved durable peer reads this. The fresh session key and the
	 * durable designator are independent values. */
	readonly provenance: DurableProvenance;
}

/** How a partner's advertised durable identity was authenticated, the third
 * fact {@link PartnerIdentity} reports beside session key and designator.
 *
 * The answer is a property of the connection rather than of its transport name
 * (ADR-0105): the same transport symbol reaches this peer over code that can
 * prove something and code that cannot, so no list of transports belongs here.
 *
 * `authenticated-transport` means the code that realized this connection
 * verified the far end of the byte channel holds a durable key, and the partner
 * claimed that same key. `unauthenticated` means no durable identity was
 * proved. */
export type DurableProvenance =
	| "authenticated-transport"
	| "unauthenticated";

/** Whether this identity's durable name was authenticated by the realized
 * channel. */
export function durableIdentityAuthenticated(id: PartnerIdentity): boolean {
	return id.provenance !== "unauthenticated";
}

/** Convert one ABI provenance value to its public name. Exported because the
 * trace surface reports the same fact about the same partner, and two mappings
 * for one answer could drift apart. */
export function provenanceFromAbi(raw: number): DurableProvenance {
	switch (raw) {
		case DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT:
			return "authenticated-transport";
		case DURABLE_PROVENANCE_UNAUTHENTICATED:
			return "unauthenticated";
		default:
			throw new GlowcapError(INTERNAL, `glowcap ABI returned unknown durable provenance ${raw}`);
	}
}
