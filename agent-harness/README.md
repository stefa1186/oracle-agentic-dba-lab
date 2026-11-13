# agent-harness/

One model-agnostic AI agent used by every test case in this repository.

It starts the SQLcl MCP server, sends the test prompt and the MCP tools to a
model, and runs the agent loop. The model can come from one of two
**providers**, both speaking the same OpenAI-compatible API:

| Provider | What it is | Where the data goes |
|---|---|---|
| `openrouter` | Hosted models from many vendors behind one API | To OpenRouter and the model vendor |
| `local` | A model server on this machine (Ollama by default, or vLLM / llama.cpp) | Nowhere: it stays on the server |

Changing the model, or the provider, is a single argument. Everything else
(prompt, tools, database, guardrails) stays the same, so results are
comparable, including hosted against local.

```
                                    ┌──► OpenRouter ──► hosted models
test prompt ──► run_agent.py ───────┤
                    │  ▲            └──► local server ──► local models
          tool call ▼  │ result
               SQLcl MCP server  ──►  Oracle 26ai Free (lab)
```

Oracle analogy: the tools are a package specification. Switching the
provider is like pointing a TNS alias at another database: same client, same
requests, different place where the data goes.

## Files

| File | Purpose |
|---|---|
| `setup_harness.sh` | Creates the isolated Python virtual environment and `.env`. Safe to rerun. |
| `env.example` | Settings template: providers, keys, default model, limits, tool allow-list |
| `requirements.txt` | Python dependencies (installed only in the virtual environment) |
| `system_prompt.md` | System prompt shared by every test, so only the model varies |
| `run_agent.py` | Runs one prompt against one model and logs every step |
| `run_matrix.sh` | Runs one prompt against every model in `models.txt`, N times each |
| `models.txt` | The models to compare, one `<provider> <model-id>` per line |
| `run_summary.py <run folder>` | One line per step of a run (tokens, tool, ok / ORA- code, SQL), then totals, errors by code and repeated statements. Reads `events.jsonl` only |
| `replay_sql.py` | Runs a fixed SQL file through SQLcl MCP as the agent, **without a model**: deterministic tests and SQL Firewall training (post 03) |
| `local-models/` | Scripts that run a local model server (Ollama) in a rootless container |

## Setup (as the lab user, once)

```bash
./setup_harness.sh            # creates .venv and .env
vi .env                       # set DEFAULT_PROVIDER, DEFAULT_MODEL, and OPENROUTER_API_KEY if used
.venv/bin/python run_agent.py --list-tools    # tools published by SQLcl MCP
.venv/bin/python run_agent.py --show-schemas  # same, with each tool's full description and parameters
```

For hosted models:

```bash
.venv/bin/python run_agent.py --provider openrouter --list-models   # models with tool calling
```

For local models, start the local server first (see `local-models/README.md`):

```bash
local-models/01_start_ollama.sh
local-models/02_pull_model.sh <model>
local-models/03_check_tool_calling.sh <model>
.venv/bin/python run_agent.py --provider local --list-models
```

Then list the models you want to compare in `models.txt`:

```
openrouter  <vendor>/<model>
local       <model>
```

## Running a test case

One model:

```bash
.venv/bin/python run_agent.py --provider local --model <model> --prompt-file ../post-05-health-check/04_prompt.md
```

Every model in `models.txt`, three runs each:

```bash
./run_matrix.sh -r 3 ../post-05-health-check/04_prompt.md
```

Only one provider's models (for example offline, local only):

```bash
./run_matrix.sh -p local ../post-05-health-check/04_prompt.md
```

An earlier post's prompt, with the runs filed under a later post's folder
(`-o`, used by post 12):

```bash
./run_matrix.sh -o post-12-offline-local-models ../post-02-plugging-in-mcp/05_prompt.md
```

Options passed after `--` go to every run, for example human approval before
each tool call:

```bash
./run_matrix.sh ../post-10-alert-log-rca/03_prompt.md -- --confirm
```

## Output

Each run writes to its own folder under `output/` (ignored by git):

- `events.jsonl`: the provider and endpoint, every model call (model and,
  on OpenRouter, the provider that answered, seconds, tokens), every failed
  model call (`model_error`) and every tool call (arguments and output), one
  JSON object per line
