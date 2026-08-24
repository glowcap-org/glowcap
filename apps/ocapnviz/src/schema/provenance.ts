import { z } from "zod";

/**
 * Provenance and descriptive-metadata schemas, keyed by published
 * RDF vocabularies (W3C PROV-O, Dublin Core Terms) used as JSON
 * property names. Documents stay property-graph-shaped; adding a
 * JSON-LD `@context` at any root promotes them to valid RDF without
 * renaming a single key. OCapN-specific vocabulary lives in
 * [`topology.ts`](./topology.ts) and [`session-end.ts`](./session-end.ts).
 */

/** IRI prefixes for JSON-LD `@context`. Not used at validation time. */
export const NAMESPACES = {
	prov: "http://www.w3.org/ns/prov#",
	dct: "http://purl.org/dc/terms/",
	ocapn: "https://pancake.dev/ns/ocapn#",
	jgf: "https://jsongraphformat.info/v2/",
} as const;

/** ISO-8601 instant (`prov:generatedAtTime`, `dct:created`, …). */
export const Iso8601Instant = z.string().regex(
	/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/,
	"must be an ISO-8601 instant (YYYY-MM-DDTHH:MM:SS[.sss]Z|±HH:MM)",
);
export type Iso8601Instant = z.infer<typeof Iso8601Instant>;

/**
 * PROV-O attribution attached to any document or event. All fields
 * optional; an empty object means "no claim made".
 */
export const Provenance = z.object({
	"prov:wasGeneratedBy": z.string().optional(),
	"prov:wasAttributedTo": z.string().optional(),
	"prov:wasDerivedFrom": z.array(z.string()).optional(),
	"prov:generatedAtTime": Iso8601Instant.optional(),
	"prov:wasInformedBy": z.array(z.string()).optional(),
	"dct:source": z.string().optional(),
	"dct:identifier": z.string().optional(),
});
export type Provenance = z.infer<typeof Provenance>;

/**
 * Dublin Core Terms describing a document, scenario, or graph.
 *
 * The one place a document says what it is. A title and a description used to
 * live here AND at the top level of `TimelineDocument`, and only the top-level
 * pair was ever read, so the block below was decoration that could not be
 * trusted. One block now, and the panel that edits a document edits this.
 *
 * `dct:modified` is written when a document is SAVED rather than as edits land.
 * A clock in the edit path would make every keystroke differ from the last, which
 * defeats the no-op detection in `endTransaction`, and undo would then have a
 * timestamp to revert as well as the edit. Saved is also what the term means.
 */
export const DescriptiveMetadata = z.object({
	"dct:title": z.string().optional(),
	"dct:description": z.string().optional(),
	"dct:created": Iso8601Instant.optional(),
	"dct:modified": Iso8601Instant.optional(),
	"dct:creator": z.string().optional(),
});
export type DescriptiveMetadata = z.infer<typeof DescriptiveMetadata>;
