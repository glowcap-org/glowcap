// Finishing a name somebody is part-way through typing.
//
// Two patterns live in this page and they answer different questions. A value
// too long to type is picked from a menu: the join card's locator hangs one off
// its own mark, because forty characters of address is not something anybody
// retypes. A value short enough to type is finished as it is typed, which is
// this, and which the composer already does for commands, people, rooms and
// emoji inside a message.
//
// This is that second pattern for a field whose whole value is the name: the
// rail's two panels, and the join card's room. It draws in the composer's own
// completion clothes, because a reader who has finished a name in the message
// field has already learned this list, and one thing that looks the same in two
// places is cheaper than two that look nearly alike.
//
// What it is not is a set to choose from. Every field using it names something
// that may not exist yet, a room is made by opening it, so what is typed
// always wins, nothing is picked until the reader walks to it, and Enter with
// nothing picked still submits the words in the field.

import type { KeyboardEvent, ReactNode } from "react";
import { useState } from "react";
import { rank } from "./complete.ts";

/** How many names a field offers at once. These come from what a directory
 * advertises and who it says is reachable, both somebody else's to size, and a
 * reader is part-way through naming one of them. */
const OFFERS = 8;

export interface Suggest {
	/** Spread onto the input: what it is, whether the list is up, and which row
	 * it is standing on. */
	aria: {
		role?: "combobox";
		"aria-autocomplete"?: "list";
		"aria-expanded"?: boolean;
		"aria-controls"?: string;
		"aria-activedescendant"?: string;
	};
	/** Give this the keydown first. True means the list answered the key and the
	 * field should not: the arrows walk it, and Enter and Escape mean something
	 * different while a row is picked. */
	keyDown: (event: KeyboardEvent) => boolean;
	/** Call when the value changes by typing, which steps out of the list so the
	 * next Enter is about the words in the field rather than a row picked before
	 * them. */
	typed: () => void;
	/** The list itself, or null when there is nothing to offer. Render it inside
	 * whatever decides the field has focus, since a list rendered outside can put
	 * its own field away on the way to being pressed. That ancestor is also what
	 * places it: the list wears `suggest-pop` and each field's own stylesheet
	 * hangs it off the box it belongs to, so a new caller cannot forget to say
	 * where it goes. It has already said, by rendering it somewhere. */
	list: ReactNode;
}

export function useSuggest(
	{ id, label, offers, value, sigil, onTake }: {
		/** The field's own id. The list and its rows are named from it. */
		id: string;
		/** What the field is, for a reader who has only the list. */
		label: string;
		/** Names this field can finish. Absent offers nothing and costs nothing. */
		offers?: readonly string[];
		value: string;
		/** The mark the rows wear, so an offered name looks like the named things
		 * already on the page. */
		sigil: string;
		/** Take this name into the field. Refocusing is the caller's, because only
		 * it knows which element the caret belongs to. */
		onTake: (name: string) => void;
	},
): Suggest {
	const [picked, setPicked] = useState(-1);
	const said = value.trim().toLowerCase();
	// A name already typed in full offers nothing: this is a way past typing, and
	// once there is nothing left to save it is only something in the way. An
	// empty field is the same case from the other end. Nothing has been started,
	// so there is nothing to finish, and a list standing open on arrival would
	// cover the field under it before the reader had said anything at all.
	// Reading what a directory carries is the rail's job, and the rail lists it.
	const matches = (said === "" ? [] : offers ?? [])
		.map((name) => ({ name, at: rank(name, said) }))
		.filter(({ name, at }) => at !== Infinity && name.toLowerCase() !== said)
		.sort((a, b) => a.at - b.at || a.name.localeCompare(b.name))
		.slice(0, OFFERS)
		.map(({ name }) => name);
	const listing = matches.length > 0;
	// A field that can finish names says so for as long as it can, rather than
	// only while its list is up. The two are different claims: one is what this
	// control is, the other is what it is doing, and a screen reader that hears
	// the first change on every keystroke announces a new control each time.
	const completing = (offers ?? []).length > 0;
	// Clamped rather than repaired after the fact, so there is never a render in
	// which the pick points past the end of the list it belongs to.
	const pick = Math.min(picked, matches.length - 1);
	const take = (name: string) => {
		onTake(name);
		setPicked(-1);
	};
	return {
		aria: completing
			? {
				role: "combobox",
				"aria-autocomplete": "list",
				"aria-expanded": listing,
				// Named only while it stands: pointing at an element that is not
				// there is a dangling reference, and a reader following it lands
				// nowhere.
				...(listing ? { "aria-controls": id + "Offers" } : {}),
				...(listing && pick >= 0 ? { "aria-activedescendant": `${id}Offer-${pick}` } : {}),
			}
			: {},
		typed: () => setPicked(-1),
		keyDown: (event) => {
			if (!listing) return false;
			// The arrows walk the names and wrap, so the last is one press from the
			// first. The composer's list uses the same keys and behavior.
			if (event.key === "ArrowDown" || event.key === "ArrowUp") {
				event.preventDefault();
				const step = event.key === "ArrowDown" ? 1 : -1;
				const from = pick < 0 ? (step === 1 ? -1 : 0) : pick;
				setPicked((from + step + matches.length) % matches.length);
				return true;
			}
			if (pick < 0) return false;
			if (event.key === "Escape") {
				// A step back rather than a way out: the list goes down and the panel
				// and the words stay standing. Held from the window, which reads the
				// same press as "leave this screen".
				event.stopPropagation();
				setPicked(-1);
				return true;
			}
			if (event.key === "Enter") {
				// Take the name and stop. There is nothing else in this field to
				// type, so the second Enter is what submits: filling and submitting
				// on one press would open a room from a row just arrived at.
				event.preventDefault();
				take(matches[pick]);
				return true;
			}
			return false;
		},
		list: listing
			? (
				<div id={id + "Offers"} className="complete-pop suggest-pop" role="listbox" aria-label={label}>
					{matches.map((name, i) => (
						<button
							key={name}
							id={`${id}Offer-${i}`}
							type="button"
							role="option"
							tabIndex={-1}
							aria-selected={i === pick}
							className={i === pick ? "complete-row picked" : "complete-row"}
							// Caught before the caret moves, so picking never blurs the
							// field it is filling.
							onMouseDown={(event) => event.preventDefault()}
							onMouseEnter={() => setPicked(i)}
							onClick={() => take(name)}
						>
							<span className="complete-label">{sigil}{name}</span>
						</button>
					))}
				</div>
			)
			: null,
	};
}
