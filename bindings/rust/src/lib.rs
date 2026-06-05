#![allow(dead_code)]

use core::ffi::{c_int, c_uchar, c_uint, c_void};

const PANCAKE_OK: c_int = 0;
const PANCAKE_ERR_SESSION: c_int = -4;
const PANCAKE_ERR_CODEC: c_int = -5;
const PANCAKE_ERR_WOULD_BLOCK: c_int = -7;
const PANCAKE_FRAME_SHAPE_BYTE: c_uint = 0;
const PANCAKE_EVENT_ABORT: c_uint = 7;

#[repr(C)]
pub struct PancakeFrame {
    bytes: *const c_uchar,
    len: usize,
    shape: c_uint,
}

#[repr(C)]
pub struct PancakePeer {
    _private: [u8; 0],
}

#[repr(C)]
pub struct PancakeManagedFrame {
    bytes: *mut c_uchar,
    len: usize,
    shape: c_uint,
    release: Option<unsafe extern "C" fn(*mut PancakeManagedFrame)>,
    private_data: *mut c_void,
}

#[repr(C)]
pub struct PancakeEvent {
    kind: c_uint,
    frame: PancakeManagedFrame,
}

extern "C" {
    fn pancake_peer_new(peer: *mut *mut PancakePeer) -> c_int;
    fn pancake_peer_release(peer: *mut PancakePeer);
    fn pancake_peer_feed_borrowed(peer: *mut PancakePeer, frame: *const PancakeFrame) -> c_int;
    fn pancake_peer_poll_event(peer: *mut PancakePeer, event: *mut PancakeEvent) -> c_int;
    fn pancake_peer_take_outbound(peer: *mut PancakePeer, frame: *mut PancakeManagedFrame)
    -> c_int;
    fn pancake_frame_release(frame: *mut c_void);
    fn pancake_event_release(event: *mut PancakeEvent);
}

#[test]
fn rust_consumes_zig_peer_c_abi() {
    unsafe {
        let mut peer: *mut PancakePeer = core::ptr::null_mut();
        assert_eq!(PANCAKE_OK, pancake_peer_new(&mut peer));
        assert!(!peer.is_null());

        let bytes = b"<8'op:abort3\"bye>";
        let frame = PancakeFrame {
            bytes: bytes.as_ptr(),
            len: bytes.len(),
            shape: PANCAKE_FRAME_SHAPE_BYTE,
        };
        assert_eq!(PANCAKE_OK, pancake_peer_feed_borrowed(peer, &frame));

        let mut event = PancakeEvent {
            kind: 0,
            frame: PancakeManagedFrame {
                bytes: core::ptr::null_mut(),
                len: 0,
                shape: 0,
                release: None,
                private_data: core::ptr::null_mut(),
            },
        };
        assert_eq!(PANCAKE_OK, pancake_peer_poll_event(peer, &mut event));
        assert_eq!(PANCAKE_EVENT_ABORT, event.kind);
        let frame = core::slice::from_raw_parts(event.frame.bytes, event.frame.len);
        assert_eq!(b"<8'op:abort3\"bye>", frame);
        pancake_event_release(&mut event);

        // An inbound `op:gc-answers` releasing answer positions a fresh peer
        // never owned is a wire-delta protocol violation (ADR-0008: an unknown
        // answer-pos is a loud error, never a silent clamp). The frame decodes
        // cleanly, so this is a session state-machine refusal — reported as a
        // typed SESSION error (not CODEC) — and the Zig peer projects a typed
        // `op:abort` onto its outbound queue for the partner.
        let gc_answer = b"<13'op:gc-answers[11+13+]>";
        let mut violating_peer: *mut PancakePeer = core::ptr::null_mut();
        assert_eq!(PANCAKE_OK, pancake_peer_new(&mut violating_peer));
        assert!(!violating_peer.is_null());

        let gc_answer_frame = PancakeFrame {
            bytes: gc_answer.as_ptr(),
            len: gc_answer.len(),
            shape: PANCAKE_FRAME_SHAPE_BYTE,
        };
        assert_eq!(
            PANCAKE_ERR_SESSION,
            pancake_peer_feed_borrowed(violating_peer, &gc_answer_frame)
        );

        // No application event surfaces for the rejected frame.
        let mut rejected_event = PancakeEvent {
            kind: 0,
            frame: PancakeManagedFrame {
                bytes: core::ptr::null_mut(),
                len: 0,
                shape: 0,
                release: None,
                private_data: core::ptr::null_mut(),
            },
        };
        assert_eq!(
            PANCAKE_ERR_WOULD_BLOCK,
            pancake_peer_poll_event(violating_peer, &mut rejected_event)
        );

        // The projected abort is queued outbound for the partner.
        let mut abort_out = PancakeManagedFrame {
            bytes: core::ptr::null_mut(),
            len: 0,
            shape: 0,
            release: None,
            private_data: core::ptr::null_mut(),
        };
        assert_eq!(
            PANCAKE_OK,
            pancake_peer_take_outbound(violating_peer, &mut abort_out)
        );
        let abort_payload = core::slice::from_raw_parts(abort_out.bytes, abort_out.len);
        assert!(abort_payload.starts_with(b"<8'op:abort"));
        pancake_frame_release(&mut abort_out as *mut PancakeManagedFrame as *mut c_void);
        pancake_peer_release(violating_peer);

        pancake_frame_release(core::ptr::null_mut());
        pancake_peer_release(peer);
    }
}
