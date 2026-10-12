import { useEffect, useRef, useState } from "react";
import { c, FONT, SIZE, SPACE } from "../tokens.ts";
import { Dialog } from "../Dialog.tsx";
import { type AppError, subscribeErrors } from "./error-bus.ts";

/**
 * Blocking modal for errors that should stop the user until
 * acknowledged: `import` failures, `internal` exceptions, and the
 * React error boundary's trip state.
 *
 * Split into two pieces by responsibility:
 *
 *   - `ErrorModalView`, what an error says and what a person can do about
 *     it. The box it says it in, and the keyboard contract it owes, are
 *     `Dialog`'s. No subscriptions, no router knowledge, so
 *     `AppErrorBoundary` can render it even after React has unmounted the
 *     bus-subscribed tree.
 *   - `BusErrorModal`, subscribes to the error bus, owns the
 *     visibility state, and dismisses on the user's primary action.
 *     The default modal mounted under `<App />`.
 */
export function ErrorModalView(
	{ title, detail, recovery, primaryLabel, onPrimary, onDismiss }: {
		title: string;
		detail: string;
		recovery: string;
		primaryLabel: string;
		onPrimary: () => void;
		/** What Escape does. Omitted when the dialog has nowhere to go, the
		 *  error boundary's, where the app behind it is already broken and
		 *  dismissing would take away the only explanation. */
		onDismiss?: (() => void) | undefined;
	},
) {
	const primaryRef = useRef<HTMLButtonElement | null>(null);

	const copyDetail = () => {
		const text = `${title}\n\n${detail}\n\n${recovery}`;
		void navigator.clipboard?.writeText(text);
	};
	return (
		<Dialog
			role="alertdialog"
			title={title}
			titleTone="danger"
			autoFocusRef={primaryRef}
			onPrimary={onPrimary}
			onDismiss={onDismiss}
			footer={
				<>
					{
						/* Both are `ocv-btn` and nothing else: the box, the corner,
              the bevel, the hover and the focus ring are the app's, and
              `is-primary` is the one thing that distinguishes the answer
              from the aside. They used to carry a style object of their
              own, which is how they came to be the only buttons in the
              app with a three-pixel corner and no hover. */
					}
					<button
						type="button"
						className="ocv-btn"
						onClick={copyDetail}
					>
						Copy detail
					</button>
					<button
						type="button"
						className="ocv-btn is-primary"
						ref={primaryRef}
						onClick={onPrimary}
					>
						{primaryLabel}
					</button>
				</>
			}
		>
			<div
				style={{
					fontSize: SIZE.base,
					color: c.text,
					marginBottom: SPACE.md,
					fontFamily: FONT.sans,
					whiteSpace: "pre-wrap",
				}}
			>
				{detail}
			</div>
			<div
				style={{
					fontSize: SIZE.sm,
					color: c.textMuted,
					fontFamily: FONT.sans,
				}}
			>
				{recovery}
			</div>
		</Dialog>
	);
}

/** Bus-subscribed modal: shows the most recent `internal` or
 * `import` error from the bus. Primary button dismisses. */
export function BusErrorModal() {
	const [current, setCurrent] = useState<AppError | null>(null);
	useEffect(() => {
		return subscribeErrors((event) => {
			if (
				event.error.code === "internal" || event.error.code === "import"
			) {
				setCurrent(event);
			}
		});
	}, []);
	if (!current) return null;
	return (
		<ErrorModalView
			title={current.error.title}
			detail={current.error.detail}
			recovery={current.error.recovery}
			primaryLabel="Dismiss"
			onPrimary={() => setCurrent(null)}
			onDismiss={() => setCurrent(null)}
		/>
	);
}
