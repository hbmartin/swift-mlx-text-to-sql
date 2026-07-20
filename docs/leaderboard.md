| config | gold | n | EX | valid SQL | T1 | T2 | T3 | s/item | top failure buckets |
|---|---|---|---|---|---|---|---|---|---|
| s2-ft-3b-gcdoff | gold_v2.jsonl | 200 | **0.665** | 0.925 | 0.714 | 0.699 | 0.278 | 1.82 | wrong-filter-or-value:20, wrong-table-or-join:20, execution-error:15 |
| s2-ft-3b-gcdon | gold_v2.jsonl | 200 | **0.665** | 0.930 | 0.714 | 0.699 | 0.278 | 2.87 | wrong-filter-or-value:21, wrong-table-or-join:20, execution-error:14 |
| q25c-3b-gcdon | gold_v1.jsonl | 60 | **0.350** | 0.850 | 0.7 | 0.167 | 0.2 | 5.26 | wrong-filter-or-value:9, execution-error:9, wrong-projection:7 |
| q25c-3b-gcdoff | gold_v1.jsonl | 60 | **0.333** | 0.783 | 0.7 | 0.133 | 0.2 | 2.72 | execution-error:13, wrong-filter-or-value:10, wrong-projection:6 |
| xiyan-3b-gcdoff | gold_v1.jsonl | 60 | **0.317** | 0.867 | 0.65 | 0.2 | 0.0 | 3.94 | wrong-filter-or-value:15, execution-error:8, wrong-aggregation:6 |
| xiyan-3b-gcdon | gold_v1.jsonl | 60 | **0.267** | 0.800 | 0.6 | 0.133 | 0.0 | 4.76 | wrong-filter-or-value:14, execution-error:12, wrong-projection:5 |
| q25c-15b-gcdoff | gold_v1.jsonl | 60 | **0.233** | 0.717 | 0.6 | 0.067 | 0.0 | 1.06 | execution-error:17, wrong-filter-or-value:8, wrong-table-or-join:7 |
| s2-q25c-3b-gcdoff | gold_v2.jsonl | 200 | **0.225** | 0.760 | 0.388 | 0.18 | 0.111 | 2.85 | execution-error:48, wrong-filter-or-value:39, wrong-table-or-join:37 |
| q3-17b-gcdoff | gold_v1.jsonl | 60 | **0.200** | 0.750 | 0.45 | 0.1 | 0.0 | 1.97 | execution-error:15, wrong-filter-or-value:11, empty-when-expected:8 |
| q25c-15b-gcdon | gold_v1.jsonl | 60 | **0.200** | 0.533 | 0.55 | 0.033 | 0.0 | 3.18 | execution-error:28, wrong-aggregation:6, wrong-table-or-join:6 |
| q3-17b-gcdon | gold_v1.jsonl | 60 | **0.183** | 0.733 | 0.45 | 0.067 | 0.0 | 6.55 | execution-error:16, wrong-filter-or-value:11, empty-when-expected:8 |
| s2-q25c-3b-gcdon | gold_v2.jsonl | 200 | **0.155** | 0.675 | 0.286 | 0.113 | 0.111 | 6.29 | execution-error:65, wrong-filter-or-value:39, wrong-table-or-join:29 |
