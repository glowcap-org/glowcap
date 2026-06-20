//! Connection: the application surface over tokio (the `async` feature).
//!
//! This is what an application holds. It composes a peer, a vat, and the tokio
//! I/O driver into one object, so a consumer never stitches those three together
//! by hand. The verbs — [`connect`] to dial, [`listen`]/[`Server::accept`] to
//! host, [`Connection::fetch`]/[`Connection::publish`], [`Connection::spawn`],
//! [`Connection::send`], [`Connection::serve`], [`Connection::close`] — are the
//! whole common surface.
//!
//! The pancake [`Peer`](crate::Peer) is a single-owner, `!Send` state machine, so
//! a `Connection` owns it on one background task and the handle talks to that task
//! over channels. The handle is therefore `!Send` too — create and use it on one
//! task, inside a `LocalSet` (or `#[tokio::main(flavor = "current_thread")]`). This
//! is the honest shape for a `!Send` resource: it is not hidden, and the channel
//! plumbing lives here so an application never writes it.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::future::{Future, IntoFuture};
use std::pin::Pin;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite};
use tokio::net::{TcpListener, TcpStream, ToSocketAddrs};
use tokio::sync::{mpsc, oneshot};

use crate::actors::{Behavior, Vat, VatRef, Vow};
use crate::wire;
use crate::{sys, Argument, Error, HandoffGive, Peer, Reference, Resolution, Result};

/// A capability, a reference to an object you can `send` to, wherever it lives.
///
/// You get a `Ref` from [`Connection::spawn`] (a local actor you host),
/// [`Connection::fetch`] (a capability a partner published), or a capability a
/// partner handed back from a `send` (lift it with `Ref::try_from(&arg)`). Pass
/// one as a `send` argument via `Into<Argument>` (`(&cap).into()`) and it
/// marshals to the right wire reference; you never build `near`/`far` references
/// by hand.
#[derive(Debug, Clone)]
pub struct Ref {
	reference: Reference,
	// Distributed-GC death rite (ADR-0063), present only on a far reference the
	// connection lifted from the wire while GC was opted in. `Arc` so clones of
	// this `Ref` share the one wire-count unit; the last clone's drop fires the
	// guard, which enqueues the single `op:gc-exports` delta. `None` for near
	// references, refs minted with GC off, and the context-free `try_from` lift.
	//
	// Held only for its `Drop`: the release fires when the last clone falls, so
	// the field is never read by name.
	#[allow(dead_code)]
	guard: Option<std::sync::Arc<ImportGuard>>,
}

// Drops to one `op:gc-exports` delta of 1 for `position` (ADR-0063). The sender
// is a clone of the connection's command channel, so the release rides the same
// queue the serve loop already drains, and `Drop` running on any thread is safe
// because the channel sender is `Send`.
#[derive(Debug)]
struct ImportGuard {
	position: u64,
	cmd_tx: mpsc::UnboundedSender<Cmd>,
}

impl Drop for ImportGuard {
	fn drop(&mut self) {
		let _ = self.cmd_tx.send(Cmd::GcDrop {
			position: self.position,
		});
	}
}

impl Ref {
	/// The underlying wire reference (for the rare power-user path).
	pub fn reference(&self) -> Reference {
		self.reference.clone()
	}

	// A reference with no GC death rite, the default for everything but a
	// wire-lifted far import.
	fn bare(reference: Reference) -> Ref {
		Ref {
			reference,
			guard: None,
		}
	}
}

impl From<&Ref> for Argument {
	fn from(r: &Ref) -> Argument {
		Argument::Reference(r.reference.clone())
	}
}

impl From<Ref> for Argument {
	fn from(r: Ref) -> Argument {
		Argument::Reference(r.reference)
	}
}

impl TryFrom<&Argument> for Ref {
	type Error = ();

	/// Lift a capability returned by a `send` (an `Argument::Reference`) back into
	/// a `Ref` you can `send` to, e.g. a capability a coordinator granted you.
	fn try_from(arg: &Argument) -> std::result::Result<Ref, ()> {
		match arg {
			Argument::Reference(reference) => Ok(Ref::bare(reference.clone())),
			_ => Err(()),
		}
	}
}

/// A revocable caretaker over a capability (ADR-0064), returned by
/// [`Connection::caretaker`]. Hand [`proxy`](Caretaker::proxy) to a partner; call
/// [`revoke`](Caretaker::revoke) to sever it, after which every call through the
/// proxy breaks with `Revoked`.
pub struct Caretaker {
	/// The capability to delegate. Forwards to the wrapped target until revoked.
	pub proxy: Ref,
	/// The revoke flag the proxy actor reads on every call, cleared here, read in
	/// the driver, the way Zig's `RevokeCell` is shared between handle and actor.
	live: Arc<AtomicBool>,
}

impl Caretaker {
	/// Sever the proxy: subsequent calls through it break with `Revoked`.
	/// Idempotent. Clears the shared flag the proxy actor reads, so it takes effect
	/// with no round trip (a closed connection has already severed every proxy).
	pub fn revoke(&self) {
		self.live.store(false, Ordering::SeqCst);
	}
}

// A command's reply carries the typed [`Error`] end to end: a partner break is
// `Error::broken` with the reason, and a local refusal (e.g. an inadmissible
// send target) keeps its own session/codec code instead of being laundered
// into a transport error.
type Reply<T> = oneshot::Sender<Result<T>>;

// The reserved far-id range a redeemed three-party-handoff capability is handed
// to the application under (ADR-0066). A redeemed cap lives on a dialed exporter
// connection, not on the connection the give arrived over; the node hands back
// an ordinary far reference drawn from this range — above any wire-allocated
// import position — and a later `send`/`tell` to it is routed to the exporter
// with the real reference swapped in, so the public `Ref`/`send` surface is
// untouched. This mirrors `engine.Node.REDEEMED_TOKEN_BASE` (the node is the one
// owner of the token model); the binding keeps the boundary only to skip the GC
// death rite on a synthetic token (`lift_import`).
const REDEEMED_TOKEN_BASE: u64 = 1u64 << 60;

// Where a redeemed token routes: the destination connection's command channel
// and the real exporter-side reference to swap in when forwarding. Resolved by
// the node from a `conn_id`, then mapped to the task that pumps that connection.
type ExporterRoute = (mpsc::UnboundedSender<Cmd>, Reference);

// A factory that mints a fresh actor behavior for one node-giftable each time a
// connection publishes it. A behavior is a `!Clone` `FnMut`, so a node-giftable
// published on several connections cannot share one boxed behavior; the node
// keeps the factory and calls it once per connection (the gifter half of a
// three-party handoff publishes the giftable on every connection, ADR-0009).
type GiftableFactory = Rc<dyn Fn() -> Behavior>;

// The sans-io cross-connection handoff router (`engine.Node`, ADR-0066): the
// thing distinct from a per-partner connection. The node owns each connection's
// peer (allocated on `register_conn`, freed on `remove_conn`/teardown), the
// retained node identity, the shared deposited-gift registry (ADR-0056), and the
// redeemed-token / foreign-home routing tables — every route value an integer,
// so the routing decision lives once in Zig instead of being reimplemented per
// binding. `!Send` (its peers are), shared via the `Node`'s `Rc` across every
// connection of the node and the off-loop resolution tasks; freed last (with
// every peer it still owns) when the last `Node` clone drops, after every
// driver task — each of which holds a `Node` clone for its whole life — has
// ended, so no live connection can dereference a freed peer.
struct NodeRaw {
	raw: *mut sys::PancakeNode,
}

impl NodeRaw {
	fn new(seed: &[u8; 32]) -> Result<NodeRaw> {
		let mut raw: *mut sys::PancakeNode = core::ptr::null_mut();
		crate::check(unsafe { sys::pancake_node_new(seed.as_ptr(), seed.len(), &mut raw) })?;
		Ok(NodeRaw { raw })
	}
}

impl Drop for NodeRaw {
	fn drop(&mut self) {
		// Frees every registered peer, the routing tables and the references they
		// own, and the shared gift registry. Safe: every driver task that pumped
		// a node-owned peer holds a `Node` clone (hence this `Rc`), so this
		// drop — the last clone falling — runs only after they have all ended.
		unsafe { sys::pancake_node_free(self.raw) };
	}
}

/// The CapTP node for a set of connections — pancake's analogue of Goblins'
/// `mycapn`, kept distinct from the per-partner connection. It is a thin handle
/// over the sans-io router (`engine.Node`, ADR-0066): the router owns the node's
/// stable identity, the shared gift registry, every connection's peer, and the
/// redeemed-token / foreign-home routing tables. The `Node` adds only what is
/// host-language idiom — the dialed-exporter cache, the `conn_id`→command-channel
/// map that delivers a routed send to the task that pumps that connection, the
/// node-giftable factories, and the iroh redeem posture.
///
/// Pass one node to several [`Connection`]s so a capability fetched on one
/// and returned on another is recognized as foreign and re-gifted rather than
/// mis-encoded. All state is `Rc`-shared, so the resolution callbacks (which run
/// off the loop via `spawn_local`), the command handler, and every connection of
/// the node share it; cloning shares the same state.
#[derive(Clone)]
pub struct Node {
	// The retained 32-byte session identity, the entropy source this binding
	// minted (the sans-io node never generates entropy) and handed to the node.
	// Kept here too because the keyed `op:start-session` handshake and the
	// gifter's `desc:handoff-give` signing both take it at the I/O boundary; the
	// node holds the same value as its one durable owner of the identity.
	seed: [u8; 32],
	// The sans-io cross-connection router (ADR-0066): node-owned peers, shared
	// gift registry, retained identity, and the redeemed-token / foreign-home
	// routing tables. Shared across clones; freed when the last clone drops.
	node: Rc<NodeRaw>,
	// Exporter connections dialed to redeem gives, keyed by `ocapn://` locator,
	// reused across redeems. Held here to keep their driver tasks alive for the
	// life of this node; dropped (and closed) when the node is.
	exporters: Rc<RefCell<HashMap<String, Connection>>>,
	// Every live connection of this node, by the node's `conn_id`, so a routed
	// deliver to a redeemed token's exporter (or a node-giftable publish) reaches
	// the task that pumps that connection's peer. The node routes by `conn_id`;
	// this map turns a `conn_id` back into the command channel.
	channels: Rc<RefCell<HashMap<u64, mpsc::UnboundedSender<Cmd>>>>,
	// Node-giftable factories by swiss name: capabilities this node exports under
	// one identity on every connection. A handoff recipient withdraws a gift
	// naming one on a connection it dialed itself, separate from the gifter's
	// deposit connection, so the gifted object must be published on the
	// withdrawing connection too. A behavior is a `!Clone` `FnMut`, so the
	// factory is called once per connection.
	giftables: Rc<RefCell<HashMap<String, GiftableFactory>>>,
	// The iroh reachability posture this node uses to redeem a *hint-less* handoff
	// give — one whose exporter location names the exporter by node id alone, so
	// the recipient must resolve it by id. Defaults to `Discovery` (n0 relays +
	// DNS/pkarr, the maximal-reach choice); a relay-policy deployment lowers it to
	// `DiscoveryNoRelay`. A hinted give always dials `Direct` and ignores this.
	// Shared across clones so a setter on one handle reaches every connection.
	redeem_reachability: Rc<Cell<Reachability>>,
}

impl Node {
	// A node bound to a known identity seed, with an empty router. The node
	// allocation failing is unrecoverable (an OOM at construction), the same
	// stance `new_node` takes for the OS RNG.
	fn new(seed: [u8; 32]) -> Node {
		let node = NodeRaw::new(&seed).expect("the allocator provides a node router");
		Node {
			seed,
			node: Rc::new(node),
			exporters: Rc::new(RefCell::new(HashMap::new())),
			channels: Rc::new(RefCell::new(HashMap::new())),
			giftables: Rc::new(RefCell::new(HashMap::new())),
			redeem_reachability: Rc::new(Cell::new(Reachability::Discovery)),
		}
	}

	/// The iroh reachability posture this node uses to redeem a *hint-less*
	/// handoff give (the exporter named by node id alone, with no direct-address
	/// hints). Defaults to [`Reachability::Discovery`]; set
	/// [`Reachability::DiscoveryNoRelay`] to honor a no-relay deployment policy. A
	/// hinted give always dials [`Reachability::Direct`] and ignores this.
	pub fn set_redeem_reachability(&self, reachability: Reachability) {
		self.redeem_reachability.set(reachability);
	}

	/// The reachability posture this node uses to redeem a hint-less handoff give.
	pub fn redeem_reachability(&self) -> Reachability {
		self.redeem_reachability.get()
	}

	// A fresh node with a random retained identity, minted at the I/O
	// boundary (the sans-io core never generates entropy). The OS RNG failing is
	// not a recoverable condition, the same stance the Deno/Python nodes take.
	// `pub(crate)` so the iroh server can mint its shared node.
	pub(crate) fn new_node() -> Node {
		let mut seed = [0u8; 32];
		getrandom::getrandom(&mut seed).expect("the OS RNG provides a node identity seed");
		Node::new(seed)
	}

	// Register a fresh node connection: allocate the node-owned peer (already
	// bound to the shared gift registry and the node identity) and return its
	// `conn_id` and raw peer for the driver to pump. Synchronous (no I/O), so the
	// caller learns the `conn_id` before spawning the driver, a redeem enrolls
	// the withdrawn capability against the exporter's `conn_id` immediately.
	fn register_conn(&self) -> Result<(u64, *mut sys::PancakePeer)> {
		let mut conn_id: u64 = 0;
		let mut peer: *mut sys::PancakePeer = core::ptr::null_mut();
		crate::check(unsafe {
			sys::pancake_node_register_conn(self.node.raw, &mut conn_id, &mut peer)
		})?;
		Ok((conn_id, peer))
	}

	// Remove a connection from the node: free its node-owned peer and retire the
	// `conn_id`. The driver calls it on its own connection after dropping the
	// peer wrapper, so no live borrow of the peer survives the free.
	fn remove_conn(&self, conn_id: u64) {
		unsafe { sys::pancake_node_remove_conn(self.node.raw, conn_id) };
	}

