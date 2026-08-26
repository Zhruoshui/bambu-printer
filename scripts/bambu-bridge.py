#!/usr/bin/env python3
"""MQTT bridge for Bambu Lab printers, Python stdlib only.

Speaks the same LAN MQTT dialect as Bambu Studio (port 1883, user "bblp",
password = printer access code) and emits one JSON object per line on stdout:

  {"event": "connected"}
  {"event": "disconnected", "reason": "..."}
  {"event": "auth_error", "reason": "..."}
  {"event": "message", "payload": {...}}            # report payload, passthrough

The script owns the whole connection lifecycle: connect, subscribe to
device/<sn>/report, request a full status push ("pushall"), answer the
keepalive, and reconnect with backoff. The QML side only reads the lines.
Exit is reserved for SIGTERM/SIGINT from the widget host.
"""

import argparse
import json
import socket
import struct
import sys
import time

CONNECT_TIMEOUT = 10.0
SOCK_TIMEOUT = 1.0
KEEPALIVE_SEC = 30
PUSHALL_REFRESH_SEC = 300
BACKOFF_MIN = 5
BACKOFF_MAX = 60
AUTH_RETRY_SEC = 60
MAX_PACKET = 8 * 1024 * 1024


def emit(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def log(msg):
    sys.stderr.write("bambu-bridge: %s\n" % msg)
    sys.stderr.flush()


# ---- MQTT 3.1.1 packet construction -----------------------------------------


def varint(n):
    out = bytearray()
    while True:
        b = n % 128
        n //= 128
        if n:
            b |= 0x80
        out.append(b)
        if not n:
            return bytes(out)


def mstr(s):
    b = s.encode("utf-8")
    return struct.pack("!H", len(b)) + b


def packet(first_byte, body):
    return bytes([first_byte]) + varint(len(body)) + body


def connect_packet(client_id, access_code):
    variable_header = mstr("MQTT") + bytes([4, 0x02]) + struct.pack("!H", 60)
    payload = mstr(client_id) + mstr("bblp") + mstr(access_code)
    return packet(0x10, variable_header + payload)  # CONNECT, clean session


def subscribe_packet(packet_id, topic):
    body = struct.pack("!H", packet_id) + mstr(topic) + b"\x00"  # QoS 0
    return packet(0x82, body)


def publish_packet(topic, message):
    return packet(0x30, mstr(topic) + message.encode("utf-8"))  # QoS 0


PINGREQ = b"\xc0\x00"


# ---- MQTT receive framing ----------------------------------------------------


def read_exact(sock, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("connection closed by peer")
        buf += chunk
    return bytes(buf)


def read_packet(sock):
    first = read_exact(sock, 1)[0]
    length = 0
    multiplier = 1
    for _ in range(4):
        b = read_exact(sock, 1)[0]
        length += (b & 0x7F) * multiplier
        multiplier *= 128
        if not (b & 0x80):
            break
    else:
        raise ConnectionError("malformed remaining-length varint")
    if length > MAX_PACKET:
        raise ConnectionError("packet too large: %d bytes" % length)
    body = read_exact(sock, length) if length else b""
    return first >> 4, body


def decode_publish(body):
    if len(body) < 2:
        return None, None
    (topic_len,) = struct.unpack("!H", body[:2])
    if len(body) < 2 + topic_len:
        return None, None
    topic = body[2 : 2 + topic_len].decode("utf-8", "replace")
    return topic, body[2 + topic_len :].decode("utf-8", "replace")


# ---- session ------------------------------------------------------------------


class Bridge:
    def __init__(self, host, port, sn, access_code):
        self.host = host
        self.port = port
        self.sn = sn
        self.access_code = access_code
        self.sock = None

    def run(self):
        backoff = BACKOFF_MIN
        while True:
            try:
                self.connect_once()
                backoff = BACKOFF_MIN  # a good session resets the backoff
            except AuthError as e:
                emit({"event": "auth_error", "reason": str(e)})
                time.sleep(AUTH_RETRY_SEC)
                continue
            except (OSError, ConnectionError) as e:
                emit({"event": "disconnected", "reason": str(e)})
                time.sleep(backoff)
                backoff = min(backoff * 2, BACKOFF_MAX)
                continue

    def connect_once(self):
        sock = socket.create_connection((self.host, self.port), CONNECT_TIMEOUT)
        self.sock = sock
        try:
            sock.settimeout(SOCK_TIMEOUT)
            client_id = "omarchy-bambu-%d" % (time.time() % 100000)
            sock.sendall(connect_packet(client_id, self.access_code))

            packet_type, body = read_packet(sock)
            if packet_type != 2:
                raise ConnectionError("expected CONNACK, got type %d" % packet_type)
            if len(body) < 2 or body[1] != 0:
                rc = body[1] if len(body) >= 2 else -1
                raise AuthError("access code rejected (CONNACK rc=%d)" % rc)

            sock.sendall(subscribe_packet(1, "device/%s/report" % self.sn))
            self.request_pushall()
            emit({"event": "connected"})
            log("connected to %s:%d sn=%s" % (self.host, self.port, self.sn))
            self.stream_loop()
        finally:
            try:
                sock.close()
            except OSError:
                pass
            self.sock = None

    def request_pushall(self):
        request = json.dumps({"pushing": {"command": "pushall"}})
        self.sock.sendall(publish_packet("device/%s/request" % self.sn, request))

    def stream_loop(self):
        last_ping = time.monotonic()
        last_pushall = time.monotonic()
        while True:
            # The 1s receive timeout turns blocking reads into a polling loop
            # so keepalives and pushall refreshes fire on schedule.
            try:
                packet_type, body = read_packet(self.sock)
            except socket.timeout:
                packet_type = None
            if packet_type == 3:  # PUBLISH
                topic, raw = decode_publish(body)
                if raw is None:
                    continue
                # Pass the printer's JSON through verbatim; fall back to an
                # escaped string if it is not valid JSON (never observed, but
                # a binary blob must not corrupt the event stream).
                try:
                    json.loads(raw)
                    sys.stdout.write(
                        '{"event": "message", "payload": %s}\n' % raw
                    )
                    sys.stdout.flush()
                except ValueError:
                    emit({"event": "message", "payload": raw})
            # SUBACK / PINGRESP and anything else: nothing to do.

            now = time.monotonic()
            if now - last_ping >= KEEPALIVE_SEC:
                self.sock.sendall(PINGREQ)
                last_ping = now
            if now - last_pushall >= PUSHALL_REFRESH_SEC:
                self.request_pushall()
                last_pushall = now


class AuthError(Exception):
    pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, default=1883)
    parser.add_argument("--sn", required=True)
    parser.add_argument("--code", required=True)
    args = parser.parse_args()

    try:
        Bridge(args.host, args.port, args.sn, args.code).run()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
