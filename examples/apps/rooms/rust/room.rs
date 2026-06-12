//! A small, friendly client for the rooms chat, built on pancake actors.
//!
//! On the connection API this is barely a layer: connect, fetch the room by
//! name, spawn an inbox the room can call back, subscribe by handing it that
//! capability, and forward the room's callbacks onto a channel. The pancake
//! `Connection` owns the peer on a background task, so the application above sees
//! only `recv`/`say`/`leave`.
//!
//!   let mut room = Room::join(addr, "alice").await?;
//!   room.say("hello").await;
//!   while let Some(msg) = room.recv().await { println!("{}: {}", msg.from, msg.text); }
//!   room.leave().await;

use std::rc::Rc;

use pancake::{connect, Argument, Connection};
use tokio::sync::mpsc;

const ROOM: &str = "room";

/// Dial a transport-neutral rooms locator: an `ocapn://…iroh` URI joins over
/// iroh (when this client is built with the `iroh` feature), a bare `host:port`
/// over TCP. The room's wire is identical either way; only how a member reaches
/// it differs. The rooms URIs carry direct-addresses, so the explicit iroh
/// posture is [`Reachability::Direct`](pancake::Reachability::Direct) — relay-less
/// and lookup-less, no default.
async fn dial(locator: &str) -> Result<Connection, String> {
    if locator.contains("://") {
        #[cfg(feature = "iroh")]
        {
            return pancake::connect_iroh_uri(locator, pancake::Reachability::Direct)
                .await
                .map_err(|e| format!("connect iroh: {e:?}"));
        }
        #[cfg(not(feature = "iroh"))]
        {
            return Err(format!(
                "this client was built without the iroh transport; rebuild with `--features iroh` to dial {locator}"
            ));
        }
    }
    let (host, port) = locator
        .rsplit_once(':')
        .ok_or_else(|| format!("rooms locator is neither host:port nor an ocapn:// URI: {locator}"))?;
    let port: u16 = port.parse().map_err(|_| format!("rooms locator has no valid port: {locator}"))?;
    connect((host, port)).await.map_err(|e| format!("connect: {e:?}"))
}

/// One line in the room. `system` is true for the room's own announcements (a
/// member joining, your welcome); otherwise `from` is who said it.
#[derive(Debug, Clone)]
pub struct Message {
    pub from: String,
    pub text: String,
    pub system: bool,
}

/// A membership in a chat room: the connection plus a stream of the lines the
/// room pushes. `recv` for the next line, `say` to talk, `leave` when done.
pub struct Room {
    conn: Rc<Connection>,
    room: pancake::Ref,
    msg_rx: mpsc::UnboundedReceiver<Message>,
}

fn as_str(arg: Option<&Argument>) -> String {
    match arg {
        Some(Argument::String(s)) => s.clone(),
        _ => String::new(),
    }
}

impl Room {
    /// Join the room at `locator` as `nick` — a `host:port` over TCP or an
    /// `ocapn://…iroh` URI over iroh. Call inside a `LocalSet` (the peer is
    /// `!Send`).
    pub async fn join(locator: &str, nick: &str) -> Result<Room, String> {
        // `dial` spawns the connection's driver task, so inbound events are
        // already being served — `fetch`, `send`, and our inbox callbacks all
        // work without a separate serve loop.
        let conn = Rc::new(dial(locator).await?);

        let room = conn.fetch(ROOM).await.map_err(|e| format!("fetch room: {e:?}"))?;

        // The room calls our inbox back with each line; forward it onto a channel.
        let (msg_tx, msg_rx) = mpsc::unbounded_channel::<Message>();
        let welcome_tx = msg_tx.clone();
        let inbox = conn
            .spawn(move |verb, args| {
                if verb != "notify" {
                    return Err(format!("inbox has no method {verb}"));
                }
                let from = as_str(args.first());
                let text = as_str(args.get(1));
                let _ = msg_tx.send(Message { system: from == "room", from, text });
                Ok(Argument::Void)
            })
            .await
            .map_err(|e| format!("spawn inbox: {e:?}"))?;

        // Subscribe, handing the room a capability to our inbox. The welcome
        // reply names everyone already present — the only way to learn about
        // earlier arrivals — so it joins the message stream as a system line.
        let welcome = conn
            .send(&room, "subscribe", &[Argument::String(nick.to_string()), (&inbox).into()])
            .await
            .map_err(|e| format!("subscribe: {e:?}"))?;
        if let Argument::String(text) = welcome {
            let _ = welcome_tx.send(Message { system: true, from: "room".to_string(), text });
        }

        Ok(Room { conn, room, msg_rx })
    }

    /// Say a line to everyone in the room.
    pub async fn say(&self, text: &str) {
        let _ = self.conn.send(&self.room, "post", &[Argument::String(text.to_string())]).await;
    }

    /// The next line the room pushes, or `None` once it has ended.
    pub async fn recv(&mut self) -> Option<Message> {
        self.msg_rx.recv().await
    }

    /// Leave the room: close the connection and let the driver wind down.
    pub async fn leave(self) {
        self.conn.close();
    }
}