	// Track a connection's command channel by `conn_id` and publish every
	// node-giftable on it. Binding-internal: `over_shared` calls it the moment the
	// connection is registered, before the driver spawns, so a giftable is queued
	// as a bootstrap cap before the driver serves a dialer's pipelined fetch.
	fn register(&self, conn_id: u64, conn: &mpsc::UnboundedSender<Cmd>) {
		self.channels.borrow_mut().insert(conn_id, conn.clone());
		for (name, factory) in self.giftables.borrow().iter() {
			let (reply, _ignored) = oneshot::channel();
			let _ = conn.send(Cmd::Publish {
				name: name.clone(),
				behavior: factory(),
				reply,
			});
		}
	}

	// Stop tracking a closed connection. Binding-internal.
	fn unregister(&self, conn_id: u64) {
		self.channels.borrow_mut().remove(&conn_id);
	}

	// The command channel of the connection the node routed a deliver to, if it
	// is still live. Cloned out so the caller holds no borrow across the forward.
	fn channel_for(&self, conn_id: u64) -> Option<mpsc::UnboundedSender<Cmd>> {
		self.channels.borrow().get(&conn_id).cloned()
	}

	/// Publish `make`'s behavior under `name` on every connection of this node —
	/// those open now and any accepted later — so a recipient can fetch it on a
	/// connection it dialed itself (the exporter half of a three-party handoff,
	/// ADR-0009). `make` is a factory because an actor behavior is a `!Clone`
	/// `FnMut`: each connection gets a freshly minted behavior with the same
	/// logic.
	pub fn publish_giftable(&self, name: &str, make: impl Fn() -> Behavior + 'static) {
		let factory: GiftableFactory = Rc::new(make);
		self.giftables
			.borrow_mut()
			.insert(name.to_string(), Rc::clone(&factory));
		for conn in self.channels.borrow().values() {
			let (reply, _ignored) = oneshot::channel();
			let _ = conn.send(Cmd::Publish {
				name: name.to_string(),
				behavior: factory(),
				reply,
			});
		}
	}

	// Record that the far capability `reference` lives on the `home` connection
	// (ADR-0009): a `fetch` stamps every far import it returns, so a later
	// foreign-home return can be recognized and re-gifted. The node skips a
	// synthetic redeemed token (a high far id, never a wire import).
	fn record_foreign_home(&self, reference: &Reference, home: u64) {
		if let Reference::Far { id, .. } = reference {
			let _ = unsafe { sys::pancake_node_record_foreign_home(self.node.raw, *id, home) };
		}
	}

	// The node `conn_id` a fetched far `far_id` was recorded as living on, if any
	// (ADR-0009). Drives the gifter-origination home lookup.
	fn foreign_home_conn(&self, far_id: u64) -> Option<u64> {
		let mut out_conn: u64 = 0;
		let mut found: core::ffi::c_uint = 0;
		crate::check(unsafe {
			sys::pancake_node_foreign_home(self.node.raw, far_id, &mut out_conn, &mut found)
		})
		.ok()?;
		(found != 0).then_some(out_conn)
	}

	// Whether far `far_id`, sent as a `send`/`tell` argument from `default_conn`,
	// names a capability foreign to that connection — a redeemed token or a far
	// the node recorded as living elsewhere (ADR-0066). The node owns the verdict;
	// the binding fails closed on it rather than re-deriving the reserved-range
	// and foreign-home rule.
	fn arg_is_foreign(&self, default_conn: u64, far_id: u64) -> bool {
		let mut foreign: core::ffi::c_uint = 0;
		crate::check(unsafe {
			sys::pancake_node_arg_is_foreign(self.node.raw, default_conn, far_id, &mut foreign)
		})
		.is_ok_and(|()| foreign != 0)
	}

	// The exporter route for a redeemed token addressed from `default_conn`, if
	// `reference` names one: the destination connection's command channel and the
	// real exporter-side reference to swap in. `None` for an ordinary reference
	// (it rides its own connection), and `None` — fail closed — when the redeemed
	// token's exporter connection is gone.
	fn route(&self, default_conn: u64, reference: &Reference) -> Option<ExporterRoute> {
		let id = match reference {
			Reference::Far { id, .. } => *id,
			_ => return None,
		};
		if id < REDEEMED_TOKEN_BASE {
			return None;
		}
		let mut out_conn: u64 = 0;
		let mut out_far: u64 = 0;
		let mut routed: core::ffi::c_uint = 0;
		crate::check(unsafe {
			sys::pancake_node_route(
				self.node.raw,
				default_conn,
				id,
				&mut out_conn,
				&mut out_far,
				&mut routed,
			)
		})
		.ok()?;
		if routed == 0 {
			return None;
		}
		let channel = self.channel_for(out_conn)?;
		Some((
			channel,
			Reference::Far {
				id: out_far,
				promise: false,
			},
		))
	}

	// Enroll a redeemed capability hosted on `exporter_conn` under a fresh
	// reserved token and return the far reference the application receives,
	// indistinguishable from any other capability a partner hands back. A
	// withdraw always resolves to a far capability; anything else cannot be a
	// routable token, so it is handed back unchanged.
	fn enroll(&self, exporter_conn: u64, reference: Reference) -> Reference {
		let far_id = match reference {
			Reference::Far { id, .. } => id,
			other => return other,
		};
		let mut token: u64 = 0;
		crate::check(unsafe {
			sys::pancake_node_enroll_redeemed(self.node.raw, exporter_conn, far_id, &mut token)
		})
		.expect("the node enrolls a redeemed capability");
		Reference::Far {
			id: token,
			promise: false,
		}
	}

	// Recipient half of a three-party handoff, issued on the dialed exporter
	// connection: sign the `desc:handoff-receive` over the verbatim `give` bytes
	// keyed by the node identity, mint the handoff-count from the shared registry,
	// and queue `withdraw-gift` to the exporter's bootstrap under `answer` — the
	// one definition `engine.Node.sendWithdraw` shares with the native driver, so
	// the binding hands it bytes and an answer rather than re-signing a receive.
	fn send_withdraw(&self, exporter_conn: u64, give: &[u8], answer: u64) -> Result<()> {
		crate::check(unsafe {
			sys::pancake_node_send_withdraw(
				self.node.raw,
				exporter_conn,
				give.as_ptr(),
				give.len(),
				answer,
			)
		})
	}

	// Gifter half of a three-party handoff (ADR-0009), the mirror of
	// `send_withdraw`: queue a deposit of `gifted` on `exporter_conn`, build a
	// `desc:handoff-give` signed by the node identity and addressed to
	// `recipient_conn`'s partner, and queue it as the fulfillment of `answer` on
	// `recipient_conn` — the one definition `engine.Node.originateGive` shares with
	// the native driver. `exporter_location`, when non-empty, is the verbatim
	// exporter locator embedded in the give (empty uses the exporter session's own
	// location record). The caller flushes both connections (exporter first).
	fn originate_give(
		&self,
		recipient_conn: u64,
		exporter_conn: u64,
		gifted: &Reference,
		gift_id: &[u8],
		answer: u64,
		exporter_location: &[u8],
	) -> Result<()> {
		let r = gifted.to_sys()?;
		crate::check(unsafe {
			sys::pancake_node_originate_give(
				self.node.raw,
				recipient_conn,
				exporter_conn,
				&r,
				gift_id.as_ptr(),
				gift_id.len(),
				answer,
				exporter_location.as_ptr(),
				exporter_location.len(),
			)
		})
	}

	// Redeem one give: dial the named exporter keyed with the retained identity
	// (reusing an open connection to it), withdraw the gift, and return the
	// exporter's `conn_id` plus the live capability's reference. The caller
	// enrolls the reference against the `conn_id` to mint a routable token.
	async fn redeem(&self, give: HandoffGive) -> Result<(u64, Reference)> {
		if give.exporter_locator.is_empty() {
			return Err(Error::broken(
				"handoff give names no dialable exporter locator".to_string(),
			));
		}
		let locator = give.exporter_locator.clone();
		// Find the open exporter connection, or dial a fresh one, the borrow on
		// `exporters` is dropped before any await.
		let existing = self
			.exporters
			.borrow()
			.get(&locator)
			.map(|c| (c.conn_id, c.cmd_sender()));
		let (conn_id, channel) = match existing {
			Some(pair) => pair,
			None => {
				let conn = Connection::dial_exporter(&locator, self.clone()).await?;
				let pair = (conn.conn_id, conn.cmd_sender());
				self.exporters.borrow_mut().insert(locator.clone(), conn);
				pair
			}
		};
		let reference = withdraw_on(&channel, give.give).await?;
		Ok((conn_id, reference))
	}
}

// Withdraw a deposited gift over an exporter connection's command channel: queue
// the `WithdrawGift` command and await the withdrawn capability's reference. The
// node signs the receive with its own retained identity (the recipient withdraw
// lives in `engine.Node`), so the caller passes only the give bytes.
async fn withdraw_on(exporter: &mpsc::UnboundedSender<Cmd>, give: Vec<u8>) -> Result<Reference> {
	let (tx, rx) = oneshot::channel();
	exporter
		.send(Cmd::WithdrawGift { give, reply: tx })
		.map_err(|_| Error::from_code(sys::ERR_IO))?;
	rx.await.map_err(|_| Error::from_code(sys::ERR_IO))?
}

// Where a `send` is addressed. A `Ref` names a capability (a near export or a far
// import) as usual; a `Pipeline` names the still-pending answer of an earlier
// far send by the client-side ticket that issued it, so the driver delivers to
// that answer's `desc:answer` target, the wire form of promise pipelining.
// Public only because it appears in the [`AsSendTarget`] trait's plumbing;
// hidden from docs and not meant to be named by applications.
#[doc(hidden)]
pub enum CmdTarget {
	Ref(Reference),
	Pipeline(u64),
}

enum Cmd {
	Spawn {
		behavior: Behavior,
		reply: Reply<u64>,
	},
	Publish {
		name: String,
		behavior: Behavior,
		reply: Reply<u64>,
	},
	Fetch {
		name: String,
		reply: Reply<Reference>,
	},
	// Sturdyref enliven (ADR-0012): bring `(peer, swissnum)` to life through the
	// engine's dedup cache. A cache hit replies the cached far reference with no
	// wire traffic; a miss queues a bootstrap-fetch and replies once it settles.
	Enliven {
		swissnum: Vec<u8>,
		reply: Reply<Reference>,
	},
	// A wire-lifted far import's last `Ref` was dropped (ADR-0063): release one
	// wire-count unit to the partner so it can release the matching export. Sent
	// by an `ImportGuard::drop`, which may run on any thread — the channel sender
	// is `Send`, and the serve loop applies the release with peer access.
	GcDrop {
		position: u64,
	},
	// Publish a caretaker actor forwarding to `target` (ADR-0064); replies the
	// proxy export position. The shared `live` flag (held by the `Caretaker`
	// handle) severs it when cleared — no revoke command needed.
	Caretaker {
		target: Reference,
		live: Arc<AtomicBool>,
		reply: Reply<u64>,
	},
	// Publish an attenuator actor forwarding only `verbs` to `target` (ADR-0064);
	// replies the proxy export position.
	Attenuate {
		target: Reference,
		verbs: Vec<String>,
		reply: Reply<u64>,
	},
	Send {
		ticket: u64,
		target: CmdTarget,
		verb: String,
		args: Vec<Argument>,
		reply: Reply<Argument>,
	},
	// Pipelined projection (ADR-0050/ADR-0052): issue `op` against the answer of
	// the send that minted `source_ticket`, recording `ticket -> answer` for the
	// projected result so it is itself pipelinable. A projection of a ticket the
	// driver never recorded (a local send, or an already-settled answer) is
	// refused on `reply`, like an unknown pipeline target.
	Project {
		source_ticket: u64,
		op: ProjectOp,
		ticket: u64,
		reply: Reply<Argument>,
	},
	Tell {
		target: Reference,
		verb: String,
		args: Vec<Argument>,
	},
	// Recipient half of a three-party handoff, issued on the exporter
	// connection: the node signs a `desc:handoff-receive` over `give` keyed by
	// its retained identity, delivers `withdraw-gift` to the exporter's
	// bootstrap, and replies with the withdrawn capability's reference once it
	// resolves. Binding-internal — the node router issues it during `redeem`.
	WithdrawGift {
		give: Vec<u8>,
		reply: Reply<Reference>,
	},
	// Gifter half of a three-party handoff (ADR-0009), issued on the *exporter*
	// connection (which owns the exporter peer and the dial-hint locator
	// override): the node deposits `gifted` here, signs a `desc:handoff-give`
	// addressed to `recipient_conn`'s partner, and queues it as the resolution of
	// `answer` on the recipient peer; this loop flushes the deposit, then signals
	// the recipient loop to flush the resolve. Binding-internal — the resolve
	// interceptor issues it when a published actor returns a foreign-home cap.
	OriginateGive {
		recipient_conn: u64,
		recipient_tx: mpsc::UnboundedSender<Cmd>,
		answer: u64,
		gifted: Reference,
	},
	// Flush this connection's queued outbound frames. Issued on the to-recipient
	// connection so it puts the give the node queued onto the wire from its own
	// loop (the loop that owns the stream).
	FlushOutbound,
	// Break the recipient's question when origination fails, so the recipient's
	// send settles as a break carrying the reason rather than hanging.
	ResolveBreak {
		answer: u64,
		message: String,
	},
	Close,
}

