//! Herdr's live event stream: one connection to its socket holding an
//! `events.subscribe` request open, so status changes arrive the moment they
//! happen instead of with the next `herdr api snapshot`. Herdr serves one
//! request per connection, so changing the subscribed panes means opening a
//! new stream. Messages arrive on a channel the monitor drains each frame.

use crate::herdr::herdr_subscriptions;
use serde_json::Value;
use std::io::{BufRead, BufReader, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};

pub enum StreamMessage {
    Open,
    Event(Value),
    Close,
}

pub struct HerdrStream {
    socket_path: String,
    subscriptions: Vec<Value>,
    connection: Arc<Mutex<Option<UnixStream>>>,
    stopped: Arc<Mutex<bool>>,
    /// Which stream a message came from, so a replaced stream's are ignored.
    pub generation: u64,
}

impl HerdrStream {
    pub fn new(socket_path: &str, panes: &[String], generation: u64) -> HerdrStream {
        HerdrStream {
            socket_path: socket_path.to_string(),
            subscriptions: herdr_subscriptions(panes),
            connection: Arc::new(Mutex::new(None)),
            stopped: Arc::new(Mutex::new(false)),
            generation,
        }
    }

    pub fn start(&self, sender: Sender<(u64, StreamMessage)>) {
        let path = self.socket_path.clone();
        let request = serde_json::json!({ "id": "hpd-events", "method": "events.subscribe", "params": { "subscriptions": self.subscriptions } });
        let connection = self.connection.clone();
        let stopped = self.stopped.clone();
        let generation = self.generation;
        std::thread::Builder::new()
            .name("herdr-events".into())
            .spawn(move || {
                let quiet = run(&path, &request, &connection, &stopped, generation, &sender);
                *connection.lock().unwrap_or_else(|e| e.into_inner()) = None;
                if !quiet {
                    let _ = sender.send((generation, StreamMessage::Close));
                }
            })
            .ok();
    }

    pub fn stop(&self) {
        *self.stopped.lock().unwrap_or_else(|e| e.into_inner()) = true;
        if let Some(stream) = self.connection.lock().unwrap_or_else(|e| e.into_inner()).as_ref() {
            let _ = stream.shutdown(Shutdown::Both);
        }
    }
}

/// Serve the stream until it ends; true when it was stopped on purpose.
fn run(path: &str, request: &Value, connection: &Arc<Mutex<Option<UnixStream>>>, stopped: &Arc<Mutex<bool>>, generation: u64, sender: &Sender<(u64, StreamMessage)>) -> bool {
    let Ok(mut stream) = UnixStream::connect(path) else { return *stopped.lock().unwrap() };
    let Ok(reader) = stream.try_clone() else { return *stopped.lock().unwrap() };
    {
        let mut slot = connection.lock().unwrap_or_else(|e| e.into_inner());
        if *stopped.lock().unwrap() { return true; }
        *slot = Some(reader);
    }
    let mut line = request.to_string();
    line.push('\n');
    if stream.write_all(line.as_bytes()).is_err() { return *stopped.lock().unwrap(); }
    let mut opened = false;
    for row in BufReader::new(stream).lines() {
        let Ok(row) = row else { break };
        let Ok(object) = serde_json::from_str::<Value>(&row) else { continue };
        if !opened {
            // The first reply confirms the subscription; an error ends the stream.
            let started = object.get("result").and_then(|r| r.get("type")).and_then(Value::as_str) == Some("subscription_started");
            if !started { break; }
            opened = true;
            let _ = sender.send((generation, StreamMessage::Open));
        } else {
            let _ = sender.send((generation, StreamMessage::Event(object)));
        }
    }
    *stopped.lock().unwrap_or_else(|e| e.into_inner())
}
