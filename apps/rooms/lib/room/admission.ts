/** One successful membership admission shared by every capability returned
 * for a retried invitation claim. */
export interface OneShotRoomAdmission {
	available(): boolean;
	consume(): void;
}

export function oneShotRoomAdmission(): OneShotRoomAdmission {
	let available = true;
	return {
		available: () => available,
		consume: () => {
			if (!available) throw new Error("this room invitation was claimed already");
			available = false;
		},
	};
}