/// The handle [`Connection::send`] returns: the eventual result of one
/// eventual-send, and — the point of promise pipelining (ADR-0007) — a target
/// you can `send` to before it resolves.
///
/// It is `IntoFuture<Output = Result<Argument>>`, so `conn.send(...).await` yields
/// the reply exactly as before (a [`Ref`] via `Ref::try_from(&arg)` if the
/// partner returned a capability; a typed `Err` on a break). Pass it *unawaited*
/// — by reference — as the `target` of a later `send` to address the object the
/// answer will resolve to: the dependent call rides a `desc:answer` deliver the
/// partner queues until the answer settles, so a `create -> use` chain costs one
/// round trip instead of one per link:
///
/// ```ignore
/// let task = conn.send(&root, "create", &["x".into()]);   // not awaited
/// conn.send(&task, "assign", &["alice".into()]);           // pipelined at the answer
/// let status = conn.send(&task, "status", &[]).await?;     // settles the chain
/// ```
///
/// A handle awaited for its value resolves once; a handle only used as a target
/// (never awaited) is a dependency anchor whose own reply is dropped.
pub struct RemotePromise {
	ticket: u64,
	reply: oneshot::Receiver<Result<Argument>>,
	// A handle back to the driver, so this promise can issue a projection
	// (`op:get` / `op:index` / `op:untag`) against its own still-pending answer
	// and a fresh ticket from the same per-connection sequence.
	cmd_tx: mpsc::UnboundedSender<Cmd>,
	next_ticket: Rc<Cell<u64>>,
}

impl RemotePromise {
	fn ticket(&self) -> u64 {
		self.ticket
	}

	// Issue a projection at this promise's answer and return a new pipelinable
	// promise for the projected value. By `&self`, so a handle can be projected
	// *and* still awaited later for its own value (the late-source-await case).
	// A projection of a local-send promise — one with no far answer — is refused
	// by the driver on the returned promise's reply, the same way an unknown
	// pipeline target is.
	fn project(&self, op: ProjectOp) -> RemotePromise {
		let ticket = self.next_ticket.get();
		self.next_ticket.set(ticket.wrapping_add(1));
		let (tx, rx) = oneshot::channel();
		let _ = self.cmd_tx.send(Cmd::Project {
			source_ticket: self.ticket,
			op,
			ticket,
			reply: tx,
		});
		RemotePromise {
			ticket,
			reply: rx,
			cmd_tx: self.cmd_tx.clone(),
			next_ticket: Rc::clone(&self.next_ticket),
		}
	}

	/// Pipeline an `op:get` for `field` at this answer (ADR-0050): a new
	/// [`RemotePromise`] for the Struct field of whatever this resolves to,
	/// projected before this answer settles.
	pub fn get(&self, field: &str) -> RemotePromise {
		self.project(ProjectOp::Get(field.to_string()))
	}

	/// Pipeline an `op:index` for `i` at this answer (ADR-0050): a new
	/// [`RemotePromise`] for the List element of whatever this resolves to.
	pub fn index(&self, i: i64) -> RemotePromise {
		self.project(ProjectOp::Index(i))
	}

	/// Pipeline an `op:untag` for `tag` at this answer (ADR-0052): a new
	/// [`RemotePromise`] for the payload of whatever this resolves to, which must
	/// be a Tagged record whose tag equals `tag`.
	pub fn untag(&self, tag: &str) -> RemotePromise {
		self.project(ProjectOp::Untag(tag.to_string()))
	}
}

// Which projection a `RemotePromise` issues against its answer; the driver maps
// it to the matching `op:get` / `op:index` / `op:untag` send.
enum ProjectOp {
	Get(String),
	Index(i64),
	Untag(String),
}

impl IntoFuture for RemotePromise {
	type Output = Result<Argument>;
	type IntoFuture = Pin<Box<dyn Future<Output = Result<Argument>>>>;

	fn into_future(self) -> Self::IntoFuture {
		Box::pin(async move {
			// The driver dropped the reply sender (it is gone, or the send never
			// reached it): surface the transport fault, matching `fetch`.
			self.reply
				.await
				.unwrap_or_else(|_| Err(Error::from_code(sys::ERR_IO)))
		})
	}
}

/// What a `send` accepts as its target: a capability [`Ref`], or a
/// [`RemotePromise`] from an earlier send to pipeline against. Borrowed in both
/// cases so an unawaited `RemotePromise` can still be awaited later.
pub trait AsSendTarget {
	#[doc(hidden)]
	fn as_send_target(&self) -> CmdTarget;
}

impl AsSendTarget for &Ref {
	fn as_send_target(&self) -> CmdTarget {
		CmdTarget::Ref(self.reference.clone())
	}
}

impl AsSendTarget for &RemotePromise {
	fn as_send_target(&self) -> CmdTarget {
		CmdTarget::Pipeline(self.ticket())
	}
}

/// A live connection to one OCapN partner — the one object an application holds.
/// `!Send` by construction (it owns a `!Send` peer on a background task); use it
/// on a single task inside a `LocalSet`.
pub struct Connection {
	cmd_tx: mpsc::UnboundedSender<Cmd>,
	driver: Cell<Option<tokio::task::JoinHandle<()>>>,
	// Client-side monotonic id stamped on each `send`, so a pipelined send can
	// name the answer of an earlier one without waiting for the driver to report
	// its wire answer position. The driver maps ticket -> answer in arrival order.
	// Shared (`Rc`) so a `RemotePromise` can mint a fresh ticket for a projection
	// it issues, from the same per-connection sequence.
	next_ticket: Rc<Cell<u64>>,
	// Opt-in distributed GC (ADR-0063), off by default. When on, a far reference
	// this connection lifts from the wire (`fetch`/`enliven`) carries a death
	// rite that releases its import on drop.
	gc: Cell<bool>,
	// The node this connection belongs to — its retained identity, shared
	// gift registry, and gifter-side routing. Shared with every other connection
	// of the same node so a capability fetched on one and returned on another is
	// recognized as foreign and re-gifted (ADR-0009).
	node: Node,
	// This connection's node `conn_id` (ADR-0066): the node owns the peer behind
	// it, routes redeemed-token sends to it, and the driver pumps it. A redeem
	// reads it to enroll the withdrawn capability against this exporter.
	conn_id: u64,
	// An optional dialable exporter location this connection's gifter origination
	// signs into a give instead of the exporter's own signed session record
	// (ADR-0009). Set by [`set_exporter_locator`](Connection::set_exporter_locator)
	// when the gifter learned the exporter's full `ocapn://…?direct-addresses=…`
	// out of band — the only way a give can name an iroh exporter reachable by a
	// dial hint under the relay-less `Direct` posture. Shared (`Rc`) with the
	// driver task, which reads it when it deposits a gift. Unset, origination falls
	// back to the partner's signed location (a TCP host:port, or an iroh node id
	// resolvable by `Discovery`).
	exporter_locator: Rc<RefCell<Option<Vec<u8>>>>,
}

impl Connection {
	/// Dial `addr` and return a ready connection, spawning its driver task.
	/// Must be called inside a `LocalSet` (the peer is `!Send`). The connection
	/// is its own node, with a fresh retained identity; use
	/// [`connect_with_node`](Connection::connect_with_node) to share one
	/// node identity across several connections (the gifter half of a three-party
	/// handoff).
	pub async fn connect<A: ToSocketAddrs>(addr: A) -> Result<Connection> {
		Connection::connect_with_node(addr, Node::new_node()).await
	}

	/// Dial `addr` sharing `node` — one node identity and gift registry across
	/// several connections (the gifter half of a three-party handoff, ADR-0009).
	/// A capability fetched on one connection of the node and returned on another
	/// is recognized as foreign and re-gifted rather than mis-encoded. Must be
	/// called inside a `LocalSet`.
	pub async fn connect_with_node<A: ToSocketAddrs>(addr: A, node: Node) -> Result<Connection> {
		let stream = TcpStream::connect(addr)
			.await
			.map_err(|_| Error::from_code(sys::ERR_IO))?;
		let designator = stream
			.local_addr()
			.map(|a| a.to_string())
			.unwrap_or_else(|_| "127.0.0.1:0".to_string());
		Ok(Connection::over_shared(stream, "tcp", designator, node))
	}

	/// Wrap an already-connected stream as its own node, spawning the driver task
	/// that completes the keyed handshake and then serves commands. The exchange
	/// is symmetric — both ends send `op:start-session` first, then read — so the
	/// same driver serves a dialed and an accepted stream. Generic over the stream
	/// so the identical driver carries the peer over TCP or over the iroh sidecar
	/// bridge ([`crate::iroh::IrohStream`]); `transport`/`designator` are what
	/// this side signs into its keyed `op:start-session` location (`tcp` +
	/// `host:port`, or `iroh` + the endpoint-id locator).
	///
	/// `pub(crate)` so the iroh transport ([`crate::iroh`]) can mint a
	/// [`Connection`] over its byte-stream bridge without `connection.rs` itself
	/// reaching into iroh. A plain `connect_iroh` dial is its own node; an iroh
	/// exporter dialed to redeem a handoff shares the recipient's node `Node`
	/// through [`Connection::over_shared`], exactly as the TCP redeem does.
	#[cfg(feature = "iroh")]
	pub(crate) fn over<S>(stream: S, transport: &str, designator: String) -> Connection
	where
		S: AsyncRead + AsyncWrite + Unpin + 'static,
	{
		Connection::over_shared(stream, transport, designator, Node::new_node())
	}

	// Spawn a driver task carrying the peer for this connection, bound to the
	// node `node` — its retained identity (the seed every connection of the
	// node presents), its shared gift registry, and its gifter-side routing.
	// `pub(crate)` so the iroh transport can mint a node-keyed connection over
	// its byte-stream bridge for a handoff redeem.
	pub(crate) fn over_shared<S>(
		stream: S,
		transport: &str,
		designator: String,
		node: Node,
	) -> Connection
	where
		S: AsyncRead + AsyncWrite + Unpin + 'static,
	{
		let (cmd_tx, cmd_rx) = mpsc::unbounded_channel();
		let transport = transport.to_string();
		let self_tx = cmd_tx.clone();
		// Register a node-owned peer for this connection synchronously (no I/O),
		// so its `conn_id` is known before the driver spawns — a redeem enrolls
		// the withdrawn capability against this exporter's `conn_id`, and a sibling
		// connection can route a redeemed-token send here right away. Registering
		// the command channel now also queues every node-giftable as a bootstrap
		// cap before the driver serves a dialer's pipelined fetch.
		let (conn_id, peer_raw) = node
			.register_conn()
			.expect("the node registers a connection");
		node.register(conn_id, &self_tx);
		let drive_node = node.clone();
		let exporter_locator: Rc<RefCell<Option<Vec<u8>>>> = Rc::new(RefCell::new(None));
		let drive_exporter_locator = Rc::clone(&exporter_locator);
		// `peer_raw` is a node-owned peer pointer (`!Send`); the driver wraps it
		// without owning it and the node frees it on `remove_conn` at task end.
		let driver = tokio::task::spawn_local(async move {
			let _ = drive(
				stream,
				&transport,
				&designator,
				cmd_rx,
				self_tx,
				drive_node,
				conn_id,
				peer_raw,
				drive_exporter_locator,
			)
			.await;
		});
		Connection {
			cmd_tx,
			driver: Cell::new(Some(driver)),
			next_ticket: Rc::new(Cell::new(0)),
			gc: Cell::new(false),
			node,
			conn_id,
			exporter_locator,
		}
	}

	/// The node this connection belongs to, its retained identity, gift
	/// registry, and gifter-side routing, shared with every connection of the
	/// same node. Pass it to [`connect_with_node`](Connection::connect_with_node)
	/// to bring up a sibling connection under one node, and publish a
	/// node-giftable on it with [`Node::publish_giftable`].
	pub fn node(&self) -> Node {
		self.node.clone()
	}

	/// Record the dialable exporter location this connection's gifter origination
	/// signs into a give, in place of the exporter's own signed session record
	/// (ADR-0009). `raw` is the verbatim location bytes from [`encode_peer_locator`]
	/// (read off the registered exporter URI). Binding-internal: a rendezvous that
	/// learned a member's iroh URI sets it so a give can name an exporter reachable
	/// only by a dial hint under the relay-less `Direct` posture. Unset, origination
	/// uses the partner's signed location.
	pub fn set_exporter_locator(&self, raw: Vec<u8>) {
		*self.exporter_locator.borrow_mut() = Some(raw);
	}

	/// Opt this connection into distributed GC (ADR-0063), off by default. Once
	/// on, a far capability returned by [`fetch`](Connection::fetch) releases its
	/// import to the partner — a single `op:gc-exports` delta — when the last
	/// `Ref` to it is dropped, so the partner can release the matching export.
	/// Capabilities lifted elsewhere (a `send` reply, a delivered argument via
	/// `Ref::try_from`, an `enliven` result the dedup cache owns) are outside this
	/// seam. Returns `self` for chaining after `connect`.
	pub fn with_gc(self) -> Connection {
		self.gc.set(true);
		self
	}

	// Wrap a wire-lifted reference into a `Ref`, attaching the GC death rite when
	// GC is on and the reference is a real far import (ADR-0063): not a near
	// export, not the bootstrap import (position 0, refused in a `gc-exports`),
	// and not a redeemed-handoff token (a synthetic far id, never a wire import).
	fn lift_import(&self, reference: Reference) -> Ref {
		if !self.gc.get() {
			return Ref::bare(reference);
		}
		match reference {
			Reference::Far { id, .. } if id != 0 && id < REDEEMED_TOKEN_BASE => Ref {
				reference,
				guard: Some(std::sync::Arc::new(ImportGuard {
					position: id,
					cmd_tx: self.cmd_tx.clone(),
				})),
			},
			_ => Ref::bare(reference),
		}
	}

	// A clone of this connection's command channel, for the node router to
	// forward redeemed-capability sends to an exporter connection it owns.
	fn cmd_sender(&self) -> mpsc::UnboundedSender<Cmd> {
		self.cmd_tx.clone()
	}

