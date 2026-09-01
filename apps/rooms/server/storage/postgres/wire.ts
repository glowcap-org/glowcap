// The PostgreSQL wire grammar: message frames in both directions, and the
// SCRAM-SHA-256 arithmetic authentication rides on.
//
// One authority for the byte forms, the same way `irc/protocol.ts` owns the
// IRC grammar: the production client and the scripted test fixture both
// speak through this module, so what the tests pin is what the server hears.
// Policy lives elsewhere — this file knows how to spell a message, never
// when to send one.

/** One framed backend message: its type byte as a character, and its payload
 * after the length word. */
export interface PgMessage {
	readonly type: string;
	readonly payload: Uint8Array;
}

/** The longest message this side will frame or accept. A history row is
 * bounded far below this; a length past it is a broken or hostile stream and
 * fails closed rather than allocating from the prefix. */
const MAX_PG_MESSAGE = 16 * 1024 * 1024;

const utf8 = new TextEncoder();
const text = new TextDecoder();

class ByteWriter {
	#chunks: number[] = [];
	cstring(value: string): this {
		if (value.includes("\0")) throw new Error("a NUL cannot ride a PostgreSQL string");
		this.bytes(utf8.encode(value));
		this.#chunks.push(0);
		return this;
	}
	bytes(value: Uint8Array): this {
		for (const b of value) this.#chunks.push(b);
		return this;
	}
	int32(value: number): this {
		this.#chunks.push((value >>> 24) & 0xff, (value >>> 16) & 0xff, (value >>> 8) & 0xff, value & 0xff);
		return this;
	}
	int16(value: number): this {
		this.#chunks.push((value >>> 8) & 0xff, value & 0xff);
		return this;
	}
	take(): Uint8Array {
		return Uint8Array.from(this.#chunks);
	}
}

function framed(type: string | null, body: Uint8Array): Uint8Array {
	const head = type === null ? 0 : 1;
	const out = new Uint8Array(head + 4 + body.length);
	if (type !== null) out[0] = type.charCodeAt(0);
	const len = 4 + body.length;
	out[head] = (len >>> 24) & 0xff;
	out[head + 1] = (len >>> 16) & 0xff;
	out[head + 2] = (len >>> 8) & 0xff;
	out[head + 3] = len & 0xff;
	out.set(body, head + 4);
	return out;
}

// ── Frontend messages ─────────────────────────────────────────────────────

/** The untyped opening message: protocol 3.0, the session parameters, and
 * the explicit terminating NUL the parameter list requires. */
export function startup(params: Record<string, string>): Uint8Array {
	const w = new ByteWriter().int32(196608);
	for (const [key, value] of Object.entries(params)) w.cstring(key).cstring(value);
	w.bytes(new Uint8Array([0]));
	const body = w.take();
	const out = new Uint8Array(4 + body.length);
	const len = out.length;
	out[0] = (len >>> 24) & 0xff;
	out[1] = (len >>> 16) & 0xff;
	out[2] = (len >>> 8) & 0xff;
	out[3] = len & 0xff;
	out.set(body, 4);
	return out;
}

export function passwordMessage(password: string): Uint8Array {
	return framed("p", new ByteWriter().cstring(password).take());
}

export function saslInitialResponse(mechanism: string, initial: Uint8Array): Uint8Array {
	return framed("p", new ByteWriter().cstring(mechanism).int32(initial.length).bytes(initial).take());
}

export function saslResponse(data: Uint8Array): Uint8Array {
	return framed("p", data);
}

/** The extended-protocol walk for one parameterized statement: parse, bind
 * the text-format parameters, describe, execute, sync — one write. Outside
 * values only ever cross as parameters, never spliced into SQL text. */
export function extendedQuery(sql: string, params: (string | null)[]): Uint8Array {
	const parse = framed("P", new ByteWriter().cstring("").cstring(sql).int16(0).take());
	const bindBody = new ByteWriter().cstring("").cstring("").int16(0).int16(params.length);
	for (const param of params) {
		if (param === null) bindBody.int32(-1);
		else {
			const bytes = utf8.encode(param);
			bindBody.int32(bytes.length).bytes(bytes);
		}
	}
	bindBody.int16(0);
	const bind = framed("B", bindBody.take());
	const describe = framed("D", new ByteWriter().bytes(utf8.encode("P")).cstring("").take());
	const execute = framed("E", new ByteWriter().cstring("").int32(0).take());
	const sync = framed("S", new Uint8Array(0));
	const out = new Uint8Array(parse.length + bind.length + describe.length + execute.length + sync.length);
	let at = 0;
	for (const part of [parse, bind, describe, execute, sync]) {
		out.set(part, at);
		at += part.length;
	}
	return out;
}

export function terminate(): Uint8Array {
	return framed("X", new Uint8Array(0));
}

// ── Backend messages the fixture speaks ───────────────────────────────────

export function authenticationOk(): Uint8Array {
	return framed("R", new ByteWriter().int32(0).take());
}

export function readyForQuery(): Uint8Array {
	return framed("Z", utf8.encode("I"));
}

export function parseComplete(): Uint8Array {
	return framed("1", new Uint8Array(0));
}

export function bindComplete(): Uint8Array {
	return framed("2", new Uint8Array(0));
}

export function noData(): Uint8Array {
	return framed("n", new Uint8Array(0));
}

export function rowDescription(columns: string[]): Uint8Array {
	const w = new ByteWriter().int16(columns.length);
	for (const name of columns) {
		w.cstring(name).int32(0).int16(0).int32(25).int16(-1).int32(-1).int16(0);
	}
	return framed("T", w.take());
}

export function dataRow(values: (string | null)[]): Uint8Array {
	const w = new ByteWriter().int16(values.length);
	for (const value of values) {
		if (value === null) w.int32(-1);
		else {
			const bytes = utf8.encode(value);
			w.int32(bytes.length).bytes(bytes);
		}
	}
	return framed("D", w.take());
}

export function commandComplete(tag: string): Uint8Array {
	return framed("C", new ByteWriter().cstring(tag).take());
}

export function errorResponse(code: string, message: string): Uint8Array {
	const w = new ByteWriter();
	w.bytes(utf8.encode("S")).cstring("ERROR");
	w.bytes(utf8.encode("C")).cstring(code);
	w.bytes(utf8.encode("M")).cstring(message);
	w.bytes(new Uint8Array([0]));
	return framed("E", w.take());
}

// ── Reading frames ────────────────────────────────────────────────────────

/** Read framed messages from a byte stream. `typed` is false only for the
 * fixture's first read, where the startup message carries no type byte. */
export async function* readPgMessages(
	stream: ReadableStream<Uint8Array>,
	options?: { firstUntyped?: boolean },
): AsyncGenerator<PgMessage> {
	let buffer = new Uint8Array(0);
	let firstUntyped = options?.firstUntyped ?? false;
	const reader = stream.getReader();
	try {
		while (true) {
			const head = firstUntyped ? 4 : 5;
			while (buffer.length < head) {
				const { done, value } = await reader.read();
				if (done) return;
				const next = new Uint8Array(buffer.length + value.length);
				next.set(buffer);
				next.set(value, buffer.length);
				buffer = next;
			}
			const lenAt = firstUntyped ? 0 : 1;
			const len = (buffer[lenAt] << 24) | (buffer[lenAt + 1] << 16) | (buffer[lenAt + 2] << 8) |
				buffer[lenAt + 3];
			if (len < 4 || len > MAX_PG_MESSAGE) throw new Error(`PostgreSQL message length ${len} is out of bounds`);
			const whole = (firstUntyped ? 0 : 1) + len;
			while (buffer.length < whole) {
				const { done, value } = await reader.read();
				if (done) throw new Error("the PostgreSQL stream ended mid-message");
				const next = new Uint8Array(buffer.length + value.length);
				next.set(buffer);
				next.set(value, buffer.length);
				buffer = next;
			}
			const type = firstUntyped ? "" : String.fromCharCode(buffer[0]);
			const payload = buffer.slice(firstUntyped ? 4 : 5, whole);
			buffer = buffer.slice(whole);
			firstUntyped = false;
			yield { type, payload };
		}
	} finally {
		reader.releaseLock();
	}
}

/** The authentication request's code, and its trailing data. */
export function authCode(payload: Uint8Array): { code: number; data: Uint8Array } {
	const code = (payload[0] << 24) | (payload[1] << 16) | (payload[2] << 8) | payload[3];
	return { code, data: payload.slice(4) };
}

/** A DataRow's text-format values, null-aware. */
export function dataRowValues(payload: Uint8Array): (string | null)[] {
	const count = (payload[0] << 8) | payload[1];
	const values: (string | null)[] = [];
	let at = 2;
	for (let i = 0; i < count; i++) {
		const len = (payload[at] << 24) | (payload[at + 1] << 16) | (payload[at + 2] << 8) | payload[at + 3];
		at += 4;
		// The OR of four bytes is a signed 32-bit value, so the null marker
		// arrives as exactly -1.
		if (len === -1) {
			values.push(null);
			continue;
		}
		values.push(text.decode(payload.slice(at, at + len)));
		at += len;
	}
	return values;
}

/** An ErrorResponse's fields, keyed by their single-letter codes. */
export function errorFields(payload: Uint8Array): Map<string, string> {
	const fields = new Map<string, string>();
	let at = 0;
	while (at < payload.length && payload[at] !== 0) {
		const key = String.fromCharCode(payload[at]);
		at++;
		let end = at;
		while (end < payload.length && payload[end] !== 0) end++;
		fields.set(key, text.decode(payload.slice(at, end)));
		at = end + 1;
	}
	return fields;
}

/** The startup message's parameters, for the fixture's first read. */
export function startupParams(payload: Uint8Array): Map<string, string> {
	const params = new Map<string, string>();
	let at = 4;
	while (at < payload.length && payload[at] !== 0) {
		let end = at;
		while (payload[end] !== 0) end++;
		const key = text.decode(payload.slice(at, end));
		at = end + 1;
		end = at;
		while (payload[end] !== 0) end++;
		params.set(key, text.decode(payload.slice(at, end)));
		at = end + 1;
	}
	return params;
}

/** A parsed extended-protocol Parse message: the statement text. */
export function parseStatement(payload: Uint8Array): string {
	let at = 0;
	while (payload[at] !== 0) at++;
	let end = at + 1;
	while (payload[end] !== 0) end++;
	return text.decode(payload.slice(at + 1, end));
}

/** A Bind message's text-format parameters. */
export function bindParams(payload: Uint8Array): (string | null)[] {
	let at = 0;
	while (payload[at] !== 0) at++;
	at++;
	while (payload[at] !== 0) at++;
	at++;
	const formats = (payload[at] << 8) | payload[at + 1];
	at += 2 + formats * 2;
	const count = (payload[at] << 8) | payload[at + 1];
	at += 2;
	const params: (string | null)[] = [];
	for (let i = 0; i < count; i++) {
		const len = (payload[at] << 24) | (payload[at + 1] << 16) | (payload[at + 2] << 8) | payload[at + 3];
		at += 4;
		if (len >>> 0 === 0xffffffff) {
			params.push(null);
			continue;
		}
		params.push(text.decode(payload.slice(at, at + len)));
		at += len;
	}
	return params;
}

// ── SCRAM-SHA-256 ─────────────────────────────────────────────────────────
//
// RFC 5802 arithmetic with SHA-256 (RFC 7677), over WebCrypto. The client
// half is what production speaks; `scramServerSignature` lets a fixture (or
// a verifying client) compute the server's expected proof from the same
// derivation, so the walk is testable without a live database.

function b64(bytes: Uint8Array): string {
	let s = "";
	for (const b of bytes) s += String.fromCharCode(b);
	return btoa(s);
}

function unb64(value: string): Uint8Array<ArrayBuffer> {
	return Uint8Array.from(atob(value), (c) => c.charCodeAt(0));
}

async function hmac(key: Uint8Array<ArrayBuffer>, message: Uint8Array<ArrayBuffer>): Promise<Uint8Array<ArrayBuffer>> {
	const k = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
	return new Uint8Array(await crypto.subtle.sign("HMAC", k, message));
}

async function sha256(bytes: Uint8Array<ArrayBuffer>): Promise<Uint8Array<ArrayBuffer>> {
	return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
}

async function saltedPassword(
	password: string,
	salt: Uint8Array<ArrayBuffer>,
	iterations: number,
): Promise<Uint8Array<ArrayBuffer>> {
	const key = await crypto.subtle.importKey("raw", utf8.encode(password), "PBKDF2", false, ["deriveBits"]);
	const bits = await crypto.subtle.deriveBits(
		{ name: "PBKDF2", hash: "SHA-256", salt, iterations },
		key,
		256,
	);
	return new Uint8Array(bits);
}

/** The client-first message for one authentication attempt. PostgreSQL
 * ignores the SASL username in favor of the startup user, so production
 * passes the default empty name; the RFC 7677 vector test passes the RFC's. */
export function scramClientFirst(clientNonce: string, username = ""): { message: string; bare: string } {
	const bare = `n=${username},r=${clientNonce}`;
	return { message: `n,,${bare}`, bare };
}

export interface ScramExchange {
	/** The client-final message to send. */
	readonly clientFinal: string;
	/** What the server must answer in its final message's `v=`. */
	readonly serverSignature: string;
}

/** Answer a server-first message: derive the proof and the server signature
 * the final message must carry. Throws when the server's nonce does not
 * extend the client's, which is the replay the nonce exists to refuse. */
export async function scramExchange(
	password: string,
	clientNonce: string,
	clientFirstBare: string,
	serverFirst: string,
): Promise<ScramExchange> {
	const fields = new Map(serverFirst.split(",").map((part) => [part.slice(0, 1), part.slice(2)] as const));
	const nonce = fields.get("r") ?? "";
	const salt = fields.get("s") ?? "";
	const iterations = Number(fields.get("i") ?? "0");
	if (!nonce.startsWith(clientNonce) || nonce === clientNonce) {
		throw new Error("the PostgreSQL server's SCRAM nonce does not extend the client's");
	}
	if (salt === "" || !Number.isSafeInteger(iterations) || iterations < 1) {
		throw new Error("the PostgreSQL server's SCRAM challenge is malformed");
	}
	const salted = await saltedPassword(password, unb64(salt), iterations);
	const clientKey = await hmac(salted, utf8.encode("Client Key"));
	const storedKey = await sha256(clientKey);
	const withoutProof = `c=biws,r=${nonce}`;
	const auth = utf8.encode(`${clientFirstBare},${serverFirst},${withoutProof}`);
	const clientSignature = await hmac(storedKey, auth);
	const proof = new Uint8Array(clientKey.length);
	for (let i = 0; i < proof.length; i++) proof[i] = clientKey[i] ^ clientSignature[i];
	const serverKey = await hmac(salted, utf8.encode("Server Key"));
	const serverSignature = await hmac(serverKey, auth);
	return {
		clientFinal: `${withoutProof},p=${b64(proof)}`,
		serverSignature: b64(serverSignature),
	};
}

/** The `v=` value from a server-final message. */
export function scramServerFinalSignature(serverFinal: string): string {
	for (const part of serverFinal.split(",")) {
		if (part.startsWith("v=")) return part.slice(2);
	}
	return "";
}
