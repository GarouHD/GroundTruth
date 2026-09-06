# GroundTruth

Ask a question in plain English about a library of videos and get an answer
with the exact moment it came from, verified against the source.

Video is the last major content type still searched by title and description
rather than by what's actually said and shown in it. GroundTruth transcribes a
video library, chunks and embeds the transcripts, and answers questions by
retrieving the passages that support the answer, citing them, and verifying
each citation actually says what the answer claims before showing it. Every
citation is clickable and seeks the video player straight to that timestamp —
the answer is never just trusted, it's checked in one click.

## Status

🚧 **Pre-v1 — scaffolding only.** Nothing is deployed yet. See the roadmap
below for what "done" looks like at each stage.

## Architecture

```text
video files
    -> ffmpeg audio extraction
    -> Whisper transcription (segment + word timestamps)
    -> chunking (timestamp-preserving)
    -> embedding
    -> Postgres + pgvector (vectors, metadata, full-text index)

query -> hybrid retrieval (vector + keyword, fused)
      -> reranking
      -> generation with structured citations
      -> grounding verifier
      -> React player that seeks to the cited timestamp
```

The one invariant the whole system is built around: **every chunk carries the
video and time range it came from, and that mapping survives every
transformation.** A citation pointing at the wrong moment is worse than no
citation at all.

## Roadmap

| Version | Goal                                                                                                       | Status         |
| ------- | ---------------------------------------------------------------------------------------------------------- | -------------- |
| v1      | Grounded transcript retrieval — ingest, chunk, embed, hybrid retrieval, cited generation, click-to-seek frontend | 🚧 in progress |
| v2      | Evals, cost, observability — labeled eval set, retrieval metrics, LLM-as-judge validated against human labels, tracing | ⬜ not started |
| v3      | Agent, tools, MCP — hand-written agent loop, LangGraph port, authored MCP server, prompt injection defense  | ⬜ not started |
| v4      | Visual channel — scene-detected frames, CLIP embeddings, OCR, multimodal fusion                             | ⬜ not started |
| v5      | Infrastructure — production Docker build, CI eval gate, cloud deploy                                        | ⬜ not started |

Each version ships with a deployed URL, a public commit history, and a
measured result before the next one starts — see `PROJECT_PLAN.md` for the
full spec, done-bars, and known traps per version.

## Corpus

10–20 hours of clearly-licensed, factually dense, slide-heavy AI/ML conference
talks. Transcribed once and cached — retrieval quality here is tuned against
this one corpus, not claimed to generalize.

## Getting started

Everything runs in Docker — you do not need Postgres, Python, or Node installed
locally.

**Prerequisites:** [Docker Desktop](https://docs.docker.com/desktop/) with the
WSL2 backend on Windows (the default), or Docker Engine on Linux/macOS.

```bash
cp .env.example .env    # then fill in POSTGRES_PASSWORD
docker compose up -d
```

Verify it came up:

```bash
docker compose ps
```

The `db` service should read `Up (healthy)`. Health here means Postgres is
actually accepting connections, not just that the container started — services
that depend on the database wait for this, so a cold `up` works on the first
try.

Open a SQL shell:

```bash
docker compose exec db psql -U groundtruth -d groundtruth
```

Useful once you're in: `\dx` lists installed extensions (`vector` should be
there), `\dt` lists tables, `\q` quits.

Stop everything:

```bash
docker compose down
```

### Things worth knowing

**`docker compose down -v` deletes the database.** The `-v` flag removes named
volumes, which is where all Postgres data lives. Plain `down` stops the
containers and leaves the data alone. Only reach for `-v` when you genuinely
want to start from an empty database.

**The Postgres volume mounts at `/var/lib/postgresql`, not
`/var/lib/postgresql/data`.** Postgres 18 changed this: it now wants a single
mount one level up and manages a version-specific subdirectory itself, so that
a future `pg_upgrade` can keep two versions side by side. Mounting the old path
fails at startup with a long "unused mount/volume" error. If you hit it after
changing the path, `docker compose down -v` clears the half-initialised volume.

**Postgres is pinned to `pgvector/pgvector:pg18`** — a full Postgres 18 server
with the pgvector extension already compiled in, so there is nothing extra to
install. The pin is deliberate: major-version upgrades need a data migration,
so the version should only change on purpose. The extension still has to be
enabled once per database with `CREATE EXTENSION IF NOT EXISTS vector;`, which
the schema migration handles.

## Docs

- [`PROJECT_PLAN.md`](./PROJECT_PLAN.md) — full spec, architecture rationale, and per-version build details
- `CLAUDE.md` — working instructions for AI-assisted development on this repo
