#!/usr/bin/env node
// Thin launcher: exec the vendored native binary that postinstall.mjs
// downloaded into ../vendor/, forwarding argv, stdio, and exit status.
// The real binary lives next to its SPM resource bundle in vendor/ —
// running it from there keeps the bundle resolvable at runtime.

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const binary = join(root, "vendor", "agent-sim");

if (!existsSync(binary)) {
  console.error(
    "agent-sim: native binary missing.\n" +
      "The postinstall step downloads it from the GitHub release; try:\n" +
      "  npm install -g agent-sim\n" +
      "agent-sim requires macOS on Apple Silicon with Xcode 26 installed."
  );
  process.exit(1);
}

const { status, signal } = spawnSync(binary, process.argv.slice(2), { stdio: "inherit" });
if (signal) {
  process.kill(process.pid, signal);
} else {
  process.exit(status ?? 1);
}
