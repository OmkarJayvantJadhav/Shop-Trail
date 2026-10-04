"""Run the queries in a SQL file and export each result to data/processed/.

Each query block starts with a marker line:   -- @export: <file>.csv
Anything above the first marker (the business-question comment) is ignored.

Usage (from the repo root):
    python scripts/run_sql.py sql/01_data_quality.sql --dry-run
    python scripts/run_sql.py sql/01_data_quality.sql
"""
import argparse
import csv
import re
import sys
from pathlib import Path

from google.cloud import bigquery

OUT_DIR = Path(__file__).resolve().parent.parent / "data" / "processed"
MARKER = re.compile(r"^--\s*@export:\s*(\S+)\s*$", re.MULTILINE)


def split_blocks(text):
    """Return [(csv_name, sql), ...] for every marked block in the file."""
    parts = MARKER.split(text)  # [preamble, name1, sql1, name2, sql2, ...]
    return [(parts[i], parts[i + 1].strip().rstrip(";")) for i in range(1, len(parts), 2)]


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("sql_file")
    parser.add_argument("--dry-run", action="store_true", help="validate and show bytes scanned only")
    parser.add_argument("--project", help="billing project (default: gcloud / ADC project)")
    parser.add_argument("--max-gb", type=float, default=5, help="refuse queries that would bill more than this")
    args = parser.parse_args()

    blocks = split_blocks(Path(args.sql_file).read_text(encoding="utf-8"))
    if not blocks:
        sys.exit("No '-- @export: <file>.csv' markers found.")

    client = bigquery.Client(project=args.project)
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    for name, sql in blocks:
        if args.dry_run:
            job = client.query(sql, job_config=bigquery.QueryJobConfig(dry_run=True, use_query_cache=False))
            print(f"{name}: would scan {job.total_bytes_processed / 1e6:,.1f} MB")
            continue
        config = bigquery.QueryJobConfig(maximum_bytes_billed=int(args.max_gb * 1e9))
        rows = client.query(sql, job_config=config).result()
        path = OUT_DIR / name
        with path.open("w", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            writer.writerow([field.name for field in rows.schema])
            for row in rows:
                writer.writerow(row.values())
        print(f"{name}: {rows.total_rows:,} rows -> {path.relative_to(OUT_DIR.parent.parent)}")


if __name__ == "__main__":
    main()
