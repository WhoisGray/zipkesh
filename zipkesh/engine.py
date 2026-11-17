#!/usr/bin/env python3
"""Zipkesh's stdlib-only archive worker. Passwords arrive over stdin, never argv."""

from __future__ import annotations

import argparse
import errno
import json
import os
from pathlib import Path
import pty
import re
import secrets
import select
import signal
import string
import subprocess
import sys
import tempfile
import termios
import time

VERSION = "1.0.0"
FORMATS = {
    "zip-aes": (".zip", ["-tzip", "-mem=AES256"]),
    "7z": (".7z", ["-t7z", "-mhe=on"]),
    "zip-legacy": (".zip", ["-tzip", "-mem=ZipCrypto"]),
}


class ArchiveError(Exception):
    pass


class Cancelled(ArchiveError):
    pass


def generate_password(style: str) -> str:
    alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"
    if style == "easy":
        return "-".join("".join(secrets.choice(alphabet) for _ in range(4)) for _ in range(4))
    if style not in ("strong", "long"):
        raise ArchiveError("Unknown password style.")
    alphabet += "!@#$%&*+-=?"
    length = 24 if style == "strong" else 48
    # Keep generated passwords usable with common password policies.
    while True:
        password = "".join(secrets.choice(alphabet) for _ in range(length))
        if (any(c.islower() for c in password) and any(c.isupper() for c in password)
                and any(c.isdigit() for c in password) and any(c in string.punctuation for c in password)):
            return password


def _stop(_signum, _frame):
    raise Cancelled("Cancelled. Any unfinished archive was removed.")


def _run_7zip(binary: str, arguments: list[str], password: str, cwd: str,
              prompt_timeout: float = 300.0, require_prompt: bool = True) -> None:
    """Use an echo-free PTY for 7-Zip's interactive password prompts.

    A pipe is not a terminal on macOS. A PTY also avoids exposing the password
    in ps, shell history, the environment, or a temporary configuration file.
    """
    master, slave = pty.openpty()
    child = None
    prompts = 0
    started = time.monotonic()
    try:
        settings = termios.tcgetattr(slave)
        settings[3] &= ~(termios.ECHO | termios.ECHONL)
        termios.tcsetattr(slave, termios.TCSANOW, settings)
        child = subprocess.Popen(
            [binary, *arguments], cwd=cwd, stdin=slave, stdout=slave,
            stderr=slave, start_new_session=True,
            env={**os.environ, "LC_ALL": "C", "LANG": "C"},
        )
        os.close(slave)
        slave = -1
        pending = bytearray()
        while True:
            ready, _, _ = select.select([master], [], [], 0.15)
            if ready:
                try:
                    chunk = os.read(master, 8192)
                except OSError as exc:
                    if exc.errno != errno.EIO:
                        raise
                    chunk = b""
                if not chunk:
                    break
                pending.extend(chunk)
                while True:
                    prompt = re.search(rb"(?:Enter password|Verify password)[^\r\n:]*:", pending)
                    if not prompt:
                        break
                    del pending[:prompt.end()]
                    prompts += 1
                    if prompts > 2:
                        raise ArchiveError("7-Zip requested the password too many times.")
                    os.write(master, password.encode("utf-8") + b"\n")
                del pending[:-4096]
            if child.poll() is not None and not ready:
                break
            if prompts == 0 and time.monotonic() - started > prompt_timeout:
                raise ArchiveError("7-Zip did not request a password. Check the installed 7zip version.")
        code = child.wait()
        if code != 0:
            # Do not echo child output: diagnostics could include private filenames.
            raise ArchiveError(f"7-Zip failed (exit {code}). Check free space, file access and source files.")
        if require_prompt and prompts == 0:
            raise ArchiveError("7-Zip finished without requesting a password; refusing this archive.")
    finally:
        if slave >= 0:
            os.close(slave)
        os.close(master)
        if child is not None and child.poll() is None:
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                child.wait()


