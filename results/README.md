# Recorded runs

One directory per A/B, as `ab.sh` writes them: `run.txt` (what ran),
per-phase logs and metrics, and `comparison.md` (the diff).

Logs are kept because the engine's own progress output — cell counts,
drain timings, oracle sizes — is often what explains a number, and it is
gone once the terminal scrolls.

| run | what it showed |
| --- | --- |
| `2026-11-03-filtered-recall-b57eb157-vs-0f1485fb` | The filtered-vector-recall fix: +0.444 recall@10 on a filter keeping 95 of 9.4M rows, with the unfiltered control flat at 0.978 on both commits. See `docs/filtered-recall.md`. |
| `null-ab-selftest` | The same commit on both sides — the noise floor. Every delta here is measurement noise, which is what calibrates `compare.py`'s thresholds. |
