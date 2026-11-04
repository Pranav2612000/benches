# 0f1485fb → 0f1485fb (same commit)

- baseline metrics: tombstone-overhead.json
- candidate metrics: tombstone-overhead.json

| section | row | metric | baseline | candidate | change |
| --- | --- | --- | --- | --- | --- |
| overhead | clean | FTS p50 | 121,313 | 114,122 | — |
| overhead | clean | Median RSS | 48,828,416 | 45,813,760 | — |
| overhead | clean | P90 RSS | 80,318,464 | 76,804,096 | — |
| overhead | clean | Peak RSS | 80,318,464 | 76,804,096 | — |
| overhead | clean | SQL COUNT(*) p50 | 161,773 | 165,129 | — |
| overhead | one_percent | FTS p50 | 114,492 | 115,183 | — |
| overhead | one_percent | Median RSS | 98,394,112 | 88,629,248 | — |
| overhead | one_percent | P90 RSS | 101,326,848 | 92,246,016 | — |
| overhead | one_percent | Peak RSS | 101,326,848 | 92,246,016 | — |
| overhead | one_percent | SQL COUNT(*) p50 | 230,357 | 234,374 | — |
| overhead | ten_percent_churned | FTS p50 | 114,132 | 110,206 | — |
| overhead | ten_percent_churned | Median RSS | 104,869,888 | 97,914,880 | — |
| overhead | ten_percent_churned | P90 RSS | 106,778,624 | 100,098,048 | — |
| overhead | ten_percent_churned | Peak RSS | 106,778,624 | 100,098,048 | — |
| overhead | ten_percent_churned | SQL COUNT(*) p50 | 254,013 | 262,605 | — |
