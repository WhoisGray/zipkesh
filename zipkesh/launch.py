#!/usr/bin/env python3
"""Detach the short-lived native window from Automator's service request."""
import subprocess
import sys


def launch(arguments):
    # No shell, no persistent agent, and no Automator timeout for a large archive.
    return subprocess.Popen(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, close_fds=True, start_new_session=True)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("Missing Zipkesh helper path. Re-run the installer.")
    try:
        launch(sys.argv[1:])
    except OSError:
        sys.exit("Could not open Zipkesh. Re-run the installer.")
