// The person chip. Initials on a stable tint today; a custom picture will fill
// the same box, so every place that names a person already has one owner for it.

import { hueOf, initials } from "./text.ts";

export type PresenceState = "online" | "away" | "offline";

export function Avatar(
	{ name, className }: { name: string; className?: string },
) {
	return (
		<span
			className={className == null ? "avatar-chip" : "avatar-chip " + className}
			aria-hidden="true"
			style={{ background: hueOf(name) }}
		>
			{initials(name)}
		</span>
	);
}

/** The person chip wearing their presence: the pip sits over the chip's
 * corner, so one element answers who this is and whether they are here. The
 * pip keeps the roster's vocabulary — filled when online, hollow when
 * offline, and away by weight rather than by shape, because away is a way of
 * being here. Contexts set `--presence-ring` to the flat tone of the surface
 * behind the chip — a colour, never a gradient, because the ring is a
 * box-shadow — so the pip reads as punched out of it. */
export function PresenceAvatar(
	{ name, state, reason, className }: {
		name: string;
		state: PresenceState;
		/** The away reason, where one was given, said on the pip's title the
		 * way the roster says it. */
		reason?: string;
		className?: string;
	},
) {
	return (
		<span className={"avatar-presence " + state + (className == null ? "" : " " + className)}>
			<Avatar name={name} />
			<span
				className="presence-pip"
				role="img"
				aria-label={state}
				title={reason != null && reason !== "" ? `away: ${reason}` : state}
			/>
		</span>
	);
}
