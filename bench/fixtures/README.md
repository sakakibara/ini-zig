# Benchmark fixtures

These files are self-generated and deterministic. `generate.sh` in this
directory produces byte-identical output on every run (no timestamps,
no randomness).

- `small.ini` (~495 B): a representative app config with five sections.
- `medium.ini` (~40 KB): a git-config-style file with 200 remote entries
  and 100 branch entries, mimicking a repo with many tracked remotes.
- `large.ini` (~230 KB): 2000 service sections with several keys each,
  representative of a large infrastructure registry.

To regenerate:

```
sh bench/fixtures/generate.sh
```
