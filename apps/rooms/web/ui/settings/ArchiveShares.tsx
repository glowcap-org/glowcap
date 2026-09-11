// Issued archive-peer shares: independently revocable Host publications.

import { useEffect, useRef, useState } from "react";
import type { ArchiveDurableShareView } from "../../../lib/archive/facet.ts";
import type { ArchiveTargetView } from "../archive_model.ts";
import { Button } from "../Button.tsx";
import { CopyField } from "../Copy.tsx";
import { useRoomsSession } from "../controller/session.ts";
import { Said } from "../Said.tsx";

export function IssuedArchiveShares({ archiveTarget }: { archiveTarget: ArchiveTargetView }) {
	const session = useRoomsSession();
	const [shares, setShares] = useState<readonly ArchiveDurableShareView[]>([]);
	const [why, setWhy] = useState("");
	const [busy, setBusy] = useState<string | null>(null);
	const [revision, setRevision] = useState(0);
	const generation = useRef(0);
	const onPeer = archiveTarget.kind === "peer" && archiveTarget.status === "connected";
	useEffect(() => {
		const own = ++generation.current;
		setShares([]);
		setWhy("");
		setBusy(null);
		if (onPeer) {
			void session.listIssuedArchiveShares().then((rows) => {
				if (generation.current === own) setShares(rows);
			}, (error) => {
				if (generation.current === own) setWhy(error instanceof Error ? error.message : String(error));
			});
		}
		return () => {
			generation.current += 1;
		};
	}, [session, archiveTarget, revision]);
	if (!onPeer) return null;
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
			if (generation.current === own) setWhy(error instanceof Error ? error.message : String(error));
		} finally {
			if (generation.current === own) setBusy(null);
		}
	};
	return (
		<>
			<h3 className="well-title overline" id="issuedArchiveSharesLegend">Issued archive shares</h3>
			<div className="group well" role="group" aria-labelledby="issuedArchiveSharesLegend">
				<p className="hint">
					These are independently revocable publications from the selected archive peer. Revoking one
					unpublishes its sturdyref; live one-shot handover is a different object.
				</p>
				{shares.length === 0
					? <p className="empty">This archive has issued no durable shares.</p>
					: (
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
