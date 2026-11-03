/** Per-layer visibility toggled from the left-panel `Layers`
 * segmented control. Applied to each layer's `.visible`. */
export type StageVisibility = {
	peers: boolean;
	connections: boolean;
	messages: boolean;
	labels: boolean;
};
