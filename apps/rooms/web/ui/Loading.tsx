// A wait that has a destination: a code chunk, or a capability's first answer.
//
// The quiet sheen is the same one the operations pane already used for its
// first fetch, so a chunk load and a server round-trip feel like the same
// kind of pause. `pane` stands in for an operations pane, `page` for the
// content cell, `catalog` for the parts catalog inside Help.

import { loadingWhat } from "../../lib/text/page.ts";

export type LoadingLayout = "pane" | "page" | "catalog";

export function LoadingSurface({ what, layout }: { what: string; layout: LoadingLayout }) {
	const surface = layout === "pane"
		? "ops-pane ops-loading"
		: layout === "page"
		? "chunk-loading chunk-loading-page"
		: "chunk-loading chunk-loading-catalog";
	return (
		<div className={surface} role="status" aria-live="polite" aria-label={loadingWhat(what)}>
			<span className="ops-loading-line lead-line" aria-hidden="true" />
			<div className="group well" aria-hidden="true">
				<span className="ops-loading-line title-line" />
				<span className="ops-loading-line" />
				<span className="ops-loading-line short-line" />
			</div>
		</div>
	);
}

/** An operations pane whose first answer has not arrived, or whose chunk is
 * still on the way. Same shape either way. */
export function OpsLoading({ what }: { what: string }) {
	return <LoadingSurface what={what} layout="pane" />;
}
