//! Goblins-shaped actors over the pancake peer, in native Rust.
//!
//! The actor model is a language-native layer on the typed peer surface, not a
//! wrapped C vat — a Rust actor is a Rust closure, the way an async connection is
//! tokio, not a foreign callback. A [`Vat`] holds local actors (each a closure
//! over a method verb and its arguments) and, when bound to a peer, routes sends
//! to *remote* objects over the wire. A leading symbol argument is the method
//! verb (matching Goblins's `($ obj 'method arg …)`); the rest are the call's
//! arguments.
//!
//! The unified [`Ref`] (local or far) and [`Promise`] (local or wire-answer) are
//! the seam: an application sends to a ref without caring where it lives, and the
//! vat routes. Two verbs mirror Goblins:
//!
//!   * [`Vat::call`] — the synchronous near-call (`$`): run a local actor's
//!     behavior now and return its value. Legal only for a local ref, exactly as
//!     Goblins forbids `$` to a far ref.
//!   * [`Vat::send`] — the eventual send (`<-`): location-transparent. To a local
//!     ref it queues a turn; to a far ref it sends an `op:deliver` over the bound
//!     peer. Either way it returns a [`Promise`] you observe with [`Vat::on`].

use crate::{Argument, Event, Peer, Reference, Resolution, Result};
use std::collections::HashMap;

/// An actor behavior: handle a `(verb, args)` call, returning a reply or an error
/// message (which becomes a broken resolution).
pub type Behavior = Box<dyn FnMut(&str, &[Argument]) -> std::result::Result<Argument, String>>;

/// A one-shot promise listener, fired with how the promise settled.
pub type Listener = Box<dyn FnOnce(Resolution)>;

/// A reference the vat can eventual-send to, wherever the object lives.
#[derive(Debug, Clone, PartialEq)]
pub enum Ref {
    /// An actor in this vat — `call`/`send` run its turns here.
    Local(u64),
    /// A partner-hosted object the bound peer holds — `send` routes to it as an
    /// `op:deliver`; `call` (near) is illegal.
    Far(Reference),
}

/// A handle to the eventual result of a [`Vat::send`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Promise {
    /// Result of a local send; settled by [`Vat::drive`].
    Local(u64),
    /// Result of a far send; the outbound answer position the partner resolves.
    Far(u64),
}

/// A queued local eventual-send awaiting [`Vat::drive`].
struct Queued {
    target: u64,
    verb: String,
    args: Vec<Argument>,
    promise: u64,
}

/// A turn loop over local actors that, when bound to a peer, also routes far
/// sends over the wire and hosts published actors for inbound delivers.
///
/// A `Vat<'a>` borrows the peer it rides on (`&'a mut Peer`) so the borrow
/// checker keeps their lifetimes honest; drive the peer (feed/step/take_outbound)
/// through [`peer`](Vat::peer). The vat owns no I/O and no scheduler — it only
/// enqueues onto the peer's outbound queue and dispatches its events.
pub struct Vat<'a> {
    peer: Option<&'a mut Peer>,
    actors: HashMap<u64, Behavior>,
    queue: Vec<Queued>,
    listeners: HashMap<u64, Listener>,
    /// Outbound answer position → listener for a far send's promise.
    far_listeners: HashMap<u64, Listener>,
    /// Export position → local actor id, for actors published on the peer.
    exports: HashMap<u64, u64>,
    next_actor: u64,
    next_promise: u64,
    /// The next outbound answer position for a far send. Started high to stay
    /// clear of a partner's answer positions (there is no `allocate_answer` in
    /// the C ABI, so the vat tracks its own counter, like the Racket binding).
    next_answer: u64,
}

impl Default for Vat<'_> {
    fn default() -> Self {
        Vat::new()
    }
}

