#!/usr/bin/env python3
"""
Vibol Local ROS Game Server Simulator
Handles NetEase / UniSDK Notice, Auth, Version, and Server List Handshakes
Over Local Wi-Fi (IP: 172.20.10.2)
"""

import http.server
import socketserver
import json
import socket
import threading
import sys
import os

HTTP_PORT = 8080
GAME_PORT = 9933
LOCAL_IP = "172.20.10.2"

class LocalROSHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        print(f"[{self.client_address[0]}] HTTP Request: {self.command} {self.path}")

    def send_json(self, data, code=200):
        body = json.dumps(data).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.lower()
        print(f"[*] Incoming GET: {self.path}")

        # 1. Notice / Announcement bypass (replaces NetEase shutdown message)
        if "notice" in path or "news" in path or "html" in path:
            self.send_json({
                "code": 200,
                "status": 0,
                "is_open": 1,
                "msg": "Welcome to Vibol Local Server",
                "notice": "Local Testing Server Active! NetEase shutdown notice bypassed.",
                "data": {
                    "notice_title": "Vibol Local Offline Server",
                    "notice_content": "Server is ONLINE. Ready for local testing.",
                    "maintenance": 0
                }
            })
            return

        # 2. Server List & Gateway Info
        if "server" in path or "gate" in path or "appsvr" in path or "query" in path:
            self.send_json({
                "code": 200,
                "status": 0,
                "server_time": 1700000000,
                "servers": [
                    {
                        "id": 1,
                        "name": "Vibol Local Test Server",
                        "ip": LOCAL_IP,
                        "port": GAME_PORT,
                        "state": 1,
                        "status": "online",
                        "ping": 10
                    }
                ]
            })
            return

        # 3. Version / Patch Check
        if "version" in path or "patch" in path or "update" in path:
            self.send_json({
                "code": 200,
                "status": 0,
                "version": 7686,
                "update_type": 0,
                "need_update": False
            })
            return

        # Default fallback: 200 OK
        self.send_json({"code": 200, "status": 0, "msg": "OK"})

    def do_POST(self):
        print(f"[*] Incoming POST: {self.path}")
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length) if content_length > 0 else b""
        
        # Auth / Login Response
        self.send_json({
            "code": 200,
            "status": 0,
            "login_state": 0,
            "uin": "vibol_local_player",
            "user_id": "vibol_local_player",
            "token": "vibol_offline_token_ok",
            "session": "vibol_session_ok",
            "expire_time": 9999999999
        })

def start_tcp_game_server():
    """Background TCP socket server to answer ping/handshake packets on port 9933"""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("0.0.0.0", GAME_PORT))
        s.listen(5)
        print(f"[✓] Game TCP Ping Server running on port {GAME_PORT}...")
        while True:
            conn, addr = s.accept()
            print(f"[TCP] Game Client connected from {addr[0]}:{addr[1]}")
            # Echo basic pong/ack packet
            try:
                data = conn.recv(1024)
                if data:
                    conn.sendall(b"\x00\x00\x00\x04\x01\x00\x00\x00")
            except Exception:
                pass
            finally:
                conn.close()
    except Exception as e:
        print(f"[-] TCP Game Server note: {e}")

def main():
    print("=" * 60)
    print("   🚀 Vibol ROS Local Wi-Fi Game Server Simulator   ")
    print("=" * 60)
    print(f" Local IP:   {LOCAL_IP}")
    print(f" HTTP Port:  {HTTP_PORT} (Notice, Login, Auth, Server List)")
    print(f" Game Port:  {GAME_PORT} (TCP Game Link & Ping)")
    print("=" * 60)
    print(" Ready! Launch Rules of Survival on your iPhone connected to the same Wi-Fi.\n")

    # Start TCP Game Server in background thread
    t = threading.Thread(target=start_tcp_game_server, daemon=True)
    t.start()

    # Start HTTP Server
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("0.0.0.0", HTTP_PORT), LocalROSHandler) as httpd:
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nShutting down local server...")
            httpd.shutdown()

if __name__ == "__main__":
    main()
