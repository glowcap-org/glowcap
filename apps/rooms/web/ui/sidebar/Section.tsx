// One rail section: a heading, an optional "+" field, and the rows.
//
// The two "+" fields behave identically, so they are one component used twice.

import { type ReactNode, useEffect, useRef, useState } from "react";
import { useDismissOnClickOutside } from "../hooks.ts";
import { tooLong } from "../text.ts";
import { identifierField } from "../field.ts";
import { Icon } from "../icons.tsx";
import { IconButton } from "../IconButton.tsx";
import { Button } from "../Button.tsx";

/** Which "+" field is open. At most one is, so this is one value rather than a
 * flag per section that could both be true. */
export type PanelName = "room" | "dm";

/** One section of the rail: a heading, an optional "+" field under it, and the
 * rows.
 *
 * The two sections differ only in what they are called and what they list, so
 * this is one component used twice. The field sits *after* the heading rather
 * than inside it, which the stylesheet depends on: the heading is a flex row, and
 * a field inside it would land beside the "+" instead of below it.
 *
 * What is typed into that field is this component's own state and nowhere else.
 * It is not a store fact, because nothing outside this section reads a
 * half-typed name; and it is not left in the DOM, because a value the element
 * holds outlives the field being closed, the conversation being switched, and
 * the room being lost — the page would then reopen a field still carrying a name
 * from some earlier intention. */
