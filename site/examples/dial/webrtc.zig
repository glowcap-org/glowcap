// PLANNED: there is no managed driver.Session adapter yet. webrtc.Resident owns
// the Rust WebRTC endpoint and exposes no Netlayer: a bare webrtc locator carries
// no signaling authority, so a signaling owner creates peers.
// From here, the CapTP workflow is transport-independent.
