// Deployment-owned ICE policy for the Rooms web front.
//
// STUN URLs are ordinary public configuration. TURN credentials are not: a
// long-lived password shipped to every page would turn the service into an
// open relay the moment one reader copied it. The web front therefore keeps a
// credential issuer's bearer token server-side and asks it for a short-lived
// browser record on each `/ice` request. The browser receives only that scoped
// result; the issuer token never crosses the HTTP boundary.

import { decodeIceServers, type IceServer, iceServersFrom } from "../lib/ice.ts";

const DEFAULT_TURN_TTL_SECONDS = 24 * 60 * 60;
const MIN_TURN_TTL_SECONDS = 5 * 60;
const MAX_TURN_TTL_SECONDS = 48 * 60 * 60;
const CREDENTIAL_REQUEST_TIMEOUT_MS = 5_000;
const MAX_CREDENTIAL_RESPONSE_BYTES = 64 * 1024;

export interface IcePolicyEnvironment {
	readonly stunServers?: string;
	readonly turnCredentialsUrl?: string;
	readonly turnBearerToken?: string;
	readonly turnTtlSeconds?: string;
}

type CredentialRequest = (
	input: string | URL | Request,
	init?: RequestInit,
) => Promise<Response>;

export interface IcePolicy {
	servers(): Promise<IceServer[]>;
}

function ttlSeconds(raw: string | undefined): number {
	if (raw === undefined || raw.trim() === "") return DEFAULT_TURN_TTL_SECONDS;
	const ttl = Number(raw);
	if (!Number.isSafeInteger(ttl) || ttl < MIN_TURN_TTL_SECONDS || ttl > MAX_TURN_TTL_SECONDS) {
		throw new Error(
			`rooms: GLOWCAP_ROOMS_TURN_TTL_SECONDS must be ${MIN_TURN_TTL_SECONDS}-${MAX_TURN_TTL_SECONDS}`,
		);
	}
	return ttl;
}

function turnOnly(server: IceServer): IceServer | null {
	const urls = Array.isArray(server.urls) ? server.urls : [server.urls];
	const turn = urls.filter((url) => /^turns?:/i.test(url));
	if (turn.length === 0) return null;
	return {
		urls: Array.isArray(server.urls) ? turn : turn[0],
		username: server.username,
		credential: server.credential,
	};
}

async function boundedJson(response: Response): Promise<unknown> {
	const length = response.headers.get("content-length");
	if (length !== null) {
		const advertised = Number(length);
		if (!Number.isSafeInteger(advertised) || advertised < 0 || advertised > MAX_CREDENTIAL_RESPONSE_BYTES) {
			throw new Error("rooms: TURN credential issuer response is too large");
		}
	}
	if (response.body === null) {
		throw new Error("rooms: TURN credential issuer returned no ICE server record");
	}
	const reader = response.body.getReader();
	const chunks: Uint8Array[] = [];
	let total = 0;
	try {
		while (true) {
			const { done, value } = await reader.read();
			if (done) break;
			if (value.byteLength > MAX_CREDENTIAL_RESPONSE_BYTES - total) {
				throw new Error("rooms: TURN credential issuer response is too large");
			}
			total += value.byteLength;
			chunks.push(value);
		}
	} catch (err) {
		await reader.cancel().catch(() => {});
		throw err;
	} finally {
		reader.releaseLock();
	}
	const bytes = new Uint8Array(total);
	let offset = 0;
	for (const chunk of chunks) {
		bytes.set(chunk, offset);
		offset += chunk.byteLength;
	}
	try {
		return JSON.parse(new TextDecoder().decode(bytes));
	} catch {
		throw new Error("rooms: TURN credential issuer returned malformed JSON");
	}
}

/** Build the one ICE policy a Rooms web server publishes.
 *
 * The credential endpoint uses the widely deployed `generate-ice-servers`
 * shape: POST `{ ttl }`, bearer authorization, and an `{ iceServers: [...] }`
 * response. Cloudflare Realtime TURN exposes exactly this contract; another
 * issuer can implement the same narrow boundary without changing the browser.
 */
export function icePolicy(
	env: IcePolicyEnvironment,
	request: CredentialRequest = fetch,
): IcePolicy {
	const stun = iceServersFrom(env.stunServers);
	const endpoint = env.turnCredentialsUrl?.trim() ?? "";
	const token = env.turnBearerToken?.trim() ?? "";
	if ((endpoint === "") !== (token === "")) {
		throw new Error(
			"rooms: GLOWCAP_ROOMS_TURN_CREDENTIALS_URL and GLOWCAP_ROOMS_TURN_BEARER_TOKEN must be set together",
		);
	}
	if (endpoint === "") {
		return { servers: () => Promise.resolve(stun) };
	}
	const parsed = new URL(endpoint);
	if (parsed.protocol !== "https:") {
		throw new Error("rooms: the TURN credential issuer must use https:");
	}
	const ttl = ttlSeconds(env.turnTtlSeconds);
	return {
		async servers(): Promise<IceServer[]> {
			const response = await request(parsed, {
				method: "POST",
				headers: {
					"authorization": `Bearer ${token}`,
					"content-type": "application/json",
				},
				body: JSON.stringify({ ttl }),
				signal: AbortSignal.timeout(CREDENTIAL_REQUEST_TIMEOUT_MS),
			});
			if (!response.ok) {
				throw new Error(`rooms: TURN credential issuer refused (${response.status})`);
			}
			const body = await boundedJson(response);
			if (body === null || typeof body !== "object" || Array.isArray(body)) {
				throw new Error("rooms: TURN credential issuer returned no ICE server record");
			}
			const issued = decodeIceServers((body as Record<string, unknown>).iceServers);
			const turn = issued.flatMap((server) => {
				const retained = turnOnly(server);
				return retained === null ? [] : [retained];
			});
			if (turn.length === 0) {
				throw new Error("rooms: TURN credential issuer returned no TURN server");
			}
			return [...stun, ...turn];
		},
	};
}
