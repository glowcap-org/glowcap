import React from "react";
import { INTERNAL_ERROR_TITLE, internalError } from "../../engine/errors.ts";
import { pushError } from "./error-bus.ts";
import { ErrorModalView } from "./ErrorModal.tsx";

interface AppErrorBoundaryState {
	hasError: boolean;
	detail: string;
	recovery: string;
}

/**
 * Top-level React error boundary. Catches synchronous throws during
 * the render phase of any descendant, including the synchronous
 * setup of `useEffect` bodies (Pixi `new Application()` ctor) but
 * NOT async rejections from `app.init().then(...)`, ticker callbacks,
 * or `window` event handlers. Those four async paths land on the
 * error bus via `window.onerror` / `unhandledrejection` (installed
 * in `main.tsx`) and `safeTick` / renderer listeners (commit 3).
 *
 * On trip, this also forwards the error onto the bus so any other
 * subscribed listener (telemetry, future log shipper) sees it.
 */
export class AppErrorBoundary extends React.Component<
	{ children: React.ReactNode },
	AppErrorBoundaryState
> {
	override state: AppErrorBoundaryState = {
		hasError: false,
		detail: "",
		recovery: "",
	};

	static getDerivedStateFromError(error: unknown): AppErrorBoundaryState {
		const err = internalError(error);
		return { hasError: true, detail: err.detail, recovery: err.recovery };
	}

	override componentDidCatch(error: unknown): void {
		pushError({ error: internalError(error), source: "react-boundary" });
	}

	override render(): React.ReactNode {
		if (this.state.hasError) {
			return (
				<ErrorModalView
					title={INTERNAL_ERROR_TITLE}
					detail={this.state.detail}
					recovery={this.state.recovery}
					primaryLabel="Reload"
					onPrimary={() => globalThis.location.reload()}
				/>
			);
		}
		return this.props.children;
	}
}
