// Sharing management of one access: a control of the recipient's own, limited
// to the powers picked here. The held control itself is never handed over,
// because it carries every power this reader has.
import { managedAccessText as text, narrowerPending } from "../../../lib/text/managed_access.ts";
import { type ReactNode, useState, useSyncExternalStore } from "react";
import { useManagedSession } from "../session/managed/context.tsx";
import type { ManagementPowers } from "../session/managed/access_powers.ts";
import { type DescribedControl, publishesHere } from "../session/managed/held_control.ts";
import { pressRefused } from "../session/managed/access_card.ts";
import type { PressRefusal } from "../session/managed/press_answer.ts";
import { useAsyncAction } from "../async_action.ts";
import { useServerGate } from "../hooks.ts";
import { serverNeedLink } from "../../../lib/text/session.ts";
import { Button } from "../Button.tsx";
import { Checkbox } from "../Checkbox.tsx";
import { CopyField } from "../Copy.tsx";
import { Said } from "../Said.tsx";

const FLAGS = ["inspect", "pause", "resume", "revoke"] as const;
const NAMES = { inspect: text.inspect, pause: text.pausePower, resume: text.resumePower, revoke: text.revokePower };

/** The picks a narrower control's `powers` were chosen from. */
function picksOf(powers: ManagementPowers) {
	return {
		inspect: powers.inspect,
		pause: powers.pause,
		resume: powers.resume,
		revoke: powers.revoke,
		delegateControl: powers.delegateControl,
		edit: powers.editCeiling != null,
	};
}

export function ShareControl({ control }: { control: DescribedControl }) {
	const { management } = useManagedSession();
	useSyncExternalStore(management.subscribe, management.getVersion, management.getVersion);
	const serverGate = useServerGate();
	const own = control.state.powers;
	const [chosen, setPicks] = useState({
		inspect: own.inspect === true,
		pause: false,
		resume: false,
		revoke: false,
		delegateControl: false,
		edit: false,
	});
	const [link, setLink] = useState("");
	// The last refused press, which shows by the rule `pressRefused` keeps.
	const [refusal, setRefusal] = useState<PressRefusal | null>(null);
	// A narrower control whose answer was lost is asked for again with the
	// choices it was made with, until it is answered or given up.
	const pending = management.narrowerPending(control);
	const picks = pending == null ? chosen : picksOf(pending);
	// A fault the owner reported ends the run, which leaves the press usable.
	const share = useAsyncAction(async (signal) => {
		setRefusal(null);
		const refused = await management.answer(control, async () => {
			const published = await management.share(
				control,
				pending ?? {
					inspect: picks.inspect,
					pause: picks.pause,
					resume: picks.resume,
					revoke: picks.revoke,
					delegateControl: picks.delegateControl,
					editCeiling: picks.edit ? own.editCeiling?.permissions ?? null : null,
					issueCeiling: null,
				},
			);
			if (!signal.aborted) setLink(published);
		});
		if (!signal.aborted) setRefusal(refused);
	});
	const said = pressRefused(refusal, management, control);
	const giveUp = useAsyncAction(async (signal) => {
		setRefusal(null);
		const refused = await management.answer(control, () => management.giveUpNarrower(control));
		if (!signal.aborted) setRefusal(refused);
	});
	const locked = share.busy || giveUp.busy || link !== "" || pending != null;
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
			<p className="hint">{pending == null ? text.shareControlSaid : narrowerPending}</p>
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
					<Button
						variant="quiet"
						busy={share.busy}
						disabled={share.busy || giveUp.busy}
						// A control link that leads here works through this browser's
						// Rooms server, so the server comes first.
						onClick={() => {
							if (!publishesHere(control) || serverGate(serverNeedLink) != null) void share.run();
						}}
					>
						{text.prepareControl}
					</Button>
					{pending != null && (
						<Button
							variant="quiet"
							busy={giveUp.busy}
							disabled={share.busy || giveUp.busy}
							onClick={() => void giveUp.run()}
						>
							{text.giveUpControl}
						</Button>
					)}
				</div>
			)}
			{said != null && <Said kind="failure">{said}</Said>}
		</>
	);
}
