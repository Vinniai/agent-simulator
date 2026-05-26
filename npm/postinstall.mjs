// Downloads the platform-native agent-sim binary + its SPM resource
// bundle from the matching GitHub release and stages them in vendor/,
// where the bin/ shim execs them.
//
// agent-sim is a Swift binary that links private SimulatorKit /
// CoreSimulator frameworks shipped with Xcode 26 — it only runs on
// macOS / Apple Silicon. The `os` / `cpu` fields in package.json gate
// normal installs; this script repeats the guard for `--force` users
// and downloads the per-version GitHub release tarball.

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, rmSync, writeFileSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const pkg = JSON.parse(
  await import("node:fs/promises").then((fs) => fs.readFile(join(here, "package.json"), "utf8"))
);

const REPO = process.env.AGENT_SIM_REPO || "Vinniai/agent-sim";
const VERSION = pkg.version;
const TAG = `v${VERSION}`;
const BASE = `https://github.com/${REPO}/releases/download/${TAG}`;
const ASSET = `agent-sim_${TAG}_macOS_arm64.tar.gz`;
const CHECKSUMS = `agent-sim_${TAG}_checksums.txt`;
const VENDOR = join(here, "vendor");

function warn(msg) {
  console.warn(`agent-sim (postinstall): ${msg}`);
}

function fail(msg) {
  console.error(`agent-sim (postinstall): ${msg}`);
  process.exit(1);
}

// Lets the publish job / CI / monorepo installs opt out of the download.
if (process.env.AGENT_SIM_SKIP_DOWNLOAD) {
  warn("AGENT_SIM_SKIP_DOWNLOAD set — skipping native binary download.");
  process.exit(0);
}

// Platform guard. os/cpu already block this on other platforms, so we
// only reach here with --force; warn and exit 0 so we never break an
// unrelated `npm install` in a cross-platform workspace.
if (process.platform !== "darwin" || process.arch !== "arm64") {
  warn(
    `unsupported platform ${process.platform}/${process.arch}. ` +
      "agent-sim requires macOS on Apple Silicon — the binary was not downloaded."
  );
  process.exit(0);
}

async function fetchOrFail(url, { binary = false } = {}) {
  let res;
  try {
    res = await fetch(url, { redirect: "follow" });
  } catch (err) {
    fail(`could not reach ${url} (${err.message}).`);
  }
  if (!res.ok) {
    fail(`GET ${url} returned ${res.status}. Is release ${TAG} published on ${REPO}?`);
  }
  return binary ? Buffer.from(await res.arrayBuffer()) : res.text();
}

function expectedSha(checksumsText) {
  const line = checksumsText.split("\n").find((l) => l.includes("macOS_arm64"));
  const sha = line?.trim().split(/\s+/)[0];
  if (!sha || !/^[0-9a-f]{64}$/.test(sha)) {
    fail(`could not find a valid arm64 checksum in ${CHECKSUMS}.`);
  }
  return sha;
}

const checksums = await fetchOrFail(`${BASE}/${CHECKSUMS}`);
const want = expectedSha(checksums);

const tarball = await fetchOrFail(`${BASE}/${ASSET}`, { binary: true });
const got = createHash("sha256").update(tarball).digest("hex");
if (got !== want) {
  fail(`checksum mismatch for ${ASSET}\n  expected ${want}\n  got      ${got}`);
}

// Extract binary + resource bundle into vendor/. They must sit
// side-by-side: WebRoot resolves the bundle via dladdr from the
// executable's directory. macOS ships bsdtar, so shelling out is safe
// here (this script only ever runs on macOS).
const tmpTar = join(tmpdir(), `agent-sim-${TAG}-${process.pid}.tar.gz`);
writeFileSync(tmpTar, tarball);
rmSync(VENDOR, { recursive: true, force: true });
mkdirSync(VENDOR, { recursive: true });

// The archive nests everything under agent-sim-<tag>-macOS-arm64/;
// --strip-components=1 lands the files directly in vendor/.
const tar = spawnSync("tar", ["xzf", tmpTar, "--strip-components=1", "-C", VENDOR], {
  stdio: "inherit",
});
rmSync(tmpTar, { force: true });
if (tar.status !== 0) {
  fail(`tar extraction failed (exit ${tar.status ?? "signal"}).`);
}

const binary = join(VENDOR, "agent-sim");
if (!existsSync(binary)) {
  fail("extraction completed but vendor/agent-sim is missing.");
}
chmodSync(binary, 0o755);

console.log(`agent-sim ${VERSION} installed (downloaded from ${REPO}).`);
