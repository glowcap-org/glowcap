import { assert, assertEquals } from "@std/assert";
import { DescriptiveMetadata, Iso8601Instant, NAMESPACES, Provenance } from "./provenance.ts";

Deno.test("Iso8601Instant accepts canonical UTC", () => {
	assertEquals(
		Iso8601Instant.safeParse("2026-05-14T10:00:00Z").success,
		true,
	);
});

Deno.test("Iso8601Instant accepts fractional seconds and offsets", () => {
	assertEquals(
		Iso8601Instant.safeParse("2026-05-14T10:00:00.123Z").success,
		true,
	);
	assertEquals(
		Iso8601Instant.safeParse("2026-05-14T10:00:00-04:00").success,
		true,
	);
});

Deno.test("Iso8601Instant rejects malformed input", () => {
	assertEquals(Iso8601Instant.safeParse("2026-05-14").success, false);
	assertEquals(Iso8601Instant.safeParse("today").success, false);
});

Deno.test("Provenance accepts empty (no claim)", () => {
	assertEquals(Provenance.safeParse({}).success, true);
});

Deno.test("Provenance accepts a fully attributed entity", () => {
	const result = Provenance.safeParse({
		"prov:wasGeneratedBy": "act:project-domain-to-ir",
		"prov:wasAttributedTo": "ocapnviz:fixtures",
		"prov:wasDerivedFrom": ["entity:topology-snapshot-1"],
		"prov:generatedAtTime": "2026-05-14T10:00:00Z",
	});
	assertEquals(result.success, true);
});

Deno.test("DescriptiveMetadata accepts DC terms", () => {
	const result = DescriptiveMetadata.safeParse({
		metadata: {
			"dct:title": "Three-vat handoff",
			"dct:description": "demonstrates per-session negotiation",
		},
		"dct:created": "2026-05-14T10:00:00Z",
	});
	assertEquals(result.success, true);
});

Deno.test("NAMESPACES exports stable IRIs", () => {
	assertEquals(NAMESPACES.prov, "http://www.w3.org/ns/prov#");
	assertEquals(NAMESPACES.dct, "http://purl.org/dc/terms/");
	assert(NAMESPACES.ocapn.startsWith("https://"));
});
