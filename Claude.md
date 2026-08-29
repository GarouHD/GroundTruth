# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

This repository is a bare scaffold. There is no application code yet — `src/`,
`tests/`, `evals/`, and `data/` each contain only a `.gitkeep`. There is no
`package.json`, `pyproject.toml`, `docker-compose.yml`, or lockfile, so there
are no build/lint/test commands to run yet. `PROJECT_PLAN.md` is the actual
spec: read it in full before writing any code, and set up tooling (Docker
Compose, FastAPI backend, React/TypeScript frontend, Postgres+pgvector) as
described there rather than guessing a stack.

## What GroundTruth is

A search engine for the *content* of a video library rather than its
metadata/titles. Given a folder of recordings, it transcribes them, chunks the
transcripts into timestamped passages, embeds the passages, and answers
natural-language questions by retrieving passages, drafting a cited answer,
and verifying each citation actually supports its claim before showing it.
Every citation in the frontend is clickable and seeks the video player to that
exact timestamp — this is the core interaction and the whole point of the
project.

## Architecture (from PROJECT_PLAN.md)

```
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

### Data model (Postgres)

```
videos      (id, title, source_url, duration_s, language, license, ingested_at)
transcripts (id, video_id, model, raw_json)
chunks      (id, video_id, text, start_s, end_s, speaker, token_count,
             embedding vector(N), tsv tsvector)
frames      (id, video_id, ts_s, image_uri, clip_embedding vector(N), ocr_text)  -- v4
queries     (id, text, created_at, cost_usd, latency_ms, model, route)           -- v2
eval_labels (id, question, video_id, start_s, end_s, answerable)                 -- v2
```

**The one non-negotiable invariant: every chunk carries the video and the time
range it came from, and that mapping survives every transformation.** A
citation that points at the wrong moment is worse than no citation. Any code
touching chunking, embedding, storage, or retrieval must preserve this.

## Build order (versions are sequential milestones, not features to mix)

The plan is deliberately staged as v1 → v5, each with its own "done" bar and a
required measurement. Do not jump ahead to a later version's feature (agent
loops, MCP server, visual retrieval, production Docker hardening) while an
earlier version is incomplete — see the "Standing rules" below.

- **v1 — Grounded transcript retrieval.** Docker Compose (FastAPI app +
  Postgres/pgvector + ingestion worker) from day one, with a pinned
  Postgres/pgvector version and `.env.example`. This compose setup is for dev
  environment parity only — do not spend v1 effort hardening it into a
  production image (that's v5). Ingestion (ffmpeg + Whisper), two switchable
  chunking strategies (fixed token window w/ overlap, and boundary-aware),
  embeddings into pgvector, retrieval starting at top-k cosine then adding
  full-text + RRF fusion (measure whether hybrid actually helps — cut it if
  not), structured-output generation with claim-to-chunk-id citations, FastAPI
  backend, React/TypeScript frontend where clicking a citation seeks the
  player. Build the click-to-seek interaction early, not last. Cache
  transcriptions — never re-run Whisper as part of iteration.
- **v2 — Evals, cost, observability.** ~100 labeled question-to-timestamp
  pairs in `eval_labels` (including ~15 unanswerable questions), retrieval
  metrics (recall@k, MRR, hit rate) compared across both v1 chunking
  strategies, code-based answer evals, an LLM-as-judge validated against the
  human labels with agreement rate recorded, OpenTelemetry + Langfuse/LangSmith
  tracing logged to `queries`, and measured-before/after optimizations
  (prompt/embedding/retrieval caching, cheaper model on the easy path). A
  model router (lookup vs. synthesis classification) is only kept if it
  measurably earns its cost/quality tradeoff.
- **v3 — Agent, tools, MCP.** Hand-write the agent loop first (no framework)
  with tools like `search_transcript`, `get_video_metadata`, `get_segment`,
  `cut_clip`, `concat_clips`, including real failure handling (iteration caps,
  timeouts, retries, tool-argument validation, graceful degradation). Then
  port to LangGraph, keeping the hand-written version in the repo as a
  reference. Author an MCP server (not just consume one) and validate it
  against a real MCP client. Treat transcript content as untrusted input —
  prompt injection defense is a required, not optional, part of this stage.
- **v4 — The visual channel.** Scene-detection frame sampling, CLIP-style
  image embeddings in a second pgvector index, OCR on slide frames, fusion of
  transcript/OCR/frame-similarity hits, plus visual-only eval questions that
  prove this stage's value numerically.
- **v5 — Infrastructure and packaging.** Harden the v1 Docker setup into a
  real multi-stage production build (this is the first time image
  size/build-speed work is in scope). GitHub Actions running lint, tests, and
  the eval suite as a merge gate — a prompt change that regresses retrieval
  hit rate should fail CI. Cloud deploy (ECS/Fargate or App Runner, RDS
  Postgres+pgvector, S3, Secrets Manager, CloudWatch).

## Standing rules for this project

1. **One corpus, deep.** The eval set and retrieval tuning are built against
   one concrete corpus (recommended: 10–20 hours of clearly-licensed,
   factually dense, slide-heavy AI/ML conference talks). Don't generalize
   before that corpus is well-served.
2. **Ship each version publicly before starting the next**: deployed URL,
   public repo, written case study.
3. **Every version must produce a number.** A version with no measurement
   (retrieval hit rate, judge agreement rate, cost/latency before-and-after,
   etc.) is not done — don't mark it complete without one.
4. **Cut anything that doesn't measurably help** (a router, a reranker, a
   caching layer) and write down that it was cut and why. Negative results
   are part of the deliverable, not a failure to hide.
5. Avoid the known traps called out per-version in `PROJECT_PLAN.md` —
   notably: re-transcribing video during iteration instead of caching;
   polishing ingestion before anything is queryable end-to-end; treating
   chunking strategy as a settled default; building an LLM-as-judge before
   human labels exist to validate it against.