	// Dial an exporter named by a handoff give's `ocapn://` locator, keyed with
	// `node`'s retained identity and bound to that same node, so the
	// redeemed capability shares one node identity, gift registry, and connection
	// table with the connection the give arrived over. Binding-internal: the
	// node router calls this during `redeem`. Dispatches on the locator's
	// transport, a `tcp` host:port, or an `iroh` endpoint id whose posture the
	// give's hints imply: direct-address hints dial them with no discovery service
	// (Direct), a bare node id resolves by id under the recipient node's
	// configured redeem posture (default Discovery; a relay-policy node lowers it
	// to DiscoveryNoRelay), so one give shape covers an offline direct dial and an
	// internet dial-by-id.
	#[cfg_attr(not(feature = "iroh"), allow(unused_variables))]
	async fn dial_exporter(uri: &str, node: Node) -> Result<Connection> {
		let loc = crate::uri::parse_locator(uri)?;
		match loc.transport.as_str() {
			"tcp" => {
				let stream = TcpStream::connect(loc.designator.as_str())
					.await
					.map_err(|_| Error::from_code(sys::ERR_IO))?;
				let designator = stream
					.local_addr()
					.map(|a| a.to_string())
					.unwrap_or_else(|_| "127.0.0.1:0".to_string());
				Ok(Connection::over_shared(stream, "tcp", designator, node))
			}
			#[cfg(feature = "iroh")]
			"iroh" => {
				let addrs = loc
					.hints
					.get("direct-addresses")
					.map(String::as_str)
					.unwrap_or("");
				let reachability = if addrs.is_empty() {
					node.redeem_reachability()
				} else {
					Reachability::Direct
				};
				Connection::connect_iroh_with_node(&loc.designator, addrs, reachability, node)
					.await
			}
			#[cfg(not(feature = "iroh"))]
			"iroh" => Err(Error::with_detail(
				sys::ERR_INVALID_ARGUMENT,
				format!("handoff redeem: this build has no iroh transport; rebuild with the iroh feature to dial {uri}"),
			)),
			other => Err(Error::with_detail(
				sys::ERR_INVALID_ARGUMENT,
				format!("handoff redeem: unsupported exporter transport \"{other}\" in {uri}"),
			)),
		}
	}

	/// Spawn a local actor and return a capability to it. Pass the returned `Ref`
	/// as a `send` argument to hand a partner a callback. The position comes from
	/// the session's one export allocator (on the driver task, hence the await),
	/// so it can never alias a bootstrap or resolver export.
	pub async fn spawn(
		&self,
		behavior: impl FnMut(&str, &[Argument]) -> std::result::Result<Argument, String> + 'static,
	) -> Result<Ref> {
		let (tx, rx) = oneshot::channel();
		self.cmd_tx
			.send(Cmd::Spawn {
				behavior: Box::new(behavior),
				reply: tx,
			})
			.map_err(|_| Error::from_code(sys::ERR_IO))?;
		let position = rx.await.map_err(|_| Error::from_code(sys::ERR_IO))??;
		Ok(Ref::bare(Reference::Near {
			id: position,
			promise: false,
		}))
	}

	/// Publish an actor so a partner can [`fetch`](Connection::fetch) it by `name`
	/// (a swiss-number). Returns a capability to it.
	pub async fn publish(
		&self,
		name: &str,
		behavior: impl FnMut(&str, &[Argument]) -> std::result::Result<Argument, String> + 'static,
	) -> Result<Ref> {
		let (tx, rx) = oneshot::channel();
		self.cmd_tx
			.send(Cmd::Publish {
				name: name.to_string(),
				behavior: Box::new(behavior),
				reply: tx,
			})
			.map_err(|_| Error::from_code(sys::ERR_IO))?;
		let position = rx.await.map_err(|_| Error::from_code(sys::ERR_IO))??;
		Ok(Ref::bare(Reference::Near {
			id: position,
			promise: false,
		}))
	}

	/// Fetch a partner's published capability by `name`. Requires
	/// [`serve`](Connection::serve) to be running so the resolution arrives.
	pub async fn fetch(&self, name: &str) -> Result<Ref> {
		let (tx, rx) = oneshot::channel();
		self.cmd_tx
			.send(Cmd::Fetch {
				name: name.to_string(),
				reply: tx,
			})
			.map_err(|_| Error::from_code(sys::ERR_IO))?;
		let reference = rx.await.map_err(|_| Error::from_code(sys::ERR_IO))??;
		Ok(self.lift_import(reference))
	}

	/// Enliven a sturdyref against this connection (ADR-0012): bring the durable
	/// `(peer, swissnum)` to life as a live [`Ref`]. Parses `sturdyref` for its
	/// swissnum, then fetches it through the dedup cache — a repeat enliven of
	/// the same swissnum on this session short-circuits with no wire traffic.
	/// The connection must already be open to the sturdyref's peer; the sans-io
	/// core tracks no remote locator and never dials, so reaching the right peer
	/// is the caller's. Requires [`serve`](Connection::serve) to be running so
	/// the resolution arrives. Rejects with a typed `Err` on a partner break or
	/// a non-capability fulfillment.
	pub async fn enliven(&self, sturdyref: &str) -> Result<Ref> {
		let swissnum = crate::uri::parse_sturdyref(sturdyref)?
			.swissnum
			.into_bytes();
		let (tx, rx) = oneshot::channel();
		self.cmd_tx
			.send(Cmd::Enliven {
				swissnum,
				reply: tx,
			})
			.map_err(|_| Error::from_code(sys::ERR_IO))?;
		let reference = rx.await.map_err(|_| Error::from_code(sys::ERR_IO))??;
		// Not GC-tracked: the ADR-0012 dedup cache retains this import for a
		// repeat enliven, so the cache — not a handle finalizer — owns its
		// lifetime (ADR-0063).
		Ok(Ref::bare(reference))
	}

	/// Wrap `target` (local or far) in a revocable caretaker (ADR-0064). Returns a
	/// [`Caretaker`] whose `proxy` is an ordinary capability you hand a partner;
	/// every call through it forwards to `target` until you
	/// [`revoke`](Caretaker::revoke) it, after which each call breaks with
	/// `Revoked`. `target` may be a capability you imported over the wire — the
	/// proxy forwards transparently — so this hands out a revocable view of
	/// authority you do not own locally.
	pub async fn caretaker(&self, target: &Ref) -> Result<Caretaker> {
		let (tx, rx) = oneshot::channel();
		let live = Arc::new(AtomicBool::new(true));
		self.cmd_tx
			.send(Cmd::Caretaker {
				target: target.reference.clone(),
				live: Arc::clone(&live),
				reply: tx,
			})
			.map_err(|_| Error::from_code(sys::ERR_IO))?;
		let position = rx.await.map_err(|_| Error::from_code(sys::ERR_IO))??;
		Ok(Caretaker {
			proxy: Ref::bare(Reference::Near {
				id: position,
				promise: false,
			}),
			live,
		})
	}

	/// Wrap `target` (local or far) in an attenuator (ADR-0064): a proxy that
	/// forwards only the calls whose verb is in `verbs` and breaks every other
	/// with `Attenuated`. Returns the proxy capability to hand a partner. `target`
	/// may be a wire-imported capability, so this narrows authority you hold.
	pub async fn attenuate(&self, target: &Ref, verbs: &[&str]) -> Result<Ref> {
		let (tx, rx) = oneshot::channel();
		let verbs = verbs.iter().map(|v| v.to_string()).collect();
		self.cmd_tx
			.send(Cmd::Attenuate {
				target: target.reference.clone(),
				verbs,
				reply: tx,
			})
			.map_err(|_| Error::from_code(sys::ERR_IO))?;
		let position = rx.await.map_err(|_| Error::from_code(sys::ERR_IO))??;
		Ok(Ref::bare(Reference::Near {
			id: position,
			promise: false,
		}))
	}

	/// Eventual-send `verb(args)` to `target` and return a [`RemotePromise`] for
	/// the reply. `await` it for the value (a capability via `Ref::try_from`; a
	/// typed `Err` on a partner break), exactly as before.
	///
	/// `target` is a capability `&Ref` *or* a `&RemotePromise` from an earlier
	/// send: passing the latter pipelines (ADR-0007) — the call is addressed at
	/// the answer that send will resolve, so a dependent chain costs one round
	/// trip instead of one per link. `args` may contain capabilities via
	/// `Into<Argument>`.
	// Whether `reference` names a capability that lives on a *different*
	// connection of this node: a redeemed-handoff token (the node routes it to
	// its exporter) or a far the node recorded as fetched on another connection.
	// The gifter half handles such a capability when it is *returned* (ADR-0009);
	// passing one as a send argument is the symmetric case still to land, so a
	// send fails closed rather than mis-encode it for this partner.
	fn is_foreign(&self, reference: &Reference) -> bool {
		match reference {
			Reference::Far { id, .. } => self.node.arg_is_foreign(self.conn_id, *id),
			_ => false,
		}
	}

	// Refuse a capability that lives on another connection in send-argument
	// position, recursing into the container shapes a reference can hide in.
	fn assert_no_foreign_ref(&self, arg: &Argument) -> Result<()> {
		match arg {
			Argument::Reference(reference) if self.is_foreign(reference) => Err(Error::with_detail(
				sys::ERR_INVALID_ARGUMENT,
				"passing a capability that lives on another connection as a send argument is not yet supported; \
				 introduce it as a return value instead (three-party handoff in argument position is the next lift)"
					.to_string(),
			)),
			Argument::List(items) | Argument::Set(items) => {
				for item in items {
					self.assert_no_foreign_ref(item)?;
				}
				Ok(())
			}
			Argument::Tagged { value, .. } => {
				for item in value {
					self.assert_no_foreign_ref(item)?;
				}
				Ok(())
			}
			_ => Ok(()),
		}
	}

	fn assert_no_foreign_args(&self, args: &[Argument]) -> Result<()> {
		for arg in args {
			self.assert_no_foreign_ref(arg)?;
		}
		Ok(())
	}

	pub fn send<T: AsSendTarget>(&self, target: T, verb: &str, args: &[Argument]) -> RemotePromise {
		let ticket = self.next_ticket.get();
		self.next_ticket.set(ticket.wrapping_add(1));
		let (tx, rx) = oneshot::channel();
		// Refuse a foreign capability in argument position before it reaches the
		// driver; the refusal surfaces when the returned promise is awaited, the
		// same path a partner break takes.
		if let Err(e) = self.assert_no_foreign_args(args) {
			let _ = tx.send(Err(e));
			return RemotePromise {
				ticket,
				reply: rx,
				cmd_tx: self.cmd_tx.clone(),
				next_ticket: Rc::clone(&self.next_ticket),
			};
		}
		// If the driver is gone the send is dropped here; the dropped `tx` makes
		// the returned promise surface `ERR_IO` when awaited, the same fault the
		// reply path reports — no separate error channel to reconcile.
		let _ = self.cmd_tx.send(Cmd::Send {
			ticket,
			target: target.as_send_target(),
			verb: verb.to_string(),
			args: args.to_vec(),
			reply: tx,
		});
		RemotePromise {
			ticket,
			reply: rx,
			cmd_tx: self.cmd_tx.clone(),
			next_ticket: Rc::clone(&self.next_ticket),
		}
	}

	/// Fire-and-forget eventual-send (Goblins `<-np`): no answer is allocated and
	/// no reply comes back, so a notification or broadcast costs one deliver
	/// rather than a deliver plus a reply.
	pub fn tell(&self, target: &Ref, verb: &str, args: &[Argument]) -> Result<()> {
		self.assert_no_foreign_args(args)?;
		self.cmd_tx
			.send(Cmd::Tell {
				target: target.reference.clone(),
				verb: verb.to_string(),
				args: args.to_vec(),
			})
			.map_err(|_| Error::from_code(sys::ERR_IO))
	}

	/// Run the inbound event loop in the background (it already runs from
	/// `connect`); the returned future completes when the connection closes.
	/// Calling it without awaiting is fine, the driver runs regardless.
	pub fn serve(&self) -> impl std::future::Future<Output = ()> {
		let handle = self.driver.take();
		async move {
			if let Some(h) = handle {
				let _ = h.await;
			}
		}
	}

	/// Close the connection; a running [`serve`](Connection::serve) completes.
	pub fn close(&self) {
		let _ = self.cmd_tx.send(Cmd::Close);
	}
}

impl Drop for Connection {
	fn drop(&mut self) {
		let _ = self.cmd_tx.send(Cmd::Close);
	}
}

/// A listening server, the host-side counterpart of [`connect`]. Call
/// [`Server::accept`] for each partner; every accepted [`Connection`] shares the
/// server's one node [`Node`] (its retained identity and gift registry), so
/// the server is one node serving many partners. Dropping the server stops
/// accepting; live connections are unaffected.
pub struct Server {
	listener: TcpListener,
	node: Node,
}

impl Server {
	/// Accept the next partner as a ready [`Connection`], sharing this server's
	/// node [`Node`]. The keyed handshake runs first on the connection's
	/// driver task, so commands issued on the returned handle wait until the
	/// session is open; a node-giftable published with [`Node::publish_giftable`]
	/// is registered as a bootstrap cap before a dialer's pipelined fetch is
	/// answered. Must be called inside a `LocalSet` (the peer is `!Send`).
	pub async fn accept(&self) -> Result<Connection> {
		let (stream, _) = self
			.listener
			.accept()
			.await
			.map_err(|_| Error::from_code(sys::ERR_IO))?;
		let designator = stream
			.local_addr()
			.map(|a| a.to_string())
			.unwrap_or_else(|_| "127.0.0.1:0".to_string());
		Ok(Connection::over_shared(
			stream,
			"tcp",
			designator,
			self.node.clone(),
		))
	}

	/// The bound local address, read the port off it when you bound port 0.
	pub fn local_addr(&self) -> Result<std::net::SocketAddr> {
		self.listener
			.local_addr()
			.map_err(|_| Error::from_code(sys::ERR_IO))
	}

	/// This server's node [`Node`], one retained identity and gift registry
	/// across every accepted connection. Pass it to
	/// [`Connection::connect_with_node`] so a capability fetched on a dialed
	/// connection and returned to an accepted one shares one node (the gifter
	/// half of a three-party handoff), and publish a node-giftable on it with
	/// [`Node::publish_giftable`].
	pub fn node(&self) -> Node {
		self.node.clone()
	}
}

