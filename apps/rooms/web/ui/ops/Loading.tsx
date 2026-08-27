// The first answer from an Operations capability has not arrived yet.
//
// A held pane is already a real destination, so returning null while its
// first fetch runs makes the card look broken. These quiet lines reserve the
// pane's ordinary rhythm without pretending to know whether the answer will
// be a table, a form, or an empty sentence. Refreshes keep the known answer on
// screen and put progress on the refresh control instead; this is only for the
// first answer.

export function OpsLoading({ what }: { what: string }) {
	return (
		<div className="ops-loading" role="status" aria-live="polite">
			<span className="visually-hidden">Loading {what}…</span>
			<span className="ops-loading-line lead-line" aria-hidden="true" />
			<div className="group well" aria-hidden="true">
				<span className="ops-loading-line title-line" />
				<span className="ops-loading-line" />
				<span className="ops-loading-line short-line" />
			</div>
		</div>
	);
}
