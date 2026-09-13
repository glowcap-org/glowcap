// The directory pane: what this directory holds, and the authority to change
// it.
//
// Two capabilities fill this one address, and they list the same inventories:
// the operator's rows carry the handles that retire them, and inspect's do
// not. So a tab holding operator is shown the operator's page alone, because
// drawing the read-only one beside it would be the same rooms twice with only
// one of the two able to act. A tab holding only inspect is shown that page
// with nothing to press.
//
// The page's own trouble journal belongs to the address rather than to either
// capability, so it stands under whichever half drew.

import { lazy, Suspense, useEffect } from "react";
import type { DiagnosticRow, RoomsOperatorState, TroubleRow } from "../types.ts";
import { loadDiagnosticsPane, loadOperatorPane, prefetch } from "../chunks.ts";
import { ErrorBoundary } from "../ErrorBoundary.tsx";
import { OpsLoading } from "./Loading.tsx";
import { SectionTitle } from "./Section.tsx";
import { opsBrowserTroubleTitle } from "../../../lib/text/ops.ts";
import {
	opsDirectoryHoldingsLoading,
	opsInspectPane,
	opsOperatorPane,
	opsOperatorStateLoading,
} from "../../../lib/text/ops.ts";

const OperatorPane = lazy(() => loadOperatorPane());
const DiagnosticsPane = lazy(() => loadDiagnosticsPane());

export function DirectoryPane(
	{ operatorHeld, operator, inspectHeld, rows, trouble }: {
		operatorHeld: boolean;
		operator: RoomsOperatorState | null;
		inspectHeld: boolean;
		rows: readonly DiagnosticRow[] | null;
		trouble: readonly TroubleRow[];
	},
) {
	useEffect(() => {
		if (operatorHeld) prefetch(loadOperatorPane);
		else if (inspectHeld) prefetch(loadDiagnosticsPane);
	}, [operatorHeld, inspectHeld]);
	const wait = operatorHeld ? opsOperatorStateLoading : opsDirectoryHoldingsLoading;
	const crash = operatorHeld ? opsOperatorPane : opsInspectPane;
	return (
		<div className="ops-pane">
			<ErrorBoundary part={crash}>
				<Suspense fallback={<OpsLoading what={wait} />}>
					{operatorHeld
						? (operator === null
							? <OpsLoading what={opsOperatorStateLoading} />
							: <OperatorPane state={operator} />)
						: inspectHeld
						? (rows === null
							? <OpsLoading what={opsDirectoryHoldingsLoading} />
							: <DiagnosticsPane rows={rows} />)
						: null}
				</Suspense>
			</ErrorBoundary>
			{trouble.length > 0 && (
				<>
					{
						/* Failures with no reader-facing surface of their own land here
				   instead of dying in the console, newest first, repeats folded
				   into a count. No empty well is drawn: the absence of a browser
				   failure already says there is nothing to inspect. */
					}
					<section className="ops-section">
						<SectionTitle>{opsBrowserTroubleTitle}</SectionTitle>
						<div className="group well" id="pageTrouble">
							<ul className="ops-trouble">
								{trouble.map((row, at) => (
									<li key={row.source + row.reason + String(at)}>
										<span className="ops-kind">{row.source}</span>
										<span className="ops-note">{row.reason}</span>
										{row.count > 1 && <span className="ops-trouble-count">×{row.count}</span>}
									</li>
								))}
							</ul>
						</div>
					</section>
				</>
			)}
		</div>
	);
}
