// The card the page opens with, and the one it comes back to when you leave a
// room without entering another.
//
// Joining is an async action, so React owns the pending state: the button reads
// "Joining…" for exactly as long as the join is outstanding, including the part
// where the peer session is still opening. That window used to be its own
// bookkeeping — a staged request, a button label written by hand, and a reset
// called from every path that might end the wait — because there was nothing
// holding "this is in flight" except the label itself.

import { memo, useActionState, useRef } from "react";
import { MAX_NICK, MAX_ROOM, nickRefusal } from "../../lib/limits.ts";
import { tooLong } from "./text.ts";
import { identifierField } from "./field.ts";
import { useRoomsBrowser } from "./controller/browser.ts";
import { useRoomsSession } from "./controller/session.ts";
import { useSessionPaused } from "./hooks.ts";
import { useSuggest } from "./Suggest.tsx";
import { Avatar } from "./Avatar.tsx";
import { Button } from "./Button.tsx";
import { Icon } from "./icons.tsx";
import { nextRoomPreset, policyForRoomPreset } from "../../lib/room/policy.ts";
import {
	destination,
	type DirectoryDestinationContext,
	JOIN_DEFAULT_NICK,
	JOIN_DEFAULT_ROOM,
	type JoinAnswers,
	joinLead,
	joinLocatorPlaceholder,
	looksLikeRoomLink,
	resolveJoin,
	thisDirectoryLocator,
	typedRoomLink,
} from "./joining.ts";
import { DirectoryPicks, typeAnotherAddress } from "./DirectoryPicks.tsx";
import { JoinField, JoinPrefix } from "./JoinField.tsx";
import { roomMarkGlyph } from "./room_mark.tsx";
import { MenuLayer, useMenu } from "./Menu.tsx";
import { Said } from "./Said.tsx";
import { type DirId, type DirView, liveRoomNames } from "./types.ts";
import { WorkingAction } from "./WorkingAction.tsx";

type JoinError = { field: "locator" | "room" | "nick" | "form"; text: string } | null;

