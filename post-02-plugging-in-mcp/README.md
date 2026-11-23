# Post 02 – Plugging an agent into Oracle via MCP

Connects an AI agent to the lab database through the **SQLcl MCP server**,
with the database password kept out of the model's reach and OS commands
switched off.

Requires: post 01 (lab built, `03_verify.sh` passing). Post 01's root setup
already installs Java 21 and `unzip`, which SQLcl needs.

## Scripts (run as `oralab`, in order)

| Script | Purpose |
|---|---|
| `env.example` | Settings: SQLcl download and checksum, agent user name, connection name, restrict level |
| `models_compare.txt` | The five other models of the comparison (2 free, 3 paid), for `run_matrix.sh -m` |
| `lib.sh` | Reuses post 01's helpers and adds the post 02 settings (not run directly) |
| `01_install_sqlcl.sh` | Installs SQLcl in `~/opt/sqlcl` from a cached, checksummed download; links `~/.local/bin/sql` |
| `02_create_agent_user.sh` | Creates `AI_AGENT` in FREEPDB1: CREATE SESSION + SELECT_CATALOG_ROLE |
| `03_save_connection.sh` | Saves the SQLcl connection `agent` with its password, and tests it by name |
| `04_check_restrict.sh` | Proves the restrict level blocks OS commands (`host id`) |
| `05_prompt.md` | The first-contact prompt |
| `06_watch_agent_sessions.sh` | Shows the agent's sessions in V$SESSION while it works (`--once` for a snapshot) |
| `99_cleanup.sh --agent` / `--all` | Drops `AI_AGENT`; `--all` also removes SQLcl and its saved connections |

```bash
cd ~/oracle-agentic-dba-lab/post-02-plugging-in-mcp
./01_install_sqlcl.sh
./02_create_agent_user.sh
./03_save_connection.sh
./04_check_restrict.sh
```

## Pin SQLcl (once)

The first run of `01_install_sqlcl.sh` prints the SHA-256 of the downloaded
zip and the SQLcl version. Pin the checksum in `env.example`
(`SQLCL_SHA256=...`) and commit it, exactly as the database image is pinned
by digest. From then on the install only accepts that exact file, and every
reinstall uses the cached copy in `~/.cache/oralab/`.

## Running the agent (first contact)

Set up the agent harness once:

```bash
cd ~/oracle-agentic-dba-lab/agent-harness
./setup_harness.sh                                    # creates .venv and .env (once)
.venv/bin/python run_agent.py --list-tools            # what SQLcl MCP offers, and what the agent sees
```

`--list-tools` needs no model or API key. To run the first contact, fill in
`.env` and `models.txt` (an OpenRouter key and model, or a local model; see
`agent-harness/README.md`), then:

```bash
./run_matrix.sh ../post-02-plugging-in-mcp/05_prompt.md
```

### The tools SQLcl publishes

SQLcl 26.3.1 publishes ten MCP tools (the 26.2 documentation lists six; the
26.3 documentation lists all ten), and some of them write. The harness shows the agent only a read-oriented
subset by default:

| Tool | Agent sees it | Why |
|---|---|---|
| `connections_list`, `connect`, `disconnect` | yes | Choose the saved connection |
| `sql_run` | yes | Run SQL; the database privileges are the real limit |
| `schema_information` | yes | Read-only schema description |
| `request_status` | yes | Results of long-running tool calls |
| `sqlcl_run` | no | Any SQLcl command: a large surface |
| `skills_sync` | no | Downloads files from the internet into the home folder |
| `annotation_generate` | no | Writes annotations into the database |
| `context_retrieve` | no | Vector search; enabled in post 08 |

`run_agent.py --list-tools` marks each one ALLOWED or hidden. Hidden tools are
never shown to the model. Oracle analogy: not granting EXECUTE on a package,
instead of asking nicely not to call it.

In a second terminal (`machinectl shell oralab@`), watch it live:

```bash
~/oracle-agentic-dba-lab/post-02-plugging-in-mcp/06_watch_agent_sessions.sh
```

The models compared are the ones in `agent-harness/models.txt`.

## What protects what

| Concern | Control |
|---|---|
| The model sees the database password | It doesn't: the MCP server connects by the **name** `agent`; the password sits in SQLcl's store (`~/.dbtools`). Oracle analogy: the secure external password store. |
| The agent runs OS commands through SQLcl (`host`, `!`) | The harness always starts SQLcl with `-R 4`. **Since SQLcl 26.1.2 the MCP server starts unrestricted unless a level is given.** `04_check_restrict.sh` proves the block. |
| The agent uses tools that write files or metadata | The harness hides `skills_sync`, `annotation_generate`, `sqlcl_run` and `context_retrieve` from the model (`ALLOWED_TOOLS`, safe by default). |
| The agent changes data | `AI_AGENT` has no DML or DDL privileges. |
| The agent reads too much | Not yet: SELECT_CATALOG_ROLE is deliberately generous here. Post 03 removes it. |
| Who did what | Every agent session is visible in V$SESSION (program/module/action set by SQLcl MCP). Before every tool call SQLcl tries to create an MCP log table, `DBTOOLS$MCP_LOG`, in the agent's own schema, and logs the call there. `AI_AGENT` can't create tables, so the attempt fails silently, on purpose: a log the agent owns is a log the agent can edit. Post 04 looks at it and at Unified Auditing. |