/// Bind `addr` and return a [`Server`] to [`accept`](Server::accept) partners
/// on, the host-side counterpart of [`connect`]. The server is one node with a
/// fresh retained identity shared across every accepted connection.
pub async fn listen<A: ToSocketAddrs>(addr: A) -> Result<Server> {
	let listener = TcpListener::bind(addr)
		.await
		.map_err(|_| Error::from_code(sys::ERR_IO))?;
	Ok(Server {
		listener,
		node: Node::new_node(),
	})
}

// The iroh transport — dialing (`connect`/`Connection::connect_iroh`) and
// hosting (`listen_iroh`/`IrohServer`) over iroh's encrypted QUIC — lives in
// [`crate::iroh`], built only with the `iroh` feature. It mints connections
// through `Connection::over`, so this core driver carries no iroh reference, the
// same `libpancake_ocapn` / `libpancake_net_transport_iroh` split the other bindings mirror.

/// How an iroh endpoint becomes reachable — the mandatory posture an iroh dial or
/// listen chooses, in the open. There is no default: a pancake peer never turns on
/// relays or a discovery service as a hidden implementation detail, so the caller
/// always names one. A `tcp` dial ignores it (pass `None` to [`connect`]).
///
/// - `Direct`: relay-less, lookup-less — dial by id plus explicit address hints
///   (loopback/LAN). The rooms demo's posture: its URIs carry direct-addresses.
/// - `Discovery`: number-0 relays + DNS/pkarr discovery — dialable by id alone
///   over the internet, with hole-punching and NAT traversal.
/// - `DiscoveryNoRelay`: DNS/pkarr discovery without relays.
/// - `LocalDiscovery`: in-process shared address book — resolves by id alone
///   with no relay, DNS, or hints. For tests and same-process embeddings.
#[repr(u32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Reachability {
	Direct = 0,
	Discovery = 1,
	DiscoveryNoRelay = 2,
	LocalDiscovery = 3,
}

/// Dial a partner from its `ocapn://` locator — the one dialer, transport-neutral.
/// A `tcp` locator (including one built with [`tcp_locator`]) ignores
/// `reachability`, so pass `None`; an `iroh` locator requires it (the posture is
/// never guessed). The signature is the same whether or not the iroh transport is
/// compiled in, so a call site never changes when the feature is turned on —
/// without it, an `iroh` locator fails with a rebuild hint rather than dialing,
/// and a tcp-only build links no iroh companion library.
#[cfg(feature = "async")]
#[cfg_attr(not(feature = "iroh"), allow(unused_variables))]
pub async fn connect(uri: &str, reachability: Option<Reachability>) -> Result<Connection> {
	let loc = crate::uri::parse_locator(uri)?;
	match loc.transport.as_str() {
        "tcp" => Connection::connect(loc.designator.as_str()).await,
        #[cfg(feature = "iroh")]
        "iroh" => {
            let reachability = reachability.ok_or_else(|| {
                Error::with_detail(
                    sys::ERR_INVALID_ARGUMENT,
                    format!("connect: an iroh locator requires a reachability posture: {uri}"),
                )
            })?;
            let addrs = loc.hints.get("direct-addresses").map(String::as_str).unwrap_or("");
            Connection::connect_iroh(&loc.designator, addrs, reachability).await
        }
        #[cfg(not(feature = "iroh"))]
        "iroh" => Err(Error::with_detail(
            sys::ERR_INVALID_ARGUMENT,
            format!("connect: this build has no iroh transport; rebuild with the iroh feature to dial {uri}"),
        )),
        other => Err(Error::with_detail(
            sys::ERR_INVALID_ARGUMENT,
            format!("connect: unsupported transport \"{other}\""),
        )),
    }
}

/// Build a `tcp` locator from a literal host and port: `ocapn://host:port.tcp`,
/// rendered through the core grammar. The convenience for the common case — a
/// caller holding a host and port passes `connect(&tcp_locator(host, port))`
/// instead of hand-formatting the URI. `host:port` is not a dial of its own; it
/// is a locator like any other.
/// Build the verbatim exporter location-record bytes a gifter embeds in a give
/// when the exporter is reachable only by a dial hint (ADR-0009) — the
/// construct-it-yourself counterpart of the partner's signed session record, for
/// an exporter whose own record carries no hint. `transport`/`designator` name
/// the exporter; a non-empty `direct_addresses` (comma-separated socket
/// addresses) adds a `direct-addresses` hint so a cross-process recipient dials
/// it directly with no discovery service (an iroh exporter reachable only by
/// address). The result feeds [`Connection::set_exporter_locator`]. An empty
/// `direct_addresses` yields a hint-less location identical to the exporter's own
/// signed record, so a TCP or discovery-reachable exporter needs no override.
pub fn encode_peer_locator(
	transport: &str,
	designator: &str,
	direct_addresses: &str,
) -> Result<Vec<u8>> {
	let mut out: *mut core::ffi::c_uchar = core::ptr::null_mut();
	let mut out_len: usize = 0;
	crate::check(unsafe {
		sys::pancake_encode_peer_locator(
			transport.as_ptr(),
			transport.len(),
			designator.as_ptr(),
			designator.len(),
			direct_addresses.as_ptr(),
			direct_addresses.len(),
			&mut out,
			&mut out_len,
		)
	})?;
	let bytes = if out.is_null() || out_len == 0 {
		Vec::new()
	} else {
		unsafe { core::slice::from_raw_parts(out, out_len) }.to_vec()
	};
	unsafe { sys::pancake_peer_locator_bytes_release(out, out_len) };
	Ok(bytes)
}

pub fn tcp_locator(host: &str, port: u16) -> String {
	crate::uri::format_peer_uri(
		"tcp",
		&format!("{host}:{port}"),
		&std::collections::BTreeMap::new(),
	)
	.expect("a tcp host:port locator always formats through the core grammar")
}

// A settled enliven's cache record, deferred out of the resolution callback
// (which cannot reach the peer) and applied by the serve loop with peer access.
// `outcome` is an `ENLIVEN_OUTCOME_*` value; `import_position`/`kind` are read
// only on the fulfilled outcome.
struct EnlivenRecord {
	swiss: Vec<u8>,
	outcome: u32,
	import_position: u64,
	kind: u32,
}

type EnlivenRecords = Rc<RefCell<Vec<EnlivenRecord>>>;

// Drain the deferred enliven records into the engine's dedup cache. Best-effort:
// the cache is non-load-bearing, so a failed record costs a future round-trip,
// not correctness. Called by the serve loop before each command, so a repeat
// enliven issued right after a settlement sees the cached row.
fn apply_enliven_records(vat: &mut Vat<'_>, records: &EnlivenRecords) {
	let drained: Vec<EnlivenRecord> = records.borrow_mut().drain(..).collect();
	if drained.is_empty() {
		return;
	}
	let peer = vat.peer().expect("a peer-bound vat");
	for rec in drained {
		let _ = peer.record_enlivenment(&rec.swiss, rec.outcome, rec.import_position, rec.kind);
	}
}

async fn drive<S>(
	mut stream: S,
	transport: &str,
	designator: &str,
	mut cmd_rx: mpsc::UnboundedReceiver<Cmd>,
	self_tx: mpsc::UnboundedSender<Cmd>,
	node: Node,
	conn_id: u64,
	peer_raw: *mut sys::PancakePeer,
	exporter_locator: Rc<RefCell<Option<Vec<u8>>>>,
) -> Result<()>
where
	S: AsyncRead + AsyncWrite + Unpin,
{
	// The node owns this connection's peer (ADR-0066): it is already bound to the
	// node's shared gift registry and identity, so an inbound deposit/withdraw
	// resolves against the node-wide table (ADR-0056) with no per-driver bind.
	// Wrap it without taking ownership; the node frees it at `remove_conn` below.
	let mut peer = unsafe { Peer::from_node_raw(peer_raw) };
	let mut inbox: Vec<u8> = Vec::new();
	let mut chunk = [0u8; wire::READ_CHUNK];

	// Establish the OCapN session before serving any command: the driver task
	// runs this first, so a `fetch`/`send` queued by the handle waits in the
	// channel until the keyed handshake has opened the session. Every connection
	// of the node presents the node's one retained identity, so the exporter
	// verifies a `desc:handoff-receive`/`-give` against the one key it saw.
	wire::handshake(
		&mut peer,
		&mut stream,
		transport,
		designator,
		&mut inbox,
		&mut chunk,
		Some(node.seed),
	)
	.await?;

	let mut vat = Vat::over(&mut peer);
	// Originate the gifter half of a three-party handoff when a published actor
	// returns a capability whose home is another connection (ADR-0009): the vat
	// consults this before resolving a delivered answer.
	{
		let node = node.clone();
		let self_tx = self_tx.clone();
		vat.set_resolve_interceptor(move |answer, value| {
			try_originate(&node, &self_tx, conn_id, answer, value)
		});
	}
	// This connection's command channel was registered with the node (and its
	// node-giftables queued) in `over_shared`, before the driver spawned.
	// ticket -> outbound answer position for the far sends still in flight, so a
	// pipelined send can resolve its `&RemotePromise` target to a `desc:answer`.
	// An entry is dropped when its send settles (or on disconnect, when
	// `break_far_vows` fires every far listener), so it never grows unbounded.
	let tickets: Rc<RefCell<HashMap<u64, u64>>> = Rc::new(RefCell::new(HashMap::new()));
	let enliven_records: EnlivenRecords = Rc::new(RefCell::new(Vec::new()));
	let served = serve_loop(
		&mut vat,
		&mut stream,
		&mut cmd_rx,
		&mut inbox,
		&mut chunk,
		&tickets,
		&enliven_records,
		&node,
		conn_id,
		&exporter_locator,
	)
	.await;
	// The wire is gone, cleanly or by a transport fault: break every send still
	// awaiting a reply so it settles as a break with the reason, matching the
	// other bindings, rather than leaving its oneshot to drop into a bare
	// transport error. This runs on every exit path out of the loop.
	vat.break_far_vows("connection closed");
	// Drop the vat and the peer wrapper before removing the connection, so no
	// borrow of the node-owned peer survives the free the node performs in
	// `remove_conn`. The wrapper is non-owning, so its drop is a no-op; the node
	// owns and frees the peer.
	drop(vat);
	drop(peer);
	node.unregister(conn_id);
	node.remove_conn(conn_id);
	served
}

// The driver task's main loop. Only a genuine wire fault (a failed read, write,
// or peer-fatal inbound frame) ends it; a failed command settles its own
// oneshot inside `handle` and the loop keeps serving.
async fn serve_loop<S>(
	vat: &mut Vat<'_>,
	stream: &mut S,
	cmd_rx: &mut mpsc::UnboundedReceiver<Cmd>,
	inbox: &mut Vec<u8>,
	chunk: &mut [u8],
	tickets: &Rc<RefCell<HashMap<u64, u64>>>,
	enliven_records: &EnlivenRecords,
	node: &Node,
	conn_id: u64,
	exporter_locator: &Rc<RefCell<Option<Vec<u8>>>>,
) -> Result<()>
where
	S: AsyncRead + AsyncWrite + Unpin,
{
	// Apply every command the application queued before serving — on the accept
	// path, the bootstrap caps it published — then dispatch any frames the
	// handshake left buffered. A partner may pipeline a bootstrap fetch behind
	// its start-session; the handshake leaves it in `inbox` (it stops at the
	// session-opening frame), so it must be answered here only after the host's
	// publishes are applied, never by a cap that does not exist yet. This is the
	// binding's form of the Zig LoopHost's publish-before-serve ordering.
	while let Ok(cmd) = cmd_rx.try_recv() {
		match cmd {
			Cmd::Close => return Ok(()),
			other => {
				handle(
					vat,
					stream,
					other,
					tickets,
					enliven_records,
					node,
					conn_id,
					exporter_locator,
				)
				.await?
			}
		}
	}
	dispatch_buffered(vat, stream, inbox).await?;

	loop {
		// Fold any enliven that settled on the previous turn into the dedup cache
		// before serving the next command, so a repeat enliven issued the instant
		// a prior one resolved sees the cached row and short-circuits.
		apply_enliven_records(vat, enliven_records);
		tokio::select! {
			biased;
			maybe = cmd_rx.recv() => {
				match maybe {
					None | Some(Cmd::Close) => return Ok(()),
					Some(cmd) => handle(vat, stream, cmd, tickets, enliven_records, node, conn_id, exporter_locator).await?,
				}
			}
			read = stream.read(&mut *chunk) => {
				let n = read.map_err(wire::io_err)?;
				if n == 0 { return Ok(()); }
				inbox.extend_from_slice(&chunk[..n]);
				dispatch_buffered(vat, stream, inbox).await?;
			}
		}
	}
}

