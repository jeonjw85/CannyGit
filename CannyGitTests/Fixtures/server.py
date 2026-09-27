"""A loopback listener owned only by terminal integration tests."""
import os
import signal
import socket
import time

signal.signal(signal.SIGINT, signal.SIG_IGN)
signal.signal(signal.SIGTERM, signal.SIG_IGN)
signal.signal(signal.SIGHUP, signal.SIG_IGN)
with socket.socket() as server:
    server.bind(("127.0.0.1", 0))
    server.listen()
    print(f"SERVER {os.getpid()} {server.getsockname()[1]}", flush=True)
    # A safety deadline bounds the fixture even if its test crashes.
    time.sleep(30)
