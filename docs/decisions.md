# Decisions log

A running record of project decisions: what was chosen, what the alternatives
were, and why. Newest entries go at the bottom. Include a measured result
whenever one exists, and record anything that was **cut** and why (negative
results are part of the deliverable — see standing rule 4 in `CLAUDE.md`).

Entry format:

```
## Short title
**Chose:** what we picked
**Alternatives:** what else was considered
**Why:** the reasoning (and the measured number, once there is one)
**Status:** active | revisit after <milestone> | cut
```

---

## Postgres 18 + pgvector image, pinned
**Chose:** `pgvector/pgvector:pg18` in `docker-compose.yaml`, with the data volume
mounted at `/var/lib/postgresql` (not `/var/lib/postgresql/data`).
**Alternatives:** plain `postgres` image plus installing pgvector by hand; an
older Postgres major version.
**Why:** the image ships Postgres with pgvector already compiled in. The version is
pinned because major-version upgrades need a data migration, so it should only
change on purpose. Postgres 18 expects the mount one level up and manages a
version-specific subdirectory itself.
**Status:** active

## Schema created by init scripts, not migrations (for now)
**Chose:** SQL files in `src/backend/db/`, bind-mounted to
`/docker-entrypoint-initdb.d`. Postgres runs them once, on first start with an empty
volume.
**Alternatives:** a migration tool (Alembic, etc.).
**Why:** simplest option while the schema is still changing and there is no real data.
Editing a script does not change an existing database; re-test with
`docker compose down -v` (wipes data).
**Status:** revisit once real data exists that is expensive to lose (cached
transcripts are the main candidate).

## Embeddings: Voyage voyage-4 family at 1024 dimensions
**Chose:** the voyage-4 model family, requesting `output_dimension=1024`, so
`chunks.embedding` is `vector(1024)`.
**Alternatives:** local open-source models (e.g. bge-base, 768 dims); other hosted
APIs (OpenAI, Cohere).
**Why:** all voyage-4 models (large, standard, lite, nano) produce compatible
embeddings, so the corpus can be embedded with the large model and queries with a
cheaper one. 1024 is the default and is under pgvector's 2000-dimension limit for
HNSW indexes on the `vector` type (2048 would not be indexable). The same
`output_dimension` must be requested from every model used. Use `input_type`
`document` for chunks and `query` for questions.
**Status:** revisit after the v2 retrieval metrics exist (compare against a local
model if cost or quality is a concern).

## Index choices on `chunks`
**Chose:** B-tree on `video_id`; HNSW with `vector_cosine_ops` on `embedding`; GIN on
the generated `tsv` column.
**Alternatives:** IVFFlat for the vector index; no vector index (brute force).
**Why:** the corpus is small (~1–2k chunks), so brute force would also be fast and the
indexes will not show a speedup yet. They are built now as the standard pattern.
Queries must use `<=>` (cosine) for the HNSW index to be used.
**Status:** revisit in v2: measure HNSW recall against exact search on this corpus.
