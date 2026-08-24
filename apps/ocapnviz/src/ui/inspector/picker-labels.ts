/**
 * How an entity reads in a picker.
 *
 * A dropdown that asks a person to choose a peer, a session, or a message
 * is read by someone who knows those things by name. "alice" is what they
 * are looking for; a sixty-four character key is not, and a list of keys
 * makes them read every row twice. So the name leads, and the id appears
 * only where the list cannot be read without it.
 *
 * The test for "cannot be read" is the rendered string, never the field
 * behind it. Two peers both named Alice collide even though their ids
 * differ, and that collision is the whole reason the id exists. When one
 * happens, every option in that list is qualified rather than only the
 * pair that collided: a visible set has one grammar, and a list mixing
 * "alice" with "alice (alice-2)" reads as though the second Alice were a
 * different kind of thing.
 *
 * A leaf, like `../elide.ts` below it: no React, no engine, no document.
 * A picker that needs a label imports it; the panels do not go through
 * a barrel to reach it.
 */

import { elideIdentifier } from "../elide.ts";

/** One thing a picker offers.
 *
 *  `name` is what a person calls it, when a person named it at all: a
 *  peer's label, or the pair a session joins. Leave it out for an entity
 *  nobody named. Passing the id as the name is the same as leaving it
 *  out, because a value that falls back to the id (`peerLabelAt` does)
 *  has not found a name, and repeating it as "alice-2 (alice-2)" would
 *  be the noise this module exists to remove. */
export type PickerOption = {
	readonly id: string;
	readonly name?: string | undefined;
};

/** The human name this option actually has, or undefined when it has
 *  none. Blank and whitespace count as none: an entity whose label was
 *  cleared has an empty string in it, and an empty option is a row a
 *  reader cannot click with any confidence. */
function humanName(option: PickerOption): string | undefined {
	const name = option.name?.trim();
	if (name === undefined || name === "" || name === option.id) {
		return undefined;
	}
	return name;
}

/**
 * What each option reads as, in the order they were given.
 *
 * Three shapes, and which one a list gets is decided by the whole list
 * rather than by any single option:
 *
 * - A named entity whose name is its own in the list shows the name.
 * - Every named entity shows `name (id)` once any two rows would have
 *   read the same.
 * - An entity nobody named shows its id, shortened.
 *
 * The id is shortened by `elideIdentifier`, which keeps both ends. Two
 * ids that survive that shortening identically would leave the list
 * unreadable after qualifying it, so that rare list falls back to whole
 * ids, which is the only thing left that tells its rows apart.
 */
export function pickerLabels(options: readonly PickerOption[]): string[] {
	const names = options.map(humanName);
	const short = options.map((o) => elideIdentifier(o.id));
	const bare = names.map((name, i) => name ?? short[i]!);
	if (unique(bare)) return bare;
	const qualified = names.map((name, i) => name === undefined ? short[i]! : `${name} (${short[i]})`);
	if (unique(qualified)) return qualified;
	return names.map((name, i) => name === undefined ? options[i]!.id : `${name} (${options[i]!.id})`);
}

function unique(labels: readonly string[]): boolean {
	return new Set(labels).size === labels.length;
}

/**
 * The same rule as a lookup, for a picker that renders its options from
 * their values rather than from an array of records. `EnumSelect` is
 * one: it takes ids and asks `labelFor` what each one says.
 *
 * An id the list never offered gets its shortened self. That is reachable
 * because a select shows the value it is holding even when the offered
 * list has lost it, and the honest answer for an entity this list knows
 * nothing about is the id it was asked about.
 */
export function pickerLabelFor(
	options: readonly PickerOption[],
): (id: string) => string {
	const labels = pickerLabels(options);
	const byId = new Map(options.map((o, i) => [o.id, labels[i]!]));
	return (id) => byId.get(id) ?? elideIdentifier(id);
}
