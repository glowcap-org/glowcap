// The band at the foot of the message column: what other members are typing,
// the formatting hint, the emoji tray, and the field itself.
//
// The draft lives in the store rather than in this component, which is the same
// rule the rest of the page follows and it pays for itself here: the @ button on
// a message and the emoji tray both put text into the draft, and neither of them
// is inside this component. With one owner they are ordinary writes. With the
// draft held locally they would each need a handle reaching in.

import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { useCoarsePointer, useDismissOnClickOutside } from "./hooks.ts";
import { usePeer } from "./peer.ts";
import type { Conv, SessionPhase } from "./types.ts";
import { acceptCompletion, type Candidate, completeCandidates, triggerAt } from "./complete.ts";
import { lineCost, lineRoom, PICKER } from "./text.ts";
import { PHASE_SAID } from "./DirectoryFacts.tsx";
import { MAX_LINE, TYPING_IDLE_MS } from "../../lib/limits.ts";
import { Icon } from "./icons.tsx";
import { IconButton } from "./IconButton.tsx";
import { Button } from "./Button.tsx";
import { fileSize, kindOf } from "./media.ts";

/** Tell the room we are typing while the draft holds text, and stop when we
 * send, go idle, blur, or leave.
 *
 * The flag is level, not edge: `true` goes once and a final `false` always goes,
 * so a stuck indicator cannot linger on the other members' screens. Leaving the
 * conversation runs this effect's cleanup, which is what sends that last
 * `false` — there is no separate "stop typing on switch" call to forget.
 *
 * `draft` is a dependency even though nothing here reads it, and that is the
 * whole of the idle timer working: `typing` stays true across a whole burst of
 * keystrokes, so depending on it alone the effect runs once, the timer fires at
 * four seconds, and nothing ever re-arms it. Typing longer than that would stop
 * telling the room. Depending on the draft re-arms the timer per keystroke,
 * which is what "idle" has to mean. */
function useTypingSignal(typing: boolean, draft: string, setTyping: (on: boolean) => void) {
	const on = useRef(false);
	useEffect(() => {
		if (!typing) {
			if (on.current) {
				on.current = false;
				setTyping(false);
			}
			return;
		}
		if (!on.current) {
			on.current = true;
			setTyping(true);
		}
		const idle = setTimeout(() => {
			on.current = false;
			setTyping(false);
		}, TYPING_IDLE_MS);
		return () => clearTimeout(idle);
	}, [typing, draft, setTyping]);
	// Leaving the page entirely still owes the room a final `false`.
	useEffect(() => () => {
		if (on.current) {
			on.current = false;
			setTyping(false);
		}
	}, [setTyping]);
}

// Long enough for a phone's keyboard to finish sliding in, so the second pass
// measures the layout it leaves behind rather than the one mid-animation.
const KEYBOARD_SETTLE_MS = 300;

function typingText(names: Iterable<string>, except: string): string {
	let first = "";
	let second = "";
	let count = 0;
	for (const name of names) {
		if (name === except) continue;
		if (count === 0) first = name;
		else if (count === 1) second = name;
		count++;
	}
	if (count === 0) return "";
	if (count === 1) return `${first} is typing…`;
	if (count === 2) return `${first} and ${second} are typing…`;
	return `${first}, ${second}, and ${count - 2} more are typing…`;
}

