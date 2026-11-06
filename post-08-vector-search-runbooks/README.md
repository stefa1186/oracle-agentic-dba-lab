# Post 08 – Teaching the agent my runbooks, with AI Vector Search

Runbooks inside Oracle: chunked, embedded by a model that runs **inside the
database**, searched with plain SQL. Then the agent answers incident
questions twice: without the runbooks, and with the chunks the search found.

Requires: posts 01-04 (database, the agent harness). The agent's account is
**not** changed: the search runs as the application user `RAG_LAB`, and the
agent gets its results attached to the prompt, with **no tools**.

## The pieces

| Piece | What |
|---|---|
| `runbooks/*.md` | Six runbooks, **invented for the lab**, each with team-specific details (our script names, channels, escalation rules, exceptions) a model can't know from its training |
| `questions.txt` | Three incident questions, worded **unlike** the runbooks (the search must find them by meaning), each with its expected runbook and its **markers**: phrases only our runbooks contain |
| The model | Oracle's prebuilt all-MiniLM-L12-v2 (ONNX, tokenizer included), loaded with `DBMS_VECTOR.LOAD_ONNX_MODEL` as `RAG_LAB.RUNBOOK_EMBEDDER` |
| `RAG_LAB.RUNBOOK_CHUNKS` | One row per runbook section, with a `VECTOR` column filled by `VECTOR_EMBEDDING` |

## Scripts (run as `oralab`, in order)

| Script | Purpose |
|---|---|
| `env.example` | Schema, model URL and file, `MODEL_SHA256` (pinned: the file tested on 2026-11-05), model folder, TOP_K |
| `lib.sh` | Reuses posts 01-04 helpers; runs SQL as `RAG_LAB`; reads questions.txt |
| `01_get_model.sh` | Downloads the model (HTTPS), checks or prints its SHA-256, unpacks the ONNX file to `~/opt/models/...` |
| `02_setup.sh` + `setup_schema.sql` | Copies the model into the container; `RAG_LAB` (new random password in `~/.config/oralab/rag_lab_pwd`, mode 600) with CREATE SESSION, CREATE TABLE, CREATE MINING MODEL, READ on the directory; loads the model; one sentence in, one vector out |
| `03_load_runbooks.sh` + `chunk_runbooks.py` | One chunk per runbook section; embeddings computed in the database |
| `04_search.sh ["question"]` | Top-K chunks by cosine distance. Without an argument: every question, `retrieval.txt` (expected runbook found, at which rank), and the agent's two files per question: `question_<id>.txt`, `context_<id>.txt` |
| `05_prompt.md` | The on-call task: follow the runbooks if attached; never invent team details |
| `06_run_agent.sh [-r N]` | Every question, without and with the runbooks |
| `07_score.sh [--answers]` + `score_answers.py` | Markers found, team details found in no runbook; `scorecard.md` |
| `99_cleanup.sh` | Drops `RAG_LAB` (model, table), the directory, the file in the container, the password file. Keeps the downloaded model |

## Step by step

```bash
cd ~/oracle-agentic-dba-lab/post-08-vector-search-runbooks
./01_get_model.sh              # verified against the pinned MODEL_SHA256
./02_setup.sh
./03_load_runbooks.sh
./04_search.sh
./04_search.sh "the listener is down, nobody can connect"   # any question
./06_run_agent.sh
./07_score.sh --answers
./99_cleanup.sh                # when done
```

## Why it's set up this way

- **Same chunks for every model.** The search runs once, in a script; the
  agent gets its results as a file (SHA-256 in each run's log). Differences
  between answers come from the model, not from the search.
- **Exact search, no vector index.** A few dozen rows: every distance is
  computed, instantly, and the result is the same every time.
- **Single-line chunks.** A blank line ends a statement in SQL*Plus and a
  line starting with `#` is a command; one line per chunk avoids both.
- **Invented runbooks.** Real ones contain internal details; and invented
  details are the point: a model can only know them from the search.

## Status

Run on the lab on 2026-11-05; full results in the article.

- Retrieval: billing and ora4031 found their runbook first; fra found it only at rank 2, with the wrong section ("If it keeps growing" instead of "What to do first").
- Markers without / with the runbooks: billing 0 → 4 of 4, fra 0 → 3 of 4, ora4031 1 → 4 of 4.
- Team details found in no runbook: none, in all 6 answers.