## Notes

- **Observed in the runs quoted in the article (SQLcl 26.3.1, 2026-11-14):**
  five runs of `05_prompt.md` with `nvidia/nemotron-3-ultra-550b-a55b:free`
  (`output/post-02-plugging-in-mcp/20261114T220721Z`, the run quoted, and
  `20261114T221301Z`, four repeats with `run_matrix.sh -r 4`).
  - Every run answered all four questions, and every run's own list of
    statements matched the harness log (9/9, 10/10, 10/10, 11/11, 10/10).
  - 4 of 5 runs asked DBA_USERS for the same non-Oracle-maintained users a
    second time (once with one column less, three times with CREATED added).
  - 3 of 5 runs misread a result: a query on owners that aren't
    Oracle-maintained users returned PUBLIC's 13,555 synonyms (PUBLIC isn't in
    DBA_USERS), and the answer called them "the only non-Oracle objects".
    All 13,555 are `ORACLE_MAINTAINED = 'Y'`. One more run called PUBLIC a
    non-Oracle-maintained owner but its synonyms "standard Oracle catalog
    synonyms"; one didn't count PUBLIC.
  - Model comparison, 5 runs each with `models_compare.txt`
    (`output/post-02-plugging-in-mcp/20261114T222623Z`):
    `google/gemma-4-31b-it:free` 5x `model_error` (rate-limited upstream,
    429/504); `baidu/ernie-5.5-flash-preview:free` 5x `max_steps`, no answer
    (18 to 57 queries per run); `anthropic/claude-haiku-5.5`,
    `openai/gpt-6.1-terra` and `google/gemini-4-hydrogen` answered 5x each,
    never repeated a question and never misread the PUBLIC synonyms. The
    repeated question and the misread are habits of the Nemotron model.
  - Earlier, on 2026-11-13, one run with the same model ended with an empty
    last reply (6 tokens, no text), which the harness then logged as a normal
    end. The harness now ends such a run as `empty_answer` with a
    `[STOPPED: ...]` final answer. Not seen again in eight later runs.
  - SQLcl's `connect` result tells the model AUTOCOMMIT is ON, and contains
    instructions to the model about what to summarise: tool output can steer
    the model (see post 04).
  - No `DBTOOLS$*` table exists in FREEPDB1. SQLcl's housekeeping block
    tries to create `DBTOOLS$MCP_LOG` in the agent's schema before every tool
    call and swallows the error (ORA-01031). Tested on 2026-11-13: with
    CREATE TABLE, CREATE SEQUENCE (identity column) and a quota granted to
    `AI_AGENT`, SQLcl created the table and logged every call (client, model,
    tool, SQL text). The grants were then revoked and the table dropped.
  - `UNIFIED_AUDIT_TRAIL` has **one row** for `AI_AGENT` (default policies):
    a failed logon (ORA-01017) from a test on 2026-11-13. `ORA_LOGIN_LOGOUT`
    records failed logons only, so the five runs' logons and queries left
    nothing. Post 04 adds the audit policy.
  - `V$SESSION` during a run (`06_watch_agent_sessions.sh --once`):
    PROGRAM `SQLcl-MCP`; ACTION = the tool being called (`connect`,
    `schema_information`, `sql_run`); MODULE = the model ID, e.g.
    `nvidia/nemotron-3-ultra-550b-a55b:free`. SQLcl's tools take a `model`
    parameter that the model is expected to fill in (default `UNKNOWN-LLM`,
    see `run_agent.py --show-schemas`). The harness hides that parameter
    from the model and fills in the true model ID on every call, so every
    agent session in the database is attributable to a specific model.

  The two checks, as `oralab`:
  ```bash
  # MCP log table created by SQLcl?
  podman exec -i oralab-db sqlplus -s / as sysdba <<'SQL'
  alter session set container = FREEPDB1;
  select owner, table_name from dba_tables where table_name like 'DBTOOLS$%';
  exit
  SQL
  # What the default audit policies recorded for the agent.
  podman exec -i oralab-db sqlplus -s / as sysdba <<'SQL'
  alter session set container = FREEPDB1;
  select event_timestamp, action_name, return_code from unified_audit_trail
  where dbusername = 'AI_AGENT' order by event_timestamp;
  exit
  SQL
  ```
- All scripts are safe to rerun. `02` and `03` always leave the same user,
  password and saved connection.