def prepare_paths(paths: list[str], output: str, format_name: str) -> tuple[list[str], str, Path]:
    if format_name not in FORMATS:
        raise ArchiveError("Unsupported archive format.")
    if not paths:
        raise ArchiveError("Select at least one file or folder in Finder.")
    destination = Path(os.path.abspath(output))
    if destination.suffix.lower() != FORMATS[format_name][0]:
        raise ArchiveError("The filename extension does not match the archive format.")
    if os.path.lexists(destination):
        raise ArchiveError("That file already exists. Choose a different archive name.")
    if not destination.parent.is_dir():
        raise ArchiveError("The destination folder does not exist.")
    selected = sorted(set(os.path.abspath(p) for p in paths), key=lambda p: (len(Path(p).parts), p))
    sources: list[str] = []
    for source in selected:
        if not os.path.lexists(source):
            raise ArchiveError("A selected file is no longer available. Download cloud files first.")
        if source == os.path.sep:
            raise ArchiveError("Select files or folders, not the entire disk.")
        if not (os.path.isfile(source) or os.path.isdir(source) or os.path.islink(source)):
            raise ArchiveError("Only regular files, folders and symbolic links are supported.")
        if any(not os.path.islink(parent) and os.path.isdir(parent)
               and os.path.commonpath([parent, source]) == parent for parent in sources):
            continue
        sources.append(source)
        if os.path.isdir(source) and not os.path.islink(source):
            real_source = os.path.realpath(source)
            if os.path.commonpath([real_source, os.path.realpath(destination)]) == real_source:
                raise ArchiveError("Save the archive outside the selected folders.")
    root = os.path.commonpath([os.path.dirname(p) for p in sources])
    relative = [os.path.relpath(p, root) for p in sources]
    # 7-Zip treats @name as a list file even after --. Prefix every operand.
    relative = ["." + os.path.sep + p for p in relative]
    return relative, root, destination


def create_archive(request: dict, binary: str) -> str:
    password = request.get("password", "")
    if not isinstance(password, str) or len(password) < 8:
        raise ArchiveError("Use a password with at least 8 characters.")
    # PTY canonical input interprets control characters and has a line limit.
    if len(password.encode("utf-8")) > 256 or any(ord(c) < 32 or ord(c) == 127 for c in password):
        raise ArchiveError("Use at most 256 UTF-8 bytes and no tabs, newlines or control characters.")
    paths = request.get("paths")
    if not isinstance(paths, list) or any(not isinstance(p, str) or not os.path.isabs(p) for p in paths):
        raise ArchiveError("Source paths must be absolute paths.")
    output = request.get("output")
    if not isinstance(output, str) or not os.path.isabs(output):
        raise ArchiveError("Choose an absolute destination path.")
    mode = request.get("format", "zip-aes")
    if mode in ("zip-aes", "zip-legacy") and not password.isascii():
        raise ArchiveError("7-Zip requires ASCII passwords for ZIP. Use English letters/symbols or choose 7z for a Unicode password.")
    relative, root, destination = prepare_paths(paths, output, mode)
    if not os.path.isabs(binary) or not os.access(binary, os.X_OK):
        raise ArchiveError("7-Zip is unavailable. Re-run the Zipkesh installer.")
    # Never share encrypted content with other local users before publication.
    with tempfile.TemporaryDirectory(prefix=".zipkesh-", dir=destination.parent) as staging:
        archive = Path(staging) / ("archive" + FORMATS[mode][0])
        _run_7zip(binary, ["a", *FORMATS[mode][1], "-p", "-y", "-bd", "-bsp0", "-spd",
                          "-snl", "-spf", str(archive), "--", *relative], password, root)
        os.chmod(archive, 0o600)
        # For testing/extracting, bare -p means an EMPTY password in 7-Zip.
        # Omit it to request a terminal prompt. Empty ZIPs may need no prompt.
        _run_7zip(binary, ["t", "-y", "-bd", "-bsp0", str(archive)], password, root,
                  require_prompt=False)
        try:
            # Atomic publication without a check-then-rename overwrite race.
            os.link(archive, destination)
        except FileExistsError:
            raise ArchiveError("That file now exists. Choose a different archive name.") from None
        except OSError as exc:
            raise ArchiveError("Could not publish the archive. Choose a local APFS/HFS+ folder with enough space.") from exc
    return str(destination)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sevenzip")
    parser.add_argument("--generate", choices=["strong", "easy", "long"])
    parser.add_argument("--version", action="version", version=VERSION)
    args = parser.parse_args()
    if args.generate:
        print(generate_password(args.generate))
        return 0
    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)
    try:
        request = json.load(sys.stdin)
        if not isinstance(request, dict):
            raise ArchiveError("Invalid request.")
        result = create_archive(request, args.sevenzip or "")
        print(json.dumps({"ok": True, "output": result}, ensure_ascii=False))
        return 0
    except (ArchiveError, OSError, ValueError, TypeError) as exc:
        message = str(exc) if isinstance(exc, ArchiveError) else "Could not read files or process the archive request."
        print(json.dumps({"ok": False, "error": message}, ensure_ascii=False))
        return 130 if isinstance(exc, Cancelled) else 1


if __name__ == "__main__":
    sys.exit(main())
