#!/usr/bin/env python3
"""Small authenticated uFBT build host for Dolphin Deck."""

from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
from typing import Optional
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


MAX_REQUEST_BYTES = 25_000_000
MAX_FILES = 1_000
MAX_LOG_CHARS = 80_000
BUILD_LOCK = threading.Lock()
UFBT_EXECUTABLE: Optional[str] = None


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
            found = UFBT_EXECUTABLE is not None
            self.send_json(
                200 if found else 503,
                {
                    "success": found,
                    "message": (
                        "uFBT build host ready"
                        if found
                        else "build host reachable, but ufbt was not found"
                    ),
                    "ufbtFound": found,
                    "ufbtCommand": UFBT_EXECUTABLE,
                    "tokenRequired": bool(os.environ.get("UFBT_BUILD_TOKEN", "")),
                },
            )
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
        if UFBT_EXECUTABLE is None:
            raise RuntimeError(
                "ufbt command not found; install it with "
                f"{sys.executable} -m pip install --upgrade ufbt"
            )
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

            process_environment = isolated_ufbt_environment(Path(temporary))
            with BUILD_LOCK:
                completed = subprocess.run(
                    [UFBT_EXECUTABLE],
                    cwd=project,
                    capture_output=True,
                    text=True,
                    timeout=600,
                    check=False,
                    env=process_environment,
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
    global UFBT_EXECUTABLE
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument(
        "--ufbt",
        default=os.environ.get("UFBT_COMMAND", "ufbt"),
        help="Pfad zum ufbt-Befehl (Standard: UFBT_COMMAND oder Suche im PATH)",
    )
    arguments = parser.parse_args()
    UFBT_EXECUTABLE = resolve_ufbt(arguments.ufbt)
    server = ThreadingHTTPServer((arguments.host, arguments.port), BuildHandler)
    print(f"uFBT build host listening on http://{arguments.host}:{arguments.port}")
    if arguments.host in {"0.0.0.0", "::"}:
        local_address = local_network_address()
        if local_address:
            print(f"iPhone address on the same network: http://{local_address}:{arguments.port}")
    if UFBT_EXECUTABLE:
        print(f"using ufbt: {UFBT_EXECUTABLE}")
    else:
        print(
            "WARNING: ufbt was not found. Install it with "
            f"'{sys.executable} -m pip install --upgrade ufbt' or pass --ufbt /path/to/ufbt."
        )
    print(
        "authentication: "
        + ("Bearer token required" if os.environ.get("UFBT_BUILD_TOKEN") else "no token configured")
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nuFBT build host stopped")
    finally:
        server.server_close()


def resolve_ufbt(value: str) -> Optional[str]:
    expanded = Path(value).expanduser()
    if (expanded.is_absolute() or "/" in value) and expanded.is_file():
        return str(expanded)

    discovered = shutil.which(value)
    if discovered:
        return discovered

    version = f"{sys.version_info.major}.{sys.version_info.minor}"
    candidates = [
        Path.home() / "Library" / "Python" / version / "bin" / "ufbt",
        Path.home() / ".local" / "bin" / "ufbt",
        Path("/opt/homebrew/bin/ufbt"),
        Path("/usr/local/bin/ufbt"),
    ]
    for candidate in candidates:
        if candidate.is_file():
            return str(candidate)
    return None


def local_network_address() -> Optional[str]:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as connection:
            connection.connect(("8.8.8.8", 80))
            return str(connection.getsockname()[0])
    except OSError:
        return None


def isolated_ufbt_environment(temporary: Path) -> dict[str, str]:
    environment = {**os.environ, "PYTHONUNBUFFERED": "1"}
    if os.name == "nt":
        return environment

    installed_home = Path(
        environment.get("UFBT_HOME", str(Path.home() / ".ufbt"))
    ).expanduser()
    current_sdk = installed_home / "current"
    toolchain = installed_home / "toolchain"
    if not current_sdk.is_dir() or not toolchain.is_dir():
        return environment

    isolated_home = temporary / "ufbt-home"
    isolated_home.mkdir()
    (isolated_home / "current").symlink_to(current_sdk, target_is_directory=True)
    (isolated_home / "toolchain").symlink_to(toolchain, target_is_directory=True)
    environment["UFBT_HOME"] = str(isolated_home)
    environment["UFBT_STATE_DIR"] = str(isolated_home)
    environment["FBT_TOOLCHAIN_PATH"] = str(isolated_home)
    return environment


if __name__ == "__main__":
    main()
