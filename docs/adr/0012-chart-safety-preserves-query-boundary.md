# Chart safety preserves the query boundary

CREG derives Chart Provenance from its frozen schema and executed SQL and supplies it to AutoTableCharts. AutoTableCharts may reject a presentation and return a Chart Safety Finding, but it never repairs already-aggregated rows; a correction that changes values must return through CREG's validated read-only query pipeline.
