#!/usr/bin/env python3
"""Loopback-only TCP relay to the isolated guest's existing Screen Sharing."""
import argparse
import select
import socket
import socketserver

parser = argparse.ArgumentParser()
parser.add_argument('--guest-ip', required=True)
parser.add_argument('--port', type=int, default=59094)
args = parser.parse_args()

class Relay(socketserver.BaseRequestHandler):
    def handle(self):
        with socket.create_connection((args.guest_ip, 5900), timeout=5) as guest:
            self.request.settimeout(None)
            guest.settimeout(None)
            sockets = [self.request, guest]
            while True:
                ready, _, errors = select.select(sockets, [], sockets, 30)
                if errors:
                    return
                for source in ready:
                    data = source.recv(65536)
                    if not data:
                        return
                    target = guest if source is self.request else self.request
                    target.sendall(data)

class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

with Server(('127.0.0.1', args.port), Relay) as server:
    print(f'Loopback VNC proxy 127.0.0.1:{args.port} to isolated guest', flush=True)
    server.serve_forever()
