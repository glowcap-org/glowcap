// The PostgreSQL history backend against a scripted database, the way the
// IRC suites script their networks: the fixture speaks the same wire
// grammar as production, so what these scenes pin is the actual walk — the
// startup, the authentication, every statement's text and parameters, and
// the transaction around a rewrite. No live database is involved; the SCRAM
// arithmetic is held to RFC 7677's vector in the wire suite.

import { PgHistoryBackend } from "../server/storage/postgres.ts";
import { HISTORY_LINES_KEPT, HistoryIndex } from "../server/history_index.ts";
import {
	authenticationOk,
	bindComplete,
	bindParams,
	commandComplete,
	dataRow,
	errorResponse,
	noData,
	parseComplete,
	parseStatement,
	type PgMessage,
	readPgMessages,
	readyForQuery,
	rowDescription,
	startupParams,
} from "../server/storage/postgres/wire.ts";
import { assert } from "./support/rooms_server.ts";

interface Statement {
	readonly sql: string;
	readonly params: (string | null)[];
}

/** One scripted database: authenticates every connection with a cleartext
 * password ask, answers each statement through `answer`, and records every
 * statement it was sent. */
class FixtureDb {
	readonly listener: Deno.TcpListener;
	readonly statements: Statement[] = [];
	answer: (sql: string) => (string | null)[][] = () => [];
	#live = new Set<Deno.Conn>();
	#closed = false;

	constructor() {
		this.listener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
	}

	get url(): string {
		const { port } = this.listener.addr as Deno.NetAddr;
		return `postgres://keeper:sesame@127.0.0.1:${port}/rooms`;
	}

	/** Accept connections until closed; each walks auth then serves. */
	async serve(): Promise<void> {
		try {
			for await (const conn of this.listener) {
				void this.#session(conn).catch(() => {});
			}
		} catch {
			/* closed */
		}
	}

	async #session(conn: Deno.Conn): Promise<void> {
		const write = async (bytes: Uint8Array) => {
			let at = 0;
			while (at < bytes.length) at += await conn.write(bytes.subarray(at));
		};
		const messages = readPgMessages(conn.readable, { firstUntyped: true });
		this.#live.add(conn);
		try {
			const opening = (await messages.next()).value as PgMessage;
			const params = startupParams(opening.payload);
			assert(params.get("user") === "keeper", "the client names the URL's user");
			assert(params.get("database") === "rooms", "the client names the URL's database");
			await write(new Uint8Array([0x52, 0, 0, 0, 8, 0, 0, 0, 3])); // AuthenticationCleartextPassword
			const password = (await messages.next()).value as PgMessage;
			assert(password.type === "p", "the client answers the password ask");
			const said = new TextDecoder().decode(password.payload.slice(0, -1));
			if (said !== "sesame") {
				await write(errorResponse("28P01", `password authentication failed for user "keeper"`));
				return;
			}
			await write(authenticationOk());
			await write(readyForQuery());
			let sql = "";
			let bound: (string | null)[] = [];
			for await (const message of messages) {
				if (message.type === "P") sql = parseStatement(message.payload);
				if (message.type === "B") bound = bindParams(message.payload);
				if (message.type === "S") {
					this.statements.push({ sql, params: bound });
					const rows = this.answer(sql);
					await write(parseComplete());
					await write(bindComplete());
					if (rows.length > 0) {
						await write(rowDescription(rows[0].map((_, i) => `c${i}`)));
						for (const row of rows) await write(dataRow(row));
					} else {
						await write(noData());
					}
					await write(commandComplete("OK"));
					await write(readyForQuery());
					sql = "";
					bound = [];
				}
			}
		} finally {
			this.#live.delete(conn);
			try {
				conn.close();
			} catch { /* the client closed first */ }
		}
	}

	/** The database restarts: every held connection dies under its client. */
	dropConnections(): void {
		for (const conn of this.#live) {
			try {
				conn.close();
			} catch { /* already down */ }
		}
	}

	close(): void {
		if (this.#closed) return;
		this.#closed = true;
		this.listener.close();
	}
}

function sqlHead(statement: Statement): string {
	return statement.sql.replace(/\s+/g, " ").trim().split(" ").slice(0, 3).join(" ");
}

