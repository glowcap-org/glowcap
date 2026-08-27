// A small PostgreSQL client: connect, authenticate, run parameterized
// statements, close. It speaks through the wire grammar beside it and
// nothing else, the way the IRC clients speak through `irc/protocol.ts`.
//
// Scope is deliberate: text-format results, one statement at a time, and
// the two authentication shapes a current server offers (SCRAM-SHA-256 and
// cleartext password). TLS is not spoken here — the deployment this serves
// puts the database on the same private compose network as the server, and
// a database further away than that is a boundary this module states rather
// than papers over. MD5 authentication is refused by name: SCRAM has been
// the default since PostgreSQL 14.

import {
	authCode,
	dataRowValues,
	errorFields,
	extendedQuery,
	passwordMessage,
	type PgMessage,
	readPgMessages,
	saslInitialResponse,
	saslResponse,
	scramClientFirst,
	scramExchange,
	scramServerFinalSignature,
	startup,
	terminate,
} from "./wire.ts";

export interface PgConfig {
	readonly hostname: string;
	readonly port: number;
	readonly user: string;
	readonly password: string;
	readonly database: string;
}

/** Read a `postgres://user:password@host:port/database` URL into a config.
 * Refuses a malformed one with the missing part named, because this is the
 * operator's first contact with the feature and the error is the manual. */
export function parsePostgresUrl(url: string): PgConfig {
	let parsed: URL;
	try {
		parsed = new URL(url);
	} catch {
		throw new Error(`the history database URL is not a URL: ${JSON.stringify(url)}`);
	}
	if (parsed.protocol !== "postgres:" && parsed.protocol !== "postgresql:") {
		throw new Error("the history database URL must start with postgres://");
	}
	const database = parsed.pathname.replace(/^\//, "");
	if (parsed.hostname === "") throw new Error("the history database URL names no host");
	if (parsed.username === "") throw new Error("the history database URL names no user");
	if (database === "") throw new Error("the history database URL names no database");
	return {
		hostname: parsed.hostname,
		port: parsed.port === "" ? 5432 : Number(parsed.port),
		user: decodeURIComponent(parsed.username),
		password: decodeURIComponent(parsed.password),
		database,
	};
}

const utf8 = new TextDecoder();

function pgError(payload: Uint8Array): Error {
	const fields = errorFields(payload);
	const code = fields.get("C") ?? "?????";
	const message = fields.get("M") ?? "unspecified database error";
	return new Error(`PostgreSQL refused (${code}): ${message}`);
}

export class PgClient {
	#conn: Deno.Conn;
	#messages: AsyncGenerator<PgMessage>;
	/** One statement at a time: the wire interleaves nothing, so callers
	 * queue here instead of corrupting each other's walks. */
	#turn: Promise<unknown> = Promise.resolve();

	private constructor(conn: Deno.Conn) {
		this.#conn = conn;
		this.#messages = readPgMessages(conn.readable);
	}

	/** Dial, authenticate, and wait for the server to say it is ready. */
	static async connect(config: PgConfig): Promise<PgClient> {
		const conn = await Deno.connect({ hostname: config.hostname, port: config.port });
		const client = new PgClient(conn);
		try {
			await client.#write(startup({ user: config.user, database: config.database }));
			await client.#authenticate(config);
			return client;
		} catch (error) {
			client.close();
			throw error;
		}
	}

	async #write(bytes: Uint8Array): Promise<void> {
		let at = 0;
		while (at < bytes.length) at += await this.#conn.write(bytes.subarray(at));
	}

	async #next(): Promise<PgMessage> {
		const { done, value } = await this.#messages.next();
		if (done) throw new Error("the PostgreSQL server closed the connection");
		return value;
	}

	async #authenticate(config: PgConfig): Promise<void> {
		let scram: { nonce: string; bare: string; serverSignature: string } | null = null;
		while (true) {
			const message = await this.#next();
			if (message.type === "E") throw pgError(message.payload);
			if (message.type === "S" || message.type === "K" || message.type === "N") continue;
			if (message.type === "Z") return;
			if (message.type !== "R") throw new Error(`unexpected PostgreSQL message "${message.type}" during startup`);
			const { code, data } = authCode(message.payload);
			if (code === 0) continue;
			if (code === 3) {
				await this.#write(passwordMessage(config.password));
				continue;
			}
			if (code === 5) {
				throw new Error(
					"the database offers only md5 authentication; use scram-sha-256 (the default since PostgreSQL 14)",
				);
			}
			if (code === 10) {
				const offered = utf8.decode(data).split("\0").filter((m) => m !== "");
				if (!offered.includes("SCRAM-SHA-256")) {
					throw new Error(
						`the database offers none of this client's SASL mechanisms (offered: ${offered.join(", ")})`,
					);
				}
				const nonce = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(18))));
				const first = scramClientFirst(nonce);
				scram = { nonce, bare: first.bare, serverSignature: "" };
				await this.#write(saslInitialResponse("SCRAM-SHA-256", new TextEncoder().encode(first.message)));
				continue;
			}
			if (code === 11) {
				if (scram === null) throw new Error("the database continued SASL it never started");
				const serverFirst = utf8.decode(data);
				const exchange = await scramExchange(config.password, scram.nonce, scram.bare, serverFirst);
				scram.serverSignature = exchange.serverSignature;
				await this.#write(saslResponse(new TextEncoder().encode(exchange.clientFinal)));
				continue;
			}
			if (code === 12) {
				if (scram === null || scram.serverSignature === "") {
					throw new Error("the database finished SASL it never continued");
				}
				const said = scramServerFinalSignature(utf8.decode(data));
				if (said !== scram.serverSignature) {
					throw new Error("the database's SCRAM proof is wrong: this is not the server the password was for");
				}
				continue;
			}
			throw new Error(`the database asked for authentication kind ${code}, which this client does not speak`);
		}
	}

	/** Run one parameterized statement and hand back its text-format rows.
	 * Outside values only ever cross as parameters. */
	run(sql: string, params: (string | null)[] = []): Promise<(string | null)[][]> {
		const turn = this.#turn.then(() => this.#run(sql, params));
		// The queue survives a failed statement: the wire is resynchronized by
		// ReadyForQuery, so the next caller starts clean.
		this.#turn = turn.catch(() => {});
		return turn;
	}

	async #run(sql: string, params: (string | null)[]): Promise<(string | null)[][]> {
		await this.#write(extendedQuery(sql, params));
		const rows: (string | null)[][] = [];
		let failure: Error | null = null;
		while (true) {
			const message = await this.#next();
			if (message.type === "Z") {
				if (failure !== null) throw failure;
				return rows;
			}
			if (message.type === "E") {
				// Keep reading to ReadyForQuery so the connection stays usable.
				failure = pgError(message.payload);
				continue;
			}
			if (message.type === "D") rows.push(dataRowValues(message.payload));
			// ParseComplete, BindComplete, RowDescription, NoData,
			// CommandComplete, ParameterStatus, NoticeResponse: walk artifacts.
		}
	}

	close(): void {
		try {
			// Best-effort courtesy; closing the socket is what retires it.
			void this.#conn.write(terminate()).catch(() => {});
		} catch { /* already down */ }
		try {
			this.#conn.close();
		} catch { /* already down */ }
	}
}
