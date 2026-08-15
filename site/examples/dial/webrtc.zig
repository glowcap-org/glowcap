// PLANNED: there is no managed driver.Session adapter yet. webrtc.Resident owns
// the sidecar endpoint and exposes no Netlayer: a bare webrtc locator carries
// no signaling authority, so a signaling owner creates peers.
// From here, the CapTP workflow is transport-independent.