Deno.test("the PostgreSQL backend walks schema, append, restore, and rewrite exactly", async () => {
	const db = new FixtureDb();
	const serving = db.serve();
	try {
		const backend = await PgHistoryBackend.open(db.url);
		assert(sqlHead(db.statements[0]) === "CREATE TABLE IF", "open ensures the table first");
		assert(sqlHead(db.statements[1]) === "CREATE INDEX IF", "then its index");

		const appendAt = db.statements.length;
		await backend.append("general", { from: "alice", text: "kept", at: 1000 }, null);
		const appendHeads = db.statements.slice(appendAt).map(sqlHead);
		assert(
			JSON.stringify(appendHeads) === JSON.stringify([
				"BEGIN",
				"INSERT INTO room_lines",
				"DELETE FROM room_lines",
				"COMMIT",
			]),
			`append and both bounds are one transaction: ${JSON.stringify(appendHeads)}`,
		);
		const insert = db.statements[appendAt + 1];
		assert(sqlHead(insert) === "INSERT INTO room_lines", "a record is an insert");
		assert(
			JSON.stringify(insert.params) === JSON.stringify(["general", "alice", "kept", "1000"]),
			`the insert carries the line as parameters: ${JSON.stringify(insert.params)}`,
		);
		const prune = db.statements[appendAt + 2];
		assert(sqlHead(prune) === "DELETE FROM room_lines", "the insert prunes past the bound");
		assert(prune.params[0] === "general", "pruning is per room");

		const edgeAt = db.statements.length;
		await backend.append("newest", { from: "alice", text: "edge", at: 1001 }, "oldest");
		const edgeHeads = db.statements.slice(edgeAt).map(sqlHead);
		assert(
			JSON.stringify(edgeHeads) === JSON.stringify([
				"BEGIN",
				"INSERT INTO room_lines",
				"DELETE FROM room_lines",
				"DELETE FROM room_lines",
				"COMMIT",
			]),
			`global room eviction shares the append transaction: ${JSON.stringify(edgeHeads)}`,
		);
		assert(db.statements[edgeAt + 3].params[0] === "oldest", "the index's exact victim is removed");

		// The fixture answers in the query's ascending sequence order; the
		// backend groups each room without manufacturing durable line identity.
		db.answer = (sql) =>
			sql.startsWith("SELECT")
				? [["general", "alice", "first", "1000"], ["general", "bob", "second", "2000"]]
				: [];
		const restored = new HistoryIndex();
		await backend.restore(restored);
		const lines = restored.read("general", 500);
		assert(lines.length === 2 && lines[0].text === "first" && lines[1].text === "second", "oldest first");
		assert(Object.keys(lines[0]).join(",") === "from,text,at", "restored rows carry only durable history fields");

		db.answer = (sql) =>
			sql.startsWith("SELECT")
				? Array.from(
					{ length: HISTORY_LINES_KEPT + 1 },
					(_, at) => ["general", "alice", `line ${at}`, String(at)],
				)
				: [];
		let overflow = "";
		try {
			await backend.restore(new HistoryIndex());
		} catch (error) {
			overflow = error instanceof Error ? error.message : String(error);
		}
		assert(
			overflow.includes(`more than ${HISTORY_LINES_KEPT} retained lines`),
			`startup refuses an unbounded database: ${overflow}`,
		);

		db.answer = () => [];
		const before = db.statements.length;
		await backend.replace("general", [{ from: "alice", text: "edited", at: 1000 }]);
		const heads = db.statements.slice(before).map(sqlHead);
		assert(
			JSON.stringify(heads) ===
				JSON.stringify(["BEGIN", "DELETE FROM room_lines", "INSERT INTO room_lines", "COMMIT"]),
			`a rewrite is one transaction: ${JSON.stringify(heads)}`,
		);

		backend.close();
	} finally {
		db.close();
		await serving;
	}
});

Deno.test("the backend reconnects once when the database dropped between verbs", async () => {
	const db = new FixtureDb();
	const serving = db.serve();
	try {
		const backend = await PgHistoryBackend.open(db.url);
		const opens = db.statements.length;
		await backend.append("general", { from: "alice", text: "one", at: 1 }, null);
		// The database restarts under the held connection. The next verb finds
		// the dead socket, reconnects once, re-ensures the schema, and lands.
		db.dropConnections();
		await backend.append("general", { from: "alice", text: "two", at: 2 }, null);
		const heads = db.statements.slice(opens).map(sqlHead);
		assert(
			heads.includes("CREATE TABLE IF") && heads.filter((h) => h === "INSERT INTO room_lines").length === 2,
			`a fresh connection re-ensures the schema: ${JSON.stringify(heads)}`,
		);
		backend.close();
	} finally {
		db.close();
		await serving;
	}
});

Deno.test("a wrong password is refused in the server's words at startup", async () => {
	const db = new FixtureDb();
	const serving = db.serve();
	try {
		const bad = db.url.replace(":sesame@", ":wrong@");
		let refused = "";
		try {
			await PgHistoryBackend.open(bad);
		} catch (error) {
			refused = error instanceof Error ? error.message : String(error);
		}
		assert(
			refused.includes("28P01") && refused.includes("password"),
			`the refusal names the cause: "${refused}"`,
		);
	} finally {
		db.close();
		await serving;
	}
});
