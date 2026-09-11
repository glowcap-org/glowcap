// The "+" and the field it opens: name a room, or name somebody to write to.
//
// Each of the rail's two lists holds one. They are the same panel with
// different words in it, and where a room lands is something this panel states
// and offers to change rather than something the place it sits in decides, so
// it lives here rather than inside either list.

import { type ReactNode, useEffect, useRef, useState } from "react";
import { useDismissOnClickOutside } from "../hooks.ts";
import { MenuLayer, useMenu } from "../Menu.tsx";
import { tooLong } from "../text.ts";
import { identifierField } from "../field.ts";
import { useSuggest } from "../Suggest.tsx";
import { Icon } from "../icons.tsx";
import { roomMarkGlyph } from "../room_mark.tsx";
import { IconButton } from "../IconButton.tsx";
import { Button } from "../Button.tsx";
import { nextRoomPreset, type RoomPreset } from "../room_policy.ts";

/** One "+" and the field under it, wherever it is being held.
 *
 * The panel and the toggle are two elements in two parents — the toggle sits on
 * a heading's line and the field opens under it — so they are named to each
 * other by `id` rather than by a shared ref: `id` is the toggle's `aria-controls`
 * and the dismissal region already names both halves that way, and one contract
 * is better than two that can drift. */
export interface AddField {
	/** This panel's element id. Its toggle is that id with `Btn` on the end and
	 * its input that id with `Input`, which is also what the proofs press. */
	id: string;
	/** Whether this is the open panel. The rail owns the at-most-one rule, so a
	 * panel only needs the answer. */
	open: boolean;
	label: string;
	placeholder: string;
	max: number;
	/** What this panel calls the thing being named, for the one message that
	 * needs it. The message itself is built here, so two panels cannot word the
	 * same refusal differently. */
	noun: string;
	canAdd: boolean;
	/** Whether this panel can make the thing being named a private one: offered
	 * for rooms, where a reference is the only way in, and not for a direct
	 * line, which is private by being between two people. */
	canChooseAccess?: boolean;
	onOpen: (open: boolean) => void;
	onSubmit: (value: string, preset: RoomPreset) => void;
	/** Present while this field is another form's remote control: the value and
	 * lock live there, typing here writes there, and Enter submits that form
	 * instead of `onSubmit`. Closing the panel then keeps what was typed,
	 * because the other form is still showing it.
	 *
	 * That form is also the rest of this panel. The two are one form drawn
	 * twice, so a press or a caret landing over there is not "somewhere else",
	 * and neither the blur nor the outside-click dismissal takes this panel away
	 * for it. What does take it away is the pair ending: the panel closes when a
	 * conversation opens, which is exactly when there is no longer a form for it
	 * to be a view of. */
	link?: {
		/** The other form, as a selector. One place names it, so the panel that
		 * submits it and the panel that stays open for it cannot come to
		 * disagree about which form that is. */
		form: string;
		value: string;
		roomPreset: RoomPreset;
		/** Whether that standing is the room's own rather than a choice: set for
		 * a name a directory already answers to, and while no listing has
		 * arrived to say either way. The control still shows the standing, so a
		 * reader can see what they would be walking into. */
		accessFixed?: boolean;
		onValue: (value: string) => void;
		onRoomPreset: (preset: RoomPreset) => void;
	};
	/** Offered when this panel can also reach somewhere this tab does not hold
	 * yet. Absent means the panel has no elsewhere: a direct line is opened from
	 * a roster, so there is no address to go and find. Absent too while `picks`
	 * is present, because then the destination is changed here rather than by
	 * stepping out to change it. */
	onElsewhere?: (value: string) => void;
	/** Offered when the destination can be changed without leaving: the rows to
	 * hang under the line that names it. `close` puts the menu away, so a row
	 * can pick and dismiss in one press.
	 *
	 * The menu's mechanics live here and its contents do not, because a panel
	 * knows about a field while only the rail knows what a directory is. */
	picks?: (close: () => void) => ReactNode;
	/** Names this field can finish for a reader: the rooms a directory is
	 * advertising, or the people it says are reachable.
	 *
	 * Offered rather than enforced. Both fields name something that may not exist
	 * yet — a room is made by opening it — so what is typed always wins and the
	 * list is a shortcut past typing a name in full, never a set to choose from.
	 * Absent leaves the field exactly as it was. */
	offers?: readonly string[];
	/** The mark this panel's rows wear, worn by the panel too so the thing being
	 * named looks like the things already named. */
	sigil: string;
	/** Where what is typed here will land, and which mark that directory wears.
	 * Absent when the panel has no destination to state — a direct line is
	 * opened on whichever directory the person is already on. */
	where?: { name: string; mark?: string };
	onError: (text: string) => void;
}

