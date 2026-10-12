/**
 * Every word the app can show from a closed/reference list has an explanation.
 *
 * The tables in this folder are each keyed by the type the schema declares,
 * so the type checker holds most of this claim already. The open sets are
 * pickers' offers or reference lists rather than closed types, because OCapN is
 * netlayer-plural, implementation-plural, and codec-extensible, and for those a
 * compiler cannot help alone. The tests below hold those against the lists the
 * UI reads, hold every ranked row against a rank the section actually shows,
 * and hold every table against the shape a row has to have to be worth reading.
 */

import { assert, assertEquals } from "@std/assert";
import {
	CAPTP_VERSION_REFERENCE_OPTIONS,
	CODEC_REFERENCE_OPTIONS,
	PROFILE_OPTIONS,
	SessionState,
	TRANSPORT_OPTIONS,
	type TransportOption,
} from "../../schema/topology.ts";
import {
	ATTRIBUTION_STANDING,
	EndpointAttribution,
	SESSION_SIDES,
	UNATTRIBUTED_WORD,
} from "../../schema/session-end.ts";
import { scenarios } from "../../fixtures/index.ts";
import type { TimelineEvent } from "../../engine/timeline.ts";
import { observationsOf } from "../../engine/temporal/recording-access.ts";
import {
	ATTRIBUTION_LADDER,
	ATTRIBUTION_NOTES,
	ATTRIBUTION_ROWS,
	ATTRIBUTION_STANDING_WORD,
	LOOSE_END_TEXT,
} from "./endpoint-attribution.ts";
import {
	CAPTP_VERSION_ROWS,
	CODEC_ROWS,
	PROFILE_ROWS,
	SESSION_STATE_ROWS,
	TRANSPORT_LADDER,
	TRANSPORT_ROWS,
	TRANSPORT_VERDICT,
} from "./vocabulary.ts";
import type { ReferenceEntry } from "./entry.ts";

const words = (rows: Record<string, unknown>) => Object.keys(rows).sort();

Deno.test("every attribution the schema declares has a row", () => {
	assertEquals(
		words(ATTRIBUTION_ROWS),
		[...EndpointAttribution.options].sort(),
	);
});

Deno.test("every attribution is ranked by evidence the section shows", () => {
	// The section reads its order off the ladder and drops a row whose standing
	// is not on it, so this is the check that a word classified in the schema
	// reaches the panel at all. It is stated over the schema's own list rather
	// than over the table, so a word that has a row but no rung still fails.
	for (const word of EndpointAttribution.options) {
		const standing = ATTRIBUTION_STANDING[word];
		assert(
			ATTRIBUTION_LADDER.includes(standing),
			`${word} stands on a rung the section does not show`,
		);
	}
	for (const rung of ATTRIBUTION_LADDER) {
		assert(
			ATTRIBUTION_STANDING_WORD[rung].length > 0,
			`${rung} has no word to announce it with`,
		);
	}
});

Deno.test("the attribution section covers the end nothing attributed", () => {
	// An end with no attribution at all is the state a reader meets most, and
	// it is the one the four words cannot describe between them. It is titled
	// with the phrase the chip wears, so a reader arriving from one lands on
	// the other.
	assert(UNATTRIBUTED_WORD.trim().length > 0);
	assert(LOOSE_END_TEXT.length > 0);
	// The notes are described, not counted. A hardcoded length is a number the
	// content outgrows, and it fails on a note being added or dropped without
	// saying anything about whether the section still reads.
	assert(ATTRIBUTION_NOTES.length > 0);
	for (const note of ATTRIBUTION_NOTES) assert(note.trim().length > 0);
});

Deno.test("every netlayer the picker offers has a row and a verdict", () => {
	assertEquals(words(TRANSPORT_ROWS), [...TRANSPORT_OPTIONS].sort());
	for (const [word, row] of Object.entries(TRANSPORT_ROWS)) {
		assert(
			TRANSPORT_LADDER.includes(row.standing),
			`${word} stands on a rung the section does not show`,
		);
		assert(
			TRANSPORT_VERDICT[row.standing] !== undefined,
			`${word} stands somewhere nothing announces`,
		);
	}
});

Deno.test("every profile the picker offers has a row", () => {
	assertEquals(words(PROFILE_ROWS), [...PROFILE_OPTIONS].sort());
});

