# Workstream F.2 — Mainnet goldens

Reference fixture files lifted (or scheduled to be lifted) from real
Ethereum mainnet data.  Cross-checked from both stacks per the
integration plan §10.2.

## Files

* `block_header_hashes.txt` — 32 lines, each a
  `preimage_hex<TAB>hash_hex` pair: a 512-byte block-header
  preimage and its keccak256.  One line per record.  There is no
  separate preimages file — the preimage rides in the first field
  and is parsed in place by
  `solidity/test/CrossCheck/Goldens.t.sol`.
* `transaction_signatures.txt` — 32 lines, each a
  `pubkey_hex<TAB>msg_hex<TAB>sig_hex` triple: a 64-byte public
  key, a 32-byte signing input, and a 65-byte ECDSA signature.
* `rlp_encodings.txt` — 32 lines, each a `rlp_hex<TAB>hash_hex`
  pair, where `rlp_hex` is a 256-byte transaction RLP encoding and
  `hash_hex` is its keccak256 (the EVM transaction hash).

Every field in all three files is `0x`-prefixed hex.

## Provenance discipline

These files are **append-only**: once a record lands, its bytes
are never altered.  Adding a record requires a new commit; removing
or rewriting a record is a Genesis-Plan amendment.

The files are pure data from byte 0 — the Solidity-side parser
(`solidity/test/CrossCheck/Goldens.t.sol`) reads every line as a
record, so the format has no comment support.  Provenance
therefore lives in the Lean generator
(`LegalKernel/Test/Bridge/CrossCheck/Goldens.lean`), which records
the derivation of every record (currently the deterministic
LCG-from-seed recipe below) and is the only writer of these
files.

## Hash-binding-conditional behaviour

* The Solidity-side asserter (`solidity/test/CrossCheck/Goldens.t.sol`)
  always runs unconditionally — the EVM `keccak256` opcode is
  available regardless of which Lean-side hash binding is linked.
* The Lean-side asserter (`LegalKernel/Test/Bridge/CrossCheck/
  Goldens.lean`) gates byte-equivalence on
  `Bridge.isKeccak256Linked` (`LegalKernel/Bridge/HashAdaptor.lean`).
  Without
  the production binding, the Lean fallback (FNV-1a-64 padded to
  32 bytes) cannot reproduce keccak256 outputs, so the per-record
  assertion is skipped with an explicit log line.  The keccak gate
  is CI's `keccak-crossstack` job
  (`.github/workflows/ci-keccak-crossstack.yml`, driven by
  `scripts/verify_keccak_crossstack.sh`), which links the
  production binding and asserts the link took, so the gated
  checks run there instead of skipping — production runs must link
  the keccak256 binding before counting goldens as "passing".

## Synthetic placeholder corpus

This initial check-in ships a **deterministic synthetic** goldens
corpus.  Each record's preimage bytes are LCG-derived from a fixed
seed so the file is byte-stable across machines, and the recorded
hash / signature is the value the *production* keccak256 / ECDSA
binding would produce on that preimage.  Without the production
binding linked, the fixtures are still well-formed: the Lean-side
asserter skips byte-equality assertions; the Solidity side confirms
its own keccak256 of the preimage matches the recorded hash.

Replacing this synthetic corpus with real mainnet records is a
follow-up that requires:

1. A Rust-or-Python tool that extracts records from `geth` /
   archive-node JSON-RPC.
2. The recorded SHA-256 of the extracted file's bytes (so an audit
   can verify the corpus hasn't been silently rewritten).
3. The two-reviewer gate per CLAUDE.md, since the corpus's
   provenance becomes part of the deployment-readiness audit
   trail.
