//! A small, friendly client for the rooms chat, built on pancake actors.
//!
//! On the new connection API this is barely a layer: connect, fetch the room by
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
    /// Join the room at `addr` as `nick`. Call inside a `LocalSet` (the peer is
    /// `!Send`).
    pub async fn join(addr: &str, nick: &str) -> Result<Room, String> {
        // `connect` spawns the connection's driver task, so inbound events are
        // already being served — `fetch`, `send`, and our inbox callbacks all
        // work without a separate serve loop.
        let conn = Rc::new(connect(addr).await.map_err(|e| format!("connect: {e:?}"))?);

        let room = conn.fetch(ROOM).await.map_err(|e| format!("fetch room: {e:?}"))?;

        // The room calls our inbox back with each line; forward it onto a channel.
        let (msg_tx, msg_rx) = mpsc::unbounded_channel::<Message>();
        let inbox = conn.spawn(move |verb, args| {
            if verb != "notify" {
                return Err(format!("inbox has no method {verb}"));
            }
            let from = as_str(args.first());
            let text = as_str(args.get(1));
            let _ = msg_tx.send(Message { system: from == "room", from, text });
            Ok(Argument::Void)
        });

        // Subscribe, handing the room a capability to our inbox. The room
        // broadcasts our join (with the head count) to every member including us,
        // so the roster count arrives on the inbox; the welcome reply is just an
        // ack here.
        conn.send(&room, "subscribe", &[Argument::String(nick.to_string()), (&inbox).into()])
            .await
            .map_err(|e| format!("subscribe: {e:?}"))?;

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
