import { ActionFeedback, useActionCooldown } from "../ActionFeedback.tsx";
import { PRESENTATION, useProgress } from "../presentation.ts";
// The band at the foot of the message column: what other members are typing,
// the formatting hint, the emoji tray, and the field itself.
//
// The draft lives in the store rather than in this component, which is the same
// rule the rest of the page follows and it pays for itself here: the @ button on
// a message and the emoji tray both put text into the draft, and neither of them
// is inside this component. With one owner they are ordinary writes. With the
// draft held locally they would each need a handle reaching in.

import { useCallback, useEffect, useLayoutEffect, useReducer, useRef } from "react";
import {
	composerAttach,
	composerAttachedFiles,
	composerCommand,
	composerCommandLike,
	composerEditingFiles,
	composerEditingMessage,
	composerEmoji,
	composerEmptiesLine,
	composerFilesOnLine,
	composerJoin,
	composerJoining,
	composerMessage,
	composerMessageDirectly,
	composerMessageRoom,
	composerMessageUnavailable,
	composerRestoreAccess,
	composerRetryJoining,
	composerSend,
	composerStopEditing,
	composerTakeBack,
} from "../../../lib/text/controls.ts";
import { useCoarsePointer, useConversationMembers, useDismissOnClickOutside } from "../hooks.ts";
import { useRoomsBrowser } from "../controller/browser.ts";
import { composerReducer, initialComposerState } from "./composer_state.ts";
import { useRoomsSession } from "../controller/session.ts";
import { actionRefusal } from "../error_text.ts";
import {
	type AttachmentView,
	type Conv,
	conversationCarries,
	conversationTakesFiles,
	type LiveRooms,
	type SessionPhase,
} from "../types.ts";
import { acceptCompletion, type Candidate, commandArgTrigger, composerCandidates, triggerAt } from "../complete.ts";
import { lineCapSaid, PHASE_SAID, roomCalled } from "../text.ts";
import { CompletionList, EmojiTray } from "../composer/pops.tsx";

import { IconButton } from "../IconButton.tsx";
import { Button } from "../Button.tsx";
import { kindOf } from "../media.ts";
import { FileChip, KEYBOARD_SETTLE_MS, useTypingSignal } from "../composer/bits.tsx";
import { ComposerStatus } from "../composer/status.tsx";
import { DraftSync } from "../composer/DraftSync.tsx";
import { markerFor, wrapSelection } from "../composer/keys.ts";
import { useOpenModal } from "../modal.ts";
import { composerHintFormatting } from "../../../lib/text/writing.ts";
import { useComposerMeasure } from "../composer/measure.tsx";
import type { DraftPreview } from "../link_preview.ts";
import { DraftLinkPreviews } from "./LinkPreviews.tsx";