export function RailSection(
	{
		id,
		className,
		title,
		listId,
		open,
		label,
		placeholder,
		max,
		noun,
		canAdd,
		canBePrivate,
		onOpen,
		onSubmit,
		link,
		onElsewhere,
		sigil,
		where,
		onError,
		children,
	}: {
		id: string;
		className?: string;
		title: string;
		listId: string;
		/** Whether this section's field is the open one. The rail owns the
		 * at-most-one rule, so a section only needs the answer, not the identity
		 * of whichever other section might hold it. */
		open: boolean;
		label: string;
		placeholder: string;
		max: number;
		/** What this section calls the thing being named, for the one message that
		 * needs it. The message itself is built here, so the two sections cannot
		 * word the same refusal differently. */
		noun: string;
		canAdd: boolean;
		/** Whether this section can make the thing being named a private one:
		 * offered for rooms, where a reference is the only way in, and not for a
		 * direct line, which is private by being between two people. */
		canBePrivate?: boolean;
		onOpen: (open: boolean) => void;
		onSubmit: (value: string, isPrivate: boolean) => void;
		/** Present while this section's field is another form's remote control:
		 * the value and lock live there, typing here writes there, and Enter
		 * submits that form instead of `onSubmit`. Closing the panel then keeps
		 * what was typed, because the other form is still showing it. */
		link?: {
			value: string;
			secret: boolean;
			onValue: (value: string) => void;
			onSecret: (secret: boolean) => void;
			submit: () => void;
		};
		/** Offered when this section can also reach somewhere this tab does not
		 * hold yet. Absent means the section has no elsewhere: a direct line is
		 * opened from a roster, so there is no address to go and find. */
		onElsewhere?: (value: string) => void;
		/** The mark this section's rows wear, worn by the panel too so the thing
		 * being named looks like the things already named. */
		sigil: string;
		/** Where what is typed here will land, and which mark that directory
		 * wears. Stated, never offered: this panel names a room on the directory
		 * the reader is already standing on, and choosing a different one is the
		 * join card's question. Absent when the section has no destination to
		 * state — a direct line is opened on whichever directory the person is
		 * already on. */
		where?: { name: string; mark?: string };
		onError: (text: string) => void;
		children: ReactNode;
	},
) {
	const button = useRef<HTMLButtonElement>(null);
	const field = useRef<HTMLInputElement>(null);
	const elsewhere = useRef<HTMLButtonElement>(null);
	const [localValue, setLocalValue] = useState("");
	// Asked for at the moment the room is made and never after, so it is state
	// of this panel rather than of the room list: a room cannot be made private
	// once it has been listed, nor opened up once people were invited into it.
	const [localSecret, setLocalSecret] = useState(false);
	// Linked, the field is a second view of the join card's answers; alone, it
	// keeps its own ephemeral state, which closing still empties.
	const value = link?.value ?? localValue;
	const secret = link?.secret ?? localSecret;
	const setValue = link?.onValue ?? setLocalValue;
	const setSecret = link?.onSecret ?? setLocalSecret;
	const showing = open && canAdd;

	// The field exists to be typed in, so it takes the caret as it opens.
	useEffect(() => {
		if (showing) field.current?.focus();
	}, [showing]);

	useDismissOnClickOutside(showing, `#${id}, #${id}Btn`, () => onOpen(false));

	// Closing empties the field and takes it out of the tab order, so focus goes
	// back to the toggle rather than being left on `<body>` with nowhere to tab
	// from.
	const close = () => {
		if (link == null) {
			setLocalValue("");
			setLocalSecret(false);
		}
		onOpen(false);
		button.current?.focus();
	};

	return (
		<div className={className ? "section " + className : "section"}>
			<div className="section-head">
				<span>{title}</span>
				<IconButton
					id={id + "Btn"}
					ref={button}
					icon="plus"
					label={label}
					size="small"
					variant="ghost"
					tone="accent"
					aria-controls={id}
					aria-expanded={showing}
					hidden={!canAdd}
					onClick={() => onOpen(!showing)}
				/>
			</div>
			<div id={id} className={showing ? "newroom show" : "newroom"} data-dir={where?.mark}>
				{
					/* The mark the thing being named will wear, so choosing private
				    changes the name in front of the reader rather than only the
				    control they pressed. */
				}
				<span className="hash" aria-hidden="true">
					{secret ? <Icon name="lock" size={13} /> : sigil}
				</span>
				<input
					id={id + "Input"}
					ref={field}
					placeholder={secret ? "private room name" : placeholder}
					enterKeyHint="go"
					aria-label={label}
					maxLength={max}
					value={value}
					onChange={(e) => setValue(e.target.value)}
					{...identifierField}
					onBlur={(e) => {
						// Except when focus is going to this panel's own two controls.
						// The toggle is about to decide the field's fate and would
						// otherwise find it already closed and open it straight back; the
						// step-up link lives *inside* the panel, so closing on the way to
						// it put the panel away before the press could land — which is
						// exactly what a keyboard reader does, since reaching that link
						// means tabbing off the field.
						if (e.relatedTarget !== button.current && e.relatedTarget !== elsewhere.current) {
							onOpen(false);
						}
					}}
					onKeyDown={(e) => {
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
							// that here too.
							close();
							link.submit();
							return;
						}
						const named = value.trim();
						if (!named) return;
						if (named.length > max) {
							onError(tooLong(noun, max));
							return;
						}
						close();
						onSubmit(named, secret);
					}}
				/>
				{canBePrivate === true && (
					// Inside the panel, beside the field, because it is part of naming
					// this room rather than a setting somewhere: pressing it changes
					// what Enter is about to make. Focus stays in the field, the way
					// the step-up link below keeps it, or the panel would put itself
					// away on the way to its own control.
					<IconButton
						icon="lock"
						className="newroom-private"
						label={secret
							? "Making a private room: only people you hand it to can reach it"
							: "Make this room private, so only people you hand it to can reach it"}
						size="small"
						variant="ghost"
						aria-pressed={secret}
						onMouseDown={(event) => event.preventDefault()}
						onClick={() => {
							setSecret(!secret);
							field.current?.focus();
						}}
					/>
				)}
				{where !== undefined && onElsewhere !== undefined && (
					// Two things a reader needs here, and they are not the same kind of
					// thing: where what they are naming will land, and how to send it
					// somewhere else. Said as one control they contradict each other,
					// which is what this was. The line read "in this directory", which
					// is a statement of fact, while pressing it left the rail entirely
					// for the join card — so it looked like the caption a room row
					// carries, whose press means "tell me about this directory", and
					// did something else. One skin, two verbs.
					//
					// So the fact is text and the verb is a button. The destination is
					// no longer pressable at all, which is the honest half of the fix:
					// nothing here can change it, because which directory a room lands
					// on is the join card's question — the card is this panel with that
					// question added, which is also why what has been typed goes with
					// the reader when they step up to it.
					<div className="newwhere">
						<Icon name="directory" size={12} />
						<span className="rwhere-said">in {where.name}</span>
						<Button
							// A word in a sentence, which is what this now is: the
							// line beside it states where the room lands, and this is
							// the one word on it that acts. The caption variant is the
							// other shape, a line of its own spanning a row and aimed
							// at as a line, so wearing it here drew a pill inside a
							// caption.
							variant="link"
							ref={elsewhere}
							id={id + "Elsewhere"}
							className="newwhere-change"
							// The visible word is the action, because that is what a
							// control owes a reader. The accessible name adds what it
							// acts on, which the line beside it already shows.
							aria-label={"Choose another directory for this " + noun.replace(/ name$/, "")}
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
								const named = value.trim();
								close();
								onElsewhere(named);
							}}
						>
							Change
						</Button>
					</div>
				)}
			</div>
			<ul id={listId}>{children}</ul>
		</div>
	);
}
