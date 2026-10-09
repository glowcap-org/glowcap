// Sharing management of one access: a control of the recipient's own, limited
// to the powers picked here. The held control itself is never handed over,
// because it carries every power this reader has.
import { managedAccessText as text } from "../../../lib/text/managed_access.ts";
import { type ReactNode, useState } from "react";
import { useManagedSession } from "../session/managed/context.tsx";
import type { HeldControl } from "../session/managed/access.ts";
import { useAsyncAction } from "../async_action.ts";
import { Button } from "../Button.tsx";
import { Checkbox } from "../Checkbox.tsx";
import { CopyField } from "../Copy.tsx";
import { Said } from "../Said.tsx";

const FLAGS = ["inspect", "pause", "resume", "revoke"] as const;
const NAMES = { inspect: text.inspect, pause: text.pausePower, resume: text.resumePower, revoke: text.revokePower };

export function ShareControl({ control }: { control: HeldControl }) {
	const { management } = useManagedSession();
	const own = control.powers;
	const [picks, setPicks] = useState({
		inspect: own.inspect === true,
		pause: false,
		resume: false,
		revoke: false,
		delegateControl: false,
		edit: false,
	});
	const [link, setLink] = useState("");
	const share = useAsyncAction(async (signal) => {
		const published = await management.share(control, {
			inspect: picks.inspect,
			pause: picks.pause,
			resume: picks.resume,
			revoke: picks.revoke,
			delegateControl: picks.delegateControl,
			editCeiling: picks.edit ? own.editCeiling?.permissions ?? null : null,
			issueCeiling: null,
		});
		if (!signal.aborted) setLink(published);
	});
	const locked = share.busy || link !== "";
	const check = (key: keyof typeof picks, allowed: boolean, children: ReactNode) => (
		<label className="check-row" key={key}>
			<Checkbox
				checked={picks[key]}
				disabled={locked || !allowed}
				onChange={() =>
					setPicks({ ...picks, [key]: !picks[key] })}
			/>
			{children}
		</label>
	);
	return (
		<>
			<p className="hint">{text.shareControlSaid}</p>
			<div className="question">
				<p className="group-label">{text.powersShare}</p>
				<div className="permission-picks">
					{FLAGS.map((flag) => check(flag, own[flag] === true, <span>{NAMES[flag]}</span>))}
				</div>
			</div>
			{check(
				"edit",
				own.editCeiling != null,
				<span>
					<strong>{text.shareEdit}</strong>
					{text.shareEditSaid}
				</span>,
			)}
			{check(
				"delegateControl",
				true,
				<span>
					<strong>{text.delegateControl}</strong>
					{text.delegateControlSaid}
				</span>,
			)}
			{link ? <CopyField text={link} label={text.copyControl} /> : (
				<div className="actions">
					<Button variant="quiet" busy={share.busy} disabled={share.busy} onClick={() => void share.run()}>
						{text.prepareControl}
					</Button>
				</div>
			)}
			{share.why !== "" && <Said kind="failure">{share.why}</Said>}
		</>
	);
}
