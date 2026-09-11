# v1 Build Plan — Grounded transcript retrieval

`PROJECT_PLAN.md` is the spec: what GroundTruth is and what each version must achieve.
This document is the **execution breakdown for v1 only** — the ordered sequence of steps,
the decisions already made, and the reasoning behind the ones that aren't obvious.

v1 is deliberately built as ~15 small steps rather than one pass. The spec's done-bar is
*"every chunking and retrieval decision can be explained without hedging"* — code written
faster than it can be understood fails that bar regardless of whether it works.

Two ordering rules from the spec drive the sequence: get **one video queryable end-to-end**
before improving any single stage, and build **click-to-seek early, not last**.

---

## Locked decisions

| Area | Choice | Note |
|---|---|---|
| Corpus | 8 MIT OCW blockchain/finance lectures (15.S12), ~8-10h | Satisfies standing rule #1, "one corpus, deep" |
| Transcription | faster-whisper, `word_timestamps=True`, on host | See "Ingestion runs on the host" below |
| Embeddings | sentence-transformers BGE-small-en-v1.5, 384 dims | Sets `vector(384)` in the schema |
| Generation | `claude-opus-5` via the `anthropic` SDK, structured outputs + streaming | Uses `output_config.format`, not the deprecated `output_format` |
| Backend | FastAPI, Python 3.11 | |
| Frontend | React + TypeScript (Vite) | |
| Player | Local MP4 served by FastAPI, `<video>`, `currentTime = start_s` | |
| Database | Postgres 18 + pgvector 0.8.6 (pinned via `pgvector/pgvector:pg18`) | Already running in compose |

The corpus is the blockchain/finance subset of `data/youtube_videos.md`. The remaining
lectures in that file (nuclear engineering, quantum physics, brain science, game theory,
statistics) are **out of scope** — a topically scattered corpus makes cross-video retrieval
trivially easy and proves nothing, which is exactly what standing rule #1 warns against.

---

## Two structural decisions

### Ingestion runs on the host, not in a container

The intuitive assumption is that this is a GPU tradeoff. It is not. faster-whisper is built
on CTranslate2, which has **no Metal backend** — transcription is CPU-only on the host *and*
inside a container. There is no acceleration being given up either way.

The actual costs of containerizing ingestion are image size (~3-4GB once torch, ctranslate2,
and model weights are in), memory headroom (Docker Desktop is allocated 8.3GB on the
development machine), and iteration speed on ingestion code.

So Compose runs `db` + `api`. Ingestion is a host CLI that writes to the Compose Postgres
over `localhost:5432`. An `ingest` service remains defined in `docker-compose.yaml` under
`profiles: [ingest]` so it stays documented and reproducible without being the daily path.

This does not violate the spec's environment-parity goal: **ingestion is a one-time offline
batch job whose output is a database, not a service.** The serving path — the only thing a
contributor or a deployment needs to reproduce — stays fully containerized.

### No vector index in v1

Roughly 10 hours of lecture speech is ~110-120k tokens, which at a few hundred tokens per
chunk yields **400-1,200 chunk rows**. An exact sequential scan over 1,200 × 384 floats is
sub-millisecond.

HNSW and IVFFlat both return *approximate* results, which would quietly corrupt the recall@k
measurements v2 is built on. IVFFlat in particular is actively wrong below ~1k rows. Vector
indexes start earning their cost near 50k-100k rows — that is v4's frame embeddings, not
v1's chunks.

This is a recorded decision, not an oversight.

---

## Phase A — Walking skeleton

### Step 0 — Toolchain
Install `ffmpeg`, `yt-dlp`, and `uv`. Create `pyproject.toml` (fastapi, uvicorn, psycopg,
sqlalchemy, alembic, pydantic-settings, ruff, pytest). Fix the misspelled `data/transcipts`
directory.

**Verify:** `ffmpeg -version`, `yt-dlp --version`, `uv run pytest` exits clean with 0 tests.

### Step 1 — FastAPI in Compose
`src/backend/` with a Dockerfile and `GET /health` that runs `SELECT 1` against Postgres and
reports the pgvector version. Add the `api` service with
`depends_on: {db: {condition: service_healthy}}`.

**Verify:** `docker compose up` → `curl localhost:8000/health` returns database and
extension info.
**Concepts:** Compose service networking (`db` as a hostname), healthcheck gating, pooling.

### Step 2 — Schema and migrations
Alembic, plus a first migration creating `videos`, `transcripts`, and `chunks` per the spec's
data model. Columns worth adding now so later steps don't become migrations:

- `chunks.strategy`, `chunks.params jsonb`, `chunks.embedding_model`
- `UNIQUE (video_id, strategy, chunk_index)` — both chunking strategies must coexist in one
  table, otherwise "switchable" (step 12) degrades into a full re-ingest
- `chunks.tsv` as `GENERATED ALWAYS AS (to_tsvector('english', text)) STORED`, plus a GIN
  index — free at this scale, and makes step 13a a query change rather than a schema change
- `chunks.first_word_idx` / `last_word_idx` into the cached transcript JSON — this is what
  makes the timestamp invariant *testable*

**Verify:** `alembic upgrade head`, then `\d chunks` shows `vector(384)` and the generated `tsv`.

## Phase B — One video, end to end

### Step 3 — Acquire and extract audio
Curate `data/youtube_videos.md` to the 8 in-scope lectures. `yt-dlp` **one** video into
`data/videos/`, then ffmpeg to 16kHz mono WAV in `data/audio/`. Insert the `videos` row.

