#!/usr/bin/env node
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const fixtureDir = path.join(repoRoot, "tests/fixtures");
const manifest = JSON.parse(await readFile(path.join(fixtureDir, "manifest.json"), "utf8"));
const requiredFiles = [
  "oracle_dnxhd_1080i2997_10bit_cid1241.mxf",
  "oracle_dnxhd_1080i2997_10bit_cid1241.yuv.gz",
  "oracle_dnxhd_1080i2997_8bit_cid1242.mxf",
  "oracle_dnxhd_1080i2997_8bit_cid1242.yuv.gz",
  "oracle_dnxhd_1080i2997_8bit_cid1243.mxf",
  "oracle_dnxhd_1080i2997_8bit_cid1243.yuv.gz",
  "oracle_dnxhd_1440x1080i2997_8bit_cid1244.mxf",
  "oracle_dnxhd_1440x1080i2997_8bit_cid1244.yuv.gz",
  "oracle_dnxhd_1440x1080i2997_8bit_cid1260.mxf",
  "oracle_dnxhd_1440x1080i2997_8bit_cid1260.yuv.gz",
  "oracle_dnxhd_720p30_10bit_cid1250.mxf",
  "oracle_dnxhd_720p30_10bit_cid1250.yuv.gz",
  "oracle_dnxhd_720p30_8bit_cid1251.mxf",
  "oracle_dnxhd_720p30_8bit_cid1251.yuv.gz",
  "oracle_dnxhd_720p30_8bit_cid1252.mxf",
  "oracle_dnxhd_720p30_8bit_cid1252.yuv.gz",
  "oracle_dnxhd_1080p30_8bit_cid1253.mxf",
  "oracle_dnxhd_1080p30_8bit_cid1253.yuv.gz",
  "oracle_dnxhd_960x720p30_8bit_cid1258.mxf",
  "oracle_dnxhd_960x720p30_8bit_cid1258.yuv.gz",
  "oracle_dnxhd_1440x1080p30_8bit_cid1259.mxf",
  "oracle_dnxhd_1440x1080p30_8bit_cid1259.yuv.gz",
  "oracle_dnxhd_1080p30_8bit_cid1237.mxf",
  "oracle_dnxhd_1080p30_8bit_cid1237.yuv.gz",
  "oracle_dnxhd_1080p30_8bit_cid1238.mxf",
  "oracle_dnxhd_1080p30_8bit_cid1238.yuv.gz",
  "oracle_dnxhd_1080p30_10bit_cid1235.mxf",
  "oracle_dnxhd_1080p30_10bit_cid1235.yuv.gz",
  "oracle_dnxhr_lb_1080p30_8bit_cid1274.mov",
  "oracle_dnxhr_lb_1080p30_8bit_cid1274.yuv.gz",
  "oracle_dnxhr_sq_1080p30_8bit_cid1273.mov",
  "oracle_dnxhr_sq_1080p30_8bit_cid1273.yuv.gz",
  "oracle_dnxhr_hq_1080p30_8bit_cid1272.mov",
  "oracle_dnxhr_hq_1080p30_8bit_cid1272.yuv.gz",
  "oracle_dnxhr_hqx_1080p30_10bit_cid1271.mov",
  "oracle_dnxhr_hqx_1080p30_10bit_cid1271.yuv.gz",
  "oracle_dnxhr_444_1080p30_10bit.mov",
  "oracle_dnxhr_444_1080p30_10bit.yuv.gz",
  "oracle_dnxhr_444_gbr_1080p30_10bit.mov",
  "oracle_dnxhr_444_gbr_1080p30_10bit.yuv.gz",
  "dnxhr-lb-op1a-pcm.mxf",
  "dnxhr-lb-op1a-pcm24-mono-24fps-tc.mxf",
  "dnxhr-lb-opatom.mxf",
  "dnxhr_hqx_2160p30_testsrc.mov.gz",
  "dnxhr_hq_2160p30_testsrc.mov.gz",
  "dnxhr_444_2160p30_testsrc.mov.gz",
  "dnxhr_hqx_4320p30_smptehdbars.mov.gz"
];
const manifestPaths = new Set(manifest.files.map((fixture) => fixture.path));
for (const requiredFile of requiredFiles) {
  assert.equal(manifestPaths.has(requiredFile), true, `${requiredFile} is required by CI`);
}

for (const fixture of manifest.files) {
  const bytes = await readFile(path.join(fixtureDir, fixture.path));
  const digest = createHash("sha256").update(bytes).digest("hex");
  assert.equal(digest, fixture.sha256, `${fixture.path} checksum`);
}

const oracleArgs = [
  "tests/dnx-oracle-test.mjs",
  "--allow-missing",
  "--fixture-dir", "tests/fixtures",
  "--frames", "1"
];
if (process.argv.includes("--require-native")) {
  oracleArgs.push("--require-native");
}
const oracle = spawnSync(process.execPath, oracleArgs, { cwd: repoRoot, stdio: "inherit" });
assert.equal(oracle.status, 0, "committed DNx oracle suite");

console.log(`Verified ${manifest.files.length} committed fixture artifacts.`);
