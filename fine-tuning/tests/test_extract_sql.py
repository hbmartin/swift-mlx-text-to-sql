from eval.run_eval import extract_sql, strip_special_tokens


def test_extract_sql_matches_swift_normalization():
    raw = (
        "<|im_start|>Here is the query:\n```sql\n"
        "SELECT name FROM properties;\n```<|im_end|>"
    )
    assert extract_sql(strip_special_tokens(raw)) == (
        "SELECT name FROM properties"
    )
    assert extract_sql(
        "analysis first\nWITH latest AS (SELECT 1) SELECT * FROM latest; trailing"
    ) == "WITH latest AS (SELECT 1) SELECT * FROM latest"


def test_extract_sql_keeps_semicolons_inside_string_literals():
    assert extract_sql(
        "SELECT name FROM tenants WHERE name = 'Acme; Inc'; trailing prose"
    ) == "SELECT name FROM tenants WHERE name = 'Acme; Inc'"
    assert extract_sql(
        "SELECT name FROM tenants WHERE name = 'O''Brien; Co' LIMIT 1;"
    ) == "SELECT name FROM tenants WHERE name = 'O''Brien; Co' LIMIT 1"
