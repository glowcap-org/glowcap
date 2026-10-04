// The card the page opens with, and the one it comes back to when you leave a
// room without entering another.
//
// Joining is an async action, so React owns the pending state: the button reads
// "Joining…" for exactly as long as the join is outstanding, including the part
// where the peer session is still opening. Without that, the window needs its own
// bookkeeping (a staged request, a hand-written label, and a reset on every
// path that might end the wait), with nothing but the label holding "this is
// in flight".

import { memo, useActionState, useRef } from "react";
import { avatarLabel } from "../../../lib/text/controls.ts";
import { MAX_NICK, MAX_ROOM, nickRefusal } from "../limits.ts";
import { tooLong } from "../text.ts";
import { identifierField } from "../field.ts";
import { useRoomsBrowser } from "../controller/browser.ts";
import { useRoomsSession } from "../controller/session.ts";
import { useRoomsState, useSessionPaused } from "../hooks.ts";
import { useSuggest } from "../Suggest.tsx";
import { Avatar } from "../Avatar.tsx";
import { Button } from "../Button.tsx";
import { Icon } from "../icons.tsx";
import { nextRoomPreset, policyForRoomPreset } from "../room_policy.ts";
import {
	destination,
	type DirectoryDestinationContext,
	JOIN_DEFAULT_ROOM,
	type JoinAnswers,
	joinLead,
	joinLocatorPlaceholder,
	joinNickTarget,
	type JoinResolution,
	looksLikeRoomLink,
	resolveJoin,
	suggestedJoinNick,
	thisDirectoryLocator,
	typedRoomLink,
} from "../joining.ts";
import { answerJoinNick, joinNickAvailability } from "../join_nick.ts";
import { NICK_TAKEN } from "../../../lib/error_codes.ts";
import { DirectoryPicks, typeAnotherAddress } from "../DirectoryPicks.tsx";
import { JoinField, JoinPrefix } from "./JoinField.tsx";
import { roomMarkGlyph } from "../room_mark.tsx";
import {
	joinAccessFixedLabel,
	joinAccessLabel,
	joinBrowseLiveRooms,
	joinCallIt,
	joinChooseAnotherName,
	joinChooseDirectory,
	joinConnect,
	joinConnecting,
	joinCreateRoom,
	joinCreating,
	joinHideDirectories,
	joinInstead,
	joinJoining,
	joinJoinRoom,
	joinLeadPaused,
	joinLeadReadOnly,
	joinLinkLabel,
	joinLocatorHere,
	joinLocatorHint,
	joinLocatorLabel,
	joinLocatorOptional,
	joinNickHint,
	joinNickLabel,
	joinNickTakenInRoom,
	joinNickTakenOnDirectory,
	joinReadOnlySession,
	joinSessionPaused,
	joinStopConnecting,
	joinStopCreating,
	joinStopJoining,
	joinTitleCreate,
	joinTitleJoin,
	roomFieldLabel,
} from "../../../lib/text/join.ts";
import { MenuLayer, useMenu } from "../Menu.tsx";
import { Said } from "../Said.tsx";
import { type DirId, type DirView, liveRoomNames } from "../types.ts";
import { WorkingAction } from "../WorkingAction.tsx";
import { suggestedNickname } from "../application.ts";

type JoinError = {
	field: "locator" | "room" | "nick" | "form";
	text: string;
	forNick?: string;
	forTarget?: string | null;
	implicitFor?: string;
	suggestion?: string;
} | null;

function nickTargetKey(target: ReturnType<typeof joinNickTarget>): string | null {
	return target === null ? null : JSON.stringify([target.directory, target.link, target.room.toLowerCase()]);
}

