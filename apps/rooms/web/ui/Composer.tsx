// The band at the foot of the message column: what other members are typing,
// the formatting hint, the emoji tray, and the field itself.
//
// The draft lives in the store rather than in this component, which is the same
// rule the rest of the page follows and it pays for itself here: the @ button on
// a message and the emoji tray both put text into the draft, and neither of them
// is inside this component. With one owner they are ordinary writes. With the
// draft held locally they would each need a handle reaching in.

import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { useCoarsePointer, useConversationMembers, useDismissOnClickOutside } from "./hooks.ts";
import { useRoomsBrowser } from "./controller/browser.ts";
import { useRoomsSession } from "./controller/session.ts";
import type { AttachmentView, Conv, LiveRooms, SessionPhase } from "./types.ts";
import { acceptCompletion, type Candidate, commandArgTrigger, composerCandidates, triggerAt } from "./complete.ts";
import { lineCapSaid, PHASE_SAID, PICKER, roomCalled } from "./text.ts";

import { IconButton } from "./IconButton.tsx";
import { Button } from "./Button.tsx";
import { kindOf } from "./media.ts";
import { FileChip, KEYBOARD_SETTLE_MS, useTypingSaid, useTypingSignal } from "./composer/bits.tsx";
import { useComposerMeasure } from "./composer/measure.tsx";
import { Said } from "./Said.tsx";

