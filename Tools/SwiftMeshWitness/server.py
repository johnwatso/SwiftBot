#!/usr/bin/env python3
"""Single independent SwiftMesh lease authority; no bot data or secrets on disk.

Run behind HTTPS on an independent host. SWIFTMESH_WITNESS_TOKEN is required.
The SQLite database must be durable and used by only this authority deployment.
"""
import argparse
import hmac
import json
import os
import sqlite3
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class LeaseStore:
    def __init__(self, database, duration=30, clock=time.monotonic):
        self.database = database
        self.duration = duration
        self.clock = clock
        with sqlite3.connect(database) as db:
            db.execute("CREATE TABLE IF NOT EXISTS leases (cluster TEXT PRIMARY KEY, owner TEXT NOT NULL, term INTEGER NOT NULL, expires REAL NOT NULL)")
            # Monotonic expiry avoids granting a second owner on a wall-clock
            # jump. After restart/reboot, the prior monotonic epoch is unknown:
            # hold all acquisitions for a full lease before clearing old leases.
            had_owner = db.execute("SELECT 1 FROM leases WHERE owner != '' AND expires > 0 LIMIT 1").fetchone() is not None
            self.recovering_until = self.clock() + duration if had_owner else 0
            db.execute("UPDATE leases SET expires=0 WHERE owner != ''")

    def apply(self, action, cluster, owner, term):
        if (action not in ("acquire", "renew", "release") or
                not isinstance(cluster, str) or not 1 <= len(cluster) <= 128 or
                not isinstance(owner, str) or not 1 <= len(owner) <= 128 or
                type(term) is not int or not 0 <= term < 2**62):
            return 400, {"error": "invalid_request"}
        with sqlite3.connect(self.database, timeout=5) as db:
            db.execute("BEGIN IMMEDIATE")
            now = self.clock()
            if now < self.recovering_until:
                return 503, {"error": "authority_recovering"}
            row = db.execute("SELECT owner, term, expires FROM leases WHERE cluster=?", (cluster,)).fetchone()
            previous_owner, previous_term, expiry = row or ("", 0, 0)
            live = expiry > now
            if action == "acquire":
                if live:
                    if previous_owner != owner or term > previous_term:
                        return 409, {"error": "ownership_held"}
                    return 200, {"ownerNodeID": owner, "term": previous_term, "expiresInSeconds": expiry - now}
                new_term = max(previous_term, term) + 1
                db.execute("INSERT OR REPLACE INTO leases VALUES (?, ?, ?, ?)", (cluster, owner, new_term, now + self.duration))
                return 200, {"ownerNodeID": owner, "term": new_term, "expiresInSeconds": self.duration}
            if previous_owner != owner or previous_term != term or not live:
                return 409, {"error": "ownership_expired_or_changed"}
            if action == "release":
                db.execute("UPDATE leases SET owner='', expires=0 WHERE cluster=?", (cluster,))
                return 200, {"released": True}
            db.execute("UPDATE leases SET expires=? WHERE cluster=?", (now + self.duration, cluster))
            return 200, {"ownerNodeID": owner, "term": term, "expiresInSeconds": self.duration}


def handler(store, token):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            # Never log bearer credentials, request bodies, or cluster names.
            pass

        def respond(self, status, payload):
            data = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            self.respond(200 if self.path == "/health" else 404, {"ready": self.path == "/health"})

        def do_POST(self):
            supplied = self.headers.get("Authorization", "")
            if not hmac.compare_digest(supplied.encode(), ("Bearer " + token).encode()):
                self.respond(401, {"error": "unauthorized"})
                return
            try:
                size = int(self.headers.get("Content-Length", "0"))
                if not 0 < size <= 4096 or not self.path.startswith("/v1/lease/"):
                    self.respond(400, {"error": "invalid_request"})
                    return
                self.connection.settimeout(5)
                body = json.loads(self.rfile.read(size))
                status, payload = store.apply(self.path.removeprefix("/v1/lease/"), body["clusterID"], body["nodeID"], body["term"])
            except (ValueError, KeyError, TypeError):
                status, payload = 400, {"error": "invalid_request"}
            except Exception:
                status, payload = 503, {"error": "authority_unavailable"}
            self.respond(status, payload)
    return Handler


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=38990)
    parser.add_argument("--database", required=True)
    args = parser.parse_args()
    witness_token = os.environ.get("SWIFTMESH_WITNESS_TOKEN", "")
    if len(witness_token) < 32:
        parser.error("SWIFTMESH_WITNESS_TOKEN must contain at least 32 characters")
    os.umask(0o077)
    ThreadingHTTPServer((args.bind, args.port), handler(LeaseStore(args.database), witness_token)).serve_forever()
