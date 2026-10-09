// What this session can act through now, and which bearer authority it has
// explicitly retained for later. Live references and saved sturdyrefs are two
// custody states, so this panel names both instead of calling configuration a
// capability or pretending durable text is harmless metadata.

import { useState } from "react";
import { Button } from "../Button.tsx";
import { CopyField } from "../Copy.tsx";
import type { ArchiveTargetView } from "../archive_model.ts";
import { useRoomsBrowser, useRoomsController } from "../controller/browser.ts";
import { useRoomsSession } from "../controller/session.ts";
import { useRoomsState } from "../hooks.ts";
import type { RoomConv } from "../types.ts";
import { CapabilitySetForm } from "./CapabilitySet.tsx";
import { ArchiveHolding } from "./History.tsx";
import { IssuedArchiveShares } from "./ArchiveShares.tsx";
import { sharedRoomsSession } from "../../../lib/workspace_view.ts";
import {
	holdingsCopyAttached,
	holdingsCopyHosted,
	holdingsEntryLink,
	holdingsManager,
	holdingsModerator,
	holdingsOpenRoomControls,
	holdingsOpsTitle,
	holdingsSavedEmpty,
	holdingsSavedTitle,
} from "../../../lib/text/session_settings.ts";
import { holdingsLocalLead, holdingsSharedLead } from "../../../lib/text/ops.ts";
import { sessionAccessTitle } from "../../../lib/text/settings.ts";
import { refusalText } from "../../../lib/text/failure.ts";

export function Holdings({ archiveTarget }: { archiveTarget: ArchiveTargetView }) {
	const browser = useRoomsBrowser();
	const session = useRoomsSession();
	const convs = useRoomsState((state) => state.convs);
	const rooms = [...convs.values()].filter((conv): conv is RoomConv => conv.type === "room");
	const savedRooms = rooms.filter((room) =>
		room.linkToken != null || room.managerToken != null || room.stewardToken != null
	);
	const controller = useRoomsController();
	const shared = sharedRoomsSession(controller);
	// Opening a saved room may have to reach it first, and until it does this
	// button was the one control here that said nothing at all: the press
	// landed, the wait was silent, and a reader with a slow directory had no
	// reason not to press it again. The refusal already had somewhere to go.
	const [opening, setOpening] = useState<string | null>(null);
	const openRoomControls = (room: RoomConv) => {
		if (opening !== null) return;
		setOpening(room.key);
		void session.openConv(room.key).then(() => {
			browser.closeSettings();
			browser.aboutConversation("capabilities");
		}, (cause) => browser.toast("failure", refusalText(cause)))
			.finally(() => setOpening(null));
	};

	return (
		<>
			<p className="lead" id="liveHoldingsLegend">
				{shared != null ? holdingsSharedLead : holdingsLocalLead}
			</p>
			{shared != null && (
				<>
					<h3 className="well-title overline" id="sessionHoldingLegend">{sessionAccessTitle}</h3>
					<div className="group well" role="group" aria-labelledby="sessionHoldingLegend">
						<CopyField
							id="currentSessionCapability"
							text={shared.sturdyref}
							label={controller.kind === "hosted" ? holdingsCopyHosted : holdingsCopyAttached}
						/>
					</div>
				</>
			)}

			<h3 className="well-title overline" id="savedHoldingsLegend">{holdingsSavedTitle}</h3>
			<div className="group well" role="group" aria-labelledby="savedHoldingsLegend">
				{savedRooms.length === 0 ? <p className="empty">{holdingsSavedEmpty}</p> : (
					<ul className="entries">
						{savedRooms.map((room) => (
							<li className="entry" key={room.key}>
								<div className="entry-head" data-one-line>
									<span className="entry-name">{room.id}</span>
									{
										/* Which authority this row is about. The name alone said a
										    room was in here without saying what was held in it, and
										    these three are not the same thing to hold: one gets
										    somebody in, one moderates, one is the room itself. */
									}
									{room.linkToken != null && (
										<span className="tag" data-tone="quiet">{holdingsEntryLink}</span>
									)}
									{room.stewardToken != null && <span className="tag">{holdingsModerator}</span>}
									{room.managerToken != null && (
										<span className="tag" data-tone="warn">{holdingsManager}</span>
									)}
									<div className="actions">
										<Button
											variant="quiet"
											busy={opening === room.key}
											disabled={opening !== null && opening !== room.key}
											onClick={() => openRoomControls(room)}
										>
											{holdingsOpenRoomControls}
										</Button>
									</div>
								</div>
							</li>
						))}
					</ul>
				)}
			</div>

			<ArchiveHolding archiveTarget={archiveTarget} />
			<IssuedArchiveShares archiveTarget={archiveTarget} />

			<h3 className="well-title overline" id="opsLegend">{holdingsOpsTitle}</h3>
			<div className="group well" role="group" aria-labelledby="opsLegend">
				<CapabilitySetForm />
			</div>
		</>
	);
}