// Frame every whole message buffered in `inbox` into the peer, run the surfaced
// events through the vat, and flush any replies. Shared by the serve loop's
// pre-loop drain (the frames the handshake left buffered) and its read branch
// (a fresh chunk just appended), so both dispatch buffered bytes identically.
async fn dispatch_buffered<S>(vat: &mut Vat<'_>, stream: &mut S, inbox: &mut Vec<u8>) -> Result<()>
where
	S: AsyncRead + AsyncWrite + Unpin,
{
	{
		let peer = vat.peer().expect("a peer-bound vat");
		while let Some(consumed) = peer.recv_stream(inbox)? {
			inbox.drain(..consumed);
		}
	}
	// Flush first, then poll, and loop until both are quiet. Applying inbound
	// frames can queue outbound work that surfaces *no* event of its own: a
	// projection resolves its answer, a listener fires a deliver. Flushing only
	// after a served event (the old shape) stranded those frames, hanging a
	// pipelined projection whose partner waits on the resolution. Flushing first
	// pumps to idle, which also drains a settled answer's pipelined calls into
	// fresh events; re-polling after returns them, so a `create -> assign ->
	// status` chain or an `untag(...).index(...)` projection drains in full
	// before this returns and the loop parks on the next read.
	loop {
		flush(vat, stream).await?;
		match vat.peer().expect("a peer-bound vat").poll()? {
			Some(event) => {
				vat.serve(&event).ok();
				// A forwarding actor that sent on to a far target parks the caller's
				// answer until that send settles; drain those resolves now so the
				// next flush sends them (a wire answer) or settles them (a local
				// send awaiting a far-proxy reply) (ADR-0064).
				vat.flush_forward_resolves()?;
				vat.flush_forward_local_resolves();
			}
			None => break,
		}
	}
	Ok(())
}

// Serve one command. An application-level failure (a refused publish, an
// inadmissible send target, a failed export allocation) replies its typed
// error on that command's own oneshot and leaves the driver alive; `?` is
// reserved for transport faults, which end the loop so `drive` can break the
// remaining vows.
async fn handle<S>(
	vat: &mut Vat<'_>,
	stream: &mut S,
	cmd: Cmd,
	tickets: &Rc<RefCell<HashMap<u64, u64>>>,
	enliven_records: &EnlivenRecords,
	node: &Node,
	conn_id: u64,
	exporter_locator: &Rc<RefCell<Option<Vec<u8>>>>,
) -> Result<()>
where
	S: AsyncRead + AsyncWrite + Unpin,
{
	match cmd {
		Cmd::Spawn { behavior, reply } => {
			let allocated = vat.peer().expect("a peer-bound vat").next_export();
			let out =
				allocated.and_then(|position| vat.publish(position, behavior).map(|_| position));
			let _ = reply.send(out);
		}
		Cmd::Publish {
			name,
			behavior,
			reply,
		} => {
			let allocated = vat
				.peer()
				.expect("a peer-bound vat")
				.register_bootstrap_cap(name.as_bytes());
			let out =
				allocated.and_then(|position| vat.publish(position, behavior).map(|_| position));
			let _ = reply.send(out);
		}
		Cmd::Caretaker {
			target,
			live,
			reply,
		} => {
			let vref = vat.resolve_target(&target);
			let allocated = vat.peer().expect("a peer-bound vat").next_export();
			let out = allocated.and_then(|position| {
				vat.publish_caretaker(position, vref, live)
					.map(|_| position)
			});
			let _ = reply.send(out);
		}
		Cmd::Attenuate {
			target,
			verbs,
			reply,
		} => {
			let vref = vat.resolve_target(&target);
			let allocated = vat.peer().expect("a peer-bound vat").next_export();
			let out = allocated.and_then(|position| {
				vat.publish_attenuator(position, vref, verbs)
					.map(|_| position)
			});
			let _ = reply.send(out);
		}
		Cmd::Fetch { name, reply } => {
			// The canonical fetch lives in the library: one call registers the
			// bootstrap import, allocates the answer, and queues the deliver.
			let sent = vat
				.peer()
				.expect("a peer-bound vat")
				.send_bootstrap_fetch(name.as_bytes())
				.map(Vow::Far);
			match sent {
				Ok(vow) => {
					let node = node.clone();
					vat.on(vow, move |resolution| {
						match resolution {
							Resolution::Fulfill(Argument::Reference(reference)) => {
								// Stamp the home: a fetched capability lives on
								// *this* connection. Returned to another connection
								// (a gift to pass on), the recorded home lets the
								// gifter half recognize it as foreign and originate
								// a three-party handoff (ADR-0009).
								node.record_foreign_home(&reference, conn_id);
								let _ = reply.send(Ok(reference));
							}
							// The partner fulfilled with a non-capability: a
							// typed broken failure carrying the fetched name,
							// distinct from a transport fault.
							Resolution::Fulfill(_) => {
								let _ = reply.send(Err(Error::broken(format!(
									"fetch {name:?} did not resolve to a capability"
								))));
							}
							Resolution::Break(message) => {
								let _ = reply.send(Err(Error::broken(message)));
							}
							// A bootstrap fetch that resolves to a three-party
							// handoff give: redeem it transparently off the loop
							// (dial the exporter keyed with this node's
							// identity, withdraw the gift) and hand back the live
							// capability under a reserved token, so `fetch` returns
							// an ordinary `Ref`.
							Resolution::Handoff(give) => {
								redeem_off_loop(node, give, reply, |reference| reference);
							}
						}
					});
					flush(vat, stream).await?;
				}
				Err(e) => {
					let _ = reply.send(Err(e));
				}
			}
		}
		Cmd::Enliven { swissnum, reply } => {
			// The canonical enliven lives in the library: one call consults the
			// dedup cache and, on a miss, registers the bootstrap import, allocates
			// the answer, and queues the deliver — exactly the fetch path, keyed by
			// swissnum instead of a bootstrap name.
			let peer = vat.peer().expect("a peer-bound vat");
			let start = match peer.prepare_enliven(&swissnum) {
				Ok(start) => start,
				Err(e) => {
					let _ = reply.send(Err(e));
					return Ok(());
				}
			};
			if start.status == sys::ENLIVEN_CACHED {
				// Cache hit: reconstruct the far reference, no wire traffic.
				let reference = Reference::Far {
					id: start.import_position,
					promise: start.kind == sys::REF_SUB_PROMISE,
				};
				let _ = reply.send(Ok(reference));
				return Ok(());
			}
			// FRESH or IN_FLIGHT: drive the (possibly shared) answer to settlement.
			// The resolution callback cannot reach the peer, so it defers the cache
			// record onto the shared queue the serve loop drains with peer access.
			let records = enliven_records.clone();
			vat.on(Vow::Far(start.answer), move |resolution| match resolution {
				Resolution::Fulfill(Argument::Reference(reference)) => {
					let (import_position, kind) = match &reference {
						Reference::Far { id, promise } => (
							*id,
							if *promise {
								sys::REF_SUB_PROMISE
							} else {
								sys::REF_SUB_OBJECT
							},
						),
						_ => (0, sys::REF_SUB_OBJECT),
					};
					records.borrow_mut().push(EnlivenRecord {
						swiss: swissnum,
						outcome: sys::ENLIVEN_OUTCOME_FULFILLED,
						import_position,
						kind,
					});
					let _ = reply.send(Ok(reference));
				}
				// Fulfilled with a non-capability: a typed broken failure, and the
				// in-flight marker is cleared so a later enliven can retry.
				Resolution::Fulfill(_) => {
					records.borrow_mut().push(EnlivenRecord {
						swiss: swissnum,
						outcome: sys::ENLIVEN_OUTCOME_BROKEN,
						import_position: 0,
						kind: 0,
					});
					let _ = reply.send(Err(Error::broken(
						"enliven did not resolve to a capability".to_string(),
					)));
				}
				Resolution::Break(message) => {
					records.borrow_mut().push(EnlivenRecord {
						swiss: swissnum,
						outcome: sys::ENLIVEN_OUTCOME_BROKEN,
						import_position: 0,
						kind: 0,
					});
					let _ = reply.send(Err(Error::broken(message)));
				}
				// A handoff give resolving an enliven would mean the partner
				// published a third-party redirect behind the swissnum; treat it
				// as broken here rather than redeeming, since enliven targets a
				// capability hosted by this very peer.
				Resolution::Handoff(_) => {
					records.borrow_mut().push(EnlivenRecord {
						swiss: swissnum,
						outcome: sys::ENLIVEN_OUTCOME_BROKEN,
						import_position: 0,
						kind: 0,
					});
					let _ = reply.send(Err(Error::broken(
						"enliven resolved to a handoff give".to_string(),
					)));
				}
			});
			flush(vat, stream).await?;
		}
		Cmd::Send {
			ticket,
			target,
			verb,
			args,
			reply,
		} => {
			// A redeemed three-party handoff capability lives on a dialed exporter
			// connection, not this one: its reference id is a reserved token the
			// node router minted. Forward the command to that exporter with the
			// real exporter-side reference swapped in, carrying the reply oneshot
			// so the application awaits the exporter's answer transparently.
			if let CmdTarget::Ref(reference) = &target {
				if let Some((exporter, real)) = node.route(conn_id, reference) {
					let _ = exporter.send(Cmd::Send {
						ticket,
						target: CmdTarget::Ref(real),
						verb,
						args,
						reply,
					});
					return Ok(());
				}
			}
			// Resolve the target: a `Ref` routes a self-spawned near export to its
			// local actor (resolving in-process, no wire round-trip) and leaves a
			// partner's ref far; a `Pipeline` names an earlier far send's answer,
			// delivered to that answer's `desc:answer` target so the partner
			// queues it until the answer settles (ADR-0007). A pipeline against a
			// ticket the driver never recorded — an unknown or already-settled
			// answer — is a caller error, refused on its own oneshot.
			let vref = match target {
				CmdTarget::Ref(reference) => vat.resolve_target(&reference),
				CmdTarget::Pipeline(prior) => match tickets.borrow().get(&prior).copied() {
					Some(answer) => VatRef::Far(Reference::Promise { answer }),
					None => {
						let _ = reply.send(Err(Error::from_code(sys::ERR_INVALID_ARGUMENT)));
						return Ok(());
					}
				},
			};
			let is_local = matches!(vref, VatRef::Local(_));
			match vat.send(&vref, &verb, &args) {
				Ok(vow) => {
					// Record this send's answer so a later send can pipeline
					// against it; drop the entry when the send settles (here, or
					// via `break_far_vows` on disconnect) to bound the map.
					if let Vow::Far(answer) = vow {
						tickets.borrow_mut().insert(ticket, answer);
					}
					let tickets = Rc::clone(tickets);
					let node = node.clone();
					vat.on(vow, move |resolution| {
						tickets.borrow_mut().remove(&ticket);
						match resolution {
							Resolution::Fulfill(value) => {
								let _ = reply.send(Ok(value));
							}
							Resolution::Break(message) => {
								let _ = reply.send(Err(Error::broken(message)));
							}
							// The send resolved to a three-party handoff give:
							// redeem it transparently off the loop and settle the
							// send with the live capability (a reserved-token far
							// reference), so the application's `Ref::try_from`
							// yields an ordinary capability it can `send` to.
							Resolution::Handoff(give) => {
								redeem_off_loop(node, give, reply, Argument::Reference);
							}
						}
					});
					if is_local {
						vat.drive();
						// A driven actor may tail-forward to a far target (a caretaker
						// over a wire-imported capability, ADR-0064); its far deliver is
						// queued and the caller's answer parks on that send. Flush so the
						// deliver leaves and the serve loop settles the parked answer.
						flush(vat, stream).await?;
					} else {
						flush(vat, stream).await?;
					}
				}
				Err(e) => {
					let _ = reply.send(Err(e));
				}
			}
		}
		Cmd::Project {
			source_ticket,
			op,
			ticket,
			reply,
		} => {
			// Map the source send's ticket to its still-pending answer; a ticket
			// the driver never recorded (a local send, or one already settled and
			// dropped) cannot be projected — refuse it the way an unknown
			// pipeline target is refused.
			let source_answer = match tickets.borrow().get(&source_ticket).copied() {
				Some(answer) => answer,
				None => {
					let _ = reply.send(Err(Error::from_code(sys::ERR_INVALID_ARGUMENT)));
					return Ok(());
				}
			};
			// Allocate the projected answer and queue the projection against the
			// source answer's `desc:answer`. Confine the peer borrow so `vat.on`
			// can take the vat back to register the result's listener.
			let answer = {
				let peer = vat.peer().expect("a peer-bound vat");
				let answer = match peer.next_answer() {
					Ok(answer) => answer,
					Err(e) => {
						let _ = reply.send(Err(e));
						return Ok(());
					}
				};
				let receiver = Reference::Promise {
					answer: source_answer,
				};
				let issued = match &op {
					ProjectOp::Get(field) => peer.send_get(&receiver, field, answer),
					ProjectOp::Index(i) => peer.send_index(&receiver, *i, answer),
					ProjectOp::Untag(tag) => peer.send_untag(&receiver, tag, answer),
				};
				if let Err(e) = issued {
					let _ = reply.send(Err(e));
					return Ok(());
				}
				answer
			};
			// Record the projected answer so it is itself pipelinable, and settle
			// the handle when it resolves — dropping the ticket on settlement, as
			// a far send does, to bound the map.
			tickets.borrow_mut().insert(ticket, answer);
			let tickets = Rc::clone(tickets);
			vat.on(Vow::Far(answer), move |resolution| {
				tickets.borrow_mut().remove(&ticket);
				match resolution {
					Resolution::Fulfill(value) => {
						let _ = reply.send(Ok(value));
					}
					Resolution::Break(message) => {
						let _ = reply.send(Err(Error::broken(message)));
					}
					Resolution::Handoff(_) => {
						let _ = reply.send(Err(Error::broken(
							"a projection resolved to a three-party handoff give".to_string(),
						)));
					}
				}
			});
			flush(vat, stream).await?;
		}
		Cmd::Tell { target, verb, args } => {
			// As `send`: a redeemed-handoff capability is fire-and-forget told on
			// its exporter connection, with the real exporter-side reference.
			if let Some((exporter, real)) = node.route(conn_id, &target) {
				let _ = exporter.send(Cmd::Tell {
					target: real,
					verb,
					args,
				});
				return Ok(());
			}
			let vref = vat.resolve_target(&target);
			if let VatRef::Local(_) = vref {
				// A self-spawned target: run the turn in-process, no reply.
				let _ = vat.send(&vref, &verb, &args);
				vat.drive();
			} else {
				// A far fire-and-forget deliver: prepend the verb symbol (skipped
				// when empty, matching `Vat::send` and the other bindings — a
				// positional tell must not put a stray empty symbol on the wire),
				// request no answer, and flush. The partner's actor runs but
				// sends no reply. A refused deliver has no reply to land on —
				// that is the fire-and-forget contract — so a typed refusal is
				// dropped here rather than allowed to kill the driver.
				let mut payload = Vec::with_capacity(args.len() + 1);
				if !verb.is_empty() {
					payload.push(Argument::Symbol(verb));
				}
				payload.extend(args);
				if vat
					.peer()
					.expect("a peer-bound vat")
					.send_deliver(&target, &payload, None)
					.is_ok()
				{
					flush(vat, stream).await?;
				}
			}
		}
		Cmd::WithdrawGift { give, reply } => {
			// Issued on the exporter connection by the node router: allocate the
			// answer, then ask the node to sign and deliver the `withdraw-gift`
			// (one definition shared with the native driver, keyed by the node's
			// retained identity), and settle the reply with the withdrawn
			// capability's reference when the answer resolves. A failed allocation
			// or deliver replies its typed error.
			let answer = match vat.peer().expect("a peer-bound vat").next_answer() {
				Ok(answer) => answer,
				Err(e) => {
					let _ = reply.send(Err(e));
					return Ok(());
				}
			};
			if let Err(e) = node.send_withdraw(conn_id, &give, answer) {
				let _ = reply.send(Err(e));
				return Ok(());
			}
			vat.on(Vow::Far(answer), move |resolution| {
				let out = match resolution {
					Resolution::Fulfill(Argument::Reference(reference)) => Ok(reference),
					Resolution::Fulfill(_) => Err(Error::broken(
						"withdraw-gift did not resolve to a capability".to_string(),
					)),
					Resolution::Break(message) => Err(Error::broken(message)),
					Resolution::Handoff(_) => Err(Error::broken(
						"withdraw-gift resolved to a nested handoff give".to_string(),
					)),
				};
				let _ = reply.send(out);
			});
			flush(vat, stream).await?;
		}
		Cmd::OriginateGive {
			recipient_conn,
			recipient_tx,
			answer,
			gifted,
		} => {
			// Gifter origination on the exporter connection (ADR-0009): the node
			// deposits `gifted` here, signs the give addressed to the recipient's
			// partner, and queues it as the recipient's resolution. This loop owns
			// the exporter peer and the dial-hint override; the recipient loop owns
			// its own stream, so flush the deposit here and signal the recipient to
			// flush the resolve. The deposit lands first, before the recipient
			// dials in to withdraw.
			let mut gift_id = [0u8; 32];
			if getrandom::getrandom(&mut gift_id).is_err() {
				let _ = recipient_tx.send(Cmd::ResolveBreak {
					answer,
					message: "handoff origination failed: gift-id entropy unavailable".to_string(),
				});
				return Ok(());
			}
			// Sign the give with the override location when the gifter recorded the
			// exporter's dialable URI out of band (an iroh exporter reachable only
			// by a Direct dial hint); empty uses the exporter's own session record.
			let location = exporter_locator.borrow().clone().unwrap_or_default();
			if let Err(e) = node.originate_give(
				recipient_conn,
				conn_id,
				&gifted,
				&gift_id,
				answer,
				&location,
			) {
				let _ = recipient_tx.send(Cmd::ResolveBreak {
					answer,
					message: format!("handoff origination failed: {e}"),
				});
				return Ok(());
			}
			flush(vat, stream).await?;
			let _ = recipient_tx.send(Cmd::FlushOutbound);
		}
		Cmd::FlushOutbound => {
			// Put the give the node queued onto the wire from the recipient's own
			// loop (the loop that owns this stream).
			flush(vat, stream).await?;
		}
		Cmd::ResolveBreak { answer, message } => {
			// Origination failed: break the recipient's question so its send
			// settles with the reason rather than hanging. Best-effort.
			let queued = {
				let peer = vat.peer().expect("a peer-bound vat");
				peer.send_resolve(answer, &Resolution::Break(message))
					.is_ok()
			};
			if queued {
				flush(vat, stream).await?;
			}
		}
		Cmd::GcDrop { position } => {
			// A wire-lifted import's last handle dropped (ADR-0063): release one
			// wire-count unit. Best-effort — a release that cannot be queued (e.g.
			// the session already closed) costs a stranded export row on the
			// partner, reclaimed at teardown, never a fault here.
			if vat
				.peer()
				.expect("a peer-bound vat")
				.send_gc_export(&[position], &[1])
				.is_ok()
			{
				flush(vat, stream).await?;
			}
		}
		Cmd::Close => {}
	}
	Ok(())
}

// Redeem a handoff give off the driver loop: dial the exporter (keyed with the
// node's retained identity) and withdraw the gift on a spawned task, so the
// dial's I/O does not stall this connection's reads, then settle the awaiting
// command's reply with the live capability under a reserved token. `into` adapts
// the redeemed reference to the command's reply type (a bare `Reference` for
// `fetch`, an `Argument::Reference` for `send`). A redeem failure breaks the
// command rather than leaving it pending.
fn redeem_off_loop<T: 'static>(
	node: Node,
	give: HandoffGive,
	reply: Reply<T>,
	into: impl FnOnce(Reference) -> T + 'static,
) {
	tokio::task::spawn_local(async move {
		match node.redeem(give).await {
			Ok((exporter_conn, reference)) => {
				let token = node.enroll(exporter_conn, reference);
				let _ = reply.send(Ok(into(token)));
			}
			Err(e) => {
				let _ = reply.send(Err(e));
			}
		}
	});
}

