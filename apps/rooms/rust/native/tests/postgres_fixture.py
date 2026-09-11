#!/usr/bin/env python3
"""Run the native PostgreSQL process contracts in an isolated TLS database.

Requires PostgreSQL server/client tools; --pg-bin may name an unpacked toolchain.
The cluster, credentials, sockets and schema belong to this invocation. No system
cluster is started, reconfigured or stopped. The repository CA is fixture trust.
"""
import argparse
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pg-bin", type=Path)
    parser.add_argument("--auth", choices=["scram-sha-256", "password"], default="scram-sha-256")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[5]

    def tool(name):
        path = args.pg_bin / name if args.pg_bin else shutil.which(name)
        if not path or not Path(path).is_file():
            parser.error(f"PostgreSQL {name} is required (use --pg-bin)")
        return str(path)

    initdb, pg_ctl, psql = [tool(name) for name in ["initdb", "pg_ctl", "psql"]]
    with tempfile.TemporaryDirectory(prefix="rooms-postgres-") as temporary:
        root = Path(temporary)
        data = root / "data"
        fixtures = repo / "test/net/fixtures"
        with (root / "setup.log").open("w+") as setup:
            subprocess.run([initdb, "-D", str(data), "-A", "trust", "-U", "rooms_proof",
                            "--no-locale", "--encoding=UTF8"], stdout=setup, stderr=setup, check=True)
        shutil.copyfile(fixtures / "tls_server.pem", data / "server.crt")
        shutil.copyfile(fixtures / "tls_server.key", data / "server.key")
        (data / "server.key").chmod(0o600)
        with socket.socket() as reserved:
            reserved.bind(("127.0.0.1", 0))
            port = reserved.getsockname()[1]
        (data / "pg_hba.conf").write_text(
            "local all all trust\n"
            f"hostssl all all 127.0.0.1/32 {args.auth}\n"
            f"hostssl all all ::1/128 {args.auth}\n"
            "host all all 0.0.0.0/0 reject\n"
            "host all all ::/0 reject\n"
        )
        with (data / "postgresql.conf").open("a") as config:
            config.write(f"\nlisten_addresses='localhost'\nport={port}\n"
                         f"unix_socket_directories='{root}'\nssl=on\n"
                         "password_encryption='scram-sha-256'\n")
        started = False
        try:
            subprocess.run([pg_ctl, "-D", str(data), "-l", str(root / "postgres.log"),
                            "-w", "-t", "10", "start"], check=True, stdout=subprocess.DEVNULL)
            started = True
            subprocess.run([psql, "-h", str(root), "-p", str(port), "-U", "rooms_proof",
                            "-d", "postgres", "-v", "ON_ERROR_STOP=1"],
                           input="ALTER ROLE rooms_proof PASSWORD 'rooms-synthetic-password';\n",
                           text=True, stdout=subprocess.DEVNULL, check=True)
            env = dict(os.environ)
            env.update({
                "SSL_CERT_FILE": str(fixtures / "tls_root.pem"),
                "SSL_CERT_DIR": str(root / "no-system-roots"),
                "GLOWCAP_ROOMS_STORAGE_LIVE_URL":
                    f"postgresql://rooms_proof:rooms-synthetic-password@localhost:{port}/postgres?sslmode=require",
                "GLOWCAP_ROOMS_SERVER_TEST_BIN": str(repo / "zig-out/bin/rooms-server"),
                "GLOWCAP_LIB_DIR": str(repo / "zig-out/lib"),
            })
            env["LD_LIBRARY_PATH"] = str(repo / "zig-out/lib") + os.pathsep + env.get("LD_LIBRARY_PATH", "")
            subprocess.run(["cargo", "test", "--locked", "--manifest-path", "apps/rooms/rust/Cargo.toml",
                            "-p", "rooms-native", "--features", "service", "--test", "postgres_process",
                            "--", "--ignored", "--test-threads=1"], cwd=repo, env=env, check=True)
        finally:
            if started:
                subprocess.run([pg_ctl, "-D", str(data), "-m", "immediate", "-w", "-t", "10", "stop"],
                               check=True, stdout=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
