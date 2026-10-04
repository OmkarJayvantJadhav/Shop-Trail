"""Run the queries in a SQL file, building tables and exporting results.

Each query block starts with a marker line:
    -- @run: <label>          execute the statement (for example CREATE TABLE ... AS)
    -- @export: <file>.csv    run the query and save the result to data/processed/<file>.csv
Anything above the first marker (the business-question comment) is ignored.
Unqualified table names resolve to the --dataset in your BigQuery project.

Usage (from the repo root):
    python scripts/run_sql.py sql/02_sessions.sql --dry-run
    python scripts/run_sql.py sql/02_sessions.sql
"""
import argparse
import csv
import re
import sys
from pathlib import Path

from google.api_core.exceptions import NotFound
from google.cloud import bigquery

OUT_DIR = Path(__file__).resolve().parent.parent / "data" / "processed"
MARKER = re.compile(r"^--\s*@(run|export):\s*(\S+)\s*$", re.MULTILINE)


def split_blocks(text):
    """Return [(kind, name, sql), ...] for every marked block in the file."""
    parts = MARKER.split(text)  # [preamble, kind1, name1, sql1, kind2, name2, sql2, ...]
    return [(parts[i], parts[i + 1], parts[i + 2].strip().rstrip(";")) for i in range(1, len(parts), 3)]


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("sql_file")
    parser.add_argument("--dry-run", action="store_true", help="validate and show bytes scanned only")
    parser.add_argument("--project", help="billing project (default: gcloud / ADC project)")
    parser.add_argument("--dataset", default="shoptrail_clean", help="dataset for the clean tables")
    parser.add_argument("--max-gb", type=float, default=5, help="refuse queries that would bill more than this")
    args = parser.parse_args()

    blocks = split_blocks(Path(args.sql_file).read_text(encoding="utf-8"))
    if not blocks:
        sys.exit("No '-- @run:' or '-- @export:' markers found.")

    client = bigquery.Client(project=args.project)
    dataset_id = f"{client.project}.{args.dataset}"

    if not args.dry_run and any(kind == "run" for kind, _, _ in blocks):
        dataset = bigquery.Dataset(dataset_id)
        dataset.location = "US"  # same location as the public GA4 sample
        client.create_dataset(dataset, exists_ok=True)

    OUT_DIR.mkdir(parents=True, exist_ok=True)

    for kind, name, sql in blocks:
        if args.dry_run:
            config = bigquery.QueryJobConfig(dry_run=True, use_query_cache=False, default_dataset=dataset_id)
            try:
                job = client.query(sql, job_config=config)
            except NotFound:
                print(f"{name}: skipped (needs a table built earlier in this file)")
                continue
            print(f"{name}: would scan {job.total_bytes_processed / 1e6:,.1f} MB")
            continue

        config = bigquery.QueryJobConfig(maximum_bytes_billed=int(args.max_gb * 1e9), default_dataset=dataset_id)
        job = client.query(sql, job_config=config)
        rows = job.result()

        if kind == "run":
            print(f"{name}: done ({(job.total_bytes_billed or 0) / 1e6:,.1f} MB billed)")
            continue

        path = OUT_DIR / name
        with path.open("w", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            writer.writerow([field.name for field in rows.schema])
            for row in rows:
                writer.writerow(row.values())
        print(f"{name}: {rows.total_rows:,} rows -> {path.relative_to(OUT_DIR.parent.parent)}")


if __name__ == "__main__":
    main()
