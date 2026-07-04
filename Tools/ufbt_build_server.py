#!/usr/bin/env python3
"""Small authenticated uFBT build host for Dolphin Deck."""

from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path, PurePosixPath
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


MAX_REQUEST_BYTES = 25_000_000
MAX_FILES = 1_000
MAX_LOG_CHARS = 80_000
BUILD_LOCK = threading.Lock()


def safe_relative_path(value: str) -> Path:
    candidate = PurePosixPath(value)
    if candidate.is_absolute() or not candidate.parts:
        raise ValueError("invalid absolute path")
    if any(part in {"", ".", ".."} for part in candidate.parts):
        raise ValueError("invalid path component")
    return Path(*candidate.parts)


class BuildHandler(BaseHTTPRequestHandler):
    server_version = "DolphinDeck-uFBT/1.0"

    def do_GET(self) -> None:
        if self.path.rstrip("/") == "/health":
            self.send_json(200, {"success": True, "message": "uFBT build host ready"})
            return
        self.send_json(404, {"success": False, "message": "not found"})

    def do_POST(self) -> None:
        if self.path.rstrip("/") != "/build":
            self.send_json(404, {"success": False, "message": "not found"})
            return
        if not self.authorized():
            self.send_json(401, {"success": False, "message": "invalid build token"})
            return

        try:
            content_length = int(self.headers.get("Content-Length", "0"))
            if content_length <= 0 or content_length > MAX_REQUEST_BYTES:
                raise ValueError("request is empty or too large")
            payload = json.loads(self.rfile.read(content_length))
            files = payload.get("files")
            if not isinstance(files, list) or not files or len(files) > MAX_FILES:
                raise ValueError("invalid file list")
            response = self.build_project(files)
            self.send_json(200, response)
        except subprocess.TimeoutExpired:
            self.send_json(504, {"success": False, "message": "uFBT timed out"})
        except Exception as error:
            self.send_json(400, {"success": False, "message": str(error)})

    def authorized(self) -> bool:
        token = os.environ.get("UFBT_BUILD_TOKEN", "")
        if not token:
            return True
        return self.headers.get("Authorization") == f"Bearer {token}"

    def build_project(self, files: list[dict[str, str]]) -> dict[str, object]:
        with tempfile.TemporaryDirectory(prefix="dolphindeck-ufbt-") as temporary:
            project = Path(temporary) / "project"
            project.mkdir()

            for item in files:
                relative = safe_relative_path(str(item.get("path", "")))
                encoded = item.get("data")
                if not isinstance(encoded, str):
                    raise ValueError(f"missing data for {relative}")
                data = base64.b64decode(encoded, validate=True)
                destination = project / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(data)

            if not any(project.rglob("application.fam")):
                raise ValueError("application.fam not found")

            command = os.environ.get("UFBT_COMMAND", "ufbt")
            with BUILD_LOCK:
                completed = subprocess.run(
                    [command],
                    cwd=project,
                    capture_output=True,
                    text=True,
                    timeout=600,
                    check=False,
                    env={**os.environ, "PYTHONUNBUFFERED": "1"},
                )
            log = (completed.stdout + "\n" + completed.stderr)[-MAX_LOG_CHARS:]
            if completed.returncode != 0:
                return {
                    "success": False,
                    "message": f"uFBT exited with code {completed.returncode}",
                    "log": log,
                }

            artifacts = sorted(
                project.rglob("*.fap"),
                key=lambda path: path.stat().st_mtime,
                reverse=True,
            )
            if not artifacts:
                return {
                    "success": False,
                    "message": "uFBT created no .fap artifact",
                    "log": log,
                }

            artifact = artifacts[0]
            return {
                "success": True,
                "message": "build completed",
                "fileName": artifact.name,
                "fap": base64.b64encode(artifact.read_bytes()).decode("ascii"),
                "log": log,
            }

    def send_json(self, status: int, payload: dict[str, object]) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format_string: str, *arguments: object) -> None:
        print(f"{self.client_address[0]} - {format_string % arguments}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8787)
    arguments = parser.parse_args()
    server = ThreadingHTTPServer((arguments.host, arguments.port), BuildHandler)
    print(f"uFBT build host listening on http://{arguments.host}:{arguments.port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nuFBT build host stopped")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
