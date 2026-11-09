// The directories this tab holds, as a menu.
//
// Two surfaces offer this choice and they are choosing the same thing from the
// same list: the join card's address field, and the rail's new-room panel while
// that card is up. Which rows appear, the order they appear in, and which one
// is marked live here rather than in each of them, because a reader picking a
// directory in one and reading it back in the other has to be shown the same
// list either way.
//
// A pick fills a address field with the full hinted route, the same address
// every share surface hands out, because that value is what a submit dials and
// the hints are part of what makes it dialable. Matching is by identity, so a
// row stays marked whether the field holds the route or the bare authority.
// Leaving it empty means the session's home directory, or the page's own when
// there is no home, so that row clears rather than fills. With neither, empty
// names nothing and the row is not offered.
//
// The last row is the way to an address this tab does not hold, and it belongs
// to the menu rather than to a surface that adds it, because two menus
// offering the same choice have to offer the same rows. Where the surfaces
// differ is only what the row does to hand the reader a field: the card has
// one, and the rail has to bring the card forward first.

import { flushSync } from "react-dom";
import { useRoomsSession } from "./controller/session.ts";
import { MenuList, MenuRow } from "./Menu.tsx";
import { directoryName } from "./text.ts";
import { type DirectoryDestinationContext, thisDirectoryAddress } from "./joining.ts";
import { homeDirectoryName } from "../../lib/text/directory.ts";
import { joinAddressHere } from "../../lib/text/join.ts";
import type { DirId, DirView } from "./directory.ts";
import { anotherAddress } from "../../lib/text/page.ts";

export function DirectoryPicks(
	{ className, address, dirs, context, onPick, onElsewhere }: {
		className: string;
		/** The address field these rows are choosing for, which decides which row
		 * is marked. */
		address: string;
		dirs: ReadonlyMap<DirId, DirView>;
		context: DirectoryDestinationContext;
		onPick: (address: string) => void;
		/** Take the reader where an address this tab does not hold can be typed.
		 * `typeAnotherAddress` below is the whole of it on the card. The rail
		 * brings the card forward and then calls the same thing. */
		onElsewhere: () => void;
	},
) {
	const session = useRoomsSession();
	const homeDirectory = context.home;
	const others = [...dirs.values()].filter((dir) => dir.id !== homeDirectory);
	const typedAs = session.directoryId(address.trim());
	const here = thisDirectoryAddress(address, context, typedAs) === "";
	const blank = homeDirectory != null ? homeDirectoryName : context.defaultDirectory != null ? joinAddressHere : null;
	// The served directory, when an empty address means home and this tab does
	// not hold it. A server that restarts as a new directory is reached here.
	const served = context.served != null && !dirs.has(context.served.id) ? context.served : null;
	const lead = blank != null || served != null;
	return (
		<MenuList className={className}>
			{blank != null && (
				<MenuRow className="line-menu-row" first marked={here} onPick={() => onPick("")}>
					{blank}
				</MenuRow>
			)}
			{served != null && (
				<MenuRow
					className="line-menu-row"
					first={blank == null}
					marked={typedAs === served.id}
					onPick={() => onPick(served.address)}
				>
					{joinAddressHere}
				</MenuRow>
			)}
			{others.map((dir, index) => (
				<MenuRow
					key={dir.id}
					className="line-menu-row"
					first={!lead && index === 0}
					marked={typedAs === dir.id}
					onPick={() => onPick(session.dirAddress(dir.id))}
				>
					{directoryName(dir.id, homeDirectory)}
				</MenuRow>
			))}
			<MenuRow className="line-menu-row" first={!lead && others.length === 0} onPick={onElsewhere}>
				{anotherAddress}
			</MenuRow>
		</MenuList>
	);
}

/** Take the reader to where an address this tab does not hold can be typed:
 * the join card's address field, with what is there selected so the next thing
 * typed replaces it.
 *
 * Every way in ends here as one offer. They differ only in what it takes to
 * make that card the surface. From the card's own
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
	const field = document.querySelector<HTMLInputElement>("#address");
	if (field === null) return;
	field.focus();
	field.select();
}
