# Learning notes

Concepts worked through while building GroundTruth, in plain language. For
project decisions and their reasons, see `decisions.md`.

## Dockerfile vs. compose file

- A **Dockerfile** is the recipe for building **one image** (base image, install
  dependencies, copy code, start command). The backend and frontend each get one.
- A **compose file** describes how to **run several containers together**: which
  services exist, which image or Dockerfile each uses, plus environment, ports,
  volumes and start order.
- The `db` service needs no Dockerfile: it uses a prebuilt image
  (`pgvector/pgvector:pg18`). Our own code uses `build: ./src/backend`.
- Docker's default Dockerfile name is `Dockerfile`; on Linux, `DockerFile` is a
  different name and will not be found by default.

## How the services will fit together

```
frontend (React) --HTTP--> backend (FastAPI) --SQL--> db (Postgres + pgvector)
                                  ^
                  ingestion worker (ffmpeg, Whisper, chunk, embed) --SQL--> db
```

Compose puts all services on one private network and each service name is a
hostname, so the backend connects to `db:5432`, not `localhost`. Only ports listed
under `ports:` are reachable from the host machine.

## Named volumes vs. bind mounts

| | Named volume | Bind mount |
|---|---|---|
| Example | `pgdata:/var/lib/postgresql` | `./src/backend/db:/docker-entrypoint-initdb.d` |
| Left side | a name | a path on your computer |
| Managed by | Docker (hidden storage) | you (a real folder in the project) |
| Declared under `volumes:` | yes | no |
| Survives `docker compose down` | yes (only `down -v` deletes) | yes (they are your files) |
| Use for | data the container produces (database files) | files you write and want the container to see (init scripts, config) |

Format is `HOST_PATH:CONTAINER_PATH`. A bind mount is the same folder seen from two
places, not a copy. The Postgres image runs every `.sql`/`.sh` file in
`/docker-entrypoint-initdb.d` in alphabetical order, **only when the data directory
is empty** (first start on a fresh volume). Editing a script does not change an
existing database; use `docker compose down -v` to re-test.

## `.env` and `${...}` substitution

Compose automatically loads a `.env` file from the folder containing the compose
file. `${VAR}` is replaced by compose itself before anything reaches a container.
`${VAR:-default}` uses the default when the variable is unset or empty.
`.env` feeds substitution in the compose file only; a container receives a variable
only if it is listed under `environment:` (or `env_file:`). `docker compose config`
prints the file with everything resolved.

## The healthcheck

```yaml
test: ["CMD-SHELL", "pg_isready -U $$POSTGRES_USER"]
interval: 5s
retries: 5
```

- Docker runs `test` inside the container on a schedule; exit code 0 = healthy.
- `CMD` runs a program directly (no shell); `CMD-SHELL` runs the string through
  `/bin/sh -c`, needed for `$VARIABLES`, pipes, `&&`.
- `pg_isready` asks "are you accepting connections?" without logging in.
- `$$` escapes compose's own substitution: compose passes a literal
  `$POSTGRES_USER` and the container's shell expands it. With a single `$`, compose
  would substitute from `.env` and would miss defaults set elsewhere in the file.
  (`$(...)` is shell command substitution and is unrelated.)
- Status shows in `docker compose ps`: `starting` → `healthy` or `unhealthy`. Later,
  other services use `depends_on` with `condition: service_healthy`.

## Commands

| Command | Does |
|---|---|
| `docker compose up` | create and start services, attached to the terminal |
| `docker compose up -d` | `-d` = detached, run in the background |
| `docker compose up --build` | rebuild images from Dockerfiles first |
| `docker compose ps` | list services and health |
| `docker compose logs db` | service output (`-f` to follow) |
| `docker compose stop` | stop containers, keep them |
| `docker compose down` | remove containers and network, **keep** volumes |
| `docker compose down -v` | also remove volumes — **wipes the database** |
| `docker compose exec db <cmd>` | run a command in a running container |
| `docker compose config` | show the resolved compose file |
| `docker ps` / `docker images` / `docker volume ls` | plain Docker listings |

Open a SQL shell:

```bash
docker compose exec db psql -U groundtruth -d groundtruth
```

`-U` is the user and `-d` the database (match `POSTGRES_USER` / `POSTGRES_DB`). No
password is needed from inside the container. In psql: `\dx` extensions, `\dt`
tables, `\d chunks` describe a table, `\q` quit.

## Embeddings and vector size

- An embedding model turns text into a list of numbers. The list length is the
  **dimension**. Similar meaning → similar direction.
