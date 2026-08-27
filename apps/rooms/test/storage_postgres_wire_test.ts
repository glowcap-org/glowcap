// The PostgreSQL wire grammar, held to fixed bytes and to RFC 7677's own
// SCRAM-SHA-256 vector. The grammar is what the production client and the
// scripted fixture both speak, so these cases are what makes the fixture's
// word about the client worth anything.

import { assertEquals } from "./assert.ts";
import {
	authCode,
	bindParams,
	dataRow,
	dataRowValues,
	errorFields,
	errorResponse,
	extendedQuery,
	parseStatement,
	readPgMessages,
	scramClientFirst,
	scramExchange,
	scramServerFinalSignature,
	startup,
	startupParams,
} from "../server/storage/postgres/wire.ts";

function stream(...chunks: Uint8Array[]): ReadableStream<Uint8Array> {
	return new ReadableStream({
		start(controller) {
			for (const chunk of chunks) controller.enqueue(chunk);
			controller.close();
		},
	});
}

Deno.test("a startup message carries its parameters and no type byte", async () => {
	const bytes = startup({ user: "alice", database: "rooms" });
	const read = readPgMessages(stream(bytes), { firstUntyped: true });
	const { value } = await read.next();
	// The payload already begins with the protocol word startupParams skips.
	const params = startupParams(value!.payload);
	assertEquals(params.get("user"), "alice");
	assertEquals(params.get("database"), "rooms");
	await read.return(undefined);
});

Deno.test("an extended query walks parse, bind, describe, execute, sync", async () => {
	const bytes = extendedQuery("SELECT said FROM room_lines WHERE room = $1", ["general", null]);
	const read = readPgMessages(stream(bytes));
	const types: string[] = [];
	let sql = "";
	let params: (string | null)[] = [];
	for await (const message of read) {
		types.push(message.type);
		if (message.type === "P") sql = parseStatement(message.payload);
		if (message.type === "B") params = bindParams(message.payload);
	}
	assertEquals(types, ["P", "B", "D", "E", "S"]);
	assertEquals(sql, "SELECT said FROM room_lines WHERE room = $1");
	assertEquals(params, ["general", null]);
});

Deno.test("frames survive arbitrary chunk boundaries", async () => {
	const whole = new Uint8Array([...dataRow(["a", null, "c"]), ...errorResponse("28P01", "bad password")]);
	for (const cut of [1, 2, 5, 7, whole.length - 1]) {
		const read = readPgMessages(stream(whole.slice(0, cut), whole.slice(cut)));
		const first = (await read.next()).value!;
		assertEquals(first.type, "D");
		assertEquals(dataRowValues(first.payload), ["a", null, "c"]);
		const second = (await read.next()).value!;
		assertEquals(second.type, "E");
		const fields = errorFields(second.payload);
		assertEquals(fields.get("C"), "28P01");
		assertEquals(fields.get("M"), "bad password");
		await read.return(undefined);
	}
});

Deno.test("a hostile length prefix is refused before any allocation", async () => {
	const bytes = new Uint8Array([0x44, 0x7f, 0xff, 0xff, 0xff]);
	const read = readPgMessages(stream(bytes));
	let refused = "";
	try {
		await read.next();
	} catch (error) {
		refused = error instanceof Error ? error.message : String(error);
	}
	assertEquals(refused.includes("out of bounds"), true);
});

Deno.test("an authentication payload reads back its code", () => {
	assertEquals(authCode(new Uint8Array([0, 0, 0, 10, 65])).code, 10);
	assertEquals(authCode(new Uint8Array([0, 0, 0, 0])).code, 0);
});

// RFC 7677's published SCRAM-SHA-256 exchange, byte for byte: user "user",
// password "pencil", the RFC's own nonces and salt. If the arithmetic here
// drifts, this fails against the standard rather than against a database.
Deno.test("the SCRAM exchange reproduces RFC 7677's vector", async () => {
	const clientNonce = "rOprNGfwEbeRWgbNEkqO";
	const first = scramClientFirst(clientNonce, "user");
	assertEquals(first.message, "n,,n=user,r=rOprNGfwEbeRWgbNEkqO");
	const serverFirst = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096";
	const exchange = await scramExchange("pencil", clientNonce, first.bare, serverFirst);
	assertEquals(
		exchange.clientFinal,
		"c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=",
	);
	assertEquals(exchange.serverSignature, "6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=");
	assertEquals(
		scramServerFinalSignature("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="),
		exchange.serverSignature,
	);
});

Deno.test("a server nonce that fails to extend the client's is refused", async () => {
	const clientNonce = "abcdef";
	const first = scramClientFirst(clientNonce);
	let refused = "";
	try {
		await scramExchange("pw", clientNonce, first.bare, "r=zzzzzz,s=AAAA,i=4096");
	} catch (error) {
		refused = error instanceof Error ? error.message : String(error);
	}
	assertEquals(refused.includes("nonce"), true);
});
