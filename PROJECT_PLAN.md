# GroundTruth

**One-line pitch:** Ask a question in plain English about a library of videos and
get an answer with the exact moment it came from, verified against the source.

**Why?** Video is the last major content type that is still
searched by title and description rather than by content.

**What it is.** GroundTruth is a search engine for the content of a video
library, not its metadata. Point it at a folder of recordings and it transcribes
them, breaks each transcript into timestamped passages, and embeds those
passages so they can be found by meaning, not just by matching words. Ask a
question and it retrieves the passages most likely to answer it, drafts an
answer that cites the specific passage behind each claim, and runs a verifier
that checks the citation actually supports what was said before the answer is
shown. In the frontend, every citation is clickable and jumps the video player
straight to that moment, so the answer is never just trusted, it's checked in
one click. Later versions extend the same retrieval index to what's on screen
(slides, diagrams) rather than only what's said, and add an agent that can act
on what it finds, such as pulling every relevant moment across a library into a
single cut. The name comes from the mechanism, not a slogan: every answer has to
be traceable back to its ground truth in the source video, and "ground truth" is
also the literal term for the labeled data the eval suite is built on.

---

## Corpus decision

**Recommended: 10 to 20 hours of public technical conference talks**, AI/ML focused.

Requirements the corpus must satisfy:

- **Clearly licensed.** Creative Commons conference recordings, or talks whose
  publishers permit reuse.
- **Factually dense**, so questions have checkable answers.
- **Slide-heavy**, which gives v4 a real visual retrieval use.
- **Small enough to transcribe once.** Transcribe, cache, and never re-run it as
  part of iteration.

---

## Architecture

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

The one non-negotiable invariant: **every chunk carries the video and the time
range it came from, and that mapping survives every transformation.** A citation
that points at the wrong moment is worse than no citation.

---

## v1 — Grounded transcript retrieval

**Goal:** a deployed system that answers questions from speech and cites the moment.

**Build:**

- **Docker Compose from day one.** The FastAPI app, a Postgres image with the
  pgvector extension, and an ingestion worker, all defined in one
  `docker-compose.yml` with a pinned Postgres/pgvector version, plus a
  `.env.example` for required secrets. Anyone on the project runs one command
  and has the identical database, extension version, and Python environment.
  This is dev tooling for environment parity across contributors, not the
  production image; a proper multi-stage build and image-size work happen in
  v5. Do not spend v1 time hardening the image, just make it reproducible.
- Ingestion pipeline: ffmpeg audio extraction, Whisper transcription with
  timestamps, persistence to Postgres.
- Chunking. This is the interesting engineering, not a detail. Implement at least
  two strategies and keep them switchable:
  1. fixed token window with overlap
  2. boundary-aware (speaker turn, or pause and sentence boundary)

  Record why each boundary choice was made.
- Embeddings into pgvector.
- Retrieval: start with top-k cosine. Then add Postgres full-text search and fuse
  the two (reciprocal rank fusion is the simple default). **Measure whether
  hybrid actually helped.** If it did not, say so and keep the simpler path.
- Generation with a raw LLM SDK, streaming, structured output returning
  claim-to-chunk-id mappings rather than prose with citations glued on afterward.
- FastAPI backend.
- React and TypeScript frontend: query box, streamed answer with inline
  citations, and clicking a citation seeks the video player to that timestamp.
  **This interaction is the entire demo. Build it early, not last.**
- Deploy. Public URL.

**Done when:** it is live, a question returns an answer, and clicking a citation
lands the player on the right moment. Every chunking and retrieval decision can be
explained without hedging.

**Traps:** re-transcribing during iteration (cache it); perfecting the ingestion
pipeline before anything is queryable (get one video end to end first); treating
chunking as a solved default (it is the part you will be asked about).

**Keywords unlocked:** RAG, retrieval, embeddings, vector database, pgvector,
chunking, semantic search, hybrid search, structured outputs, LLM integration,
FastAPI, React, TypeScript, PostgreSQL, Docker, docker-compose

---

## v2 — Evals, cost, observability

**Build:**

- **A labeled eval set.** Roughly 100 question-to-timestamp pairs built by
  actually reading transcripts. Include about 15 **unanswerable** questions where
  the correct behavior is refusal. Store in `eval_labels`.
- **Retrieval metrics:** recall@k, MRR, hit rate. Run them **across both chunking
  strategies from v1** and record the delta. That comparison table is resume
  material on its own.
- **Code-based answer evals:** does the answer cite a real chunk id, does the
  cited timestamp fall inside the labeled range, does it refuse when retrieval
  returns nothing useful, is the answer within length bounds.
- **LLM-as-judge** for faithfulness and completeness. Then **validate the judge
  against the human labels and record the agreement rate.** "My judge agreed with
  my own labels on 87 of 100" is a sentence very few applicants can say.
- **Instrumentation:** OpenTelemetry traces, plus Langfuse or LangSmith. Log
  tokens, cost, and latency per query into the `queries` table.
- **Optimizations, each measured before and after:** prompt caching, embedding
  cache, retrieval cache, and a cheaper model on the easy path.
