struct HistoryMigrationSQL {
  // ruleid: creg-history-migrations-forbid-unconditional-deletes
  let destructive = "DELETE FROM message;"

  // ok: creg-history-migrations-forbid-unconditional-deletes
  let scoped = "DELETE FROM message WHERE conversation_id = ?;"

  // ok: creg-history-migrations-forbid-unconditional-deletes
  let unrelated = "DELETE FROM transient_chart_cache;"
}
