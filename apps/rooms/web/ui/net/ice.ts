// The ICE servers this page's browser peers dial and answer through.
//
// Asked once per connection, with concurrent callers sharing the request. TURN
// credentials expire, so holding the first answer for the lifetime of a tab
// makes a long-open page quietly lose reachability. The side that offers and
// the side that answers each need relay-capable credentials; they do not need
// the same short-lived credential instance.
//
// A deployment that answers with an empty list means it, and gets none. A
// request that does not arrive is not authority to substitute a third-party
// default: retry it so the deployment still decides which hosts learn member
// addresses.

import { decodeIceServers, type IceServer } from "../../../lib/ice.ts";

type IceRequest = () => Promise<Response>;

async function requestIceServers(request: IceRequest): Promise<IceServer[]> {
	const answer = await request();
	if (!answer.ok) throw new Error(`rooms: ICE configuration request failed (${answer.status})`);
	return decodeIceServers(await answer.json());
}

/** One retrying loader. Exported only from this internal leaf so its rejection
 * and retry contract can be tested without widening the page API. */
export function iceServerSource(request: IceRequest): () => Promise<IceServer[]> {
	let asked: Promise<IceServer[]> | null = null;
	return () => {
		if (asked === null) {
			const attempt = requestIceServers(request);
			attempt.finally(() => {
				if (asked === attempt) asked = null;
			}).catch(() => {});
			asked = attempt;
		}
		return asked;
	};
}

export const iceServers = iceServerSource(() => fetch("/ice"));