async fn flush<S>(vat: &mut Vat<'_>, stream: &mut S) -> Result<()>
where
	S: AsyncRead + AsyncWrite + Unpin,
{
	wire::pump_outbound(vat.peer().expect("a peer-bound vat"), stream).await
}

// The vat's resolve interceptor (ADR-0009, the gifter half): claim a delivered
// answer whose reply is a capability living on another connection of this node,
// and originate a three-party handoff for it instead of letting the vat encode a
// cross-connection reference. Returns whether the answer was claimed; an
// ordinary reply (or one whose home is this very connection) falls through.
fn try_originate(
	node: &Node,
	self_tx: &mpsc::UnboundedSender<Cmd>,
	conn_id: u64,
	answer: u64,
	value: &Argument,
) -> bool {
	let reference = match value {
		Argument::Reference(reference) => reference,
		_ => return false,
	};
	let id = match reference {
		Reference::Far { id, .. } => *id,
		_ => return false,
	};
	let exporter_conn = match node.foreign_home_conn(id) {
		Some(exporter_conn) => exporter_conn,
		None => return false,
	};
	// A capability whose home is this very connection is not a gift to pass on.
	if exporter_conn == conn_id {
		return false;
	}
	let exporter_tx = match node.channel_for(exporter_conn) {
		Some(exporter_tx) => exporter_tx,
		None => return false,
	};
	// Origination runs on the exporter loop (it owns the exporter peer and the
	// dial-hint locator override): the node deposits, signs the give, and queues
	// it on our peer, then the exporter loop signals us to flush the resolution.
	let _ = exporter_tx.send(Cmd::OriginateGive {
		recipient_conn: conn_id,
		recipient_tx: self_tx.clone(),
		answer,
		gifted: reference.clone(),
	});
	true
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::{AsyncConnection, Event};
	use tokio::task::LocalSet;

	// A fresh node redeems a hint-less iroh give under `Discovery` by default —
	// the behavior-preserving, maximal-reach choice every existing handoff gate
	// relies on — and the recipient can lower it to a no-relay policy. The setter
	// is shared across node clones, so a knob set on one handle reaches the
	// connections that share the node's identity.
	#[test]
	fn redeem_reachability_defaults_to_discovery_and_is_settable() {
		let node = Node::new_node();
		assert_eq!(node.redeem_reachability(), Reachability::Discovery);
		node.set_redeem_reachability(Reachability::DiscoveryNoRelay);
		assert_eq!(node.redeem_reachability(), Reachability::DiscoveryNoRelay);
		assert_eq!(
			node.clone().redeem_reachability(),
			Reachability::DiscoveryNoRelay
		);
	}

	// `listen` hosts the same surface `connect` dials: a server accepts a
	// pancake dialer, publishes a capability on the accepted connection, and the
	// dialer fetches and calls it, both ends riding the high-level Connection,
	// no peer or vat stitched by hand on either side.
	#[tokio::test]
	async fn listen_accepts_a_pancake_dialer_end_to_end() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let server = listen("127.0.0.1:0").await.unwrap();
				let addr = server.local_addr().unwrap();

				// The client must not fetch before the service is published, so
				// the host signals readiness over a oneshot.
				let (ready_tx, ready_rx) = oneshot::channel::<()>();
				let host = tokio::task::spawn_local(async move {
					let conn = server.accept().await.unwrap();
					conn.publish("svc", |verb, args| {
						if verb != "greet" {
							return Err(format!("no such method: {verb}"));
						}
						let who = match args.first() {
							Some(Argument::String(s)) => s.as_str(),
							_ => "?",
						};
						Ok(Argument::String(format!("hello {who}")))
					})
					.await
					.unwrap();
					ready_tx.send(()).unwrap();
					conn.serve().await;
				});

				let conn = Connection::connect(addr).await.unwrap();
				ready_rx.await.unwrap();
				let cap = conn.fetch("svc").await.unwrap();
				let reply = conn
					.send(&cap, "greet", &[Argument::String("pancake".into())])
					.await
					.unwrap();
				assert_eq!(reply, Argument::String("hello pancake".into()));
				conn.close();
				host.await.unwrap();
			})
			.await;
	}

	// Sturdyref enliven (ADR-0012): the client brings a durable `(peer, swissnum)`
	// to life as a live `Ref` through the dedup cache, calls it, then enlivens the
	// same swissnum again and gets the cached capability with no new wire fetch.
	// The swissnum keys the bootstrap fetch, so a host publish under that name
	// answers it.
	#[tokio::test]
	async fn enliven_round_trips_then_caches() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let server = listen("127.0.0.1:0").await.unwrap();
				let addr = server.local_addr().unwrap();

				let (ready_tx, ready_rx) = oneshot::channel::<()>();
				let host = tokio::task::spawn_local(async move {
					let conn = server.accept().await.unwrap();
					conn.publish("greeter", |verb, _args| {
						if verb != "hello" {
							return Err(format!("no such method: {verb}"));
						}
						Ok(Argument::Symbol("alive".into()))
					})
					.await
					.unwrap();
					ready_tx.send(()).unwrap();
					conn.serve().await;
				});

				let conn = Connection::connect(addr).await.unwrap();
				ready_rx.await.unwrap();

				// The connection is already open; enliven keys on the sturdyref's
				// swissnum, carried by the URI as `/s/greeter`.
				let sturdyref = "ocapn://greeter-host.tcp/s/greeter";
				let cap = conn.enliven(sturdyref).await.unwrap();
				let reply = conn.send(&cap, "hello", &[]).await.unwrap();
				assert_eq!(reply, Argument::Symbol("alive".into()));

				// A repeat enliven hits the dedup cache: the same live capability.
				let again = conn.enliven(sturdyref).await.unwrap();
				assert_eq!(again.reference(), cap.reference());
				let reply2 = conn.send(&again, "hello", &[]).await.unwrap();
				assert_eq!(reply2, Argument::Symbol("alive".into()));

				conn.close();
				host.await.unwrap();
			})
			.await;
	}

	// A broken `send` carries the partner's reason, not just a code: the partner
	// publishes a cap, the client fetches and calls it, and the partner breaks
	// the call with a reason the client must read back off the error.
	#[tokio::test]
	async fn send_surfaces_the_partner_break_reason() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
				let addr = listener.local_addr().unwrap();

				// Server: a default negotiating peer that publishes a bootstrap
				// cap. The engine auto-answers the `fetch`; the server breaks
				// the `do` call that follows, with a reason the client must read
				// back.
				let server = tokio::task::spawn_local(async move {
					let (stream, _) = listener.accept().await.unwrap();
					let mut peer = Peer::new().unwrap();
					peer.register_bootstrap_cap(b"svc").unwrap();
					// Responder half of the keyed handshake (a fixed seed is fine
					// in a test): the client's `Connection::connect` handshakes,
					// so the server must too or it would refuse the start-session.
					peer.start_session(&[7u8; 32], "tcp", "127.0.0.1:2", true)
						.unwrap();
					let mut conn = AsyncConnection::from_stream(peer, stream);
					while !conn.peer().session_is_open() {
						if conn.next_event().await.unwrap().is_none() {
							panic!("server connection closed during the handshake");
						}
					}
					while let Some(event) = conn.next_event().await.unwrap() {
						if let Event::Deliver {
							args,
							answer: Some(answer),
							..
						} = &event
						{
							let verb = match args.first() {
								Some(Argument::Symbol(s)) => s.as_str(),
								_ => "",
							};
							if verb == "do" {
								conn.send_resolve(
									*answer,
									&Resolution::Break("nope: revoked".into()),
								)
								.await
								.unwrap();
								break;
							}
						}
					}
				});

				let conn = Connection::connect(addr).await.unwrap();
				let _serve = conn.serve();
				let cap = conn.fetch("svc").await.unwrap();
				let err = conn.send(&cap, "do", &[]).await.unwrap_err();
				assert_eq!(err.message().as_deref(), Some("nope: revoked"));
				// A break is PANCAKE_ERR_BROKEN, not a transport or value error.
				assert_eq!(err.code(), crate::sys::ERR_BROKEN);
				conn.close();
				server.await.unwrap();
			})
			.await;
	}

	// Distributed GC (ADR-0063), opt-in: a client that enables GC and fetches a
	// capability releases its import — a single `op:gc-exports` — when the last
	// `Ref` to it drops, so the partner can release the matching export. The raw
	// host observes that release frame as an `Event::Other`.
	#[tokio::test]
	async fn dropping_a_fetched_cap_releases_its_import_when_gc_is_on() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
				let addr = listener.local_addr().unwrap();

				let (seen_tx, seen_rx) = oneshot::channel::<bool>();
				let server = tokio::task::spawn_local(async move {
					let (stream, _) = listener.accept().await.unwrap();
					let mut peer = Peer::new().unwrap();
					peer.register_bootstrap_cap(b"svc").unwrap();
					peer.start_session(&[7u8; 32], "tcp", "127.0.0.1:2", true)
						.unwrap();
					let mut conn = AsyncConnection::from_stream(peer, stream);
					while !conn.peer().session_is_open() {
						if conn.next_event().await.unwrap().is_none() {
							panic!("server closed during the handshake");
						}
					}
					// The engine auto-answers the bootstrap fetch; we wait for the
					// gc-export the client emits once it drops the fetched cap.
					let mut seen = false;
					while let Some(event) = conn.next_event().await.unwrap() {
						if let Event::Other { frame, .. } = &event {
							if std::str::from_utf8(frame)
								.map(|s| s.contains("op:gc-export"))
								.unwrap_or(false)
							{
								seen = true;
								break;
							}
						}
					}
					let _ = seen_tx.send(seen);
				});

				let conn = Connection::connect(addr).await.unwrap().with_gc();
				let cap = conn.fetch("svc").await.unwrap();
				// Dropping the only handle fires the import guard, which queues the
				// release the driver flushes to the wire.
				drop(cap);
				let seen = seen_rx.await.unwrap();
				assert!(
					seen,
					"host never received the op:gc-exports for the dropped import"
				);
				conn.close();
				server.await.unwrap();
			})
			.await;
	}

	// A failed command settles its own oneshot with the typed refusal and
	// leaves the driver task alive: a send to a never-granted far import is
	// refused with its session code (not laundered into IO -9, not a dead
	// channel), and the same connection then fetches and calls the published
	// capability, proving the driver survived to serve the next command.
	#[tokio::test]
	async fn a_failed_command_replies_typed_and_the_connection_survives() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let server = listen("127.0.0.1:0").await.unwrap();
				let addr = server.local_addr().unwrap();
				let (ready_tx, ready_rx) = oneshot::channel::<()>();
				let host = tokio::task::spawn_local(async move {
					let conn = server.accept().await.unwrap();
					conn.publish("svc", |verb, _args| {
						if verb != "ping" {
							return Err(format!("no such method: {verb}"));
						}
						Ok(Argument::String("pong".into()))
					})
					.await
					.unwrap();
					ready_tx.send(()).unwrap();
					conn.serve().await;
				});

				let conn = Connection::connect(addr).await.unwrap();
				ready_rx.await.unwrap();

				// An inadmissible target: import 999 was never granted by the
				// partner, so the session refuses the deliver locally.
				let bogus = Ref::try_from(&Argument::Reference(Reference::far(999))).unwrap();
				let err = conn.send(&bogus, "ping", &[]).await.unwrap_err();
				assert_eq!(err.code(), crate::sys::ERR_SESSION);

				// The driver survived the refusal: the next commands still work.
				let cap = conn.fetch("svc").await.unwrap();
				let reply = conn.send(&cap, "ping", &[]).await.unwrap();
				assert_eq!(reply, Argument::String("pong".into()));
				conn.close();
				host.await.unwrap();
			})
			.await;
	}

	// A `send` to a `Ref` this same connection spawned resolves in-process, not
	// over the wire: the server hosts no such export, so a wire route would never
	// reply. The client never starts a serve loop, the local turn drives and the
	// reply comes straight back.
	#[tokio::test]
	async fn send_to_a_self_spawned_actor_resolves_in_process() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let server = listen("127.0.0.1:0").await.unwrap();
				let addr = server.local_addr().unwrap();
				let host = tokio::task::spawn_local(async move {
					let conn = server.accept().await.unwrap();
					conn.serve().await; // ends when the client closes
				});

				let conn = Connection::connect(addr).await.unwrap();
				let me = conn
					.spawn(|verb, args| {
						if verb != "greet" {
							return Err(format!("no such method: {verb}"));
						}
						let who = match args.first() {
							Some(Argument::String(s)) => s.as_str(),
							_ => "?",
						};
						Ok(Argument::String(format!("hi {who}")))
					})
					.await
					.unwrap();
				let reply = conn
					.send(&me, "greet", &[Argument::String("self".into())])
					.await
					.unwrap();
				assert_eq!(reply, Argument::String("hi self".into()));
				conn.close();
				host.await.unwrap();
			})
			.await;
	}

	// Promise pipelining (ADR-0007), the questioner's half: `send` returns a
	// `RemotePromise` that is itself a `send` target, so a create -> assign ->
	// complete -> status chain is issued against the *unresolved* create answer,
	// none of the four waits for create's reply. The board returns a freshly
	// spawned task; the partner's engine queues the pipelined calls on the create
	// answer and drains them onto the task once create resolves. A status of
	// `done` proves the chain crossed the wire without round-tripping per link.
	#[tokio::test]
	async fn promise_pipelining_drives_a_dependent_chain() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let server = listen("127.0.0.1:0").await.unwrap();
				let addr = server.local_addr().unwrap();
				let (ready_tx, ready_rx) = oneshot::channel::<()>();
				let host = tokio::task::spawn_local(async move {
					let conn = server.accept().await.unwrap();
					// The task the board hands out: `complete` flips done and
					// `status` reports it. Pre-spawned because a behavior runs
					// synchronously on the driver and cannot itself await a spawn.
					let done = Cell::new(false);
					let task = conn
						.spawn(move |verb: &str, _args: &[Argument]| match verb {
							"assign" => Ok(Argument::String("assigned".into())),
							"complete" => {
								done.set(true);
								Ok(Argument::String("done".into()))
							}
							"status" => Ok(Argument::String(
								if done.get() { "done" } else { "open" }.into(),
							)),
							other => Err(format!("no such method: {other}")),
						})
						.await
						.unwrap();
					conn.publish("root", move |verb, _args| {
						if verb != "create" {
							return Err(format!("no such method: {verb}"));
						}
						Ok((&task).into())
					})
					.await
					.unwrap();
					ready_tx.send(()).unwrap();
					conn.serve().await;
				});

				let conn = Connection::connect(addr).await.unwrap();
				ready_rx.await.unwrap();
				let root = conn.fetch("root").await.unwrap();
				// The four verbs leave together: none awaits create's reply, and
				// assign / complete / status target the create answer directly.
				let task = conn.send(&root, "create", &[Argument::String("benchmark".into())]);
				conn.send(&task, "assign", &[Argument::String("alice".into())]);
				conn.send(&task, "complete", &[]);
				let status = conn.send(&task, "status", &[]).await.unwrap();
				assert_eq!(status, Argument::String("done".into()));
				conn.close();
				host.await.unwrap();
			})
			.await;
	}

	// Pipelined projections (ADR-0050/ADR-0052): `RemotePromise::untag` / `index`
	// reach into the value an answer will resolve to *before* it resolves, each
	// returning a new pipelinable promise. The board's `make` returns a Tagged
	// "task" wrapping one row `["assigned", label, 7]`; untag unwraps to that
	// row, index 1 takes the label, a two-hop chain riding the unresolved make
	// answer, no extra round trip. The source handle is awaited afterward to
	// prove a far reply observed *late* (after a sibling projection already
	// pumped the loop) still settles.
	#[tokio::test]
	async fn pipelined_projections_reach_a_field() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let server = listen("127.0.0.1:0").await.unwrap();
				let addr = server.local_addr().unwrap();
				let (ready_tx, ready_rx) = oneshot::channel::<()>();
				let host = tokio::task::spawn_local(async move {
					let conn = server.accept().await.unwrap();
					conn.publish("root", |verb, args| {
						if verb != "make" {
							return Err(format!("no such method: {verb}"));
						}
						let label = match args.first() {
							Some(Argument::String(s)) => s.clone(),
							_ => "anon".to_string(),
						};
						// A Tagged wrapping a single row: untag unwraps to it.
						Ok(Argument::Tagged {
							tag: "task".into(),
							value: vec![Argument::List(vec![
								Argument::String("assigned".into()),
								Argument::String(label),
								Argument::Integer(7),
							])],
						})
					})
					.await
					.unwrap();
					ready_tx.send(()).unwrap();
					conn.serve().await;
				});

				let conn = Connection::connect(addr).await.unwrap();
				ready_rx.await.unwrap();
				let root = conn.fetch("root").await.unwrap();
				// Neither projection awaits a prior reply: they ride the
				// unresolved make answer and the whole chain leaves on one flush.
				let made = conn.send(&root, "make", &[Argument::String("alice".into())]);
				let label = made.untag("task").index(1).await.unwrap();
				assert_eq!(label, Argument::String("alice".into()));
				// The source answer settled while the projection pumped the loop;
				// awaiting it now must still resolve.
				let full = made.await.unwrap();
				assert!(matches!(full, Argument::Tagged { ref tag, .. } if tag == "task"));
				conn.close();
				host.await.unwrap();
			})
			.await;
	}

	// Object-capability forwarding proxies over the wire (ADR-0064). The host fetches the
	// client's published tool — a *far* reference on the host side — wraps it in a
	// caretaker, and hands the proxy back to the client. A call through the proxy
	// forwards across the host to the client's tool (the far deferred-answer path)
	// and resolves the caller's answer; an attenuator passes only its allow-listed
	// verb; and a revoke breaks every later call. The forward target being far is
	// the point: it exercises the binding's deferred forward-resolve path.
	#[tokio::test]
	async fn forwarding_proxies_forward_revoke_and_attenuate_over_the_wire() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let server = listen("127.0.0.1:0").await.unwrap();
				let addr = server.local_addr().unwrap();
				let (tool_ready_tx, tool_ready_rx) = oneshot::channel::<()>();
				let (proxy_ready_tx, proxy_ready_rx) = oneshot::channel::<()>();

				let host = tokio::task::spawn_local(async move {
					let conn = server.accept().await.unwrap();
					// Wait for the client to publish its tool, then fetch it: a far
					// reference this host wraps.
					tool_ready_rx.await.unwrap();
					let tool = conn.fetch("tool").await.unwrap();

					let care = conn.caretaker(&tool).await.unwrap();
					let proxy = care.proxy.clone();
					let readonly = conn.attenuate(&tool, &["get"]).await.unwrap();

					conn.publish("root", move |verb, _args| match verb {
						"proxy" => Ok((&proxy).into()),
						"readonly" => Ok((&readonly).into()),
						"revoke" => {
							care.revoke();
							Ok(Argument::Void)
						}
						other => Err(format!("no such method: {other}")),
					})
					.await
					.unwrap();
					proxy_ready_tx.send(()).unwrap();
					conn.serve().await;
				});

				let conn = Connection::connect(addr).await.unwrap();
				// The tool the host will wrap: `add` increments, `get` reads.
				conn.publish("tool", |verb, args| match verb {
					"add" => {
						let n = args.first().and_then(|a| a.as_i64()).unwrap_or(0);
						Ok(Argument::Integer(n + 1))
					}
					"get" => Ok(Argument::Integer(7)),
					other => Err(format!("no such method: {other}")),
				})
				.await
				.unwrap();
				tool_ready_tx.send(()).unwrap();
				proxy_ready_rx.await.unwrap();

				let root = conn.fetch("root").await.unwrap();

				// Live caretaker: a call forwards across the host to the far tool.
				let proxy = Ref::try_from(&conn.send(&root, "proxy", &[]).await.unwrap()).unwrap();
				let reply = conn
					.send(&proxy, "add", &[Argument::Integer(41)])
					.await
					.unwrap();
				assert_eq!(reply, Argument::Integer(42));

				// Attenuator: the allow-listed verb forwards; any other breaks.
				let readonly =
					Ref::try_from(&conn.send(&root, "readonly", &[]).await.unwrap()).unwrap();
				let got = conn.send(&readonly, "get", &[]).await.unwrap();
				assert_eq!(got, Argument::Integer(7));
				let denied = conn
					.send(&readonly, "add", &[Argument::Integer(1)])
					.await
					.unwrap_err();
				assert!(denied.to_string().contains("Attenuated"), "{denied}");

				// Revoke: every later call through the proxy breaks.
				conn.send(&root, "revoke", &[]).await.unwrap();
				let severed = conn
					.send(&proxy, "add", &[Argument::Integer(1)])
					.await
					.unwrap_err();
				assert!(severed.to_string().contains("Revoked"), "{severed}");

				conn.close();
				host.await.unwrap();
			})
			.await;
	}

	// The wart ADR-0064 closes: a caretaker/attenuator proxy is an ordinary
	// spawned actor, so its own host calls it locally exactly as a partner calls
	// it over the wire. A caretaker over a *local* tool answers a local send; a
	// caretaker over a *far* tool forwards across the wire and the local send still
	// settles; and a revoke breaks the local call too.
	#[tokio::test]
	async fn a_forwarding_proxy_answers_its_hosts_own_local_call() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let server = listen("127.0.0.1:0").await.unwrap();
				let addr = server.local_addr().unwrap();
				let host = tokio::task::spawn_local(async move {
					let conn = server.accept().await.unwrap();
					conn.publish("tool", |verb, _args| match verb {
						"ping" => Ok(Argument::Integer(99)),
						other => Err(format!("no such method: {other}")),
					})
					.await
					.unwrap();
					conn.serve().await;
				});

				let conn = Connection::connect(addr).await.unwrap();

				// A caretaker over a local tool, called locally by its own host.
				let local_tool = conn
					.spawn(|verb, args| match verb {
						"double" => {
							let n = args.first().and_then(|a| a.as_i64()).unwrap_or(0);
							Ok(Argument::Integer(n * 2))
						}
						other => Err(format!("no such method: {other}")),
					})
					.await
					.unwrap();
				let care_local = conn.caretaker(&local_tool).await.unwrap();
				let doubled = conn
					.send(&care_local.proxy, "double", &[Argument::Integer(21)])
					.await
					.unwrap();
				assert_eq!(doubled, Argument::Integer(42));

				// A caretaker over a far tool, called locally: the proxy forwards
				// across the wire and the local send still settles on the reply.
				let far = conn.fetch("tool").await.unwrap();
				let care_far = conn.caretaker(&far).await.unwrap();
				let pong = conn.send(&care_far.proxy, "ping", &[]).await.unwrap();
				assert_eq!(pong, Argument::Integer(99));

				// Revoke severs the local call exactly as it severs a partner's.
				care_local.revoke();
				let severed = conn
					.send(&care_local.proxy, "double", &[Argument::Integer(1)])
					.await
					.unwrap_err();
				assert!(severed.to_string().contains("Revoked"), "{severed}");

				conn.close();
				host.await.unwrap();
			})
			.await;
	}
}
