//! Construction of one data-channel-only WebRTC peer on the endpoint runtime.

use std::sync::Arc;

use webrtc::error::{Error as WebrtcError, Result as WebrtcResult};
use webrtc::peer_connection::{
	MediaEngine, PeerConnection, PeerConnectionBuilder, PeerConnectionEventHandler, RTCConfigurationBuilder,
	RTCIceServer, Registry, SettingEngineBuilder, register_default_interceptors,
};
use webrtc::runtime::TokioRuntime;

use glowcap_sidecar_common::RuntimeOwner;

pub(crate) fn build(
	runtime: &RuntimeOwner,
	handler: Arc<dyn PeerConnectionEventHandler>,
	ice_servers: &[RTCIceServer],
	include_loopback: bool,
	receive_buffer_bound: usize,
	send_buffer_bound: usize,
) -> WebrtcResult<Arc<dyn PeerConnection>> {
	let setting_engine = SettingEngineBuilder::new()
		.with_include_loopback_candidate(include_loopback)
		.with_sctp_max_receive_buffer_size(receive_buffer_bound as u32)
		.build();

	let mut media_engine = MediaEngine::default();
	media_engine.register_default_codecs()?;
	let registry = register_default_interceptors(Registry::new(), &mut media_engine)?;
	let config = RTCConfigurationBuilder::new()
		.with_ice_servers(ice_servers.to_vec())
		.build();
	let udp_addrs = udp_bind_addrs(include_loopback);
	runtime.block_on(async move {
		let peer = PeerConnectionBuilder::new()
			.with_configuration(config)
			.with_media_engine(media_engine)
			.with_interceptor_registry(registry)
			.with_setting_engine(setting_engine)
			.with_handler(handler)
			.with_runtime(Arc::new(TokioRuntime))
			.with_udp_addrs(udp_addrs)
			.with_data_channel_send_buffer_limit(send_buffer_bound)
			.build()
			.await?;
		Ok::<Arc<dyn PeerConnection>, WebrtcError>(Arc::new(peer))
	})
}

pub(crate) fn udp_bind_addrs(include_loopback: bool) -> Vec<String> {
	let mut addrs = vec!["0.0.0.0:0".to_owned()];
	if include_loopback {
		addrs.push("127.0.0.1:0".to_owned());
	}
	addrs
}