/** The "+" that opens one. It sits on a heading's line rather than in the panel,
 * so it is its own element and knows its panel by id. */
export function AddButton({ id, label, open, canAdd, onOpen }: {
	id: string;
	label: string;
	open: boolean;
	canAdd: boolean;
	onOpen: (open: boolean) => void;
}) {
	return (
		<IconButton
			id={id + "Btn"}
			icon="plus"
			label={label}
			size="small"
			variant="ghost"
			tone="accent"
			aria-controls={id}
			aria-expanded={open && canAdd}
			hidden={!canAdd}
			onClick={() => onOpen(!(open && canAdd))}
		/>
	);
}

/** The field itself.
 *
 * What is typed into it is this component's own state and nowhere else. It is
 * not a store fact, because nothing outside reads a half-typed name; and it is
 * not left in the DOM, because a value the element holds outlives the field
 * being closed, the conversation being switched, and the room being lost — the
 * page would then reopen a field still carrying a name from some earlier
 * intention. */
export function NamePanel(
	{
		id,
		open,
		label,
		placeholder,
		max,
		noun,
		canAdd,
		canChooseAccess,
		onOpen,
		onSubmit,
		link,
		onElsewhere,
		picks,
		offers,
		sigil,
		where,
		onError,
	}: AddField,
) {
	const field = useRef<HTMLInputElement>(null);
	// The destination menu, when this panel has one. Its holder is the panel
	// itself, so a press on the line that opens it — or anywhere else the panel
	// offers — is not "somewhere else".
	const { open: picking, setOpen: setPicking, holder: panel, trigger: elsewhere, layer } = useMenu();
	const [localValue, setLocalValue] = useState("");
	const [localRoomPreset, setLocalRoomPreset] = useState<RoomPreset>("open");
	// Linked, the field is a second view of the join card's answers; alone, it
	// keeps its own ephemeral state, which closing still empties.
	const value = link?.value ?? localValue;
	const roomPreset = link?.roomPreset ?? localRoomPreset;
	const secret = roomPreset === "private";
	const setValue = link?.onValue ?? setLocalValue;
	const setRoomPreset = link?.onRoomPreset ?? setLocalRoomPreset;
	const showing = open && canAdd;
	// The panel's list of names has its own layer: it and the directory menu are
	// two things this one panel can put on screen.
	const offered = useRef<HTMLDivElement>(null);
	const suggest = useSuggest({
		id,
		label,
		offers,
		value,
		sigil,
		// Back to the field afterwards, because a press that left the caret
		// elsewhere would blur it and put this panel away on the way to its own row.
		onTake: (name) => {
			setValue(name);
			field.current?.focus();
		},
	});

	// The toggle, by the id it is given rather than by a ref: it is rendered by
	// whichever heading holds this panel, and the dismissal region below already
	// names it this way.
	const toggle = () => document.getElementById(id + "Btn");

	// The field exists to be typed in, so it takes the caret as it opens.
	//
	// A panel that closes takes its menu and its draft with it. Left standing,
	// the menu's open state would outlive the panel and the next opening would
	// find rows hanging under a line nobody had pressed; the draft would come
	// back naming something the reader meant a while ago. Both are kept here,
	// on the panel actually closing, rather than in the verb that closes it,
	// because the panel is also put away by a conversation opening and that
	// path calls no verb of this component's. Only the unlinked draft is this
	// panel's to forget: linked, the value belongs to the other form, which is
	// still showing it.
	useEffect(() => {
		if (showing) {
			field.current?.focus();
			return;
		}
		setPicking(false);
		if (link == null) {
			setLocalValue("");
			setLocalRoomPreset("open");
		}
	}, [showing]);

	// The other form counts as inside, so a press over there leaves this panel
	// standing; see `link` above.
	// This panel's own menu counts as inside it. It is drawn at the end of the
	// document so that scrolling to a row cannot scroll the rail out from under
	// it, which takes it off the path a press travels; it names this panel, and
	// this panel names it back.
	const mine = `#${id}, #${id}Btn, [data-menu-in="${id}"]`;
	const region = link == null ? mine : `${mine}, ${link.form}`;
	useDismissOnClickOutside(showing, region, () => onOpen(false));

	// Closing takes the field out of the tab order, so focus goes back to the
	// toggle rather than being left on `<body>` with nowhere to tab from. What
	// the field held is forgotten by the effect above, which sees every close
	// and not only this one.
	const close = () => {
		onOpen(false);
		toggle()?.focus();
	};

	return (
		<div id={id} ref={panel} className={showing ? "newroom show" : "newroom"} data-dir={where?.mark}>
			{
				/* The mark the thing being named will wear, so choosing private
				   changes the name in front of the reader rather than only the
				   control they pressed. */
			}
			<span className="hash" aria-hidden="true">
				{roomPreset === "open" ? sigil : roomMarkGlyph(roomPreset, 13)}
			</span>
			<input
				id={id + "Input"}
				ref={field}
				placeholder={secret ? "private room name" : placeholder}
				enterKeyHint="go"
				aria-label={label}
				maxLength={max}
				value={value}
				{...suggest.aria}
				onChange={(e) => {
					setValue(e.target.value);
					suggest.typed();
				}}
				{...identifierField}
				onBlur={(e) => {
					// Linked, the caret leaving is not the panel's business at all.
					// Its life belongs to the other form: it is put away when a
					// conversation opens, or by a press outside both halves, and
					// walking from one half to the other is ordinary. The rule has
					// to be that broad rather than "unless focus went to the other
					// form", because the other form's own lock suppresses the focus
					// shift to keep the caret in the field it belongs to, so the
					// blur it does cause names no related target to recognize.
					if (link != null) return;
					// Alone, the field is the whole panel and losing the caret ends
					// it. Except when the focus is staying inside this panel, or
					// going to the toggle that owns it. The toggle is about to
					// decide the field's fate and would otherwise find it already
					// closed and open it straight back. Everything else the panel
					// offers — the lock, the line that names the destination, the
					// rows of the menu that line opens — lives inside it, so closing
					// on the way to any of them put the panel away before the press
					// could land. That is exactly what a keyboard reader does, since
					// reaching them means tabbing off the field.
					//
					// Asked as containment rather than as a list of the controls,
					// because the list was already wrong once: the menu's rows are
					// this panel's too, and naming each new control here is how the
					// next one gets forgotten.
					const to = e.relatedTarget;
					if (to !== toggle() && !(to instanceof Node && panel.current?.contains(to) === true)) {
						onOpen(false);
					}
				}}
				onKeyDown={(e) => {
					// The list first: while a row is picked, the arrows, Enter and
					// Escape are all about the list rather than about the field.
					if (suggest.keyDown(e)) return;
					if (e.key === "Escape") {
						// This field consumed the key. Say so, or the window handler
						// treats the same press as "close the rooms list" and the
						// phone loses the whole screen the field was sitting on.
						e.stopPropagation();
						close();
						return;
					}
					if (e.key !== "Enter") return;
					// Cancel the default so the Enter cannot fall through to the
					// composer we are about to focus and land as a stray newline.
					e.preventDefault();
					if (link != null) {
						// The other form owns submission, defaults included: an
						// empty name there means the default room, so it means
						// that here too. This panel is left standing, because a
						// join that is refused leaves that form up with its
						// reason on it and this field is still the same field;
						// a join that lands opens a conversation, and that is
						// what puts the panel away.
						document.querySelector<HTMLFormElement>(link.form)?.requestSubmit();
						return;
					}
					const named = value;
					if (!named) return;
					if (named.length > max) {
						onError(tooLong(noun, max, "characters"));
						return;
					}
					close();
					onSubmit(named, roomPreset);
				}}
			/>
			{
				/* Inside the panel, because the panel closes when the caret leaves it
				   and decides that by containment: a list rendered anywhere else would
				   put the panel away on the way to its own rows. */
			}
			{suggest.list !== null && (
				<MenuLayer holder={panel} layer={offered} owner={id} className="rail-offers">
					{suggest.list}
				</MenuLayer>
			)}
			{canChooseAccess === true && (
				// Inside the panel, beside the field, because it is part of naming
				// this room rather than a setting somewhere: pressing it changes
				// what Enter is about to make. Focus is put back in the field
				// afterwards, because a press that left it elsewhere would blur the
				// field and put the panel away on the way to its own control.
				<IconButton
					icon={roomPreset === "private" ? "lock" : roomPreset === "moderated" ? "observer" : "group"}
					className="newroom-private"
					label={link?.accessFixed === true
						? `Room access: ${roomPreset}. Not this session's to change.`
						: `Room access: ${roomPreset}. Change to ${nextRoomPreset(roomPreset)}.`}
					size="small"
					variant="ghost"
					disabled={link?.accessFixed === true}
					onMouseDown={(event) => event.preventDefault()}
					onClick={() => {
						setRoomPreset(nextRoomPreset(roomPreset));
						field.current?.focus();
					}}
				/>
			)}
			{where !== undefined && (picks !== undefined || onElsewhere !== undefined) && (
				// The same line a room's group carries over it, saying where the room
				// being named will land rather than where rooms already named live. A
				// heading reports a directory and opens what is known about it; this
				// one changes where the naming is aimed, so the word that acts sits
				// beside the destination and the destination itself is not a control.
				//
				// With the card up the change happens here, in a menu of the
				// directories this tab holds: that card and this panel are two
				// views of one answer, and a reader who can retype the room name
				// in either should not have to cross the page to retarget it.
				// Without a card there is nothing to be a second view of, so the
				// press steps out to the one surface that can dial an address —
				// carrying whatever has been typed, and the directory this panel
				// was naming, so nothing has to be picked again.
				<Button
					variant="caption"
					ref={elsewhere}
					id={id + "Elsewhere"}
					className="rwhere"
					title={where.name}
					aria-haspopup={picks !== undefined ? "menu" : undefined}
					aria-expanded={picks !== undefined ? picking : undefined}
					// Both halves are said out loud here, because a reader using the
					// accessible name gets no separator to tell them apart.
					aria-label={"Change directory. This " + noun.replace(/ name$/, "") + " is going in " +
						where.name}
					// The field's blur closes this panel, so a press that moved focus
					// would take its own target away before it landed. Preventing the
					// pointer's default keeps the caret in the field; it suppresses
					// the focus shift and nothing else, so the click still follows.
					//
					// The action belongs on the click and not on the press, because a
					// button reached by keyboard fires click alone — Enter and Space
					// raise no mousedown at all, and neither does a screen reader's
					// activation. Acting on mousedown left this control focusable,
					// visibly focused, and dead.
					onMouseDown={(e) => e.preventDefault()}
					onClick={() => {
						if (picks !== undefined) {
							setPicking((was) => !was);
							return;
						}
						// This press hands off to the join card rather than opening the
						// menu. Clear any menu intent retained across the panel's linked
						// and unlinked forms before the card makes picks eligible again.
						// The panel stays: the press is about to put a form on
						// screen that this field becomes a second view of, and
						// taking the field away at the moment it gains its
						// other half is the opposite of what the press meant.
						onElsewhere?.(value);
					}}
				>
					<Icon name="directory" size={12} />
					<span className="rwhere-said">in {where.name}</span>
					<span className="rwhere-change">Change</span>
				</Button>
			)}
			{picks !== undefined && picking && (
				<MenuLayer holder={panel} layer={layer} owner={id}>
					{picks(() => {
						setPicking(false);
						// Back to the name being typed, which is what the reader was
						// doing before they said where it lands.
						field.current?.focus();
					})}
				</MenuLayer>
			)}
		</div>
	);
}
