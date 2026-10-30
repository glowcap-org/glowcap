"""Shutdown acceptance checks for the relay-tls-build server fixture."""

import argparse
import os
from pathlib import Path
import socket
import ssl
import threading
import unittest
from unittest.mock import Mock, patch

import relay_tls_server as server


class CleanCloseTest(unittest.TestCase):
    def peer(self, terminal=b"", reply_error=None):
        peer = Mock(spec=ssl.SSLSocket)
        peer.recv.side_effect = [b"\x88\x80", b"mask", terminal]
        peer.unwrap.side_effect = reply_error
        return peer

    def test_completed_shutdown_closes_raw_socket(self):
        peer = self.peer()
        server.clean_close(peer)
        peer.unwrap.return_value.close.assert_called_once_with()

    def test_peer_may_retire_after_sending_close_notify(self):
        for error in (BrokenPipeError(), ConnectionResetError()):
            with self.subTest(error=type(error).__name__):
                peer = self.peer(reply_error=error)
                server.clean_close(peer)
                self.assertEqual(peer.recv.call_count, 3)
                peer.close.assert_called_once_with()

    def test_unnotified_peer_failure_is_fatal(self):
        for error in (ssl.SSLEOFError(), ConnectionResetError(), BrokenPipeError()):
            with self.subTest(error=type(error).__name__):
                peer = self.peer(terminal=error)
                with self.assertRaises(type(error)):
                    server.clean_close(peer)
                peer.unwrap.assert_not_called()

    def test_application_data_after_websocket_close_is_fatal(self):
        peer = self.peer(terminal=b"x")
        with self.assertRaises(RuntimeError):
            server.clean_close(peer)
        peer.unwrap.assert_not_called()

    def test_other_shutdown_failures_are_fatal(self):
        for error in (ssl.SSLEOFError(), TimeoutError()):
            with self.subTest(error=type(error).__name__):
                with self.assertRaises(type(error)):
                    server.clean_close(self.peer(reply_error=error))

    def test_unmasked_websocket_close_is_fatal(self):
        peer = self.peer()
        peer.recv.side_effect = [b"\x88\x00"]
        with self.assertRaises(RuntimeError):
            server.clean_close(peer)
        peer.unwrap.assert_not_called()

    def test_tls_socket_preserves_truncated_eof(self):
        raw = Mock()
        context = Mock()
        args = argparse.Namespace(mode="clean-close")
        with patch.object(server, "tls_context", return_value=context), \
                patch.object(server, "upgrade"), patch.object(server, "clean_close"):
            server.serve_one(raw, args)
        context.wrap_socket.assert_called_once_with(
            raw, server_side=True, suppress_ragged_eofs=False,
        )


class LiveCloseTest(unittest.TestCase):
    def test_authenticated_and_truncated_shutdown(self):
        fixtures = Path(__file__).resolve().parents[2] / "test/net/fixtures"
        for notified in (True, False):
            with self.subTest(notified=notified):
                args = argparse.Namespace(
                    mode="clean-close", cert=str(fixtures / "tls_server.pem"),
                    key=str(fixtures / "tls_server.key"),
                )
                outcomes = []
                incoming, outgoing = socket.socketpair()
                incoming.settimeout(2)
                outgoing.settimeout(2)

                def accept():
                    try:
                        with incoming:
                            server.serve_one(incoming, args)
                    except Exception as error:
                        outcomes.append(error)

                worker = threading.Thread(target=accept)
                context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
                context.load_verify_locations(cafile=str(fixtures / "tls_root.pem"))
                worker.start()
                try:
                    with context.wrap_socket(outgoing, server_hostname="localhost") as peer:
                        peer.sendall(
                            b"GET /relay?peer=test HTTP/1.1\r\n"
                            b"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
                        )
                        response = bytearray()
                        while not response.endswith(b"\r\n\r\n"):
                            chunk = peer.recv(4096)
                            self.assertTrue(chunk)
                            response.extend(chunk)
                        peer.sendall(b"\x88\x80mask")
                        self.assertEqual(server.recv_exact(peer, 2), b"\x88\x00")
                        if notified:
                            peer.unwrap().close()
                        else:
                            os.close(peer.detach())
                finally:
                    outgoing.close()
                    worker.join(timeout=3)
                    if worker.is_alive():
                        incoming.close()
                        worker.join(timeout=3)
                    self.assertFalse(worker.is_alive(), "TLS fixture did not retire")
                if notified:
                    self.assertEqual(outcomes, [])
                else:
                    self.assertEqual(len(outcomes), 1)
                    self.assertIsInstance(outcomes[0], (
                        ssl.SSLEOFError, ConnectionResetError, BrokenPipeError,
                    ))


if __name__ == "__main__":
    unittest.main()
