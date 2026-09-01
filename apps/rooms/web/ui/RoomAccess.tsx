// The manager-owned public membership offer for one room.

import { Button } from "./Button.tsx";
import { Icon, type IconName } from "./icons.tsx";
import { Said } from "./Said.tsx";
import { nextRoomPreset, type RoomPolicy, type RoomPreset, roomPreset } from "../../lib/room/policy.ts";

export function roomPresetFace(preset: RoomPreset): { label: string; icon: IconName; description: string } {
	if (preset === "moderated") {
		return {
			label: "Moderated",
			icon: "observer",
			description: "Anyone with the name can come and watch. An invitation is what lets somebody post.",
		};
	}
	if (preset === "private") {
		return {
			label: "Private",
			icon: "lock",
			description: "The name gets nobody in. A room link or an invitation still does.",
		};
	}
	return {
		label: "Open",
		icon: "group",
		description: "Anyone with the name can come in and post.",
	};
}

/** Who this room offers membership to, as its own titled well: what it is now,
 * what that means, and the way to change it. Its own section rather than a
 * paragraph inside the manager's, because a reader asking who can get in is not
 * asking about the capability that administers the room, and the manager's own
 * acts belong under the manager's own name. */
export function RoomAccessControl({ policy, busy, disabled, said, onChange }: {
	policy: RoomPolicy;
	busy: boolean;
	disabled: boolean;
	/** A refusal from the last change, kept with the control it answered. */
	said?: string;
	onChange(preset: RoomPreset): void;
}) {
	const preset = roomPreset(policy);
	const face = roomPresetFace(preset);
	return (
		<>
			<h3 className="well-title overline" id="convcardRoomAccessTitle">Room access</h3>
			<div className="group well" role="group" aria-labelledby="convcardRoomAccessTitle">
				{
					/* The standing that is set now leads the well, the way the archive
				    peer's name leads its own. The icon marks that standing; the
				    button below only says what pressing it does, because it moves
				    to the next one rather than to the one drawn here. */
				}
				<div className="entry-head">
					<Icon name={face.icon} size={16} />
					<span className="entry-name" id="convcardRoomAccessStanding">{face.label}</span>
				</div>
				<p className="hint">{face.description}</p>
				<div className="actions">
					<Button
						id="convcardRoomPolicy"
						variant="quiet"
						busy={busy}
						disabled={disabled || busy}
						onClick={() => onChange(nextRoomPreset(preset))}
					>
						Change room access
					</Button>
				</div>
				{said !== undefined && said !== "" && <Said kind="failure">{said}</Said>}
			</div>
		</>
	);
}
