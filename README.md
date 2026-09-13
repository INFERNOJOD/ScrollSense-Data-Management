# ScrollSense — Data Management Assignment 1

## Overview

This repository contains the SQLite implementation of the ScrollSense database for Data Management Assignment 1.

The implementation includes:

- relational schema and constraints
- synthetic data generation
- analytical SQL queries
- database views
- transaction and concurrency demonstrations
- JSON usage for tool-call arguments

Database used: **SQLite 3.44+**

---

## Required Source Files

The repository contains exactly the six required source files:

| File | Purpose |
|---|---|
| `schema.sql` | Relational schema, keys, constraints, indexes and triggers |
| `views.sql` | Required database views for Deliverable G |
| `transactions.sql` | Transaction, isolation and concurrency demonstrations for G.3 |
| `generate_data.py` | Parameterized, reproducible synthetic data generator |
| `queries.sql` | Numbered analytical SQL queries for Deliverable F |
| `README.md` | Setup, execution and verification instructions |

The written deliverables are submitted separately as **one PDF**.

---

## Requirements

- SQLite 3.44 or later
- Python 3
- Python standard library only

No external Python packages are required.

Check the SQLite version with:

```bash
sqlite3 --version
```

---

## Setup

Create a fresh database and load the schema:

```bash
rm -f scrollsense.db scrollsense.db-wal scrollsense.db-shm
sqlite3 scrollsense.db < schema.sql
```

The schema begins by enabling foreign-key enforcement and WAL mode, as required by the assignment.

Generate the synthetic dataset:

```bash
python3 generate_data.py scrollsense.db
```

Create the required views:

```bash
sqlite3 scrollsense.db < views.sql
```

Run the analytical queries:

```bash
sqlite3 scrollsense.db < queries.sql
```

---

## Recommended Fresh Run

To recreate the database from scratch:

```bash
rm -f scrollsense.db scrollsense.db-wal scrollsense.db-shm

sqlite3 scrollsense.db < schema.sql
python3 generate_data.py scrollsense.db
sqlite3 scrollsense.db < views.sql
sqlite3 scrollsense.db < queries.sql
```

The generator uses the student's roll number as the random seed, as required by the assignment. The generator is parameterized through its command-line options and uses only the Python standard library.

---

## Default Data Volumes

The default generator volumes required by the assignment are:

- 5,000 users
- 20,000 videos
- 300,000 impressions
- 2,000 agent sessions

Run the generator with:

```bash
python3 generate_data.py scrollsense.db
```

The generated data is synthetic.

---

## Checking the Database

Check the SQLite version:

```bash
sqlite3 scrollsense.db "SELECT sqlite_version();"
```

Check foreign-key enforcement for the current SQLite connection:

```bash
sqlite3 scrollsense.db "PRAGMA foreign_keys = ON; PRAGMA foreign_keys;"
```

The result should be:

```text
1
```

Note that SQLite's `foreign_keys` setting is connection-specific, so a newly opened SQLite connection may report `0` unless foreign keys are enabled for that connection.

Check the tables:

```bash
sqlite3 scrollsense.db ".tables"
```

Check the required views:

```bash
sqlite3 scrollsense.db "SELECT name FROM sqlite_master WHERE type = 'view' ORDER BY name;"
```

---

## Queries

`queries.sql` contains the 13 numbered analytical queries required for Deliverable F.

Run them with:

```bash
sqlite3 scrollsense.db < queries.sql
```

The file includes the SQL for each query together with the requested result/reporting information.

The relational-algebra requirements for the specified queries and the selection-pushdown rewrite are documented in the written deliverables.

---

## Views

`views.sql` creates the five required views for Deliverable G.

Load them with:

```bash
sqlite3 scrollsense.db < views.sql
```

The views cover:

- public profile information
- current video moderation state
- current creator tier
- daily creator/video engagement
- historical turn cost using model pricing periods

---

## Transactions and Concurrency

`transactions.sql` contains the required G.3 transaction demonstrations.

Run the script with:

```bash
sqlite3 scrollsense.db < transactions.sql
```

The demonstrations involving multiple connections should be carried out using separate SQLite sessions, following the instructions and comments in `transactions.sql`.

SQLite WAL mode is enabled by `schema.sql`:

```sql
PRAGMA journal_mode = WAL;
```

This is required for the concurrency demonstration.

The transaction section demonstrates:

- rollback after a failed write
- visibility of uncommitted changes between connections
- the single-writer behavior of SQLite
- the expected `SQLITE_BUSY` behavior when a second writer conflicts with an open writer

---

## Important Design Points

- `schema.sql` enables foreign-key enforcement and WAL mode.
- `generate_data.py` also enables foreign-key enforcement on its database connection.
- Primary keys, foreign keys, `CHECK` constraints, uniqueness constraints, indexes and triggers are used where required.
- Temporal relationships are represented using validity intervals or event-log tables according to the design.
- Historical events that must be retained are stored as append-only records.
- JSON is used for tool-call arguments while keeping commonly queried attributes relational.
- The schema uses deferred foreign keys where required to support circular relationships during loading.
- Database triggers enforce rules that cannot be expressed using ordinary SQLite constraints alone.

---

## Reproducibility

The database can be recreated from the source files using the commands in the Setup section.

The random seed in `generate_data.py` is the student's roll number, as required by the assignment.

Generated database files such as:

- `scrollsense.db`
- `scrollsense.db-wal`
- `scrollsense.db-shm`

are generated artifacts and are not part of the six required source-file submission.

---

## Submission

The assignment submission consists of:

1. **One PDF** containing all required written deliverables.
2. **A repository containing exactly these six required source files:**
   - `schema.sql`
   - `views.sql`
   - `transactions.sql`
   - `generate_data.py`
   - `queries.sql`
   - `README.md`

Generated database files, temporary test files and other development artifacts should not be included among the six required source files.

---

## LLM Usage

LLM assistance was used during development for explanation, debugging and review of SQL/Python design.

The final implementation was checked against the assignment requirements and tested locally. The written report appendix documents an example where an initial LLM suggestion was incorrect and explains how the issue was identified and corrected.