- **Model router, but only if it earns it.** Classify the query as *lookup*
  (answer is a direct quote from one chunk, cheap model) versus *synthesis*
  (requires combining several chunks or videos, strong model). Measure the quality
  delta and the cost delta. **If the numbers do not justify the router, cut it and
  say why.**

**Done when:** there is a numbers table containing retrieval hit rate by chunking
strategy, judge-to-human agreement rate, cost per query before and after, and p50
and p95 latency before and after. That table goes straight onto the resume.

**Traps:** building the judge before the human labels (then there is nothing to
validate against); labeling only easy questions; skipping the unanswerable cases,
which are exactly where hallucination shows up.

**Keywords unlocked:** evals, eval harness, LLM-as-judge, error analysis,
observability, tracing, OpenTelemetry, LangSmith / Langfuse, cost optimization,
latency optimization, prompt caching, model routing

---

## v3 — Agent, tools, MCP

**Goal:** the system does multi-step work, not just single-turn answers.

**Build:**

- **Hand-write the agent loop first**, no framework. Tools, roughly:
  `search_transcript`, `get_video_metadata`, `get_segment`, `cut_clip`,
  `concat_clips`.
- Real tasks it must handle: "find every mention of X across the library and cut
  me a supercut," "what did these three speakers each say about Y."
- **Failure handling**, which is the part worth writing about: max iteration caps,
  tool timeouts, retries with backoff, validation of tool arguments the model got
  wrong, graceful degradation when a tool fails outright.
- **Then port it to LangGraph.** Ship the LangGraph version; keep the hand-written
  one in the repo as the reference implementation. The comparison between them is
  a better interview answer than either version alone.
- **MCP server** exposing search, segment retrieval, and clip generation
  (`cut_clip`, `concat_clips`), so other MCP clients, not just the project's own
  agent, can query the library and generate clips from it. Connect it to a real
  MCP client and actually use it. This upgrades the MCP claim from "client" to
  "authored."
- **Prompt injection defense.** Transcripts are untrusted input; a speaker can say
  "ignore your previous instructions" out loud, and in a talk about AI someone
  almost certainly will. That is a genuine, non-hypothetical attack surface and
  handling it is worth a paragraph in the write-up.
- Write up the failure modes actually encountered.

**Done when:** the agent survives its own tools failing, and the MCP server works with other clients.

**Keywords unlocked:** agents, agent loops, tool calling, tool design, LangChain,
LangGraph, MCP server authoring, prompt injection defense, guardrails, retries

---

## v4 — The visual channel

**Goal:** the system searches what was *shown*, not only what was *said*.

The gap this closes: a speaker puts up a comparison table and says "as you can see
here." The transcript for that moment is worthless. v1 through v3 are blind to
that slide.

**Build:**

- Frame sampling by **scene detection** rather than fixed interval, so slide
  changes are what get captured.
- CLIP-style image embeddings into a second pgvector index.
- OCR on slide frames, indexed as text alongside the transcript.
- Fusion: combine transcript hits, OCR hits, and frame-similarity hits into one
  ranked result set.
- Extend the eval set with **visual-only questions** ("which slide shows the
  architecture diagram") that v1 provably cannot answer. The before-and-after on
  those is the proof this version was worth building.

**Done when:** a question answerable only from the screen returns the right
moment, and the eval set shows the improvement numerically.

**Keywords unlocked:** multimodal retrieval, image embeddings, CLIP, OCR,
multimodal RAG, fusion ranking

---

## v5 — Infrastructure and packaging

**Build:**

- **Harden the Docker setup from v1** into a real multi-stage production build
  (separate build and runtime stages, minimal base image, no dev dependencies in
  the final image). The dev-compose file from v1 already covers local
  reproducibility; this stage is about image size, build speed, and a production
  target the CI pipeline and cloud deploy actually run. Understand the layers
  rather than copying a template.
- GitHub Actions: lint, tests, and **the eval suite as a merge gate.** A prompt
  change that regresses retrieval hit rate fails the build. That is the most
  credible CI story available to an applied AI candidate.
- AWS/Cloud: ECS/Fargate or App Runner, RDS Postgres with pgvector, S3 for media,
  Secrets Manager, CloudWatch.
- README: architecture diagram, the numbers table from v2, a demo GIF, and an
  honest limitations section.

**Keywords unlocked:** multi-stage Docker builds, CI/CD, GitHub Actions, AWS, RDS,
S3, secrets management

---

## Budget and prerequisites

Money is not the constraint. Rough estimate: Whisper transcription of 20 hours is
on the order of ten dollars, embeddings are cents, and a full 100-query eval sweep
is well under a dollar. Total spend across the whole project should land under
fifty dollars if transcripts are cached properly. Time is the only real budget.

---

## Standing rules for this project

1. **One corpus, deep.** Retrieval quality is corpus-specific and the eval set is
   built against something concrete. A system that claims to work on everything
   has been tuned for nothing, and it shows.
2. **Ship each version publicly before starting the next.** Deployed URL, public
   repo, written case study.
3. **Every version must produce a number.** If a version ends with no measurement,
   it is not done.
4. **Cut the router, the reranker, or anything else that does not measurably
   help**, and write down that it was cut. Negative results read as more credible
   than a feature list.