use super::*;

impl Server {
	pub(super) async fn bind(config: Config, options: ListenOptions) -> Result<Server> {
		let (loop_shared, host, owns_loop) = match options.identity {
			ListenerIdentity::Fresh => {
				let lp = crate::driver_loop::LoopShared::open_with_durable_seed(
					crate::session::HANDSHAKE_TIMEOUT.as_millis() as u32,
					crate::session::HANDSHAKE_TIMEOUT.as_millis() as u32,
					None,
				)?;
				let host = Host::from_shared(lp.wrapper_host()?);
				(lp, host, true)
			}
			ListenerIdentity::Seed(seed) => {
				let lp = crate::driver_loop::LoopShared::open_with_durable_seed(
					crate::session::HANDSHAKE_TIMEOUT.as_millis() as u32,
					crate::session::HANDSHAKE_TIMEOUT.as_millis() as u32,
					Some(seed),
				)?;
				let host = Host::from_shared(lp.wrapper_host()?);
				(lp, host, true)
			}
			ListenerIdentity::Host(host) => {
				let shared = host.shared();
				let lp = shared.ensure_driver_loop(
					crate::session::HANDSHAKE_TIMEOUT.as_millis() as u32,
					crate::session::HANDSHAKE_TIMEOUT.as_millis() as u32,
				)?;
				(lp, host, false)
			}
		};
		Server::bind_on_loop(loop_shared, host, config, owns_loop).await
	}

	async fn bind_on_loop(
		loop_shared: Rc<crate::driver_loop::LoopShared>,
		host: Host,
		config: Config,
		owns_loop: bool,
	) -> Result<Server> {
		let host_shared = host.shared();
		let mut listener = None;
		let result = async {
			let node_id = ensure_loop_provider(&host_shared, &loop_shared, config).await?;
			let id = loop_shared
				.listen(crate::abi_constants::TRANSPORT_IROH, &node_id)
				.await?;
			listener = Some(id);
			loop_shared.select_listener(id)?;
			Ok(Server {
				listener: crate::server::LoopListener::new(Rc::clone(&loop_shared), id, host),
				node_id,
			})
		}
		.await;
		match result {
			Ok(server) => Ok(server),
			Err(mut error) => {
				if let Some(id) = listener {
					error = crate::retain_cleanup_failure(error, loop_shared.close_listener(id).await);
				}
				if owns_loop {
					loop_shared.close();
				}
				Err(error)
			}
		}
	}

	pub fn host(&self) -> Host {
		self.listener.host()
	}

	pub fn node_id(&self) -> &str {
		&self.node_id
	}

	pub fn direct_addresses(&self) -> Result<String> {
		Ok(self
			.locator()?
			.string_hint(crate::abi_constants::HINT_DIRECT_ADDRESSES)?
			.map(str::to_owned)
			.unwrap_or_default())
	}

	/// Return the canonical locator partners use to dial this listener.
	pub fn locator(&self) -> Result<crate::Locator> {
		self.listener.locator()
	}

	pub fn uri(&self) -> Result<String> {
		crate::uri::format_locator_uri(&self.locator()?)
	}

	pub async fn accept(&self) -> Result<Session> {
		self.listener.accept().await
	}

	/// Stop iroh admission through this listener. Sessions already returned by
	/// [`Server::accept`] remain live on the shared Host; [`Host::close`]
	/// is the terminal endpoint and session release barrier.
	pub async fn close(&self) -> Result<()> {
		self.listener.close().await
	}
}

// ── the iroh application surface ──────────────────────────────────────────────
// The same [`Session`] surface over iroh's encrypted QUIC: the one
// [`Runtime::connect`](crate::Runtime::connect) routes an `ocapn://<nodeid>.iroh?…` locator
// to the binding-internal iroh dial here, and [`listen`]/[`Server`] host.
// The byte-fed pump remains for a redeem on a Host that already owns
// externally supplied channels —
// `Session::establish_dialed_locator` carries the session over the iroh
// byte-stream bridge ([`Stream`]) exactly as over a `TcpStream`; only the
// dialed locator differs (`iroh` + endpoint id, never `tcp` + host:port). The
// default listener uses the generic driver resident and accepted-session
// lifecycle. The iroh-touching code lives here behind the `iroh`
// feature, so a tcp-only build references no iroh symbol — the same
// `libglowcap_ocapn` / `libglowcap_net_transport_iroh` split the other bindings
// mirror.

impl Session {
	/// Binding-internal Host-keyed iroh dial behind [`Runtime::connect`](crate::Runtime::connect)
	/// and handoff redeem. Application code uses
	/// `connect(locator, options)`.
	///
	/// This is the byte-fed iroh channel adapter used when a redeem is emitted
	/// by a Host that already owns byte-fed sessions. Ordinary bounded dials,
	/// including dials on a quiescent caller-supplied Host, use the generic
	/// driver resident.
	///
	/// `handshake_timeout` bounds the OCapN handshake only. The dial-by-id
	/// budget above it (a `Discovery` posture retries while the exporter's
	/// pkarr record propagates, ADR-0082) is already spent by the time the
	/// stream exists, so a slow discovery never eats the handshake's bound.
	pub(crate) async fn connect_iroh_with_host(
		node_id: &str,
		direct_addresses: &str,
		reachability: Reachability,
		host: Host,
		handshake_timeout: Option<std::time::Duration>,
	) -> Result<Session> {
		let stream = Stream::connect(node_id, direct_addresses, reachability).await?;
		// As the accept side: this module opened the connection, so it is the
		// one place that can say what QUIC proved about the far end.
		let proved = stream.remote_node_id();
		Session::establish_dialed_locator(
			host.shared(),
			&crate::Locator::bare(crate::abi_constants::TRANSPORT_IROH, node_id),
			stream,
			handshake_timeout,
			proved.as_deref(),
		)
		.await
	}
}
