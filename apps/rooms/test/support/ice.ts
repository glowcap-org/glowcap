import {
	WEBRTC_MAX_ICE_CREDENTIAL_BYTES,
	WEBRTC_MAX_ICE_SERVERS,
	WEBRTC_MAX_ICE_URL_BYTES,
	WEBRTC_MAX_ICE_URLS_PER_SERVER,
} from "@glowcap/abi";
import { utf8Fits } from "../../lib/limits.ts";

// Which ICE servers this deployment's browser peers use.
//
// WebRTC finds a path between two peers by trading candidate addresses. A
// `host` candidate is an address on the machine's own networks, and it is the
// only kind a browser can produce unaided. Two tabs on one machine, or two
// people on one office network, reach each other with nothing else — which is
// why every proof in this tree passes without any of this, and why the gap
// below stayed invisible until two people on different networks tried.
//
// Anywhere else, each side is behind a router that rewrote its address, and
// neither can name itself in terms the other can dial. A STUN server answers
// exactly one question — "what address did my packet appear to come from?" —
// and that answer is the candidate the other side can use. It sees no message
// bytes: a direct line is encrypted end to end whether or not STUN helped
// arrange it. ADR-0089 assumed this was here; it names an intermediary "only
// as a byte relay when ICE cannot find a direct path through NAT".
//
// The set is a deployment's to choose, because it names hosts that deployment
// is willing to depend on and disclose an address to. `GLOWCAP_ROOMS_ICE_SERVERS`
// is a comma-separated STUN list, and an empty value deliberately runs with
// none: a private network where every member can already reach every other wants
// no outside host in the path at all. TURN credentials are short-lived bearer
// authority, so the web-server policy mints them and this shared boundary only
// validates the browser-facing record it produced.

/** A STUN URL this project is willing to name as a default.
 *
 * Cloudflare's is public, free, unauthenticated, and answers the address
 * question and nothing else. It is a default, not a dependency: a deployment
 * that would rather not disclose member addresses to a third party sets
 * `GLOWCAP_ROOMS_ICE_SERVERS` to its own server, and one whose members already
 * share a network sets it empty. */
const DEFAULT_STUN = "stun:stun.cloudflare.com:3478";

/** One entry of what the browser hands to `RTCPeerConnection`. */
export interface IceServer {
	urls: string | string[];
	username?: string;
	credential?: string;
}

function iceUrl(value: unknown): { url: string; turn: boolean } {
	if (typeof value !== "string") throw new Error("rooms: an ICE server URL must be text");
	const url = value.trim();
	if (url.length === 0 || !utf8Fits(url, WEBRTC_MAX_ICE_URL_BYTES)) {
		throw new Error("rooms: an ICE server URL is empty or too long");
	}
	if (!/^(?:stuns?|turns?):/i.test(url)) {
		throw new Error(`rooms: ICE server URL must use stun:, stuns:, turn:, or turns: (${url})`);
	}
	return { url, turn: /^turns?:/i.test(url) };
}

function credential(value: unknown, field: string): string {
	if (typeof value !== "string" || value.length === 0 || !utf8Fits(value, WEBRTC_MAX_ICE_CREDENTIAL_BYTES)) {
		throw new Error(`rooms: ICE server ${field} is missing or too long`);
	}
	return value;
}

/** Validate the same JSON-shaped list the server publishes and the browser
 * consumes. Keeping one decoder on both sides means a proxy or stale deploy
 * cannot widen the browser's configuration contract. */
export function decodeIceServers(value: unknown): IceServer[] {
	if (!Array.isArray(value) || value.length > WEBRTC_MAX_ICE_SERVERS) {
		throw new Error(`rooms: ICE configuration must contain at most ${WEBRTC_MAX_ICE_SERVERS} servers`);
	}
	return value.map((entry) => {
		if (entry === null || typeof entry !== "object" || Array.isArray(entry)) {
			throw new Error("rooms: each ICE server must be a record");
		}
		const record = entry as Record<string, unknown>;
		for (const field of Object.keys(record)) {
			if (field !== "urls" && field !== "username" && field !== "credential") {
				throw new Error(`rooms: unknown ICE server field ${field}`);
			}
		}
		const rawUrls = Array.isArray(record.urls) ? record.urls : [record.urls];
		if (rawUrls.length === 0 || rawUrls.length > WEBRTC_MAX_ICE_URLS_PER_SERVER) {
			throw new Error(`rooms: one ICE server must contain 1-${WEBRTC_MAX_ICE_URLS_PER_SERVER} URLs`);
		}
		const parsed = rawUrls.map(iceUrl);
		const hasTurn = parsed.some((part) => part.turn);
		const hasCredential = record.username !== undefined || record.credential !== undefined;
		if (hasTurn !== hasCredential) {
			throw new Error(
				hasTurn
					? "rooms: a TURN server needs both username and credential"
					: "rooms: STUN servers do not take TURN credentials",
			);
		}
		const urls = parsed.map((part) => part.url);
		return hasTurn
			? {
				urls: Array.isArray(record.urls) ? urls : urls[0],
				username: credential(record.username, "username"),
				credential: credential(record.credential, "credential"),
			}
			: { urls: Array.isArray(record.urls) ? urls : urls[0] };
	});
}

/** Read deployment configuration. Empty text means no servers, which is a real
 * answer and not a missing one, so it is distinguished from an unset variable.
 * The value is a concise comma-separated STUN list. */
export function iceServersFrom(configured: string | null | undefined): IceServer[] {
	const text = configured ?? DEFAULT_STUN;
	if (text.trim() === "") return [];
	return decodeIceServers(text.split(",").map((urls) => ({ urls })));
}