export const JoinCard = memo(function JoinCard(
	{ shown, answers, dirs, directoryContext, canInteract }: {
		shown: boolean;
		canInteract: boolean;
		/** Every field, with the evidence behind it. Resolved from the act that
		 * put this card up rather than held as state, so the same card is a gate
		 * on a link and a blank form from the rail without either one having to
		 * clear up after the other. The lock rides along for the same reason the
		 * others do: the rail's room panel names this room too, and its lock has
		 * to be this lock. */
		answers: JoinAnswers;
		/** Every directory this tab already holds. Offered from the locator field's
		 * own mark, so an address that is already known does not have to be typed
		 * or pasted again. */
		dirs: ReadonlyMap<DirId, DirView>;
		directoryContext: DirectoryDestinationContext;
	},
) {
	const browser = useRoomsBrowser();
	const session = useRoomsSession();
	/** A link held at nothing, which is not the same as one held to reading.
	 * Asked separately from `canInteract`, because that answers what the reader
	 * may do and this answers what there is to do it to. */
	const paused = useSessionPaused();
	const homeDir = directoryContext.home;
	const room = answers.room.value;
	const locator = answers.locator.value;
	const nick = answers.nick.value;
	const roomPreset = answers.roomPreset.value;
	const secret = roomPreset === "private";
	const defaultDirectoryAddress = directoryContext.defaultDirectory?.locator ?? null;
	const asLink = typedRoomLink(locator, room) !== null;
	// What the world says about what has been asked for. Resolved on every
	// render and never written back: the reader's own standing outlives a
	// directory that happens to hold the name, and comes back the moment they
	// point somewhere else. The rail's own control reads this same answer, so
	// the two cannot disagree about one question.
	const resolved = resolveJoin(answers, dirs, homeDir, (at) => session.directoryId(at));
	const { standing } = resolved;
	const wantedRoom = room.trim();
	// The card asks one question at a time. A directory the reader named and this
	// tab has not reached has no listing, so there is nothing here that could
	// tell one room from another, name a standing, or say whether a name makes a
	// room or enters one. So the card asks for the directory first and the room
	// after, and its one act reaches rather than joins until it has.
	//
	// One control either way. A second button beside the submit would be two
	// controls for one question, and a reader would have to work out which of
	// them their typing was for.
	const reaching = resolved.act === "connect";
	const making = resolved.act === "create";
	const halt = useRef<AbortController | null>(null);
	const [error, join, joining] = useActionState(async (_was: JoinError, form: FormData): Promise<JoinError> => {
		halt.current?.abort();
		const run = new AbortController();
		halt.current = run;
		const typedNick = String(form.get("nick") ?? "");
		const nick = typedNick === "" ? JOIN_DEFAULT_NICK : typedNick;
		// Checked before either act, because the field belongs to the card rather
		// than to one of the two things submitting can mean.
		if (nick.length > MAX_NICK) return { field: "nick", text: tooLong("name", MAX_NICK, "characters") };
		const nickWhy = nickRefusal(nick);
		if (nickWhy != null) return { field: "nick", text: nickWhy };
		const typedText = String(form.get("locator") ?? "");
		const typedRoom = String(form.get("room") ?? "");
		// The submitted locator decides the act, not the flag from the render that
		// built this closure: Connect is reaching that address, and a refusal has
		// to land on it rather than on the join the button is not performing.
		const submitted = resolveJoin(
			{
				...answers,
				locator: { ...answers.locator, value: typedText },
				room: { ...answers.room, value: typedRoom },
				nick: { ...answers.nick, value: typedNick },
			},
			dirs,
			homeDir,
			(at) => session.directoryId(at),
		);
		try {
			if (submitted.act === "connect") {
				const why = await session.reachDirectory(typedText, nick, run.signal);
				if (run.signal.aborted) return null;
				return why === "" ? null : { field: "locator", text: why };
			}
			// Empty, the bare home authority, and home's hinted route are one
			// destination: this page's own directory, reached over the session
			// already open rather than by a fresh dial. A room link is none of
			// those: collapsing it to home would drop the swissnum.
			const typed = thisDirectoryLocator(typedText, directoryContext, session.directoryId(typedText.trim()));
			const locator = typed;
			const linked = typedRoomLink(locator, typedRoom);
			// A remembered room name is from a previous join, not a name for this
			// link. Only a name the reader typed under this paste is a label.
			const namedTheLink = linked !== null &&
				(answers.room.from === "edited" || answers.room.from === "named");
			const room = linked !== null ? (namedTheLink ? linked.label : "") : typedRoom || JOIN_DEFAULT_ROOM;
			if (room.length > MAX_ROOM) return { field: "room", text: tooLong("room name", MAX_ROOM, "characters") };
			const text = await session.join(
				{
					room,
					locator: linked !== null ? linked.link : locator,
					// A room that already answers to this name has its own standing,
					// and this session is not the one that sets it. Same answer the
					// control reads, so what the card showed is what the act sends.
					hidden: linked !== null || submitted.fixed ? false : secret,
					policy: linked !== null || submitted.fixed ? undefined : policyForRoomPreset(roomPreset),
				},
				nick,
				run.signal,
			);
			if (run.signal.aborted) return null;
			if (text !== "") return { field: "form", text };
			// The lock is an intention about the room just made, and it is now
			// spent: left pressed, the next name typed here would mint a private
			// room nobody asked for.
			if (roomPreset !== "open") browser.editJoin({ roomPreset: "open" });
			return null;
		} catch (err) {
			if (run.signal.aborted) return null;
			const text = err instanceof Error ? err.message : String(err);
			return { field: submitted.act === "connect" ? "locator" : "form", text };
		} finally {
			if (halt.current === run) halt.current = null;
		}
	}, null);
	// The card's top stripe stays accent into teal for home, matching Settings,
	// and swaps only the teal stop for a foreign directory's mark. The rail's
	// room panel is aimed by the same field, and asks the same question of the
	// same answer.
	const field = useRef<HTMLInputElement>(null);
	const aimed = destination(
		locator,
		session.directoryId(locator.trim()),
		dirs,
		directoryContext,
		"this page's directory",
	);
	const who = nick === "" ? JOIN_DEFAULT_NICK : nick;
	// The same names the rail's room panel offers, because this field and that
	// one name one room: they share a draft and a lock, and offering in one and
	// not the other would make the same words behave differently depending on
	// which half of the pair the reader happened to be typing in.
	//
	// Rooms on the directory this card is aimed at, which moves with the locator
	// above: a name advertised somewhere else would open a different room.
	const aimedAt = session.directoryId(locator.trim()) ?? homeDir;
	const roomOffers = asLink || aimedAt == null ? [] : liveRoomNames(dirs.get(aimedAt)?.liveRooms ?? new Map());
	// The box the list of room names is measured from, and the layer it is drawn
	// in. Its own, not the locator menu's: the two can be open at once.
	const roomWrap = useRef<HTMLDivElement>(null);
	const roomOffered = useRef<HTMLDivElement>(null);
	const suggest = useSuggest({
		id: "room",
		label: asLink ? "Call it" : "Room",
		offers: roomOffers,
		value: room,
		sigil: "#",
		onTake: (name) => {
			browser.editJoin({ room: name });
			field.current?.focus();
		},
	});

	return (
		<div className="join-wrap" id="joinScreen" hidden={!shown}>
			<form id="joinForm" className="join" data-dir={aimed.mark} action={join}>
				<h2>{making ? "Create a room" : "Join a room"}</h2>
				<p className="lead">
					{paused
						// Not the read-only sentence, which promises browsing. A paused
						// link is answered with no session at all, so there is nothing
						// here to browse either, and this is the card a reader lands on
						// when there is nothing else to show them.
						? "This session capability is paused, so there is nothing here to browse or join."
						: canInteract
						? joinLead(answers, aimed.name)
						: "This session capability can browse the shared rooms but cannot join one."}
				</p>
				<div className="join-fields" inert={joining || !canInteract || undefined}>
					<label htmlFor="locator">
						{asLink ? "Room entry link" : (
							<>
								Directory locator{" "}
								<span className="optional">
									{homeDir == null && defaultDirectoryAddress != null ? "This page" : "Optional"}
								</span>
							</>
						)}
					</label>
					<JoinLocator
						locator={locator}
						dirs={dirs}
						defaultAddress={defaultDirectoryAddress}
						directoryContext={directoryContext}
						invalid={error?.field === "locator"}
						onPick={(next) => browser.editJoin({ locator: next })}
						onType={(next) => browser.editJoin({ locator: next })}
					/>
					{
						/* Connect is reaching this address. A refusal belongs under it,
					    not under the name or as a leftover of the join the button is
					    not performing. */
					}
					{error?.field === "locator" && error.text !== "" && (
						<Said id="joinError" kind="failure">{error.text}</Said>
					)}
					{
						/* Out until the directory can describe what naming a room there
					    would do. */
					}
					{!reaching && (
						<label htmlFor="room">
							{asLink
								? "Call it"
								: roomPreset === "private"
								? "Private room"
								: roomPreset === "moderated"
								? "Moderated room"
								: "Room"}
						</label>
					)}
					{
						/* The list hangs off this box rather than off the field, so it
					    lines up with the field's outer edge and not with the inside
					    of the lock that stands before it. */
					}
					<div className="join-field-wrap" hidden={reaching} ref={roomWrap}>
						<JoinField invalid={error?.field === "room"}>
							{asLink ? undefined : (
								<JoinPrefix
									id="joinPrivate"
									disabled={resolved.fixed}
									// One answer drives both halves of this control. Keying the
									// label and the disabled state to separate conditions is how
									// they come to say different things about one question.
									label={resolved.fixed
										? `Room access: ${standing}. The room called ${wantedRoom} already exists, and its manager sets this.`
										: `Room access: ${standing}. Change to ${nextRoomPreset(standing)}.`}
									onMouseDown={(event) => event.preventDefault()}
									onClick={() => browser.editJoin({ roomPreset: nextRoomPreset(standing) })}
								>
									{standing === "open"
										? <span className="join-hash" aria-hidden="true">#</span>
										: roomMarkGlyph(standing, 18)}
								</JoinPrefix>
							)}
							<input
								ref={field}
								id="room"
								name="room"
								placeholder={asLink ? "a room" : JOIN_DEFAULT_ROOM}
								enterKeyHint="next"
								aria-describedby={error?.field === "room" ? "joinError" : undefined}
								aria-invalid={error?.field === "room"}
								maxLength={looksLikeRoomLink(room) ? undefined : MAX_ROOM}
								value={room}
								{...suggest.aria}
								onChange={(e) => {
									browser.editJoin({ room: e.target.value });
									suggest.typed();
								}}
								onPaste={(e) => {
									const text = e.clipboardData.getData("text").trim();
									if (!looksLikeRoomLink(text)) return;
									e.preventDefault();
									browser.editJoin({ locator: text });
								}}
								onKeyDown={(e) => {
									// The list first: while a row is picked, the arrows,
									// Enter and Escape are the list's rather than the form's,
									// and Enter here would otherwise submit the card.
									suggest.keyDown(e);
								}}
								{...identifierField}
							/>
						</JoinField>
						{suggest.list !== null && (
							<MenuLayer holder={roomWrap} layer={roomOffered} owner="joinForm" className="join-offers">
								{suggest.list}
							</MenuLayer>
						)}
					</div>
					<label htmlFor="nick">Display name</label>
					<JoinField invalid={error?.field === "nick"}>
						<JoinPrefix label="A picture of you. Choosing one is not offered yet.">
							<Avatar name={who} />
						</JoinPrefix>
						<input
							id="nick"
							name="nick"
							placeholder={JOIN_DEFAULT_NICK}
							enterKeyHint="go"
							{...identifierField}
							autoComplete="nickname"
							aria-describedby={error?.field === "nick" ? "joinError" : undefined}
							aria-invalid={error?.field === "nick"}
							maxLength={MAX_NICK}
							value={nick}
							onChange={(e) => browser.editJoin({ nick: e.target.value })}
						/>
					</JoinField>
				</div>
				{error != null && error.field !== "locator" && error.text !== "" && (
					<Said id="joinError" kind="failure">{error.text}</Said>
				)}
				{
					/* The act, named as what pressing it does now. Busy is this card's
				    own act and nothing else: the stop beside it aborts what this press
				    started, so wearing another's work would put a stop on the card with
				    nothing behind it. */
				}
				<WorkingAction
					type="submit"
					id="joinBtn"
					size="large"
					block
					busy={joining}
					disabled={!canInteract}
					stopId="joinStop"
					stopLabel={reaching ? "Stop connecting" : making ? "Stop creating" : "Stop joining"}
					onStop={() => halt.current?.abort()}
				>
					{paused
						? "Session paused"
						: !canInteract
						? "Read-only session"
						: reaching
						? (joining ? "Connecting…" : "Connect")
						: joining
						? (making ? "Creating…" : "Joining…")
						: making
						? "Create room"
						: "Join room"}
				</WorkingAction>
				{
					/* The phone's way to the rooms screen before anything is open. A
				    paused link has no rooms to go to and the screen it opens says so,
				    which makes this an offer with nothing behind it; the rail is still
				    a tap away on the header. */
				}
				{!paused && (
					<Button
						id="browseRoomsBtn"
						variant="quiet"
						onClick={() => browser.showRail(true)}
					>
						Browse live rooms
					</Button>
				)}
			</form>
		</div>
	);
});

