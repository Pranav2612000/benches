# b57eb157 (parent) → 0f1485fb (fix)

- baseline metrics: filtered-recall.json
- candidate metrics: filtered-recall.json

| section | row | metric | baseline | candidate | change |
| --- | --- | --- | --- | --- | --- |
| filtered-recall | clustered, 1 × 1024 rows | p50 | 419.40 ms | 582.95 ms | +163.55 ms |
| filtered-recall | clustered, 1 × 1024 rows | recall@10 | 0.901 | 0.972 | +0.071 |
| filtered-recall | clustered, 10 × 1024 rows | p50 | 407.22 ms | 578.75 ms | +171.52 ms |
| filtered-recall | clustered, 10 × 1024 rows | recall@10 | 0.974 | 0.991 | +0.017 |
| filtered-recall | clustered, 100 × 1024 rows | p50 | 491.49 ms | 598.95 ms | +107.46 ms |
| filtered-recall | clustered, 100 × 1024 rows | recall@10 | 0.975 | 0.993 | +0.018 |
| filtered-recall | scattered, 1 of 100003 | p50 | 616.69 ms | 886.55 ms | +269.86 ms |
| filtered-recall | scattered, 1 of 100003 | recall@10 | 0.556 | 1.000 | +0.444 |
| filtered-recall | scattered, 1 of 1009 | p50 | 761.85 ms | 988.40 ms | +226.55 ms |
| filtered-recall | scattered, 1 of 1009 | recall@10 | 0.964 | 0.992 | +0.028 |
| filtered-recall | scattered, 1 of 11 | p50 | 989.93 ms | 1084.45 ms | +94.53 ms |
| filtered-recall | scattered, 1 of 11 | recall@10 | 0.982 | 0.985 | — |
| filtered-recall | scattered, 10 of 100003 | p50 | 767.39 ms | 987.06 ms | +219.67 ms |
| filtered-recall | scattered, 10 of 100003 | recall@10 | 0.844 | 0.940 | +0.096 |
| filtered-recall | scattered, 10 of 1009 | p50 | 786.86 ms | 1006.48 ms | +219.62 ms |
| filtered-recall | scattered, 10 of 1009 | recall@10 | 0.977 | 0.993 | +0.016 |
| filtered-recall | scattered, 5 of 11 | p50 | 2051.94 ms | 2132.91 ms | +80.97 ms |
| filtered-recall | scattered, 5 of 11 | recall@10 | 0.983 | 0.983 | — |
| filtered-recall | unfiltered | p50 | 479.96 ms | 441.33 ms | -38.63 ms |
| filtered-recall | unfiltered | recall@10 | 0.978 | 0.978 | — |
