#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "fastmcp>=2.5.0",
#   "httpx>=0.27.0",
# ]
# ///
"""
Pre-warm script for uv's global cache.

When server.py runs under launchd for the first time, `uv run --script` has
to download + install the dependency tree (fastmcp pulls in ~68 transitive
packages). On a fresh machine this takes 5–15 seconds, which races against
the install script's launchd-job-up health check and produces false-positive
"WARNING: launchd job not found" output.

Run this once during _install-on-this-machine.sh BEFORE loading the launchd
plist. It declares the same PEP 723 deps as server.py, so resolving and
caching them here means the launchd-managed first run sees a hot cache.

Idempotent. Safe to re-run after dependency upgrades.
"""
import sys

import fastmcp
import httpx

print(f"warmup ok: fastmcp=={fastmcp.__version__} httpx=={httpx.__version__}", flush=True)
sys.exit(0)
