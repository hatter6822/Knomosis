# Codemaps

This directory follows the seLe4n `codebase_map.json` schema (JSON format).

## Files

- `lean/codemap.json`
- `solidity/codemap.json`
- `rust/codemap.json`

## Regeneration (required for every PR)

Run the codemap generator before opening or updating a PR:

```bash
python3 scripts/regenerate_codemaps.py
```

CI reruns the generator and fails if any codemap is out of date.
