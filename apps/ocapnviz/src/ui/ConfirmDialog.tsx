import { useRef, useSyncExternalStore } from "react";
import { Dialog } from "./Dialog.tsx";
import { currentConfirm, subscribeConfirm } from "./confirm.ts";
import { c, FONT, SIZE } from "./tokens.ts";

/**
 * The one dialog that asks before an act takes work away.
 *
 * Mounted once under the app, beside the error modal, and showing nothing until
 * something asks. One rather than one per question, for the reason `Dialog` is
 * one component: a keyboard contract that holds in some dialogs and not others is
 * worse than none, and these are the dialogs where getting it wrong costs a
 * reader their work.
 *
 * # The default answer is no
 *
 * Focus lands on Cancel, so Enter cancels and Escape cancels, and going ahead
 * takes a deliberate move. That is the opposite of the browser's own dialog,
 * which focuses OK, and the difference is the point: every question that reaches
 * here is about destroying something, so the answer a reader gives by reflex
 * should be the one that keeps their work.
 *
 * `onPrimary` is what Enter does when focus is not on a button, and it cancels
 * too. Both agree, which is what makes it safe rather than merely likely: there
 * is no path through the keyboard that goes ahead without the reader saying so.
 *
 * The ref is explicit even though Cancel is also the first control in the panel
 * and `Dialog` would land there anyway. Focus starting on the safe answer is a
 * property worth stating, not one to leave resting on the order two buttons
 * happen to be written in.
 */
export function ConfirmDialog() {
	const pending = useSyncExternalStore(
		subscribeConfirm,
		currentConfirm,
		currentConfirm,
	);
	const cancelRef = useRef<HTMLButtonElement | null>(null);
	if (!pending) return null;
	const cancel = () => pending.answer(false);
	return (
		<Dialog
			// What a person has to deal with before carrying on, which is the same
			// reading the error modal asks for.
			role="alertdialog"
			title={pending.title}
			titleTone="danger"
			autoFocusRef={cancelRef}
			onPrimary={cancel}
			onDismiss={cancel}
			footer={
				<>
					<button
						type="button"
						className="ocv-btn"
						ref={cancelRef}
						onClick={cancel}
					>
						Cancel
					</button>
					{
						/* Neither button is accented. `is-primary` would dress the
              destructive answer as the recommended one, and putting it on Cancel
              would accent a button whose whole job is to change nothing. The
              labels carry the difference, which is why `confirmLabel` names the
              act rather than agreeing with the question. */
					}
					<button
						type="button"
						className="ocv-btn"
						onClick={() => pending.answer(true)}
					>
						{pending.confirmLabel}
					</button>
				</>
			}
		>
			<div style={detail}>{pending.detail}</div>
		</Dialog>
	);
}

const detail = {
	fontSize: SIZE.base,
	color: c.text,
	fontFamily: FONT.sans,
	lineHeight: 1.5,
} satisfies React.CSSProperties;
