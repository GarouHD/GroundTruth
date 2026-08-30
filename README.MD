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

## Docs

- [`PROJECT_PLAN.md`](./PROJECT_PLAN.md) — full spec, architecture rationale, and per-version build details
- `CLAUDE.md` — working instructions for AI-assisted development on this repo
