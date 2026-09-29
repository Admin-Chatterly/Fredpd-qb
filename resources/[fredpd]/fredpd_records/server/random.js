// SPDX-License-Identifier: GPL-3.0-only
// CSPRNG for share-link tokens (IMPLEMENTATION.md §4.6: token = 32 random bytes, base64url). FiveM's Lua has no
// secure random source (math.random must never be used for tokens), so this resource's JS runtime exports Node's
// crypto.randomBytes. Called from Lua as exports.fredpd_records:randomToken(32) (server/shares.lua).
'use strict';
const nodeCrypto = require('crypto');

/** base64url (no padding) of n random bytes; n is clamped to 16..64 (default 32). */
function randomToken(n) {
  const bytes = Number.isInteger(n) && n >= 16 && n <= 64 ? n : 32;
  return nodeCrypto.randomBytes(bytes).toString('base64url');
}

exports('randomToken', randomToken);
