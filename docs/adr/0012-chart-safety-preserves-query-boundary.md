# Chart safety preserves the query boundary

CREG captures exact physical reads and direct result-column origins while SQLite prepares the executed statement. A shared, query-block-aware analyzer combines that evidence with the frozen schema to derive output lineage, effective row grain, and aggregate semantics; grounding and chart presentation consume the same analysis rather than maintaining separate SQL scanners.

CREG supplies the resulting Chart Provenance to AutoTableCharts. AutoTableCharts may reject a presentation and return a Chart Safety Finding, but it never repairs already-aggregated rows; a correction that changes values must return through CREG's validated read-only query pipeline.