export function Composer(
	{
		canInteract,
		conv,
		nick,
		draft,
		draftFiles,
		draftPreviews,
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
		draftPreviews: readonly DraftPreview[];
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
		 * command whose target is somebody to bring in (`/invite`, `/msg`)
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
		 * had scrolled up, as focusing the field on a phone requires. */
		keepLatestInView: (force?: boolean) => void;
	},
) {
	const browser = useRoomsBrowser();
	const openModalFrom = useOpenModal();
	const session = useRoomsSession();
	const members = useConversationMembers(conv?.type === "room" ? conv.key : null);
	const bar = useRef<HTMLDivElement>(null);
	const field = useRef<HTMLTextAreaElement>(null);
	const filePick = useRef<HTMLInputElement>(null);
	// Two pieces of state nothing outside this band ever reads, so they stay here:
	// whether the tray is open, and whether the field holds the caret.
	const closeEmoji = useCallback(() => dispatch({ kind: "tray", open: false }), []);
	// Inline completion. The caret is tracked as state so the trigger under it
	// is a plain derivation; Escape remembers which trigger it dismissed (by
	// its start index), so the list stays down until a new token begins.

	// Last submitted line sitting in the field because Up recalled it.
	// Down restores empty while this still matches; any other edit drops it.
	const [state, dispatch] = useReducer(composerReducer, initialComposerState);
	const { emojiOpen, focused, recovering: recoveringRoom, caret, picked, dismissedAt, recalled } = state;
	const trigger = focused && enabled ? commandArgTrigger(draft, caret) ?? triggerAt(draft, caret) : null;
	const candidates = composerCandidates(trigger, dismissedAt, conv, draft, reachable, nick, members, liveRooms);
	const listOpen = candidates.length > 0;
	// Where the selection really is. The list is derived from the roster and the
	// live rooms, so it can shrink under a reader mid-token (somebody leaves
	// while an `@` is half-typed, which is ordinary rather than exotic) while the
	// index they had arrowed to is separate state that knew nothing about it.
	// Clamped here rather than repaired in an effect, so there is never a render
	// in which the selection points past the end: out of range, Enter read an
	// absent candidate and the key did nothing at all.
	const pick = Math.min(picked, candidates.length - 1);
	// A new token, a new list: reset the pick and forget the dismissal.
	const triggerId = trigger === null ? null : `${trigger.kind}:${trigger.start}`;
	useEffect(() => {
		dispatch({ kind: "token", id: triggerId });
		// eslint-disable-next-line react-hooks/exhaustive-deps -- keyed on token identity, not the object
	}, [triggerId]);
	useEffect(() => {
		if (recalled !== null && draft !== recalled) dispatch({ kind: "recalled", line: null });
	}, [draft, recalled]);
	// Keep the picked row on screen. The command list is every command this
	// conversation can run and the box holds eight and a half rows, so the arrows
	// walk past the fold: without this a reader presses Down, the highlight
	// leaves the box, and Enter takes a row they cannot see. `nearest` rather
	// than centring, so a pick already in view does not shunt the list under the
	// pointer for no reason. Layout, not paint: the row is picked and scrolled to
	// in one frame rather than flashing at the old offset first. status-allow: replacement state identity
	useLayoutEffect(() => {
		if (!listOpen) return;
		document.getElementById(`complete-${pick}`)?.scrollIntoView({ block: "nearest" });
	}, [listOpen, pick]);
	const syncCaret = (box: HTMLTextAreaElement) => dispatch({ kind: "caret", caret: box.selectionStart ?? 0 });
	const accept = (candidate: Candidate) => {
		if (trigger === null) return;
		const next = acceptCompletion(draft, trigger, caret, candidate);
		session.setDraft(next.text);
		dispatch({ kind: "caret", caret: next.caret });
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
	const joiningProgress = useProgress(
		conv?.type === "room" && conv.membership === "joining",
		PRESENTATION.connection,
		conv?.key,
	);
	const recoverRoom = () => {
		if (conv?.type !== "room" || recoveringRoom) return;
		if (conv.held && conv.linkToken == null) {
			browser.aboutConversation("capabilities");
			return;
		}
		dispatch({ kind: "recovering", held: true });
		void actionRefusal(() => session.recoverRoom(conv.key)).then((refused) => {
			if (refused !== "") browser.toast("failure", refused);
		}).finally(() => dispatch({ kind: "recovering", held: false }));
	};

	// Rooms and direct lines both carry an ephemeral typing level. Every way of
	// stopping (sending, going idle, blurring, switching away, closing the tab)
	// is this one condition going false.
	useTypingSignal(
		enabled && focused && conv !== null && (conv.type !== "dm" || conv.line === "live") &&
			draft.trim() !== "" && conversationCarries(conv, "typing"),
		draft,
		session.setTyping,
	);

	// Never carry a stray tray across a conversation switch. Arriving at a
	// conversation on a wide screen also takes the caret, so you can type at once;
	// on a phone it must not, because forcing the keyboard up would cover the
	// messages you just opened. The composer can become sendable after the
	// reader has moved on to another field, such as naming a new room; taking
	// the caret then would close that field under their typing.
	useEffect(() => {
		dispatch({ kind: "tray", open: false });
		if (mobile || !enabled) return;
		const held = document.activeElement;
		if (
			held instanceof HTMLElement && held !== field.current &&
			held.matches("input, textarea, select, [contenteditable='true']")
		) return;
		field.current?.focus();
	}, [conv?.key, mobile, enabled]);

	useEffect(() => {
		dispatch({ kind: "recalled", line: null });
	}, [conv?.key]);

	// Pressing Edit hands the words over; this hands the caret over with them, at
	// the end of what is being rewritten. Without it the field fills up while the
	// focus stays on the mark that was pressed, and that mark is gone the moment
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
	// every file with no caption left is a real instruction. It takes the line
	// down. So a file-line change is always sendable; `draftKeeping` is what says
	// this is one.
	const canSend = draft.trim() !== "" || draftFiles.length > 0 || draftKeeping !== undefined;
	// Editing a file line down to no files and no caption leaves nothing for the
	// message to be, so sending takes it back. That is a real thing to want, it
	// is how the last file comes off a message that was only ever its files, but
	// it must not arrive as a surprise: the bar above says what will happen and
	// the control below stops calling itself Send.
	const emptiesLine = draftKeeping !== undefined && draftKeeping.length === 0 && draftFiles.length === 0 &&
		draft.trim() === "";
	const addressee = conv
		? (conv.type === "dm"
			? composerMessageDirectly(conv.id)
			: conv.type === "room"
			? composerMessageRoom(roomCalled(conv.id, conv.held))
			: conv.type === "directory"
			? composerCommandLike
			: composerMessage)
		: composerMessage;
	// A placeholder names the addressee, and only while there is one to name. Why
	// the field is unavailable is said once, on the line under it, which is where
	// a standing condition belongs and the one place it can be read at all: a
	// placeholder is hidden by whatever the reader had already typed, and a
	// reason that disappears behind their own draft is a field that has gone
	// quiet on them. The accessible name below carries it either way.
	const sendCooldown = useActionCooldown(`send:${conv?.key ?? ""}`);
	const unavailable = availability || (!enabled && conv ? PHASE_SAID[phase] : "");
	const placeholder = enabled ? addressee : "";
	useComposerMeasure({ field, band: bar, draft, enabled, placeholder, onMeasured: keepLatestInView });

	return (
		<div className="composer" ref={bar}>
			<EmojiTray
				open={emojiOpen}
				onPick={(glyph) => {
					insertAtCursor(glyph);
					dispatch({ kind: "tray", open: false });
				}}
			/>
			{listOpen && (
				<CompletionList
					candidates={candidates}
					pick={pick}
					onPick={(picked) => dispatch({ kind: "pick", picked })}
					onAccept={accept}
				/>
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
							? composerEmptiesLine
							: draftKeeping !== undefined
							? composerEditingFiles
							: composerEditingMessage}
					</span>
					<IconButton
						icon="close"
						label={composerStopEditing}
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
					   ones, each removable. A × here drops a file the line already has.
					   A × below drops one about to be added. */
				}
				{draftKeeping !== undefined && draftKeeping.length > 0 && (
					<div className="composer-files" aria-label={composerFilesOnLine}>
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
					<div className="composer-files" aria-label={composerAttachedFiles}>
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
				{conv != null && conv.type !== "directory" && (
					<DraftLinkPreviews conversation={conv.key} previews={draftPreviews} />
				)}
				<DraftSync convKey={conv?.key ?? null} />
				<ActionFeedback action={`send:${conv?.key ?? ""}`} />
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
							? (conv?.type === "directory" ? composerCommand : composerMessage)
							: unavailable || composerMessageUnavailable}
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
						onBlur={() => dispatch({ kind: "focused", held: false })}
						onFocus={() => {
							dispatch({ kind: "focused", held: true });
							// The keyboard slides in on a phone; once it has settled, bring
							// the newest messages into view so you see what you are replying
							// to. Two passes ride out the animation without a magic delay.
							if (!mobile) return;
							keepLatestInView(true);
							setTimeout(() => keepLatestInView(true), KEYBOARD_SETTLE_MS);
						}}
						onKeyDown={(e) => {
							// Bold, italic, code, and struck out by chord, on whatever is
							// selected. Ahead of everything else because the browser has its
							// own ideas about these chords, and the field is where a reader
							// expects the editor's.
							const marker = markerFor(e);
							if (marker !== null) {
								e.preventDefault();
								const box = e.currentTarget;
								const next = wrapSelection(
									box.value,
									box.selectionStart ?? 0,
									box.selectionEnd ?? 0,
									marker,
								);
								session.setDraft(next.text);
								queueMicrotask(() => {
									box.setSelectionRange(next.start, next.end);
									syncCaret(box);
								});
								return;
							}
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
									dispatch({ kind: "pickStepped", step, count: candidates.length });
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
									dispatch({ kind: "dismissed", at: trigger?.start ?? null });
									return;
								}
							}
							if (e.key === "Escape" && emojiOpen) {
								dispatch({ kind: "tray", open: false });
								return;
							}
							// Escape backs out of rewriting a line, which is the one way
							// out that does not need the mouse. The line stays as posted.
							if (e.key === "Escape" && changing !== undefined) {
								browser.cancelChange();
								return;
							}
							// An empty field's Up is otherwise a no-op. Fill it with the last
							// line submitted here, including a command that never appeared in
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
										dispatch({ kind: "recalled", line: last });
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
									dispatch({ kind: "recalled", line: null });
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
						{
							/* Drawn only where a file can go: a direct line, or a room whose
						    membership holds the files facet. A control that can never work
						    is not disabled but absent, the way the subject control is absent
						    without the subject facet. A file that arrives anyway, by paste
						    or drop, is told why in the log by the one admission all three
						    ways share. */
						}
						{conversationTakesFiles(conv) && (
							<IconButton
								id="attachBtn"
								icon="clip"
								label={composerAttach}
								size={mobile ? "large" : "normal"}
								variant="ghost"
								disabled={!enabled}
								onMouseDown={(e) => e.preventDefault()}
								onClick={() => filePick.current?.click()}
							/>
						)}
						<IconButton
							id="emojiBtn"
							icon="smile"
							label={composerEmoji}
							size={mobile ? "large" : "normal"}
							variant="ghost"
							aria-controls="emojiPop"
							aria-expanded={emojiOpen}
							disabled={!enabled}
							onMouseDown={(e) => e.preventDefault()}
							onClick={() => dispatch({ kind: "tray", open: !emojiOpen })}
						/>
						{
							/* The way to the writing help. On a wide screen it is a link in
						    the hint under an empty field. A phone draws no hint, so the
						    same way stands here among the tools instead. */
						}
						{mobile && (
							<IconButton
								id="composerFormatting"
								icon="help"
								label={composerHintFormatting}
								size="large"
								variant="ghost"
								disabled={!enabled || conv?.type === "directory"}
								onClick={(event) =>
									openModalFrom(event.currentTarget, () => browser.openHelp("writing"))}
							/>
						)}
					</div>
					{roomWaiting && canInteract && (conv.membership !== "joining" || joiningProgress)
						? (
							<Button
								id="roomReconnect"
								type="button"
								busy={recoveringRoom || conv.membership === "joining"}
								disabled={recoveringRoom || conv.membership === "joining"}
								onClick={recoverRoom}
							>
								{conv.membership === "joining"
									? composerJoining
									: conv.held && conv.linkToken == null
									? composerRestoreAccess
									: nick === ""
									? composerJoin
									: composerRetryJoining}
							</Button>
						)
						: (
							<IconButton
								id="sendBtn"
								icon={emptiesLine ? "close" : "send"}
								label={emptiesLine ? composerTakeBack : composerSend}
								size={mobile ? "large" : "normal"}
								variant={canSend ? "solid" : "outline"}
								tone={emptiesLine ? "danger" : canSend ? "accent" : "neutral"}
								shape="circle"
								type="submit"
								disabled={!enabled || !canSend || sendCooldown > 0}
							/>
						)}
				</div>
			</form>
			<ComposerStatus
				unavailable={unavailable}
				capSaid={capSaid}
				convKey={conv?.key ?? null}
				nick={nick}
				mobile={mobile}
				directory={conv?.type === "directory"}
			/>
		</div>
	);
}