- `transcript.md`: the same run, readable
- `summary.tsv`: per matrix run, one line per provider, model and repetition

Compare `events.jsonl` with the database audit trail from post 04: the log
records what the harness sent, the audit trail records what the database ran.

## Isolation and data

- The database container stays on its internal network.
- **`openrouter`:** the harness needs outbound HTTPS to `openrouter.ai`, and
  everything the agent reads is sent to OpenRouter and the model vendor. Use
  only synthetic lab data, and a dedicated OpenRouter key with a low credit
  limit.
- **`local`:** the model server listens on `127.0.0.1` only and nothing
  leaves the server. Internet access is needed only to download models.
  Post 12 proves it: the lab user offline (loopback only), the same tests
  with local models, and the policy's drop counter before and after.
- **SQLcl always starts with an explicit restrict level** (`SQLCL_RESTRICT`,
  default 4: no host commands, no scripts). Since SQLcl 26.1.2 the MCP server
  starts unrestricted unless a level is given; the harness never relies on
  that default. Post 02's `04_check_restrict.sh` proves the block.
- **Only read-oriented MCP tools by default.** SQLcl 26.x publishes ten
  tools, some of which write (`skills_sync` downloads files into the home
  folder, `annotation_generate` writes into the database). With
  `ALLOWED_TOOLS` empty, the agent only sees `connections_list`, `connect`,
  `disconnect`, `sql_run`, `schema_information` and `request_status`; the
  others are never shown to the model. `run_agent.py --list-tools` marks each
  tool ALLOWED or hidden. Set `ALLOWED_TOOLS=ALL` only deliberately.
- **The harness, not the model, says who is calling.** It introduces itself
  to SQLcl as `oracle-agentic-dba-lab`, and if a tool declares a `model` or
  `mcp_client` parameter, the harness hides it from the model and fills in
  the true values (the model ID in use, the client name). The transcript
  shows each value added ("Harness added: ...").
- **`--attach FILE`** (repeatable): appends a text file to the prompt, between
  `BEGIN/END ATTACHED FILE` markers. `run_start` logs each file's size and
  SHA-256, so the log proves exactly what the model read; the transcript shows
  the name only. Used in post 06 for the AWR report.
- **`--allow-tools NONE`**: the model gets no tools at all and can only answer
  from the prompt (post 06: reading a report, not querying the database).
- **`--final-on-limit`** (off by default): when a run reaches MAX_STEPS without
  an answer, the harness makes one more model call with no tools, asking for the
  final answer from the results already received. The call is logged as step
  MAX_STEPS+1, the instruction appears in the transcript, and `run_end` records
  `ended: final_on_limit`. Without the option the run stops with no answer, as
  in post 03.
- **Provider errors.** A temporary error (timeout, connection error, rate
  limit, a provider failure, or a reply with no answer in it, which OpenRouter
  sends with HTTP 200 when the provider behind it fails) is retried
  `MODEL_RETRIES` times (default 3), waiting 15, 30 and 60 seconds. A
  permanent one (for example 402, no credits) is not retried. Every failed
  attempt is a `model_error` event. If no attempt succeeds, the run ends with
  `ended: model_error` and exit code 1, and `run_matrix.sh` exits 1 after the
  matrix, naming the number of failed runs. The openai client's own hidden
  retries are switched off, so the log shows every attempt.
- **Empty answer.** If the model stops calling tools but writes no text (seen
  in post 02), the run ends with `ended: empty_answer` and a `[STOPPED: ...]`
  final answer, so an empty reply is never mistaken for a finished task.
  The exit code stays 0: the model was reached, it just didn't answer.
- `MAX_STEPS`, `ALLOWED_TOOLS`, `MAX_TOOL_OUTPUT_CHARS`, `REQUEST_TIMEOUT`
  and `MODEL_RETRIES` limit what a run can do. These are convenience limits;
  the real guardrails are in the database (post 03).
- **Thinking.** `REASONING_EFFORT` (empty by default: nothing is sent, the
  server decides) is passed as `reasoning_effort` with every model call, and
  recorded in `run_start`. `none` switches a reasoning model's thinking off
  on servers that accept it, Ollama among them. Post 12 uses it for its local
  models: with Ollama's default, a 4B model on a CPU thought for 9,000
  tokens on one step and ran into the 30-minute timeout.
