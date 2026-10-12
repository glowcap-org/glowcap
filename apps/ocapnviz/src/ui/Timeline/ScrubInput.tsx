/**
 * ScrubInput, Maya/Blender-style scrub-or-type numeric input.
 *
 *   click + drag:           scrub live (DCC convention)
 *   click without drag:     focus, select-all, type, Enter/blur
 *                            commits, Esc reverts
 *   wheel:                  same as drag (up/right = increase)
 *   shift / alt:            0.1× / 10× sensitivity
 *   double-click:           reset to `defaultValue` if provided
 *
 * Sensitivity is logarithmic by default, `pxPerDoubling` px of
 * drag doubles/halves the value, scale-invariant.
 */

import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { useGestureSurface } from "../../interactions/use-gesture-surface.ts";
import { FONT, SIZE } from "../tokens.ts";

const SCRUB_INPUT_SURFACE_TAG = "ui-scrub-input";
// Chrome lives in `.ocv-input.is-numeric` in controls.css, the input
// family, because a value you can type is what this is. The scrub is a
// gesture the component adds on top, not a different kind of control.
const NUMERIC_CLASS = "ocv-input is-numeric";

export type ScrubInputProps = {
	/** Controlled value, parent owns the state.
	 *
	 *  A FUNCTION where the value lives outside React and moves faster than a
	 *  render: the stage camera's scale changes every frame of a wheel gesture, and
	 *  its store wakes React only when the reading a person can see
	 *  changes. Passing the number would mean a drag multiplied from whatever the
	 *  last render happened to catch, which is off by up to one rounding of the
	 *  display, small, and visible as a jump on mousedown. A getter is read at the
	 *  moment the gesture starts, so it starts from the truth.
	 *
	 *  Read through one accessor for display, drag, wheel and arrow keys alike, so
	 *  the four cannot come to disagree about where the value comes from. */
	value: number | (() => number);
	/** Called with the next value during drag and on commit. */
	onChange: (next: number) => void;
	min: number;
	max: number;
	/** Format for display (units, suffixes, etc.). */
	format: (value: number) => string;
	/** Format for the editable draft string. Defaults to `String`
	 * (no units). */
	formatInput?: (value: number) => string;
	/** Parse user-typed text. Defaults to `parseFloat` (handles
	 * "1.5", "1.5×", "0.25s" etc.). Return null to reject. */
	parse?: (text: string) => number | null;
	/** Double-click-to-reset target. */
	defaultValue?: number;
	/** Px of drag per value doubling (log mode) / per +1 (linear).
	 * Lower = more sensitive. */
	pxPerDoubling?: number;
	/** Linear scaling instead of logarithmic. */
	linear?: boolean;
	label?: string;
	/** Extra classes on both the display and the edit element, after the numeric
	 *  family's own. `is-segment` makes the pill a cell of a segmented row: the two
	 *  are modifiers on one field family and compose, so a control can be a value
	 *  you scrub AND a cell in a row without either class knowing about the other. */
	className?: string;
	/** Scrub-session brackets. `onScrubStart` fires once when a
	 * gesture that emits continuous changes begins, a drag crossing
	 * its threshold, or the first wheel event of a burst, and
	 * `onScrubEnd` fires once when it settles (drag release, wheel
	 * quiet for a beat). Hosts whose `onChange` mints undoable edits
	 * wrap the pair in a transaction so one gesture is ONE undo step
	 * instead of one per event. A typed edit commits once on
	 * Enter/blur and needs no bracket. */
	onScrubStart?: () => void;
	onScrubEnd?: () => void;
	/** Caller-supplied style overrides for the display + edit
	 * elements. Merged after the internal layout style so callers
	 * can adjust typography (font, size, min-width) to match the
	 * surrounding context, e.g. an Inspector kv row using
	 * `valueMono` typography rather than the default chrome size. */
	style?: React.CSSProperties;
};

const DEFAULT_PX_PER_DOUBLING = 100;
/** Drag must exceed this many px before we count it as a scrub.
 * Below this a click commits to edit mode instead. */
const DRAG_THRESHOLD_PX = 2;
/** Wheel deltas are ~100 per notch, damp so one notch is roughly
 * 1.15× value change at default settings. */
const WHEEL_DAMPING = 5;
/** A wheel gap longer than this ends the burst's scrub session. */
const WHEEL_SESSION_QUIET_MS = 250;

