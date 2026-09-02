// The PostgreSQL history backend: the same three verbs the file backend
// beside it answers, against a database the operator named. Retention
// semantics — what is kept, how many, when a copy is forgotten — live in
// `history.ts`; this file only persists, exactly the split the module head
// there states. The wire machinery it stands on lives under `postgres/`.
//
// Evidence, honestly bounded: the hermetic suites hold the walk to RFC
// 7677's vector and a scripted fixture speaking this same grammar, which
// proves glowcap agrees with glowcap. `test/storage/postgres_live_test.ts` runs
// the round trip against a real database whenever
// GLOWCAP_ROOMS_STORAGE_LIVE_URL names one; until a deployment has, the
// boot line is part of the evidence.

import { type HistoryBackend, type KeptLine, LINES_KEPT } from "../history.ts";
import { HISTORY_LINES_KEPT, type HistoryRestoreTarget } from "../history_index.ts";
import { parsePostgresUrl, PgClient, type PgConfig } from "./postgres/client.ts";

const SCHEMA = `CREATE TABLE IF NOT EXISTS room_lines (
	seq bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
	room text NOT NULL,
	from_nick text NOT NULL,
	said text NOT NULL,
	at_ms bigint NOT NULL
)`;
const SCHEMA_INDEX = `CREATE INDEX IF NOT EXISTS room_lines_room_seq ON room_lines (room, seq)`;

export class PgHistoryBackend implements HistoryBackend {
	#config: PgConfig;
	#client: PgClient | null = null;

	private constructor(config: PgConfig) {
		this.#config = config;
	}

	/** Connect and make sure the schema exists, so a bad URL or unreachable
	 * database is a startup answer rather than a silent retention gap. */
	static async open(url: string): Promise<PgHistoryBackend> {
		const backend = new PgHistoryBackend(parsePostgresUrl(url));
		await backend.#ensure();
		return backend;
	}

	async #ensure(): Promise<PgClient> {
		if (this.#client !== null) return this.#client;
		const client = await PgClient.connect(this.#config);
		try {
			await client.run(SCHEMA);
			await client.run(SCHEMA_INDEX);
		} catch (error) {
			client.close();
			throw error;
		}
		this.#client = client;
		return client;
	}

	/** Run one step, reconnecting once if the connection had died between
	 * calls. A second failure is the caller's to hear. */
	async #step<T>(work: (client: PgClient) => Promise<T>): Promise<T> {
		try {
			return await work(await this.#ensure());
		} catch (error) {
			if (this.#client !== null) {
				this.#client.close();
				this.#client = null;
			}
			if (error instanceof Error && error.message.startsWith("PostgreSQL refused")) throw error;
			return await work(await this.#ensure());
		}
	}

	async restore(into: HistoryRestoreTarget): Promise<void> {
		const rows = await this.#step((client) =>
			client.run(
				`SELECT room, from_nick, said, at_ms FROM (
					SELECT seq, room, from_nick, said, at_ms FROM room_lines
					ORDER BY seq DESC LIMIT ${HISTORY_LINES_KEPT + 1}
				) recent ORDER BY seq`,
				[],
			)
		);
		if (rows.length > HISTORY_LINES_KEPT) {
			throw new Error(`PostgreSQL room history contains more than ${HISTORY_LINES_KEPT} retained lines`);
		}
		const rooms = new Map<string, KeptLine[]>();
		for (const row of rows) {
			const room = row[0] ?? "";
			let lines = rooms.get(room);
			if (lines === undefined) {
				lines = [];
				rooms.set(room, lines);
			}
			lines.push({
				from: row[1] ?? "",
				text: row[2] ?? "",
				at: Number(row[3] ?? "0"),
			});
		}
		for (const [room, lines] of rooms) into.restoreRoom(room, lines);
	}

	async append(room: string, line: KeptLine, evictedRoom: string | null): Promise<void> {
		await this.#step(async (client) => {
			await client.run("BEGIN");
			try {
				await client.run(
					`INSERT INTO room_lines (room, from_nick, said, at_ms) VALUES ($1, $2, $3, $4)`,
					[room, line.from, line.text, String(line.at)],
				);
				await client.run(
					`DELETE FROM room_lines WHERE room = $1 AND seq < (
						SELECT seq FROM room_lines WHERE room = $1 ORDER BY seq DESC LIMIT 1 OFFSET ${LINES_KEPT - 1}
					)`,
					[room],
				);
				if (evictedRoom !== null) await client.run(`DELETE FROM room_lines WHERE room = $1`, [evictedRoom]);
				await client.run("COMMIT");
			} catch (error) {
				await client.run("ROLLBACK").catch(() => {});
				throw error;
			}
		});
	}

	/** Swap a room's kept lines for the tail as it now stands: a withdrawal
	 * or an edit reached the kept copies. One transaction, so a crash leaves
	 * the old rows whole rather than half of both. */
	async replace(room: string, tail: readonly KeptLine[]): Promise<void> {
		await this.#step(async (client) => {
			await client.run("BEGIN");
			try {
				await client.run(`DELETE FROM room_lines WHERE room = $1`, [room]);
				for (const line of tail) {
					await client.run(
						`INSERT INTO room_lines (room, from_nick, said, at_ms) VALUES ($1, $2, $3, $4)`,
						[room, line.from, line.text, String(line.at)],
					);
				}
				await client.run("COMMIT");
			} catch (error) {
				await client.run("ROLLBACK").catch(() => {});
				throw error;
			}
		});
	}

	close(): void {
		this.#client?.close();
		this.#client = null;
	}
}
