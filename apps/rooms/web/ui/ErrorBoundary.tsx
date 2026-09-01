// What the page does when a render throws.
//
// One wraps the whole page, so the worst case is a card explaining itself rather
// than a white page. The others wrap each pane that draws text other people sent,
// which is the rule rather than a number: a line, a nick, or a room name that
// somehow cannot be drawn takes down the pane it is in and nothing else, and the
// rest of the page stays up. That is the same posture the rest of the project
// takes, failing closed at the layer that owns the failure.
//
// Neither of them stops the peer. The CapTP session is not owned by React and
// does not live in this tree, so messages keep arriving and the store keeps
// taking them while a boundary is showing; recovering re-reads the state that
// accumulated meanwhile.

import { Component, type ErrorInfo, type ReactNode } from "react";
import { coveringReload, handOffNow } from "./boot.ts";
import { Button } from "./Button.tsx";
import { Said } from "./Said.tsx";

interface Props {
	/** What this boundary protects, in words a reader would use. */
	part: string;
	children: ReactNode;
}

interface Boundary {
	failed: Error | null;
}

/** The card a boundary puts up in place of the part it was protecting. */
export function CrashCard(
	{ part, message, onRetry }: { part: string; message: string; onRetry: () => void },
) {
	return (
		<div className="crash" role="alert">
			<h2>The {part} ran into a problem</h2>
			<Said kind="failure">{message}</Said>
			<p>Your session is still open, so nothing has been lost.</p>
			<Button variant="quiet" onClick={onRetry}>Try again</Button>
		</div>
	);
}

export class ErrorBoundary extends Component<Props, Boundary> {
	override state: Boundary = { failed: null };

	static getDerivedStateFromError(failed: Error): Boundary {
		return { failed };
	}

	override componentDidCatch(failed: Error, info: ErrorInfo) {
		if (coveringReload()) return;
		console.error(
			`rooms: the ${this.props.part} ran into a problem:`,
			failed,
			info.componentStack,
		);
		// The card below is for a reader, so it has to be one a reader can see.
		// On a load where the peer has not answered yet, the opening screen is
		// still over the page, and it would sit on top of that card waiting for a
		// session that may never open.
		handOffNow();
	}

	override render() {
		const { failed } = this.state;
		if (!failed) return this.props.children;
		if (coveringReload()) return null;
		return (
			<CrashCard
				part={this.props.part}
				message={failed.message || "Something in this part of the page went wrong."}
				onRetry={() => this.setState({ failed: null })}
			/>
		);
	}
}
