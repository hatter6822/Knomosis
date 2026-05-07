# Workstream F.2 — Mainnet goldens

Reference fixture files lifted (or scheduled to be lifted) from real
Ethereum mainnet data.  Cross-checked from both stacks per the
integration plan §10.2.

## Files

* `block_header_hashes.txt` — 32 lines, each a `0x<hex>` keccak256 of
  a real Ethereum mainnet block header.  One line per record.  The
  preimage bytes for each are stored alongside in
  `block_header_preimages.txt`.
* `transaction_signatures.txt` — 32 lines, each a `(pk_hex, msg_hex,
  sig_hex)` triple separated by `\t`.  Each line is a real signed
  transaction's signing input + ECDSA signature recovered from
  mainnet history.
* `rlp_encodings.txt` — 32 lines, each a `(rlp_hex, hash_hex)` pair
  separated by `\t`, where `rlp_hex` is a real signed mainnet
  transaction's RLP encoding and `hash_hex` is its keccak256 (the
  EVM transaction hash).

## Provenance discipline

These files are **append-only**: once a record lands, its bytes
are never altered.  Adding a record requires a new commit; removing
or rewriting a record is a Genesis-Plan amendment.

Source-attribution comments at the top of each file record:

  * The block range (or transaction-hash list) the records were
    drawn from.
  * The off-chain tool used to extract the record (e.g. `cast
    block <num>`, `geth`'s RLP test vectors).
  * The git SHA of any third-party verification script that
    cross-checked the values.

## Hash-binding-conditional behaviour

* The Solidity-side asserter (`solidity/test/CrossCheck/Goldens.t.sol`)
  always runs unconditionally — the EVM `keccak256` opcode is
  available regardless of which Lean-side hash binding is linked.
* The Lean-side asserter (`LegalKernel/Test/Bridge/CrossCheck/
  Goldens.lean`) gates byte-equivalence on
  `Bridge.HashAdaptor.isKeccak256Linked`.  Without the production
  binding, the Lean fallback (FNV-1a-64 padded to 32 bytes) cannot
  reproduce keccak256 outputs, so the per-record assertion is
  skipped with an explicit log line.  CI's
  `cross-stack-equivalence` job fails if the skip is taken in a
  deployment context — production runs must link the keccak256
  binding before counting goldens as "passing".

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
