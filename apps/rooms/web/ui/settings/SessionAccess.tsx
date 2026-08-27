// Who else may attach to this session: the durable grants an administering
// capability can issue, copy, and revoke, on a card of their own.
//
// The card is all this file owns. The Data tab says how many grants exist and
// keeps the door; issuing one is a form with a name, an access level, and a
// bearer link to carry away, which is a card's worth of work rather than a
// row's.

import { useState } from "react";
import { MAX_SESSION_GRANT_LABEL } from "../../../lib/limits.ts";
import type { RoomsSessionFacet } from "../../../lib/rooms_session.ts";
import { Button } from "../Button.tsx";
import { Confirm } from "../Confirm.tsx";
import { CopyField } from "../Copy.tsx";
import { Field } from "../Field.tsx";
import { useRoomsState } from "../hooks.ts";
import { useRoomsBrowser } from "../controller/browser.ts";
import { useRoomsSession } from "../controller/session.ts";
import { Said } from "../Said.tsx";
import { SettingsSubmodal } from "./Submodal.tsx";

const ACCESS_LABEL: Readonly<Record<RoomsSessionFacet, string>> = {
	observe: "Read only",
	interact: "Can interact",
	admin: "Can administer",
};

export function SessionAccessModal({ open, onClose }: { open: boolean; onClose(): void }) {
	const browser = useRoomsBrowser();
	const session = useRoomsSession();
	const grants = useRoomsState((state) => state.sessionGrants);
	const [label, setLabel] = useState("");
	const [rights, setRights] = useState<RoomsSessionFacet>("interact");
	const [operationId, setOperationId] = useState<string | null>(null);
	const [busy, setBusy] = useState(false);
	const [error, setError] = useState("");
	const [confirming, setConfirming] = useState<string | null>(null);
	const [revoking, setRevoking] = useState<string | null>(null);
	const [revokeWhy, setRevokeWhy] = useState<Readonly<Record<string, string>>>({});
	const changeIntent = () => {
		setOperationId(null);
		setError("");
	};
	const issue = async () => {
		const id = operationId ?? crypto.randomUUID();
		setOperationId(id);
		setBusy(true);
		setError("");
		try {
			const why = await session.issueSessionGrant(id, rights, label);
			setError(why);
			if (why === "") {
				browser.toast("success", `Issued ${ACCESS_LABEL[rights].toLowerCase()} access for ${label}.`);
				setLabel("");
				setRights("interact");
				setOperationId(null);
			}
		} finally {
			setBusy(false);
		}
	};
	const revoke = async (id: string, name: string) => {
		setRevoking(id);
		setRevokeWhy((prior) => ({ ...prior, [id]: "" }));
		try {
			const why = await session.revokeSessionGrant(id);
			setRevokeWhy((prior) => ({ ...prior, [id]: why }));
			if (why === "") {
				setConfirming(null);
				browser.toast("success", `Revoked session access for ${name}.`);
			}
		} finally {
			setRevoking(null);
		}
	};
	return (
		<SettingsSubmodal
			title="Session access"
			titleId="sessionAccessTitle"
			className="session-access-modal"
			open={open}
			onClose={onClose}
		>
			<p className="hint">
				Each capability survives a session-host restart and can be revoked without changing this workspace or
				another grant.
			</p>
			<h3 className="well-title overline" id="sessionGrantIssueTitle">Issue a capability</h3>
			<form
				className="group well"
				role="group"
				aria-labelledby="sessionGrantIssueTitle"
				onSubmit={(event) => {
					event.preventDefault();
					void issue();
				}}
			>
				<div className="session-grant-fields">
					<Field id="sessionGrantLabel" label="Name">
						{(wiring) => (
							<input
								id={wiring.id}
								className="field"
								value={label}
								maxLength={MAX_SESSION_GRANT_LABEL}
								disabled={busy}
								onChange={(event) => {
									setLabel(event.currentTarget.value);
									changeIntent();
								}}
								placeholder="Kitchen display"
							/>
						)}
					</Field>
					<Field id="sessionGrantRights" label="Access">
						{(wiring) => (
							<span className="select-wrap">
								<select
									id={wiring.id}
									className="field"
									value={rights}
									disabled={busy}
									onChange={(event) => {
										const next = event.currentTarget.value;
										if (next === "observe" || next === "interact" || next === "admin") {
											setRights(next);
										}
										changeIntent();
									}}
								>
									<option value="observe">Read only</option>
									<option value="interact">Can interact</option>
									<option value="admin">Can administer</option>
								</select>
							</span>
						)}
					</Field>
				</div>
				{error !== "" && <Said kind="failure">{error}</Said>}
				<div className="actions">
					<Button type="submit" busy={busy} disabled={busy || label === ""}>
						Issue capability
					</Button>
				</div>
			</form>
			<h3 className="well-title overline" id="sessionGrantListTitle">Issued capabilities</h3>
			<div className="group well" role="group" aria-labelledby="sessionGrantListTitle">
				{grants.length === 0
					? <p className="empty">No durable grants have been issued.</p>
					: (
						<ul className="entries">
							{grants.map((grant) => (
								<li className="entry session-grant" key={grant.id}>
									<div className="entry-head">
										<span className="entry-name">{grant.label}</span>
										<span className="tag">{ACCESS_LABEL[grant.rights]}</span>
										<div className="actions">
											<Button
												variant="quiet"
												disabled={confirming === grant.id}
												onClick={() => setConfirming(grant.id)}
											>
												Revoke…
											</Button>
										</div>
									</div>
									<CopyField
										compact
										text={grant.sturdyref}
										label={`Copy session access for ${grant.label}`}
									/>
									{confirming === grant.id && (
										<Confirm
											label={`Revoke access for ${grant.label}`}
											say="Existing holders lose access immediately, and this sturdyref stays revoked after restart."
											keep="Keep access"
											commit="Revoke access"
											busy={revoking === grant.id}
											onKeep={() => setConfirming(null)}
											onCommit={() => void revoke(grant.id, grant.label)}
										/>
									)}
									{revokeWhy[grant.id] != null && revokeWhy[grant.id] !== "" && (
										<Said kind="failure">{revokeWhy[grant.id]}</Said>
									)}
								</li>
							))}
						</ul>
					)}
			</div>
		</SettingsSubmodal>
	);
}