export function Composer(
	{
		canInteract,
		conv,
		nick,
		draft,
		draftFiles,
		changing,
		draftKeeping,
		liveRooms,
		reachable,
		mobile,
		enabled,
		phase,
		availability,
		keepLatestInView,
	}: {
		canInteract: boolean;
		conv: Conv | null;
		nick: string;
		draft: string;
		draftFiles: readonly File[];
		/** The line being rewritten, or nothing while an ordinary message is being
		 * written. The id rather than a flag, because moving from changing one line
		 * to changing another is a change this has to notice. */
		changing: number | undefined;
		/** The files kept on a file line being changed, when the change is to one.
		 * Present makes the composer a view of that line's files, each removable,
		 * with the new ones added after them. */
		draftKeeping: readonly AttachmentView[] | undefined;
		liveRooms: LiveRooms;
		/** Names this directory says are reachable for a direct message. What a
		 * command whose target is somebody to bring in — `/invite`, `/msg` —
		 * completes against, since those want the people the members list omits. */
		reachable: ReadonlySet<string>;
		mobile: boolean;
		enabled: boolean;
		/** What this conversation's directory is doing. Read only when the field
		 * cannot be used, to say why in the one place a reader is already looking. */
		phase: SessionPhase;
		/** A room-membership realization that is more specific than its
		 * directory connection, empty while the membership is live. */
		availability: string;
		/** Keep the newest message in view. `force` scrolls even when the reader
		 * had scrolled up, which is what focusing the field on a phone wants. */
		keepLatestInView: (force?: boolean) => void;
	},
) {
	const browser = useRoomsBrowser();
	const session = useRoomsSession();
	const members = useConversationMembers(conv?.type === "room" ? conv.key : null);
	const bar = useRef<HTMLDivElement>(null);
	const field = useRef<HTMLTextAreaElement>(null);
	const filePick = useRef<HTMLInputElement>(null);
	// Two pieces of state nothing outside this band ever reads, so they stay here:
	// whether the tray is open, and whether the field holds the caret.
	const [emojiOpen, setEmojiOpen] = useState(false);
	const closeEmoji = useCallback(() => setEmojiOpen(false), []);
	const [focused, setFocused] = useState(false);
	const [recoveringRoom, setRecoveringRoom] = useState(false);
	// Inline completion. The caret is tracked as state so the trigger under it
	// is a plain derivation; Escape remembers which trigger it dismissed (by
	// its start index), so the list stays down until a new token begins.
	const [caret, setCaret] = useState(0);
	const [picked, setPicked] = useState(0);
	const [dismissedAt, setDismissedAt] = useState<number | null>(null);
	// Last submitted line currently sitting in the field because Up recalled it.
	// Down restores empty while this still matches; any other edit drops it.
	const [recalled, setRecalled] = useState<string | null>(null);
	const trigger = focused && enabled ? commandArgTrigger(draft, caret) ?? triggerAt(draft, caret) : null;
	const candidates = composerCandidates(trigger, dismissedAt, conv, draft, reachable, nick, members, liveRooms);
	const listOpen = candidates.length > 0;
	// Where the selection really is. The list is derived from the roster and the
	// live rooms, so it can shrink under a reader mid-token — somebody leaves
	// while an `@` is half-typed, which is ordinary rather than exotic — while the
	// index they had arrowed to is separate state that knew nothing about it.
	// Clamped here rather than repaired in an effect, so there is never a render
	// in which the selection points past the end: out of range, Enter read an
	// absent candidate and the key did nothing at all.
	const pick = Math.min(picked, candidates.length - 1);
	// A new token, a new list: reset the pick and forget the dismissal.
	const triggerId = trigger === null ? null : `${trigger.kind}:${trigger.start}`;
	useEffect(() => {
		setPicked(0);
		if (trigger === null) setDismissedAt(null);
		// eslint-disable-next-line react-hooks/exhaustive-deps -- keyed on token identity, not the object
	}, [triggerId]);
	useEffect(() => {
		if (recalled !== null && draft !== recalled) setRecalled(null);
	}, [draft, recalled]);
	// Keep the picked row on screen. The command list is every command this
	// conversation can run and the box holds eight and a half rows, so the arrows
	// walk past the fold: without this a reader presses Down, the highlight
	// leaves the box, and Enter takes a row they cannot see. `nearest` rather
	// than centring, so a pick already in view does not shunt the list under the
	// pointer for no reason. Layout, not paint: the row is picked and scrolled to
	// in one frame rather than flashing at the old offset first.
	useLayoutEffect(() => {
		if (!listOpen) return;
		document.getElementById(`complete-${pick}`)?.scrollIntoView({ block: "nearest" });
	}, [listOpen, pick]);
	const syncCaret = (box: HTMLTextAreaElement) => setCaret(box.selectionStart ?? 0);
	const accept = (candidate: Candidate) => {
		if (trigger === null) return;
		const next = acceptCompletion(draft, trigger, caret, candidate);
		session.setDraft(next.text);
		setCaret(next.caret);
		const box = field.current;
		queueMicrotask(() => {
			if (!box) return;
			box.selectionStart = box.selectionEnd = next.caret;
			box.focus();
		});
	};
	// Enter sends on a physical keyboard (Shift+Enter is the newline). On a touch
	// device there is no Shift, so Return inserts a newline and sending is the
	// button's job.
	const coarse = useCoarsePointer();
	const roomWaiting = conv?.type === "room" && conv.membership !== "joined";
	const recoverRoom = () => {
		if (conv?.type !== "room" || recoveringRoom) return;
		if (conv.held && conv.link == null) {
			browser.aboutConversation("capabilities");
			return;
		}
		setRecoveringRoom(true);
		void session.recoverRoom(conv.key).then((refused) => {
			if (refused !== "") browser.toast("failure", refused);
		}).finally(() => setRecoveringRoom(false));
	};

	// Rooms and direct lines both carry an ephemeral typing level. Every way of
	// stopping — sending, going idle, blurring, switching away, closing the tab —
	// is this one condition going false.
	useTypingSignal(
		enabled && focused && conv !== null && conv.type !== "directory" && draft.trim() !== "",
		draft,
		session.setTyping,
	);

	// Never carry a stray tray across a conversation switch. Arriving at a
	// conversation on a wide screen also takes the caret, so you can type at once;
	// on a phone it must not, because forcing the keyboard up would cover the
	// messages you just opened.
	useEffect(() => {
		setEmojiOpen(false);
		if (!mobile && enabled) field.current?.focus();
	}, [conv?.key, mobile, enabled]);

	useEffect(() => {
		setRecalled(null);
	}, [conv?.key]);

	// Pressing Edit hands the words over; this hands the caret over with them, at
	// the end of what is being rewritten. Without it the field fills up while the
	// focus stays on the mark that was pressed — and that mark is gone the moment
	// the menu closes, so the focus lands on nothing and a reader has to click
	// into their own sentence before they can change it. On a phone too: the
	// keyboard coming up is what was asked for here, unlike arriving at a
	// conversation.
	useEffect(() => {
		if (changing === undefined) return;
		const box = field.current;
		if (box === null) return;
		box.focus();
		box.setSelectionRange(box.value.length, box.value.length);
	}, [changing]);

	useDismissOnClickOutside(emojiOpen, ".emoji-pop, #emojiBtn", closeEmoji);

	const insertAtCursor = (s: string) => {
		const box = field.current;
		if (!box) return;
		const start = box.selectionStart ?? draft.length;
		const end = box.selectionEnd ?? draft.length;
		session.setDraft(draft.slice(0, start) + s + draft.slice(end));
		queueMicrotask(() => {
			box.selectionStart = box.selectionEnd = start + s.length;
			box.focus();
		});
	};

	const capSaid = lineCapSaid(conv, draft);
	// Changing a file line can send with an empty field and no new files: removing
	// every file with no caption left is a real instruction — it takes the line
	// down. So a file-line change is always sendable; `draftKeeping` is what says
	// this is one.
	const canSend = draft.trim() !== "" || draftFiles.length > 0 || draftKeeping !== undefined;
	// Editing a file line down to no files and no caption leaves nothing for the
	// message to be, so sending takes it back. That is a real thing to want — it
	// is how the last file comes off a message that was only ever its files — but
	// it must not arrive as a surprise: the bar above says what will happen and
	// the control below stops calling itself Send.
	const emptiesLine = draftKeeping !== undefined && draftKeeping.length === 0 && draftFiles.length === 0 &&
		draft.trim() === "";
	const said = useTypingSaid(conv?.key ?? null, nick);
	const addressee = conv
		? (conv.type === "dm"
			? "Message " + conv.id + " directly"
			: conv.type === "room"
			? "Message " + roomCalled(conv.id, conv.held)
			: conv.type === "directory"
			? "A command, like /help"
			: "Message")
		: "Message";
	// A placeholder names the addressee, and only while there is one to name. Why
	// the field is unavailable is said once, on the line under it, which is where
	// a standing condition belongs and the one place it can be read at all: a
	// placeholder is hidden by whatever the reader had already typed, and a
	// reason that disappears behind their own draft is a field that has gone
	// quiet on them. The accessible name below carries it either way.
	const unavailable = availability || (!enabled && conv ? PHASE_SAID[phase] : "");
	const placeholder = enabled ? addressee : "";
	useComposerMeasure({ field, band: bar, draft, enabled, placeholder, onMeasured: keepLatestInView });

	return (
		<div className="composer" ref={bar}>
			<div
				id="emojiPop"
				className={emojiOpen ? "emoji-pop show" : "emoji-pop"}
				role="group"
				aria-label="Emoji"
			>
				{PICKER.map((glyph) => (
					<button
						key={glyph}
						type="button"
						// Keep the field focused: a mousedown here would otherwise
						// collapse the caret and land the emoji at the end.
						onMouseDown={(e) => e.preventDefault()}
						onClick={() => {
							insertAtCursor(glyph);
							setEmojiOpen(false);
						}}
					>
						{glyph}
					</button>
				))}
			</div>
			{listOpen && (
				<div id="completePop" className="complete-pop" role="listbox" aria-label="Completions">
					{candidates.map((candidate, i) => (
						<button
							key={candidate.kind + candidate.label}
							id={`complete-${i}`}
							type="button"
							role="option"
							tabIndex={-1}
							aria-selected={i === pick}
							// Said the way a reader would say it. The row draws its three
							// parts with space between them, and space drawn by a layout is
							// nothing to software that reads the text: without this the
							// option announces as "/awaysay you have stepped away".
							aria-label={[candidate.label, candidate.hint].filter(Boolean).join(", ")}
							className={i === pick ? "complete-row picked" : "complete-row"}
							// Keep the field focused, same rule as the emoji tray.
							onMouseDown={(e) => e.preventDefault()}
							// A pointer that moves onto a row picks it. Entering is not
							// enough: the list opens under wherever the pointer last
							// came to rest, and a row arriving under a parked pointer
							// would steal the pick from the row the typing narrowed to.
							onMouseMove={() => {
								if (i !== pick) setPicked(i);
							}}
							onClick={() => accept(candidate)}
						>
							{candidate.glyph ? <span className="complete-glyph">{candidate.glyph}</span> : null}
							<span className="complete-label">{candidate.label}</span>
							{candidate.hint === undefined
								? null
								: <span className="complete-hint">{candidate.hint}</span>}
						</button>
					))}
				</div>
			)}
			{
				/* Rewriting a line already posted, which the field alone cannot say:
				    the words in it look exactly like a new message. Named here, with
				    the way out beside it, because a reader who has forgotten what
				    Enter is about to do is looking at the field. */
			}
			{changing !== undefined && (
				<div id="changing" className="changing-bar">
					<span className="changing-said">
						{emptiesLine
							? "Nothing left on this message: sending takes it back"
							: draftKeeping !== undefined
							? "Editing this line's files"
							: "Editing a message"}
					</span>
					<IconButton
						icon="close"
						label="Stop editing this message"
						size="small"
						variant="ghost"
						onClick={() => {
							browser.cancelChange();
							field.current?.focus();
						}}
					/>
				</div>
			)}
			<form
				id="composer"
				hidden={conv === null}
				onSubmit={(e) => {
					e.preventDefault();
					session.send();
				}}
			>
				{
					/* The files a file-line change is keeping, above the newly-picked
					   ones, each removable. A × here drops a file the line already has;
					   a × below drops one about to be added. */
				}
				{draftKeeping !== undefined && draftKeeping.length > 0 && (
					<div className="composer-files" aria-label="Files on this line">
						{draftKeeping.map((file, index) => (
							<FileChip
								key={`kept:${file.id}`}
								image={kindOf(file.mime) === "image"}
								name={file.name}
								size={file.size}
								onRemove={() => browser.dropKeptFile(index)}
							/>
						))}
					</div>
				)}
				{draftFiles.length > 0 && (
					<div className="composer-files" aria-label="Attached files">
						{draftFiles.map((file, index) => (
							<FileChip
								key={`${file.name}:${file.size}:${index}`}
								image={kindOf(file.type) === "image"}
								name={file.name}
								size={file.size}
								onRemove={() => browser.removeFile(index)}
							/>
						))}
					</div>
				)}
				<div className="composer-input">
					<textarea
						id="line"
						ref={field}
						rows={1}
						value={draft}
						placeholder={placeholder}
						autoComplete="off"
						autoCapitalize="sentences"
						enterKeyHint="send"
						role="combobox"
						aria-label={enabled
							? (conv?.type === "directory" ? "Command" : "Message")
							: unavailable || "Message unavailable"}
						aria-autocomplete="list"
						aria-expanded={listOpen}
						aria-controls={listOpen ? "completePop" : undefined}
						aria-activedescendant={listOpen ? `complete-${pick}` : undefined}
						disabled={!enabled}
						onChange={(e) => {
							session.setDraft(e.target.value);
							syncCaret(e.target);
						}}
						onSelect={(e) => syncCaret(e.currentTarget)}
						onPaste={(e) => {
							// A screenshot on the clipboard arrives as a file with no name
							// worth showing; posting it is what a person means by pasting it
							// here, and the text arm of the same paste is left alone. A
							// directory has no message to carry a file, so the paste stays
							// text.
							if (conv?.type === "directory") return;
							const files = [...e.clipboardData.files];
							if (files.length === 0) return;
							e.preventDefault();
							browser.addFiles(files);
						}}
						onBlur={() => setFocused(false)}
						onFocus={() => {
							setFocused(true);
							// The keyboard slides in on a phone; once it has settled, bring
							// the newest messages into view so you see what you are replying
							// to. Two passes ride out the animation without a magic delay.
							if (!mobile) return;
							keepLatestInView(true);
							setTimeout(() => keepLatestInView(true), KEYBOARD_SETTLE_MS);
						}}
						onKeyDown={(e) => {
							// Input and selection events update the store before React commits the
							// next render. A key can arrive in that gap, so only let the rendered
							// completion list consume it when it describes the textarea's live
							// value and caret. The send path already reads current store state.
							const completionCurrent = e.currentTarget.value === draft &&
								(e.currentTarget.selectionStart ?? 0) === caret;
							if (listOpen && completionCurrent) {
								if (e.key === "ArrowDown" || e.key === "ArrowUp") {
									e.preventDefault();
									const step = e.key === "ArrowDown" ? 1 : -1;
									setPicked((pick + step + candidates.length) % candidates.length);
									return;
								}
								// Tab completes whatever is highlighted. Enter does too only
								// while the row has something left to offer, so a command
								// typed out in full runs on Enter rather than being handed
								// back with a space on the end.
								if (e.key === "Tab" || (e.key === "Enter" && candidates[pick].keepsEnter)) {
									e.preventDefault();
									accept(candidates[pick]);
									return;
								}
								if (e.key === "Escape") {
									setDismissedAt(trigger?.start ?? null);
									return;
								}
							}
							if (e.key === "Escape" && emojiOpen) {
								setEmojiOpen(false);
								return;
							}
							// Escape backs out of rewriting a line, which is the one way
							// out that does not need the mouse. The line stays as posted.
							if (e.key === "Escape" && changing !== undefined) {
								browser.cancelChange();
								return;
							}
							// An empty field's Up is otherwise a no-op. Fill it with the last
							// line submitted here — including a command that never appeared in
							// the log. Down restores empty while that recall is still intact.
							if (
								!e.altKey && !e.metaKey && !e.ctrlKey && !e.shiftKey &&
								!e.nativeEvent.isComposing
							) {
								if (
									e.key === "ArrowUp" && changing === undefined &&
									draft.trim() === "" && draftFiles.length === 0
								) {
									const last = session.recallLastSent();
									if (last !== null) {
										e.preventDefault();
										setRecalled(last);
										const box = field.current;
										queueMicrotask(() => {
											if (!box) return;
											box.selectionStart = box.selectionEnd = last.length;
											box.focus();
										});
									}
									return;
								}
								if (e.key === "ArrowDown" && recalled !== null && draft === recalled) {
									e.preventDefault();
									session.setDraft("");
									setRecalled(null);
									return;
								}
							}
							// isComposing guards against sending mid-IME-composition.
							if (
								e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing &&
								!coarse
							) {
								e.preventDefault();
								// A native key event can follow the input event before React has
								// committed the controlled value. The controller reads the store, so
								// admit the textarea's current word before asking that controller to
								// send it. `setDraft` is synchronous at the view boundary for both
								// local and attached controllers.
								session.setDraft(e.currentTarget.value);
								session.send();
							}
						}}
					/>
				</div>
				<input
					ref={filePick}
					id="filePick"
					type="file"
					hidden
					multiple
					onChange={(e) => {
						browser.addFiles([...(e.target.files ?? [])]);
						// Clear it, so picking the same file twice in a row is two
						// posts rather than one and then silence.
						e.target.value = "";
					}}
				/>
				<div className="composer-actions">
					<div className="composer-actions-left">
						<IconButton
							id="attachBtn"
							icon="clip"
							label="Attach a file"
							size={mobile ? "large" : "normal"}
							variant="ghost"
							disabled={!enabled || conv?.type === "directory"}
							onMouseDown={(e) => e.preventDefault()}
							onClick={() => filePick.current?.click()}
						/>
						<IconButton
							id="emojiBtn"
							icon="smile"
							label="Insert emoji"
							size={mobile ? "large" : "normal"}
							variant="ghost"
							aria-controls="emojiPop"
							aria-expanded={emojiOpen}
							disabled={!enabled}
							onMouseDown={(e) => e.preventDefault()}
							onClick={() => setEmojiOpen(!emojiOpen)}
						/>
					</div>
					{roomWaiting && canInteract
						? (
							<Button
								id="roomReconnect"
								type="button"
								busy={recoveringRoom || conv.membership === "joining"}
								disabled={recoveringRoom || conv.membership === "joining"}
								onClick={recoverRoom}
							>
								{conv.membership === "joining"
									? "Joining…"
									: conv.held && conv.link == null
									? "Restore access…"
									: nick === ""
									? "Join"
									: "Retry joining"}
							</Button>
						)
						: (
							<IconButton
								id="sendBtn"
								icon={emptiesLine ? "close" : "send"}
								label={emptiesLine ? "Take this message back" : "Send"}
								size={mobile ? "large" : "normal"}
								variant={canSend ? "solid" : "outline"}
								tone={emptiesLine ? "danger" : canSend ? "accent" : "neutral"}
								shape="circle"
								type="submit"
								disabled={!enabled || !canSend}
							/>
						)}
				</div>
			</form>
			<div className="composer-status">
				<div id="typing" className={said ? "typing show" : "typing"} aria-hidden="true">
					{said}
				</div>
				<Said
					id="composerAvailability"
					className={unavailable === "" ? "composer-availability" : "composer-availability show"}
					kind="warning"
				>
					{unavailable}
				</Said>
				{unavailable !== "" ? null : capSaid !== null
					? (
						<div
							id="lineRoom"
							className={capSaid.over ? "hint room-cap over" : "hint room-cap"}
							role={capSaid.over ? "alert" : undefined}
						>
							{capSaid.said}
						</div>
					)
					: (
						<div id="hint" className="hint">
							{conv?.type === "directory"
								? (
									<>
										<b>Enter</b> to run · <b>/</b> for a command, like <b>/help</b>
									</>
								)
								: (
									<>
										<b>Enter</b> to send · <b>Shift+Enter</b> for a new line · <b>**bold**</b> ·
										{" "}
										<b>*italic*</b> · <b>`code`</b> · <b>@name</b> · <b>:smile:</b> · <b>/me</b>
									</>
								)}
						</div>
					)}
			</div>
		</div>
	);
}