function JoinLocator(
	{ locator, dirs, defaultAddress, directoryContext, invalid, onPick, onType }: {
		locator: string;
		dirs: ReadonlyMap<DirId, DirView>;
		defaultAddress: string | null;
		directoryContext: DirectoryDestinationContext;
		invalid?: boolean;
		onPick: (locator: string) => void;
		onType: (locator: string) => void;
	},
) {
	const { open, setOpen, holder, trigger, layer } = useMenu();
	return (
		<div className="join-field-wrap" ref={holder}>
			<JoinField invalid={invalid}>
				<JoinPrefix
					id="joinLocator"
					ref={trigger}
					className="join-prefix-dir"
					label={open ? "Hide held directories" : "Choose a held directory"}
					aria-haspopup="menu"
					aria-expanded={open}
					onClick={() => setOpen((was) => !was)}
				>
					<Icon name="directory" size={18} />
				</JoinPrefix>
				<input
					id="locator"
					name="locator"
					type="text"
					inputMode="url"
					enterKeyHint="next"
					placeholder={joinLocatorPlaceholder(defaultAddress)}
					value={locator}
					aria-describedby={invalid === true ? "joinError" : undefined}
					aria-invalid={invalid === true}
					onChange={(e) => onType(e.target.value)}
					{...identifierField}
				/>
			</JoinField>
			{
				/* The addresses already in hand, from the mark that stands for this
				    field. A locator is forty characters nobody can retype, and every one
				    of these was typed or pasted once already; the only reason the field
				    is empty on the way back to it is that the field is where a *new* one
				    goes. Leaving it empty means this page's own directory, so that one
				    clears rather than fills. The last row is the way to an address that
				    is in none of them, and here it is the short way: the field it hands
				    over is the one this menu hangs from. */
			}
			{open && (
				<MenuLayer holder={holder} layer={layer} owner="joinForm">
					<DirectoryPicks
						className="locator-picks"
						locator={locator}
						dirs={dirs}
						context={directoryContext}
						onPick={(picked) => {
							setOpen(false);
							onPick(picked);
						}}
						onElsewhere={() => typeAnotherAddress(() => setOpen(false))}
					/>
				</MenuLayer>
			)}
		</div>
	);
}
