// Issued archive-peer shares: independently revocable Host publications.

import { useEffect, useRef, useState } from "react";
import type { ArchiveDurableShareView } from "../../../lib/archive/facet.ts";
import type { ArchiveTargetView } from "../archive_model.ts";
import { Button } from "../Button.tsx";
import { CopyField } from "../Copy.tsx";
import { useRoomsSession } from "../controller/session.ts";
import { Said } from "../Said.tsx";
import { refusalText } from "../../../lib/text/failure.ts";
import { archiveSharesEmpty, archiveSharesLead, archiveSharesTitle } from "../../../lib/text/settings.ts";

/** Whether there is a peer on the other end to ask. */
function reachesPeer(target: ArchiveTargetView): boolean {
	return target.kind === "peer" && target.status === "connected";
}

export function IssuedArchiveShares({ archiveTarget }: { archiveTarget: ArchiveTargetView }) {
	const session = useRoomsSession();
	const [shares, setShares] = useState<readonly ArchiveDurableShareView[]>([]);
	const [why, setWhy] = useState("");
	const [busy, setBusy] = useState<string | null>(null);
	const [revision, setRevision] = useState(0);
	const generation = useRef(0);
	useEffect(() => {
		const own = ++generation.current;
		setShares([]);
		setWhy("");
		setBusy(null);
		// On the whole target, not on whether a peer is reached: the list is
		// that peer's, so leaving one connected peer for another is a new list
		// even though "reached" never changed. A dependency of only the boolean
		// kept the first peer's shares up under the second's name.
		if (reachesPeer(archiveTarget)) {
			void session.listIssuedArchiveShares().then((rows) => {
				if (generation.current === own) setShares(rows);
			}, (error) => {
				if (generation.current === own) setWhy(refusalText(error));
			});
		}
		return () => {
			generation.current += 1;
		};
	}, [session, archiveTarget, revision]);
	if (!reachesPeer(archiveTarget)) return null;
	const revoke = async (id: string) => {
		const own = generation.current;
		setBusy(id);
		setWhy("");
		try {
			const refused = await session.revokeIssuedArchiveShare(id);
			if (generation.current !== own) return;
			setWhy(refused);
			if (refused === "") setRevision((value) => value + 1);
		} catch (error) {
			if (generation.current === own) setWhy(refusalText(error));
		} finally {
			if (generation.current === own) setBusy(null);
		}
	};
	return (
		<>
			<h3 className="well-title overline" id="issuedArchiveSharesLegend">{archiveSharesTitle}</h3>
			<div className="group well" role="group" aria-labelledby="issuedArchiveSharesLegend">
				<p className="hint">{archiveSharesLead}</p>
				{shares.length === 0 ? <p className="empty">{archiveSharesEmpty}</p> : (
					<ul className="entries">
						{shares.map((share) => (
							<li className="entry" key={share.id}>
								<div className="entry-head">
									<span className="entry-name">{share.label}</span>
								</div>
								<CopyField
									id={`issuedArchiveShare-${share.id}`}
									text={share.sturdyref}
									label={`Copy ${share.label}`}
								/>
								<div className="actions">
									<Button
										variant="quiet"
										busy={busy === share.id}
										disabled={busy != null}
										onClick={() => void revoke(share.id)}
									>
										Revoke
									</Button>
								</div>
							</li>
						))}
					</ul>
				)}
				{why !== "" && <Said kind="failure">{why}</Said>}
			</div>
		</>
	);
}