export function Composer(
	{ conv, nick, draft, draftFiles, changing, liveRooms, mobile, enabled, phase, keepLatestInView }: {
		conv: Conv | null;
		nick: string;
		draft: string;
		draftFiles: readonly File[];
		/** Whether these words are a line being rewritten rather than a new one. */
		changing: boolean;
		liveRooms: ReadonlyMap<string, number>;
		mobile: boolean;
		enabled: boolean;
		/** What this conversation's directory is doing. Read only when the field
		 * cannot be used, to say why in the one place a reader is already looking. */
		phase: SessionPhase;
		/** Keep the newest message in view. `force` scrolls even when the reader
		 * had scrolled up, which is what focusing the field on a phone wants. */
		keepLatestInView: (force?: boolean) => void;
	},
) {
	const peer = usePeer();
	const bar = useRef<HTMLDivElement>(null);
	const field = useRef<HTMLTextAreaElement>(null);
	const filePick = useRef<HTMLInputElement>(null);
	// Two pieces of state nothing outside this band ever reads, so they stay here:
	// whether the tray is open, and whether the field holds the caret.
	const [emojiOpen, setEmojiOpen] = useState(false);
	const closeEmoji = useCallback(() => setEmojiOpen(false), []);
	const [focused, setFocused] = useState(false);
	// Inline completion. The caret is tracked as state so the trigger under it
	// is a plain derivation; Escape remembers which trigger it dismissed (by
	// its start index), so the list stays down until a new token begins.
	const [caret, setCaret] = useState(0);
	const [picked, setPicked] = useState(0);
	const [dismissedAt, setDismissedAt] = useState<number | null>(null);
	const trigger = focused && enabled ? triggerAt(draft, caret) : null;
	const candidates = trigger !== null && trigger.start !== dismissedAt
		? completeCandidates(trigger, {
			nicks: trigger.kind === "nick"
				? conv === null ? [] : conv.type === "room" ? [...conv.members.keys()] : [conv.id]
				: [],
			rooms: trigger.kind === "room" ? [...liveRooms.keys()] : [],
			grants: conv?.type === "room" ? conv.grants : undefined,
		})
		: [];
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
	const syncCaret = (box: HTMLTextAreaElement) => setCaret(box.selectionStart ?? 0);
	const accept = (candidate: Candidate) => {
		if (trigger === null) return;
		const next = acceptCompletion(draft, trigger, caret, candidate);
		peer.setDraft(next.text);
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

	// Only a room has a typing channel; a direct message is peer to peer with none.
	// Every way of stopping — sending, going idle, blurring, switching away,
	// closing the tab — is this one condition going false.
	useTypingSignal(
		enabled && focused && conv !== null && draft.trim() !== "",
		draft,
		peer.setTyping,
	);

	// Never carry a stray tray across a conversation switch. Arriving at a
	// conversation on a wide screen also takes the caret, so you can type at once;
	// on a phone it must not, because forcing the keyboard up would cover the
	// messages you just opened.
	useEffect(() => {
		setEmojiOpen(false);
		if (!mobile && enabled) field.current?.focus();
	}, [conv?.key, mobile, enabled]);

	// Fit the box to its content. The cap is the stylesheet's `max-height`, read
	// rather than repeated: two copies of one number drift the moment either moves.
	// It is read once and remembered, because asking for it is a style
	// recalculation and asking on every character is one per keystroke; the band's
	// own observer below re-reads it when anything could have changed it.
	const cap = useRef(Infinity);
	const fit = useCallback(() => {
		const box = field.current;
		if (!box) return;
		box.style.height = "auto";
		box.style.height = Math.min(box.scrollHeight, cap.current) + "px";
	}, []);
	useLayoutEffect(() => {
		const box = field.current;
		if (box) cap.current = parseFloat(getComputedStyle(box).maxHeight) || Infinity;
		fit();
	}, [draft, enabled, fit]);

	// The composer floats over the bottom of the message column, so the log has to
	// leave that much of itself clear and the jump-to-latest button has to sit above
	// it. Both read one number. The band holds one height at rest by design — every
	// row in it reserves its space — but a long draft grows the field and the window
	// can be resized under it, so the number is measured rather than guessed.
	useLayoutEffect(() => {
		const band = bar.current;
		if (!band) return;
		const observer = new ResizeObserver(() => {
			document.documentElement.style.setProperty(
				"--composer-h",
				`${Math.round(band.getBoundingClientRect().height)}px`,
			);
			keepLatestInView();
		});
		observer.observe(band);
		return () => observer.disconnect();
	}, [keepLatestInView]);

	useDismissOnClickOutside(emojiOpen, ".emoji-pop, #emojiBtn", closeEmoji);

	const insertAtCursor = (s: string) => {
		const box = field.current;
		if (!box) return;
		const start = box.selectionStart ?? draft.length;
		const end = box.selectionEnd ?? draft.length;
		peer.setDraft(draft.slice(0, start) + s + draft.slice(end));
		queueMicrotask(() => {
			box.selectionStart = box.selectionEnd = start + s.length;
			box.focus();
		});
	};

	// What this room will carry, and what the draft costs against it. Shown only
	// when the room asks for less than this app does and the draft is close
	// enough for the answer to be worth the space.
	const lineCap = lineRoom(conv, MAX_LINE);
	const cost = lineCost(draft);
	const overBy = cost - lineCap;
	const room = lineCap < MAX_LINE && cost > lineCap * 0.8 ? lineCap : null;
	const files = draftFiles;
	const canSend = draft.trim() !== "" || files.length > 0;
	const said = typingText(conv?.typers ?? [], nick);
	// A field that cannot be used says why, rather than greying out under an
	// invitation to type in it. The connection is stated in the rail's foot too,
	// but that is a small line at the other end of a wide screen and a different
	// screen entirely on a phone — and with more than one directory held it is
	// answering about the whole page while this field is refusing for one of
	// them. What is true belongs where the person is looking.
	const placeholder = !enabled && conv
		? PHASE_SAID[phase]
		: conv
		? (conv.type === "dm" ? "Message " + conv.id + " directly" : "Message #" + conv.id)
		: "Message";

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
							className={i === pick ? "complete-row picked" : "complete-row"}
							// Keep the field focused, same rule as the emoji tray.
							onMouseDown={(e) => e.preventDefault()}
							onMouseEnter={() => setPicked(i)}
							onClick={() => accept(candidate)}
						>
							{candidate.glyph ? <span className="complete-glyph">{candidate.glyph}</span> : null}
							<span className="complete-label">{candidate.label}</span>
						</button>
					))}
				</div>
			)}
			<div className="composer-status">
				<div id="typing" className={said ? "typing show" : "typing"} aria-hidden="true">
					{said}
				</div>
				{
					/* The room's own cap, once a draft is near enough to it to matter.
				    A room bridged somewhere else may carry less than this app allows,
				    and finding that out by having a message cut in half on the other
				    side is finding out too late. Quiet until the last fifth, because
				    a counter that is always there is furniture; urgent once it is
				    past, because then the message will not go. */
				}
				{room !== null
					? (
						<div
							id="lineRoom"
							className={overBy > 0 ? "hint room-cap over" : "hint room-cap"}
							role={overBy > 0 ? "alert" : undefined}
						>
							{overBy > 0 ? `${overBy} bytes too long for this room` : `${room - cost} bytes left`}
						</div>
					)
					: (
						<div id="hint" className="hint">
							<b>Enter</b> to send · <b>Shift+Enter</b> for a new line · <b>**bold**</b> · <b>*italic*</b>
							{" "}
							· <b>`code`</b> · <b>@name</b> · <b>:smile:</b> · <b>/me</b>
						</div>
					)}
			</div>
			{
				/* Rewriting a line already posted, which the field alone cannot say:
				    the words in it look exactly like a new message. Named here, with
				    the way out beside it, because a reader who has forgotten what
				    Enter is about to do is looking at the field. */
			}
			{changing && (
				<div id="changing" className="changing-bar">
					<span className="changing-said">Changing a message</span>
					<Button
						variant="link"
						onClick={() => {
							peer.cancelChange();
							field.current?.focus();
						}}
					>
						Cancel
					</Button>
				</div>
			)}
			<form
				id="composer"
				hidden={conv === null}
				onSubmit={(e) => {
					e.preventDefault();
					peer.send();
				}}
			>
				{files.length > 0 && (
					<div className="composer-files" aria-label="Attached files">
						{files.map((file, index) => (
							<div className="composer-file" key={`${file.name}:${file.size}:${index}`}>
								<span className="composer-file-kind">
									<Icon name={kindOf(file.type) === "image" ? "image" : "file"} size={18} />
								</span>
								<span className="composer-file-copy">
									<span className="composer-file-name" title={file.name}>{file.name}</span>
									<span className="composer-file-size">{fileSize(file.size)}</span>
								</span>
								<IconButton
									className="composer-file-remove"
									icon="close"
									label={`Remove ${file.name}`}
									size="small"
									variant="ghost"
									tone="danger"
									onClick={() =>
										peer.removeFile(index)}
								/>
							</div>
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
						role="combobox"
						aria-label="Message"
						aria-autocomplete="list"
						aria-expanded={listOpen}
						aria-controls={listOpen ? "completePop" : undefined}
						aria-activedescendant={listOpen ? `complete-${pick}` : undefined}
						disabled={!enabled}
						onChange={(e) => {
							peer.setDraft(e.target.value);
							syncCaret(e.target);
						}}
						onSelect={(e) => syncCaret(e.currentTarget)}
						onPaste={(e) => {
							// A screenshot on the clipboard arrives as a file with no name
							// worth showing; posting it is what a person means by pasting it
							// here, and the text arm of the same paste is left alone.
							const files = [...e.clipboardData.files];
							if (files.length === 0) return;
							e.preventDefault();
							peer.addFiles(files);
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
							if (listOpen) {
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
							if (e.key === "Escape" && changing) {
								peer.cancelChange();
								return;
							}
							// isComposing guards against sending mid-IME-composition.
							if (
								e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing &&
								!coarse
							) {
								e.preventDefault();
								peer.send();
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
						peer.addFiles([...(e.target.files ?? [])]);
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
							disabled={!enabled}
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
					<IconButton
						id="sendBtn"
						icon="send"
						label="Send"
						size={mobile ? "large" : "normal"}
						variant={canSend ? "solid" : "outline"}
						tone={canSend ? "accent" : "neutral"}
						shape="circle"
						type="submit"
						disabled={!enabled || !canSend}
					/>
				</div>
			</form>
		</div>
	);
}
