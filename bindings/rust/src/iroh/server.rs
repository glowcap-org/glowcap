use super::*;

impl Server {
	/// Bind through the shared [`crate::server::bind_loop_listener`] spine.
	/// The iroh-shaped step is the provider install itself: the endpoint is
	/// built from the Host's durable seed (ADR-0028), and the endpoint id it
	/// reports is both the designator the listener binds and the node id this
	/// server names.
	pub(super) async fn bind(config: Config, options: ListenOptions) -> Result<Server> {
		let (listener, node_id) = crate::server::bind_loop_listener(
			options.identity,
			crate::abi_constants::TRANSPORT_IROH,
			|host, lp| async move { Ok((ensure_loop_provider(&host, &lp, config).await?, ())) },
			|_lp, _listener, node_id, ()| Ok(node_id),
		)
		.await?;
		Ok(Server { listener, node_id })
	}

	pub fn host(&self) -> Host {
		self.listener.host()
	}

	pub fn node_id(&self) -> &str {
		&self.node_id
	}

	/// The comma-separated direct socket addresses the canonical locator
	/// advertises, or `None` while the endpoint has gathered none: the provider
	/// omits the hint until at least one address exists, and a relay-only
	/// endpoint may never carry it.
	pub fn direct_addresses(&self) -> Result<Option<String>> {
		Ok(self
			.locator()?
			.string_hint(crate::abi_constants::HINT_DIRECT_ADDRESSES)?
			.map(str::to_owned))
	}

	/// Return the canonical locator partners use to dial this listener.
	pub fn locator(&self) -> Result<crate::Locator> {
		self.listener.locator()
	}

	pub fn uri(&self) -> Result<String> {
		crate::uri::format_locator_uri(&self.locator()?)
	}

	/// Await the next accepted session. It delivers its partner's inbound only
	/// once served: publish what it should answer, then `session.serve()`.
	pub async fn accept(&self) -> Result<Session> {
		self.listener.accept().await
	}

	/// Stop iroh admission through this listener. Sessions already returned by
	/// [`Server::accept`] remain live on the shared Host. [`Host::close`]
	/// is the terminal endpoint and session release barrier.
	pub async fn close(&self) -> Result<()> {
		self.listener.close().await
	}

	/// Select this listener's locator as the shared Host's advertised
	/// location. See [`crate::tcp::Server::select`].
	pub fn select(&self) -> Result<()> {
		self.listener.select()
	}
}

// ── the iroh application surface ──────────────────────────────────────────────
// The same [`Session`] surface over iroh's encrypted QUIC: the one
// [`Runtime::connect`](crate::Runtime::connect) routes an `ocapn://<nodeid>.iroh?…` locator
// to the binding-internal iroh dial here, and [`listen`]/[`Server`] host.
// The byte-fed pump remains for a redeem on a Host that already owns
// externally supplied channels:
// `Session::establish_dialed_locator` carries the session over the iroh
// byte-stream bridge ([`Stream`]) exactly as over a `TcpStream`; only the
// dialed locator differs (`iroh` + endpoint id, never `tcp` + host:port). The
// default listener uses the generic driver resident and accepted-session
// lifecycle. The iroh-touching code lives here behind the `iroh`
// feature, so a tcp-only build references no iroh symbol: the same
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
	/// pkarr record propagates, ADR-0030) is already spent by the time the
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
