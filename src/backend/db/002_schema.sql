-- Creating tables and indexes fro db
CREATE TABLE videos (
    id SERIAL PRIMARY KEY,
    title TEXT NOT NULL,
    source_url TEXT,
    duration_s REAL,
    language TEXT,
    license TEXT,
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE transcripts (
    id SERIAL PRIMARY KEY,
    video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
    model TEXT NOT NULL,
    raw_json JSONB NOT NULL
);

CREATE TABLE chunks (
    id SERIAL PRIMARY KEY,
    video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
    text TEXT NOT NULL,
    start_s REAL NOT NULL,
    end_s REAL NOT NULL,
    speaker TEXT,
    token_count INTEGER,
    embedding VECTOR(1024),
    tsv tsvector GENERATED ALWAYS AS (to_tsvector('english', text)) STORED,
    CHECK (end_s > start_s)
);

-- Plain B-tree index
CREATE INDEX chunks_video_idx ON chunks(video_id);
-- Vector index for embeddings using hnsw (find nearest neighbors with calculating all distances)
CREATE INDEX chunks_embedding_idx ON chunks USING hnsw (embedding vector_cosine_ops);
-- Reverse index, assigns words to chunks
CREATE INDEX chunks_tsv_idx ON chunks USING GIN(tsv);