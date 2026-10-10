#!/usr/bin/env node
// Explicit private provisioning. No key/pin values are printed or rotated.
import { constants, closeSync, existsSync, fstatSync, fsyncSync, lstatSync, mkdirSync, openSync, writeSync } from "node:fs";
import { createHash, createPrivateKey, createPublicKey, randomBytes, randomUUID } from "node:crypto";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";

const args = process.argv.slice(2);
if (args.length !== 4 || args[0] !== "--max-records" || args[2] !== "--max-bytes"
    || !/^[1-9][0-9]*$/.test(args[1]) || !/^[1-9][0-9]*$/.test(args[3])) {
  console.error("Usage: provision-bridge-issuer.mjs --max-records N --max-bytes N (explicit adopted limits required)");
  process.exit(2);
}
const max_records = Number(args[1]), max_bytes = Number(args[3]);
if (!Number.isSafeInteger(max_records) || !Number.isSafeInteger(max_bytes) || max_bytes < 2) process.exit(2);
const root = join(homedir(), ".clawgate", "bridge-issuer");
function ancestors(path) {
  for (let p = resolve(path); ; p = dirname(p)) {
    if (existsSync(p) || (() => { try { lstatSync(p); return true; } catch { return false; } })()) {
      const s = lstatSync(p);
      if (s.isSymbolicLink() || !s.isDirectory()) throw new Error("unsafe_provisioning_path");
    }
    if (dirname(p) === p) break;
  }
}
function writePrivate(path, data) {
  const fd = openSync(path, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
  try {
    const s = fstatSync(fd);
    if (!s.isFile() || s.uid !== process.getuid() || (s.mode & 0o077) !== 0) throw new Error("unsafe_provisioning_file");
    let offset = 0;
    while (offset < data.length) offset += writeSync(fd, data, offset, data.length - offset);
    fsyncSync(fd);
  } finally { closeSync(fd); }
}
try {
  ancestors(root);
  mkdirSync(root, { recursive: true, mode: 0o700 });
  const s = lstatSync(root);
  if (s.uid !== process.getuid() || (s.mode & 0o077) !== 0) throw new Error("unsafe_provisioning_directory");
  const names = ["issuer.key", "limits.json", "public-pin.json", "generation.json", "admissions.jsonl"];
  if (names.some(name => { try { lstatSync(join(root, name)); return true; } catch { return false; } })) {
    throw new Error("issuer_already_present_no_rotation");
  }
  const seed = randomBytes(32);
  const privateKey = createPrivateKey({ key: Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), seed]), format: "der", type: "pkcs8" });
  const raw = createPublicKey(privateKey).export({ type: "spki", format: "der" }).subarray(-32);
  const keyId = createHash("sha256").update(raw).digest("hex");
  writePrivate(join(root, "limits.json"), Buffer.from(JSON.stringify({ max_records, max_bytes }) + "\n"));
  writePrivate(join(root, "public-pin.json"), Buffer.from(JSON.stringify({ version: 1, public_key_hex: raw.toString("hex"), issuer_key_id: keyId }) + "\n"));
  writePrivate(join(root, "generation.json"), Buffer.from(JSON.stringify({ value: randomUUID(), issuerKeyId: keyId }) + "\n"));
  writePrivate(join(root, "admissions.jsonl"), Buffer.alloc(0));
  writePrivate(join(root, "issuer.key"), seed);
  seed.fill(0);
  const directoryFd = openSync(root, constants.O_RDONLY);
  try { fsyncSync(directoryFd); } finally { closeSync(directoryFd); }
  console.log("Bridge issuer provisioned; private key retained on bridge host; public-pin.json ready for explicit pin distribution.");
} catch (error) {
  console.error(`Bridge issuer provisioning failed: ${error.message}; partial files retained, no automatic reset.`);
  process.exitCode = 1;
}
