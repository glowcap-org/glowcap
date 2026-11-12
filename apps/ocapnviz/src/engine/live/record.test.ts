import { assertEquals, assertThrows } from "@std/assert";
import { parseWireRecord } from "./record.ts";

Deno.test("parseWireRecord returns a well-formed record unchanged", () => {
	const raw = parseWireRecord('{"v":1,"sim_t_ns":0,"kind":"x","replay":true,"summary":{"len":3}}');
	assertEquals(raw.replay, true);
	assertEquals(raw.summary?.len, 3);
	assertEquals(parseWireRecord('{"kind":"ocapn.session-meta","meta":{"label":null}}').meta?.label, null);
});

Deno.test("parseWireRecord refuses lines that are not records", () => {
	for (const line of ["null", "5", '"text"', "[1]", "true"]) {
		assertThrows(() => parseWireRecord(line), Error, "not a JSON object");
	}
	assertThrows(() => parseWireRecord("{"), SyntaxError);
});

Deno.test("parseWireRecord refuses wrongly typed declared fields", () => {
	for (
		const line of [
			'{"replay":"yes"}',
			'{"outbound":1}',
			'{"summary":5}',
			'{"summary":[1]}',
			'{"meta":5}',
			'{"meta":[1]}',
			'{"meta":null}',
		]
	) {
		assertThrows(() => parseWireRecord(line), Error, "not a JSON object");
	}
});
