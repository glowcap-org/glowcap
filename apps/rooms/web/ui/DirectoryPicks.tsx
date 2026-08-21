// The directories this tab holds, as a menu.
//
// Two surfaces offer this choice and they are choosing the same thing from the
// same list: the join card's locator field, and the rail's new-room panel while
// that card is up. Which rows appear, the order they appear in, and which one
// is marked live here rather than in each of them, because a reader picking a
// directory in one and reading it back in the other has to be shown the same
// list either way.
//
// A pick fills a locator field with the full hinted route, the same address
// every share surface hands out, because that value is what a submit dials and
// the hints are part of what makes it dialable. Matching is by identity, so a
// row stays marked whether the field holds the route or the bare authority.
// Leaving it empty means this page's own directory, so that row clears rather
// than fills.
//
// The last row is the way to an address this tab does not hold, and it belongs
// to the menu rather than to a surface that adds it, because two menus
// offering the same choice have to offer the same rows. Where the surfaces
// differ is only what the row does to hand the reader a field: the card has
// one, and the rail has to bring the card forward first.

import { flushSync } from "react-dom";
import { usePeer } from "./peer.ts";
import { MenuList, MenuRow } from "./Menu.tsx";
import { directoryName } from "./text.ts";
import { thisDirectoryLocator } from "./joining.ts";
import type { DirId, DirView } from "./types.ts";

export function DirectoryPicks(
	{ className, locator, dirs, homeDir, onPick, onElsewhere }: {
		className: string;
		/** The locator field these rows are choosing for, which decides which row
		 * is marked. */
		locator: string;
		dirs: ReadonlyMap<DirId, DirView>;
		homeDir: DirId | null;
		onPick: (locator: string) => void;
		/** Take the reader where an address this tab does not hold can be typed.
		 * `typeAnotherAddress` below is the whole of it on the card; the rail
		 * brings the card forward and then calls the same thing. */
		onElsewhere: () => void;
	},
) {
	const peer = usePeer();
	const others = [...dirs.values()].filter((dir) => dir.id !== homeDir);
	const typedAs = peer.directoryId(locator.trim());
	const here = thisDirectoryLocator(locator, homeDir) === "" || (homeDir != null && typedAs === homeDir);
	return (
		<MenuList className={className}>
			<MenuRow className="line-menu-row" first marked={here} onPick={() => onPick("")}>
				this directory
			</MenuRow>
			{others.map((dir) => (
				<MenuRow
					key={dir.id}
					className="line-menu-row"
					marked={typedAs === dir.id}
					onPick={() => onPick(peer.dirAddress(dir.id))}
				>
					{directoryName(dir.id, homeDir)}
				</MenuRow>
			))}
			<MenuRow className="line-menu-row" onPick={onElsewhere}>Another address…</MenuRow>
		</MenuList>
	);
}

/** Take the reader to where an address this tab does not hold can be typed:
 * the join card's locator field, with what is there selected so the next thing
 * typed replaces it.
 *
 * Every way in ends here, which is what makes them one offer, and they differ
 * only in what it takes to make that card the surface. From the card's own
 * menu, nothing. From the rail with the card already up, a screen change,
 * which is only visible on a phone. From the rail with a room open there is no
 * card at all, so the press files the act that puts one there. `arrive` is
 * that difference and nothing else.
 *
 * It is committed rather than merely called, because the same press can be
 * what puts the card on screen: a field inside a hidden card cannot take
 * focus, and the render that unhides it would otherwise be queued behind the
 * press that asked for the caret. The field is then found in the document
 * rather than handed down, because the rail's menu is on the other side of the
 * page from the field it is handing over. */
export function typeAnotherAddress(arrive: () => void): void {
	flushSync(arrive);
	const field = document.querySelector<HTMLInputElement>("#locator");
	if (field === null) return;
	field.focus();
	field.select();
}
