# Legal Kernel

A formally grounded, implementation-oriented constitutional kernel built in
Lean 4. The Legal Kernel is a **proof-carrying state transition system** in
which legality is a type, every state change is accompanied by a
machine-checkable proof of admissibility, and global system properties are
guaranteed by inductive invariants rather than by trust in operators.

The full architectural and mathematical blueprint, including the formal
kernel, mathematical guarantees, threat model, and phased implementation
roadmap, lives in:

- [docs/GENESIS_PLAN.md](docs/GENESIS_PLAN.md)

That document is the canonical source of truth for the project's design
philosophy, formal model, and implementation strategy. Start there.

## License

See [LICENSE](LICENSE).
