// Trace publication follows the exact capability held by this workspace.
import {
	traceEndpointLabel,
	traceLead,
	traceNowTitle,
	traceOn,
	tracePublisherShared,
	tracePublisherTab,
	tracePublishing,
	traceReconnecting,
	traceRefused,
} from "../../../lib/text/ops.ts";
import { useRoomsController } from "../controller/browser.ts";
import { useRoomsSession } from "../controller/session.ts";
import { Said } from "../Said.tsx";
import type { TracePublishState } from "../types.ts";
import { OpsHead } from "./Head.tsx";
import { SectionTitle } from "./Section.tsx";
import { sharedRoomsSession } from "../../../lib/workspace_view.ts";

export function TracePane({ state }: { state: TracePublishState | null }) {
	const session = useRoomsSession();
	const controller = useRoomsController();
	if (state === null) return null;
	const publisher = sharedRoomsSession(controller) != null ? tracePublisherShared : tracePublisherTab;
	return (
		<div className="ops-pane">
			<OpsHead refresh={() => session.refreshOpsCap("trace")}>{traceLead(publisher)}</OpsHead>
			<section className="ops-section">
				<SectionTitle id="traceNowLegend">{traceNowTitle}</SectionTitle>
				<div className="group well" role="group" aria-labelledby="traceNowLegend">
					<dl className="dirfacts">
						<dt>{traceEndpointLabel}</dt>
						<dd>{state.url}</dd>
						<dt>{tracePublishing}</dt>
						<dd
							id="tracePublishing"
							data-connected={String(state.connected)}
							data-refusal={state.refusal ?? undefined}
						>
							{state.connected ? traceOn : state.refusal != null ? traceRefused : traceReconnecting}
						</dd>
					</dl>
					{state.refusal != null && <Said id="traceRefusal" kind="failure">{state.refusal}</Said>}
				</div>
			</section>
		</div>
	);
}