Deno.test("every codec, version and session state has a row", () => {
	assertEquals(words(CODEC_ROWS), [...CODEC_REFERENCE_OPTIONS].sort());
	assertEquals(
		words(CAPTP_VERSION_ROWS),
		[...CAPTP_VERSION_REFERENCE_OPTIONS].sort(),
	);
	assertEquals(words(SESSION_STATE_ROWS), [...SessionState.options].sort());
});

Deno.test("every row says what its word means in a sentence", () => {
	// A row that trails off into a fragment is the shape a reference decays
	// into, so the bar is stated here rather than left to taste: what a row
	// says starts as a sentence does and ends where one does.
	const tables: Record<string, Record<string, ReferenceEntry>> = {
		attribution: ATTRIBUTION_ROWS,
		transports: TRANSPORT_ROWS,
		codecs: CODEC_ROWS,
		versions: CAPTP_VERSION_ROWS,
		profiles: PROFILE_ROWS,
		states: SESSION_STATE_ROWS,
	};
	for (const [section, rows] of Object.entries(tables)) {
		for (const [word, entry] of Object.entries(rows)) {
			const where = `${section}.${word}`;
			assert(entry.says.length > 20, `${where} says almost nothing`);
			assert(
				entry.says.endsWith("."),
				`${where} does not end its sentence`,
			);
			const aside = entry.aside;
			if (aside !== undefined) {
				assert(
					aside.endsWith("."),
					`${where}'s aside is not a sentence`,
				);
			}
		}
	}
});

Deno.test("no sentence in the Reference runs past a reader", () => {
	// The project's documentation voice refuses a sentence past 250 characters,
	// which is well past the point a reader has lost the thread. Nothing in the
	// build reaches these strings, so the bar is held here instead.
	const prose: string[] = [
		LOOSE_END_TEXT,
		...ATTRIBUTION_NOTES,
		...Object.values(ATTRIBUTION_ROWS).flatMap(sentencesOf),
		...Object.values(TRANSPORT_ROWS).flatMap(sentencesOf),
		...Object.values(CODEC_ROWS).flatMap(sentencesOf),
		...Object.values(CAPTP_VERSION_ROWS).flatMap(sentencesOf),
		...Object.values(PROFILE_ROWS).flatMap(sentencesOf),
		...Object.values(SESSION_STATE_ROWS).flatMap(sentencesOf),
	];
	for (const passage of prose) {
		for (const sentence of passage.split(". ")) {
			assert(
				sentence.length <= 250,
				`a sentence runs to ${sentence.length} characters: ${sentence}`,
			);
		}
	}
});

Deno.test("no recording claims a proof its transport could not have made", () => {
	// `authenticated-transport` means a lower layer proved the far end of the
	// byte channel holds the key the partner claimed. A cleartext netlayer proves
	// no such thing, so a recording that pairs the two is teaching a proof that
	// cannot happen. It reached the shipped fixtures once already: the sturdyref
	// chapter carried it on `keyed-tcp` for as long as there was a hello
	// credential behind it, and kept carrying it after the credential went.
	//
	// Authored recordings are the gap this closes. A live verdict arrives on the
	// trace and is the producer's own answer, but nothing on that path ever reads
	// a fixture, so the fixtures answer to this instead.
	for (const doc of scenarios) {
		for (const ev of observationsOf(doc) as readonly TimelineEvent[]) {
			if (ev.kind !== "session-opened") continue;
			const transport = ev.transport;
			// A netlayer this build has never heard of has no row to check against,
			// and `TRANSPORT_OPTIONS` is an offer rather than a domain.
			const row = TRANSPORT_ROWS[transport as TransportOption];
			if (row === undefined) continue;
			for (const side of SESSION_SIDES) {
				if (ev[side].attributedBy !== "authenticated-transport") {
					continue;
				}
				assert(
					row.authenticatesPeer,
					`${doc.id}/${ev.id}: side ${side} claims authenticated-transport ` +
						`on \`${transport}\`, which authenticates no peer. The Reference ` +
						`says of it: ${row.says}`,
				);
			}
		}
	}
});

function sentencesOf(entry: ReferenceEntry): string[] {
	return entry.aside === undefined ? [entry.says] : [entry.says, entry.aside];
}
