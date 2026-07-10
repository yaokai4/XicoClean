#!/usr/bin/env node
// Derive the app-side `XICO_LICENSE_PUBLIC_KEYS` value from the website's
// license SIGNING key, so the app provably trusts exactly what production signs.
//
// The private key NEVER needs to leave the server: run this ON the machine that
// holds it (or paste the seed locally). It prints `<keyID>:<base64 pubkey>` —
// copy that into scripts/build.env as XICO_LICENSE_PUBLIC_KEYS, then rebuild.
//
// Usage:
//   # from the website server (.env already loaded into the shell):
//   XICO_LICENSE_PRIVATE_KEY=... XICO_LICENSE_KEY_ID=xico-license-1 \
//     node scripts/print_license_pubkey.mjs
//   # or pass the seed + keyID as args:
//   node scripts/print_license_pubkey.mjs <base64-seed> [keyID]
//
// This mirrors xicoai.com/src/lib/license/sign.ts exactly (Ed25519, PKCS8/SPKI).

import { createPrivateKey, createPublicKey } from "node:crypto";

const ED25519_PKCS8_PREFIX = Buffer.from(
  "302e020100300506032b657004220420",
  "hex",
);

const seedB64 = (process.argv[2] || process.env.XICO_LICENSE_PRIVATE_KEY || "").trim();
const keyId = (process.argv[3] || process.env.XICO_LICENSE_KEY_ID || "xico-license-1").trim();

if (!seedB64) {
  console.error(
    "✗ No private key. Set XICO_LICENSE_PRIVATE_KEY or pass the base64 seed as arg 1.",
  );
  process.exit(1);
}

const seed = Buffer.from(seedB64, "base64");
if (seed.length !== 32) {
  console.error(`✗ Private key must decode to 32 bytes (got ${seed.length}).`);
  process.exit(1);
}

const priv = createPrivateKey({
  key: Buffer.concat([ED25519_PKCS8_PREFIX, seed]),
  format: "der",
  type: "pkcs8",
});
const spki = createPublicKey(priv).export({ format: "der", type: "spki" });
const pub = Buffer.from(spki.subarray(spki.length - 32)).toString("base64");

// The one line to paste into scripts/build.env:
console.log(`${keyId}:${pub}`);