const defaultParse = (text: string): number | null => {
	const n = Number.parseFloat(text);
	return Number.isFinite(n) ? n : null;
};

// What a ScrubInput is beyond an input: a mono, tabular read-out.
// Numeric controls in this app are always inline in dense toolbars or
// sidebar kv rows, so they read one notch down from chrome text; the
// previous 11px sans default never had a caller. Callers can still
// override via `style`.
//
// The box is not here. Height, corner, inset, bevel, background, hover
// and the width floor all come from `.ocv-input.is-numeric`, and an
// inline copy of any of them would beat the class and freeze it, which
// is what the floor did, at 40px against a class that said 56.
const BASE_STYLE: React.CSSProperties = {
	fontFamily: FONT.mono,
	fontSize: SIZE.sm,
	fontVariantNumeric: "tabular-nums",
};

export function ScrubInput(
	{
		value: valueSource,
		onChange,
		min,
		max,
		format,
		formatInput = String,
		parse = defaultParse,
		defaultValue,
		pxPerDoubling = DEFAULT_PX_PER_DOUBLING,
		linear = false,
		label,
		className,
		onScrubStart,
		onScrubEnd,
		style,
	}: ScrubInputProps,
) {
	// The one place the value is read. Through a ref so the accessor is stable
	// across renders, and so a wheel event, which fires faster than React renders,
	// sees the current prop rather than the one its listener closed over.
	const source = useRef(valueSource);
	source.current = valueSource;
	const readValue = useCallback(
		() => typeof source.current === "function" ? source.current() : source.current,
		[],
	);
	// Gesture-local value. Inspector hosts often subscribe to `docVersion`,
	// which stays quiet inside an edit transaction, so the controlled prop
	// does not move mid-scrub. Wheel ticks must accumulate from THIS, not
	// from the stale prop, otherwise each event recomputes from the
	// pre-gesture number and the field fights itself.
	const liveRef = useRef<number | null>(null);
	const [liveDisplay, setLiveDisplay] = useState<number | null>(null);
	const value = liveDisplay ?? readValue();
	const classes = className ? `${NUMERIC_CLASS} ${className}` : NUMERIC_CLASS;
	// Bumped on every publish so a deferred clear from a prior gesture
	// cannot wipe a newer overlay still in flight.
	const liveGenRef = useRef(0);

	const publishLive = useCallback(
		(next: number, emit: (n: number) => void) => {
			liveGenRef.current += 1;
			liveRef.current = next;
			setLiveDisplay(next);
			emit(next);
		},
		[],
	);

	/** Drop the overlay after the controlled prop has had a chance to
	 *  absorb the gesture. Clearing in the same turn as `onScrubEnd`
	 *  flashes the pre-gesture digits for a frame. A generation token
	 *  keeps a stale rAF from clearing a newer scrub that started in
	 *  between. */
	const clearLiveSoon = useCallback(() => {
		const gen = liveGenRef.current;
		requestAnimationFrame(() => {
			if (liveGenRef.current !== gen) return;
			liveRef.current = null;
			setLiveDisplay(null);
		});
	}, []);

	const dragRef = useRef<DragState>(null);
	// At rest the element advertises vertical scrub (the dominant
	// convention). On drag, the axis is locked to whichever
	// direction the user moves in first, and the body cursor swaps
	// to match, same model as stage drag. Wheel/scroll handles
	// both axes independently below (up + right raise).
	const restCursor = "ns-resize";
	const clamp = useCallback(
		(n: number) => Math.max(min, Math.min(max, n)),
		[min, max],
	);

	const [editing, setEditing] = useState(false);
	const [draft, setDraft] = useState("");
	// Display width captured at the moment we swap into edit mode.
	// Native <input> defaults to size=20 (~20 char widths), which is
	// much wider than this control's display state, pinning to the
	// measured width prevents any shift when the mode flips.
	const [lockedWidth, setLockedWidth] = useState<number | null>(null);
	const displayRef = useRef<HTMLDivElement | null>(null);
	const inputRef = useRef<HTMLInputElement | null>(null);

	// This surface's lease on the gesture lock. The hook ends a held
	// gesture when the input leaves the tree, which matters here more
	// than anywhere else in the app: scrub inputs are rendered inside
	// lists that re-key and drop rows, and a row removed mid-drag
	// takes its React pointer handlers with it before any pointerup
	// can reach them. So `cleanupDrag` is this surface's only end, and
	// it runs on every path to one. That is what restores the body
	// cursor and fires `onScrubEnd` for a row that goes away under the
	// pointer. The arrow reads it late, after this render has finished.
	const surface = useGestureSurface(
		SCRUB_INPUT_SURFACE_TAG,
		() => cleanupDrag(),
	);

	// Capture current display width and switch to input. Used by both
	// pointer (click without drag) and keyboard (F2 / Enter) paths.
	const enterEdit = useCallback(() => {
		const w = displayRef.current?.getBoundingClientRect().width;
		if (w !== undefined && w > 0) setLockedWidth(w);
		setEditing(true);
	}, []);

	// Set while leaving edit mode with the caret still in the input,
	// which is what tells the effect below to hand focus back.
	const restoreFocusRef = useRef(false);

	// Focus follows the mode swap, both ways, in one effect so the
	// hand-back cannot be dropped independently of the take. Entering
	// edit mode seeds the draft from `formatInput` (just the number
	// by default. No units) and selects it so the user can type
	// straight away. Leaving hands focus to the display chrome that
	// replaces the input, so Tab carries on from this control instead
	// of restarting at the top of the document.
	//
	// Deps narrow: only on a change of mode. A
	// parent-driven `value` change while the user is typing must NOT
	// overwrite their draft.
	useLayoutEffect(() => {
		if (editing) {
			setDraft(formatInput(readValue()));
			const el = inputRef.current;
			if (el) {
				el.focus();
				el.select();
			}
			return;
		}
		if (!restoreFocusRef.current) return;
		restoreFocusRef.current = false;
		displayRef.current?.focus();
	}, [editing]);

	const exitEdit = useCallback(() => {
		// Enter and Escape commit with the caret still here, so the
		// user is still on this control and focus belongs back on it.
		// A blur commit means they have already clicked somewhere
		// else, and pulling focus back from where they went would be
		// worse than dropping it.
		restoreFocusRef.current = inputRef.current !== null &&
			globalThis.document.activeElement === inputRef.current;
		setEditing(false);
		setLockedWidth(null);
	}, []);

	const commitDraft = useCallback(() => {
		const parsed = parse(draft);
		if (parsed !== null && !Number.isNaN(parsed)) {
			onChange(clamp(parsed));
		}
		exitEdit();
	}, [draft, parse, onChange, clamp, exitEdit]);

	const cancelEdit = exitEdit;

	const handlePointerDown = useCallback(
		(e: React.PointerEvent<HTMLDivElement>) => {
			if (e.button !== 0) return;
			if (!surface.claim(e.currentTarget, e.pointerId)) return;
			e.preventDefault();
			e.currentTarget.setPointerCapture(e.pointerId);
			// Body cursor is locked once the axis lock is established,
			// until then the pre-drag rest cursor stays in place.
			const bodyCursorPrev = globalThis.document.body.style.cursor;
			dragRef.current = {
				startX: e.clientX,
				startY: e.clientY,
				// Prefer the gesture-local overlay: a recent wheel tick can
				// leave `liveRef` ahead of the still-quiet controlled prop.
				startValue: liveRef.current ?? readValue(),
				moved: false,
				axis: null,
				bodyCursorPrev,
			};
		},
		[readValue, surface],
	);

	const handlePointerMove = useCallback(
		(e: React.PointerEvent<HTMLDivElement>) => {
			// A move with no button held is a pointer-up that went
			// missing, and `watchGestureEnd` has already run `cleanupDrag`
			// by the time this bubbles here. So a live `dragRef` is the
			// whole guard, and no bogus value is emitted for it.
			const drag = dragRef.current;
			if (!drag) return;
			const dx = e.clientX - drag.startX;
			const dy = e.clientY - drag.startY;
			// Lock to whichever axis crosses the threshold first.
			// Up + right = raise; down + left = lower (matches the wheel
			// handler's `-deltaY + deltaX` math).
			if (drag.axis === null) {
				const ax = Math.abs(dx);
				const ay = Math.abs(dy);
				if (ax < DRAG_THRESHOLD_PX && ay < DRAG_THRESHOLD_PX) return;
				drag.axis = ay >= ax ? "y" : "x";
				drag.moved = true;
				onScrubStart?.();
				globalThis.document.body.style.cursor = drag.axis === "y" ? "ns-resize" : "ew-resize";
			}
			const raw = drag.axis === "y" ? -dy : dx;
			const fineness = e.shiftKey ? 0.1 : e.altKey ? 10 : 1;
			const effectivePxPerDoubling = pxPerDoubling / fineness;
			let next: number;
			if (linear) {
				next = drag.startValue + (raw / effectivePxPerDoubling);
			} else {
				next = drag.startValue *
					Math.pow(2, raw / effectivePxPerDoubling);
			}
			const clamped = clamp(next);
			publishLive(clamped, onChange);
		},
		[linear, clamp, onChange, pxPerDoubling, onScrubStart, publishLive],
	);

	// Idempotent, called from pointerup (synchronous),
	// lostpointercapture (backstop for interrupted paths), and the
	// window watch inside `useGestureSurface` when the release
	// happens somewhere this element cannot see it. Calling several
	// of them keeps the bookkeeping correct regardless of browser
	// order.
	const cleanupDrag = useCallback(() => {
		surface.release();
		const drag = dragRef.current;
		if (!drag) return;
		globalThis.document.body.style.cursor = drag.bodyCursorPrev;
		const scrubbed = drag.moved;
		dragRef.current = null;
		// After the ref clears so a re-render inside the callback can't
		// observe a half-torn-down drag.
		if (scrubbed) {
			onScrubEnd?.();
			clearLiveSoon();
		} else {
			liveGenRef.current += 1;
			liveRef.current = null;
			setLiveDisplay(null);
		}
	}, [onScrubEnd, surface, clearLiveSoon]);

	// Cleanup happens here synchronously (not deferred to
	// lostpointercapture): `setEditing(true)` re-renders and
	// unmounts this element, and lostpointercapture is async in
	// some browsers, so it can arrive after the tree is gone.
	const handlePointerUp = useCallback(
		(e: React.PointerEvent<HTMLDivElement>) => {
			const drag = dragRef.current;
			if (!drag) return;
			const wasScrub = drag.moved;
			e.currentTarget.releasePointerCapture(e.pointerId);
			cleanupDrag();
			if (!wasScrub) enterEdit();
		},
		[cleanupDrag, enterEdit],
	);

	// Backstop for paths where pointerup never fires (cancel,
	// detach mid-drag, OS gesture, alt-tab).
	const handleLostPointerCapture = useCallback(() => {
		cleanupDrag();
	}, [cleanupDrag]);

	// Wheel/two-finger-scroll → adjust value. Native listener
	// (React's synthetic wheel is passive → preventDefault no-ops).
	// Direction: `-deltaY + deltaX` so up + right both increase, and
	// diagonal trackpad gestures sum cleanly.
	//
	// Ref-reads keep the listener attached for the component's
	// lifetime, wheel fires faster than React renders. Accumulation
	// reads `liveRef` so successive ticks stack instead of rebasing
	// on the still-stale controlled prop.
	const onScrubStartRef = useRef(onScrubStart);
	onScrubStartRef.current = onScrubStart;
	const onScrubEndRef = useRef(onScrubEnd);
	onScrubEndRef.current = onScrubEnd;
	// Non-null while a wheel burst's session is open; the timer that
	// will close it when the wheel goes quiet.
	const wheelSessionRef = useRef<number | null>(null);
	const onChangeRef = useRef(onChange);
	onChangeRef.current = onChange;
	const clampRef = useRef(clamp);
	clampRef.current = clamp;
	const clearLiveSoonRef = useRef(clearLiveSoon);
	clearLiveSoonRef.current = clearLiveSoon;
	useEffect(() => {
		if (editing) return;
		const el = displayRef.current;
		if (!el) return;
		const endWheelSession = () => {
			wheelSessionRef.current = null;
			onScrubEndRef.current?.();
			clearLiveSoonRef.current();
		};
		const onWheel = (e: WheelEvent) => {
			const delta = -e.deltaY + e.deltaX;
			if (delta === 0) return;
			e.preventDefault();
			// A wheel burst is one gesture: open the session on the first
			// event, close it after a quiet beat, so hosts see one
			// bracket (one undo step) per burst instead of one per tick.
			if (wheelSessionRef.current === null) {
				onScrubStartRef.current?.();
			} else {
				clearTimeout(wheelSessionRef.current);
			}
			wheelSessionRef.current = setTimeout(
				endWheelSession,
				WHEEL_SESSION_QUIET_MS,
			);
			const fineness = e.shiftKey ? 0.1 : e.altKey ? 10 : 1;
			const effectivePxPerDoubling = (pxPerDoubling * WHEEL_DAMPING) /
				fineness;
			const cur = liveRef.current ?? readValue();
			const next = linear
				? cur + (delta / effectivePxPerDoubling)
				: cur * Math.pow(2, delta / effectivePxPerDoubling);
			const clamped = clampRef.current(next);
			liveGenRef.current += 1;
			liveRef.current = clamped;
			setLiveDisplay(clamped);
			onChangeRef.current(clamped);
		};
		el.addEventListener("wheel", onWheel, { passive: false });
		return () => {
			el.removeEventListener("wheel", onWheel);
			if (wheelSessionRef.current !== null) {
				clearTimeout(wheelSessionRef.current);
				endWheelSession();
			}
		};
	}, [editing, linear, pxPerDoubling, readValue]);

	const handleDoubleClick = useCallback(() => {
		if (defaultValue !== undefined) onChange(defaultValue);
	}, [defaultValue, onChange]);

	// Display-chrome keyboard:
	//   Arrow up/right     nudge +  (Shift = 10×)
	//   Arrow down/left    nudge -  (Shift = 10×)
	//   Enter / F2         enter edit (Excel convention)
	const handleKeyDown = useCallback(
		(e: React.KeyboardEvent<HTMLDivElement>) => {
			if (e.key === "Enter" || e.key === "F2") {
				e.preventDefault();
				enterEdit();
				return;
			}
			let direction = 0;
			if (e.key === "ArrowUp" || e.key === "ArrowRight") direction = 1;
			else if (e.key === "ArrowDown" || e.key === "ArrowLeft") {
				direction = -1;
			}
			if (direction === 0) return;
			e.preventDefault();
			const stride = e.shiftKey ? 10 : 1;
			const from = readValue();
			const next = linear ? from + direction * stride : from * Math.pow(2, (direction * stride) / 10);
			onChange(clamp(next));
		},
		[readValue, linear, clamp, onChange, enterEdit],
	);

	if (editing) {
		return (
			<input
				ref={inputRef}
				type="text"
				// No edit-state class: entering edit focuses this input and
				// leaving it blurs, so `.ocv-input:focus` already says the
				// digits are live.
				className={classes}
				value={draft}
				// size=1 neutralizes the native default of 20 character
				// widths; `width` (set inline) is what actually sizes us.
				size={1}
				onChange={(e) => setDraft(e.target.value)}
				onKeyDown={(e) => {
					if (e.key === "Enter") {
						e.preventDefault();
						commitDraft();
					} else if (e.key === "Escape") {
						e.preventDefault();
						cancelEdit();
					}
				}}
				onBlur={commitDraft}
				aria-label={label}
				spellCheck={false}
				autoComplete="off"
				style={{
					width: lockedWidth ?? undefined,
					...BASE_STYLE,
					...style,
				}}
			/>
		);
	}

	return (
		<div
			ref={displayRef}
			role="spinbutton"
			tabIndex={0}
			aria-label={label}
			aria-valuenow={value}
			// What the value MEANS, since `aria-valuenow` is the bare number and every
			// caller here shows it in a unit: a scale of 1.77 is "177%", a duration of
			// 6000 is "6s". Without this a screen reader reads the raw number and the
			// sighted reading and the spoken one disagree.
			aria-valuetext={format(value)}
			aria-valuemin={min}
			aria-valuemax={max}
			className={classes}
			onPointerDown={handlePointerDown}
			onPointerMove={handlePointerMove}
			onPointerUp={handlePointerUp}
			onPointerCancel={handleLostPointerCapture}
			onLostPointerCapture={handleLostPointerCapture}
			onDoubleClick={handleDoubleClick}
			onKeyDown={handleKeyDown}
			style={{
				cursor: restCursor,
				touchAction: "none",
				...BASE_STYLE,
				...style,
			}}
			title={label
				? `${label} (drag to scrub — axis locks to first motion; click to type; double-click to reset)`
				: undefined}
		>
			{format(value)}
		</div>
	);
}

type DragState = {
	startX: number;
	startY: number;
	startValue: number;
	moved: boolean;
	/** null until the first cross-threshold motion locks the axis. */
	axis: "x" | "y" | null;
	bodyCursorPrev: string;
} | null;