- The column is declared `vector(N)` and every embedding, corpus and query, must have
  exactly that length.
- Voyage voyage-4 models share an embedding space; request the same
  `output_dimension` from every model. See `decisions.md` for the choice.

## Schema concepts

- **Foreign key** (`REFERENCES videos(id)`): Postgres rejects a row whose `video_id`
  does not exist in `videos`. **`ON DELETE CASCADE`**: deleting a video also deletes
  its transcripts and chunks.
- **`NOT NULL` on `video_id`, `start_s`, `end_s`** enforces the project invariant:
  every chunk knows its video and time range. `CHECK (end_s > start_s)` rejects
  impossible ranges.
- **`JSONB`** stores JSON in a queryable form; `transcripts.raw_json` is the Whisper
  cache.
- **Generated column**: `tsv tsvector GENERATED ALWAYS AS (to_tsvector('english', text)) STORED`
  - `tsv` is the name, `tsvector` the type.
  - `GENERATED ALWAYS AS (expr)`: Postgres computes it from the expression; you can
    never insert into it and it cannot drift out of sync with `text`.
  - `STORED`: computed once at write time and saved on disk. (`VIRTUAL` would compute
    on every read and cannot be indexed.)

## Full-text search (`tsvector`)

A `tsvector` is **not** an embedding. It is a normalized list of words with
positions: lowercased, filler words dropped, words reduced to roots. The search query
gets the same treatment, so "run model" matches "The models are running". Embeddings
find same-meaning text but can blur exact terms (model names, acronyms); keyword
search is exact but blind to synonyms. Combining them is hybrid retrieval, which the
plan says to measure and cut if it does not help. Example query shape:
`WHERE tsv @@ plainto_tsquery('english', 'attention mechanism')`.

## Indexes

An index is an extra structure that lets Postgres jump to matching rows instead of
reading every row. Costs: a bit of disk and slightly slower inserts.
`CREATE INDEX name ON table USING method (column)`.

- **B-tree** (default) on `video_id`: ordinary lookups ("all chunks of video 7").
  Postgres does not auto-index foreign keys.
- **HNSW** on `embedding`: Hierarchical Navigable Small World, a layered graph of
  neighbor links; search hops toward the target and checks a tiny fraction of the
  vectors. **Approximate**: it can occasionally miss the true nearest neighbor.
  `vector_cosine_ops` builds it for cosine distance (direction), the standard for
  text embeddings.
- **GIN** on `tsv`: Generalized Inverted Index, word → list of chunks containing it
  (like a book's index). Each distinct word is stored once, with a compressed list of
  chunk IDs, so it stays small.

### Does Postgres use them automatically?

Yes, the query planner decides; you never name an index. But the query must be
written in a form the index can serve:

| Index | Query shape |
|---|---|
| `chunks_video_idx` | `WHERE video_id = 7` |
| `chunks_embedding_idx` | `ORDER BY embedding <=> $query_vec LIMIT 10` |
| `chunks_tsv_idx` | `WHERE tsv @@ plainto_tsquery('english', 'attention')` |

The HNSW index built with `vector_cosine_ops` is only used with `<=>`; `<->` (L2)
silently falls back to a full scan. The planner may also skip an index on a tiny
table because reading everything is cheaper. Check with `EXPLAIN SELECT ...`
(`Index Scan` vs `Seq Scan`), or `EXPLAIN ANALYZE` to actually time it.

## Nearest-neighbor search

- **KNN** is the goal ("find the k closest vectors"), not a method.
- **Exact KNN** (brute force): distance to every vector, keep the k smallest.
- **ANN** (approximate): far fewer distance computations, tiny accuracy loss.
  - **HNSW**: layered neighbor graph.
  - **IVFFlat**: pre-cluster the vectors, search only the nearest clusters; builds
    faster and smaller but is usually less accurate, and needs data before building.
  - **Quantization**: store compressed vectors so each distance is cheaper.

## How big is "big"?

For ~15 hours of talks: ~135k words (~1 MB of text), ~1–2k chunks, ~4 KB per
embedding (1024 × 4 bytes) → under 10 MB of vectors; raw Whisper JSON maybe 10–30 MB.
The whole database is likely under 100 MB. Rough limits for Postgres: ordinary tables
fine to millions of rows; brute-force vector search fine up to roughly 10k–100k
vectors; HNSW worthwhile from a few hundred thousand up; GIN fine for millions of
documents. The slow parts of this project are Whisper transcription (hours on CPU)
and LLM answer generation (seconds per query), not the database. Estimate first
(rows × bytes vs. RAM), then measure.
