// Action feedback and grouped presence narration share the product voice here.
export const retryJoin = "Retry join";
export const retryCountdown = (seconds: number) => `Try again in ${seconds}s.`;
export const connectionChanges = (name: string, changes: number, online: boolean) =>
	`${name}’s connection changed ${changes} times. Now ${online ? "online" : "offline"}.`;
export const offlineMember = (name: string) => `${name} is offline.`;