impl<'a> Vat<'a> {
    /// A pure-local vat (no wire). `call`/`send`/`drive` over local actors only.
    pub fn new() -> Vat<'a> {
        Vat {
            peer: None,
            actors: HashMap::new(),
            queue: Vec::new(),
            listeners: HashMap::new(),
            far_listeners: HashMap::new(),
            exports: HashMap::new(),
            next_actor: 1,
            next_promise: 1,
            next_answer: 1000,
        }
    }

    /// A vat bound to `peer`: far sends route to it, and [`publish`](Vat::publish)
    /// exports actors so inbound deliveries (via [`serve`](Vat::serve)) run them.
    pub fn over(peer: &'a mut Peer) -> Vat<'a> {
        let mut vat = Vat::new();
        vat.peer = Some(peer);
        vat
    }

    /// The peer this vat rides on — to feed/step/take_outbound around `serve`.
    /// Returns `None` for a pure-local vat.
    pub fn peer(&mut self) -> Option<&mut Peer> {
        self.peer.as_deref_mut()
    }

    /// Spawn a local actor, returning a local [`Ref`].
    pub fn spawn(
        &mut self,
        behavior: impl FnMut(&str, &[Argument]) -> std::result::Result<Argument, String> + 'static,
    ) -> Ref {
        let id = self.next_actor;
        self.next_actor += 1;
        self.actors.insert(id, Box::new(behavior));
        Ref::Local(id)
    }

    /// The synchronous near-call (`$`): run `target`'s behavior now and return its
    /// value. Legal only for a local ref — a far ref must be reached with `send`.
    pub fn call(&mut self, target: &Ref, verb: &str, args: &[Argument]) -> std::result::Result<Argument, String> {
        match target {
            Ref::Local(id) => self.call_local(*id, verb, args),
            Ref::Far(_) => Err("cannot near-call a far ref; use send".to_string()),
        }
    }

    fn call_local(&mut self, id: u64, verb: &str, args: &[Argument]) -> std::result::Result<Argument, String> {
        let behavior = self.actors.get_mut(&id).ok_or_else(|| "no such actor".to_string())?;
        behavior(verb, args)
    }

    /// The eventual send (`<-`): location-transparent. A local target queues a
    /// turn for [`drive`](Vat::drive); a far target sends an `op:deliver` over the
    /// bound peer (a leading symbol carries the verb, matching Goblins's
    /// `($ obj 'method …)`). Returns a [`Promise`] for the result.
    pub fn send(&mut self, target: &Ref, verb: &str, args: &[Argument]) -> Result<Promise> {
        match target {
            Ref::Local(id) => {
                let promise = self.next_promise;
                self.next_promise += 1;
                self.queue.push(Queued {
                    target: *id,
                    verb: verb.to_string(),
                    args: args.to_vec(),
                    promise,
                });
                Ok(Promise::Local(promise))
            }
            Ref::Far(reference) => {
                let answer = self.next_answer;
                self.next_answer += 1;
                let mut full = Vec::with_capacity(args.len() + 1);
                // A non-empty verb leads as an OCapN symbol (Goblins's
                // `($ obj 'method …)`); an empty verb is a positional call with no
                // method symbol (Goblins's `(<- obj arg …)`) — matching the Deno,
                // Python, and Racket vats.
                if !verb.is_empty() {
                    full.push(Argument::Symbol(verb.to_string()));
                }
                full.extend_from_slice(args);
                let peer = self.peer.as_deref_mut().expect("a far send needs a bound peer");
                peer.send_deliver(reference, &full, Some(answer))?;
                Ok(Promise::Far(answer))
            }
        }
    }

    /// Register a one-shot listener for `promise`. A local promise fires during
    /// [`drive`](Vat::drive); a far promise fires when the partner's resolution
    /// arrives and is dispatched by [`serve`](Vat::serve).
    pub fn on(&mut self, promise: Promise, listener: impl FnOnce(Resolution) + 'static) {
        match promise {
            Promise::Local(id) => {
                self.listeners.insert(id, Box::new(listener));
            }
            Promise::Far(answer) => {
                self.far_listeners.insert(answer, Box::new(listener));
            }
        }
    }

    /// Publish an actor at `export_id` so a partner's deliveries to it run the
    /// behavior. Registers the export on the bound peer and binds it. Requires a
    /// bound peer.
    pub fn publish(
        &mut self,
        export_id: u64,
        behavior: impl FnMut(&str, &[Argument]) -> std::result::Result<Argument, String> + 'static,
    ) -> Result<Ref> {
        let actor = self.spawn(behavior);
        let Ref::Local(local_id) = actor else { unreachable!("spawn returns a local ref") };
        let peer = self.peer.as_deref_mut().expect("publish needs a bound peer");
        peer.register_export(export_id)?;
        self.exports.insert(export_id, local_id);
        Ok(actor)
    }

    /// Run queued local eventual-sends to quiescence, settling each promise with
    /// the behavior's value (or a break on error) and firing its listener. Turns
    /// queued by a turn run in the same drive (FIFO).
    pub fn drive(&mut self) {
        let mut index = 0;
        while index < self.queue.len() {
            let Queued { target, verb, args, promise } = std::mem::replace(
                &mut self.queue[index],
                Queued { target: 0, verb: String::new(), args: Vec::new(), promise: 0 },
            );
            index += 1;
            let resolution = match self.call_local(target, &verb, &args) {
                Ok(value) => Resolution::Fulfill(value),
                Err(message) => Resolution::Break(message),
            };
            self.settle_local(promise, resolution);
        }
        self.queue.clear();
    }

    fn settle_local(&mut self, promise: u64, resolution: Resolution) {
        if let Some(listener) = self.listeners.remove(&promise) {
            listener(resolution);
        }
    }

    /// Dispatch one inbound peer event. A deliver to a published export runs the
    /// actor (leading symbol = verb) and resolves the answer with its reply; a
    /// resolve for a pending far promise fires its listener. Returns whether the
    /// event belonged to this vat (false → not ours; the caller handles it).
    pub fn serve(&mut self, event: &Event) -> Result<bool> {
        match event {
            Event::Deliver { target, args, answer } => self.serve_deliver(target, args, *answer),
            Event::Resolve { answer, resolution } => Ok(self.serve_resolve(*answer, resolution)),
            _ => Ok(false),
        }
    }

    fn serve_deliver(&mut self, target: &Reference, args: &[Argument], answer: Option<u64>) -> Result<bool> {
        let export_id = match target {
            Reference::Near { id, .. } => *id,
            _ => return Ok(false),
        };
        let actor = match self.exports.get(&export_id) {
            Some(id) => *id,
            None => return Ok(false),
        };

        // A leading symbol is the method verb; the rest are its arguments.
        let (verb, rest): (&str, &[Argument]) = match args.split_first() {
            Some((Argument::Symbol(symbol), rest)) => (symbol, rest),
            _ => ("", args),
        };

        let result = self.call_local(actor, verb, rest);
        if let Some(answer) = answer {
            let peer = self.peer.as_deref_mut().expect("serving a deliver needs a bound peer");
            match result {
                Ok(reply) => peer.send_resolve(answer, &Resolution::Fulfill(reply))?,
                Err(message) => peer.send_resolve(answer, &Resolution::Break(message))?,
            }
        }
        Ok(true)
    }

    fn serve_resolve(&mut self, answer: u64, resolution: &Resolution) -> bool {
        match self.far_listeners.remove(&answer) {
            Some(listener) => {
                listener(resolution.clone());
                true
            }
            None => false,
        }
    }
}