**Verify:** file on disk, duration matches `videos.duration_s`.
**Concepts:** why 16kHz mono is what Whisper expects; ffmpeg argument anatomy.

### Step 4 — Transcribe, cached
faster-whisper with `word_timestamps=True`. The **cache key is content-addressed:
`sha256(audio) + model + params`**, which structurally prevents the spec's first named trap
(re-transcribing during iteration). Raw JSON to `data/transcripts/`, then to the
`transcripts` table.

**Verify:** run twice — the second run is a cache hit and does zero work.
**Expect:** ~8-15 min per hour of audio on `large-v3` int8; ~3-6 min on `distil-large-v3`.

### Step 5 — Chunking strategy #1 (fixed token window with overlap)
Flatten the transcript into a **word-level array** and window over that. `start_s =
words[i].start`, `end_s = words[j].end`. Never interpolate, never average, never inherit the
previous chunk's `end_s`.

The invariant test ships in this same step (`tests/test_chunk_invariant.py`, runs against
cached JSON, under a second, no LLM):

- `0 <= start_s < end_s <= video.duration_s`
- `end_s - start_s <= token_count / 1.2` seconds — catches Whisper silence hallucinations
- `start_s` is non-decreasing across `chunk_index`
- **the round-trip:** re-derive the word list from the raw transcript over `[start_s, end_s]`
  and assert the chunk's first five and last five words appear in it

That last assertion is the load-bearing one. It catches the four most likely silent
breakages: overlap off-by-one (every chunk drifts late), null word timestamps collapsing to
`0.0` (the citation seeks to the start of the lecture and looks plausible), text
normalization desyncing word index from token slice, and counting tokens with a tokenizer
while slicing on whitespace.

### Step 6 — Embed into pgvector
BGE-small-en-v1.5 over chunks, batched, **normalized at write time** so `<=>` and `<#>` agree.

**Verify:** `SELECT count(*) FROM chunks WHERE embedding IS NOT NULL`; dimension is 384.

### Step 7 — Retrieval endpoint
`GET /search?q=` ordering by `embedding <=> query_embedding`.

**BGE asymmetry:** prefix the *query* only with
`"Represent this sentence for searching relevant passages: "`. Passages get no prefix.
Omitting this costs measurable recall and is invisible in testing.

**Freeze the response contract here:**
`{chunks: [{id, video_id, text, start_s, end_s, score}]}`. Step 9 adds a separate `/ask`
endpoint that reuses this exact chunk shape, so the frontend's results list and seek handler
survive step 9 untouched. This is what makes building the UI before generation cost nothing.

## Phase C — The demo

### Step 8a — Prove HTTP Range requests
FastAPI serves MP4 at `/media/{video_id}` — never a filesystem path in `src`, so deployment
doesn't later force a frontend change. Plus a ~20-line static HTML page with a `<video>` and
hardcoded seek buttons.

This is separated deliberately: `<video>` seeking against an endpoint that ignores Range
headers silently degrades to a full-file download, or fails to seek at all. Starlette's
`FileResponse` handles Range; a naive `Response(f.read())` does not. Better to discover that
here than in the middle of debugging React.

### Step 8b — React frontend
Vite + React + TS. Query box → `/search` → results list → clicking a result sets
`video.currentTime = start_s`.

**This is the milestone where the demo exists.** Click a result, land on the moment.

### Step 9 — Generation with structured citations
`/ask` using `claude-opus-5`, streamed, returning claim→`chunk_id` mappings as structured
output — not prose with citations glued on afterward.

### Step 10 — Grounding verifier
A second pass checking each claim is actually supported by the chunk it cites. Placed here
on purpose: it's the same structured-output work, while the generation code is still fresh.

## Phase D — Deepen

### Step 11 — Batch-ingest the remaining 7 videos, and label 20 questions
The ingest is a background batch job, not a working session — start it during step 8.

While reviewing the ingested videos, hand-label **~20 question→timestamp pairs**. These are
required, not optional: step 13b has to measure whether hybrid retrieval helped, and standing
rule #3 requires v1 to produce a number. No labels, no measurement.

### Step 12 — Chunking strategy #2 (boundary-aware), switchable
Pause, sentence, and speaker-turn boundaries, selected via `chunks.strategy`. Both strategies
live in the table simultaneously. Record why each boundary choice was made.

### Step 13 — Hybrid retrieval, measured
- **13a:** full-text query over the existing `tsv` column with `ts_rank`
- **13b:** RRF fusion, then measure recall@k against the step-11 labels

Per standing rule #4: if hybrid doesn't beat cosine alone, **cut it and write down why.** A
negative result here is a deliverable, not a failure.

### Step 14 — Deploy
Decide before starting: ~10GB of MP4s do not deploy as-is. Either object storage (R2/S3)
behind the existing `/media/{video_id}` route, or a YouTube-embed fallback player in
production with the local `<video>` in development.

Never run ingestion in the cloud — ingest locally, then `pg_dump` and restore.

---

## v1 acceptance

1. `docker compose up` → `/health` green
2. `uv run pytest` → invariant tests pass across every ingested video
3. A question in the deployed UI returns a cited answer, streamed
4. Clicking any citation lands the player on the moment the claim came from
5. A recall@k number exists, comparing both chunking strategies and hybrid vs. cosine

## Standing-rule checkpoints

- **Rule 3 — every version produces a number:** satisfied at 13b, enabled by the labels at 11
- **Rule 4 — cut what doesn't measurably help:** the explicit decision point is 13b
- **Decisions recorded so far:** no vector index at v1 scale; ingestion deliberately outside
  Docker; corpus narrowed to the blockchain/finance subset
