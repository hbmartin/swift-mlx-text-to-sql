def unsafe_identity(database_inputs):
    # ruleid: creg-database-identity-requires-canonical-inputs
    return database_set_identity(database_inputs)


def safe_identity(database_paths):
    database_paths, database_inputs = canonicalize_database_inputs(database_paths)
    # ok: creg-database-identity-requires-canonical-inputs
    return database_set_identity(database_inputs)