export const JoinCard = memo(function JoinCard(
	{ answers, resolved, dirs, directoryContext, canInteract }: {
		canInteract: boolean;
		/** Every field, with the evidence behind it. Resolved from the act that
		 * put this card up rather than held as state, so the same card is a gate
		 * on a link and a blank form from the rail without either one having to
		 * clear up after the other. The lock rides along for the same reason the
		 * others do: the rail's room panel names this room too, and its lock has
		 * to be this lock. */
		answers: JoinAnswers;
		/** The same render-time answer used by the linked rail field. */
		resolved: JoinResolution;
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
	const conversations = useRoomsState((state) => state.convs);
	const members = useRoomsState((state) => state.members);
	const defaultDirectoryAddress = directoryContext.defaultDirectory?.locator ?? null;
	const asLink = typedRoomLink(locator, room) !== null;
	// What the world says about what has been asked for. Resolved on every
	// render and never written back: the reader's own standing outlives a
	// directory that happens to hold the name, and comes back the moment they
	// point somewhere else. The rail's own control reads this same answer, so
	// the two cannot disagree about one question.
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
	const answerNick = (
		requested: string,
		at: string,
		target: ReturnType<typeof joinNickTarget>,
		refusal: JoinError = null,
	) => {
		const offered = suggestedJoinNick(at, dirs, directoryContext, (locator) => session.directoryId(locator));
		const refusedSuggestion = refusal?.field === "nick" && refusal.suggestion !== undefined &&
				refusal.implicitFor === offered && refusal.forTarget === nickTargetKey(target)
			? refusal.suggestion
			: null;
		return answerJoinNick(
			requested,
			offered,
			target,
			target === null ? null : dirs.get(target.directory)?.nick ?? null,
			target === null
				? null
				: [...(dirs.get(target.directory)?.dmablePeers.values() ?? [])].map((peer) => peer.name),
			conversations,
			members,
			refusedSuggestion === null ? null : { suggestion: refusedSuggestion },
		);
	};
	const halt = useRef<AbortController | null>(null);
	const [error, join, joining] = useActionState(async (was: JoinError, form: FormData): Promise<JoinError> => {
		halt.current?.abort();
		const run = new AbortController();
		halt.current = run;
		let failureField: "locator" | "form" = "form";
		try {
			const typedText = String(form.get("locator") ?? "");
			const typedNick = String(form.get("nick") ?? "");
			// Resolving the aimed directory belongs to the locator. Even an
			// unexpected classifier failure is answered on the field whose value
			// could not be interpreted, rather than escaping the form action.
			failureField = "locator";
			let nick = answerNick(typedNick, typedText, null, was).request;
			if (nick.length > MAX_NICK) {
				return { field: "nick", text: tooLong("name", MAX_NICK, "characters"), forNick: nick };
			}
			const nickWhy = nickRefusal(nick);
			if (nickWhy != null) return { field: "nick", text: nickWhy, forNick: nick };
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
			failureField = submitted.act === "connect" ? "locator" : "form";
			if (submitted.act === "connect") {
				const why = await session.reachDirectory(
					typedText,
					typedNick === "" ? { kind: "automatic", base: nick } : { kind: "exact", name: typedNick },
					run.signal,
				);
				if (run.signal.aborted) return null;
				if (why !== "") return { field: "locator", text: why };
				// The typed name was an override for this connection attempt. Once the
				// directory has reconciled it, the effective grant becomes the next
				// form's offer rather than a prefilled request to repeat.
				browser.editJoin({ nick: "" });
				return null;
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
			const roomDestination = {
				room,
				locator: linked !== null ? linked.link : locator,
				// A room that already answers to this name has its own standing,
				// and this session is not the one that sets it. Same answer the
				// control reads, so what the card showed is what the act sends.
				hidden: linked !== null || submitted.fixed ? false : secret,
				policy: linked !== null || submitted.fixed ? undefined : policyForRoomPreset(roomPreset),
			};
			const target = joinNickTarget(
				roomDestination.locator,
				roomDestination.room,
				directoryContext,
				(at) => session.directoryId(at),
			);
			const targetKey = nickTargetKey(target);
			const implicitFor = typedNick === ""
				? suggestedJoinNick(typedText, dirs, directoryContext, (at) => session.directoryId(at))
				: undefined;
			const nickAnswer = answerNick(typedNick, typedText, target, was);
			nick = nickAnswer.request;
			const availability = nickAnswer.availability;
			if (availability.kind === "taken") {
				return {
					field: "nick",
					text: knownNickTakenText(availability.source),
					forNick: nick,
					forTarget: targetKey,
					implicitFor,
					suggestion: availability.suggestion,
				};
			}
			const outcome = await session.join(
				roomDestination,
				typedNick === "" ? { kind: "automatic", base: nick } : { kind: "exact", name: typedNick },
				run.signal,
			);
			if (run.signal.aborted) return null;
			if (!outcome.ok) {
				if (outcome.code === NICK_TAKEN) {
					const after = joinNickAvailability(nick, target, null, null, conversations, members);
					return {
						field: "nick",
						text: outcome.text,
						forNick: nick,
						forTarget: targetKey,
						implicitFor,
						suggestion: after.kind === "taken" ? after.suggestion : suggestedNickname(nick),
					};
				}
				return { field: "form", text: outcome.text };
			}
			// The lock is an intention about the room just made, and it is now
			// spent: left pressed, the next name typed here would mint a private
			// room nobody asked for.
			browser.editJoin({
				nick: "",
				...(roomPreset === "open" ? {} : { roomPreset: "open" as const }),
			});
			return null;
		} catch (err) {
			if (run.signal.aborted) return null;
			const text = err instanceof Error ? err.message : String(err);
			return { field: failureField, text };
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
	const nickTarget = joinNickTarget(locator, room, directoryContext, (at) => session.directoryId(at));
	const nickAnswer = answerNick(nick, locator, nickTarget, error);
	const who = nickAnswer.request;
	const nickAvailability = nickAnswer.availability;
	const refusedNick = error?.field === "nick" &&
			(error.forNick === undefined ||
				(error.forNick === who &&
					(error.forTarget === undefined || error.forTarget === nickTargetKey(nickTarget))))
		? error
		: null;
	const nickSuggestion = refusedNick?.suggestion ??
		(nickAvailability.kind === "taken" ? nickAvailability.suggestion : null);
	const nickNotice = refusedNick?.text ??
		(nickAvailability.kind === "taken" ? knownNickTakenText(nickAvailability.source) : null);
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
		label: asLink ? joinCallIt : roomFieldLabel(standing),
		offers: roomOffers,
		value: room,
		sigil: "#",
		onTake: (name) => {
			browser.editJoin({ room: name });
			field.current?.focus();
		},
	});

	return (
		<div className="join-wrap" id="joinScreen">
			<form id="joinForm" className="join" data-dir={aimed.mark} action={join}>
				<h2>{making ? joinTitleCreate : joinTitleJoin}</h2>
				<p className="lead">
					{paused
						// Not the read-only sentence, which promises browsing. A paused
						// link is answered with no session at all, so there is nothing
						// here to browse either, and this is the card a reader lands on
						// when there is nothing else to show them.
						? joinLeadPaused
						: canInteract
						? joinLead(answers, aimed.name)
						: joinLeadReadOnly}
				</p>
				<div className="join-fields" inert={joining || !canInteract || undefined}>
					<label htmlFor="locator">
						{asLink ? joinLinkLabel : (
							<>
								{joinLocatorLabel}{" "}
								<span className="optional">
									{homeDir == null && defaultDirectoryAddress != null
										? joinLocatorHere
										: joinLocatorOptional}
								</span>
							</>
						)}
					</label>
					{error?.field === "locator" && error.text !== "" && (
						<Said id="joinError" kind="failure">{error.text}</Said>
					)}
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
						/* Connect is reaching this address, so a refusal stands over it
					    rather than under the name or as a leftover of the join the
					    button is not performing. The sentence about what to type
					    follows the box it describes. */
					}
					{!asLink && <p className="hint" id="locatorHint">{joinLocatorHint}</p>}
					{
						/* Out until the directory can describe what naming a room there
					    would do. */
					}
					{!reaching && (
						<label htmlFor="room">
							{asLink ? joinCallIt : roomFieldLabel(standing)}
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
										? joinAccessFixedLabel(standing, wantedRoom)
										: joinAccessLabel(standing, nextRoomPreset(standing))}
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
					<label htmlFor="nick">{joinNickLabel}</label>
					{nickNotice !== null && (
						<Said
							id="joinNickError"
							kind="failure"
							className="join-nick-answer"
						>
							<span>{nickNotice}</span>
							{nickSuggestion !== null && (
								<>
									{" Try "}
									<Button
										id="joinNickSuggestion"
										variant="link"
										onClick={() => browser.editJoin({ nick: nickSuggestion })}
									>
										{nickSuggestion}
									</Button>
									{joinInstead}
								</>
							)}
						</Said>
					)}
					<JoinField invalid={nickNotice !== null}>
						<JoinPrefix label={avatarLabel}>
							<Avatar name={who} />
						</JoinPrefix>
						<input
							id="nick"
							name="nick"
							placeholder={nickAnswer.placeholder}
							enterKeyHint="go"
							{...identifierField}
							autoComplete="nickname"
							aria-describedby={nickNotice === null ? "nickHint" : "joinNickError nickHint"}
							aria-invalid={nickNotice !== null}
							maxLength={MAX_NICK}
							value={nick}
							onChange={(e) => browser.editJoin({ nick: e.target.value })}
						/>
					</JoinField>
					<p className="hint" id="nickHint">{joinNickHint}</p>
				</div>
				{error != null && error.field !== "locator" && error.field !== "nick" && error.text !== "" && (
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
					disabled={!canInteract || nickAvailability.kind === "taken"}
					stopId="joinStop"
					stopLabel={reaching ? joinStopConnecting : making ? joinStopCreating : joinStopJoining}
					onStop={() => halt.current?.abort()}
				>
					{paused
						? joinSessionPaused
						: !canInteract
						? joinReadOnlySession
						: nickAvailability.kind === "taken"
						? joinChooseAnotherName
						: reaching
						? (joining ? joinConnecting : joinConnect)
						: joining
						? (making ? joinCreating : joinJoining)
						: making
						? joinCreateRoom
						: joinJoinRoom}
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
						{joinBrowseLiveRooms}
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
					label={open ? joinHideDirectories : joinChooseDirectory}
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

function knownNickTakenText(source: "directory" | "room"): string {
	return source === "directory" ? joinNickTakenOnDirectory : joinNickTakenInRoom;
}
