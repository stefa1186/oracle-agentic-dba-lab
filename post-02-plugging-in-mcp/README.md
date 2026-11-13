# Post 02 – Plugging an agent into Oracle via MCP

Connects an AI agent to the lab database through the **SQLcl MCP server**,
with the database password kept out of the model's reach and OS commands
switched off.

Requires: post 01 (lab built, `03_verify.sh` passing). If your root setup is
older than this post, rerun it once as root: it now also installs Java 21
and `unzip`, which SQLcl needs.

## Scripts (run as `oralab`, in order)

| Script | Purpose |
|---|---|
| `env.example` | Settings: SQLcl download and checksum, agent user name, connection name, restrict level |
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
| Who did what | Every agent session is visible in V$SESSION (program/module/action set by SQLcl MCP). SQLcl writes an MCP log table, `DBTOOLS$MCP_LOG`, only if that table exists in the agent's own schema. It is deliberately not created: a log the agent owns is a log the agent can edit. Post 04 looks at it and at Unified Auditing. |

## Notes

- **Observed in the first run (SQLcl 26.3.1, 2026-11-04):**
  - The agent ran 12 `sql_run` calls; its own final list had 11 (it merged a
    repeated query). The harness log, not the agent's summary, is the record.
  - SQLcl's `connect` result tells the model AUTOCOMMIT is ON, and contains
    instructions to the model about what to summarise: tool output can steer
    the model (see post 09).
  - No `DBTOOLS$*` table exists in FREEPDB1, and SQLcl doesn't create one:
    retested on 2026-11-13 with CREATE TABLE and a quota granted to
    `AI_AGENT`, still no table. SQLcl only writes to `DBTOOLS$MCP_LOG` if
    it already exists in the agent's own schema.
  - `UNIFIED_AUDIT_TRAIL` had **no rows** for `AI_AGENT` (default policies):
    not the logons, not the queries. Post 04 adds the audit policy.
  - `V$SESSION` during a run (`06_watch_agent_sessions.sh --once`):
    PROGRAM `SQLcl-MCP`; ACTION = the tool being called (`schema_information`,
    `sql_run`); MODULE was `UNKNOWN-LLM`. SQLcl's tools take a `model`
    parameter that the model itself is expected to fill in; it didn't.
    **Fixed in the harness:** it now hides that parameter from the model and
    fills in the true model ID on every call, so MODULE shows e.g.
    `nvidia/nemotron-3-ultra-550b-a55b:free`. Every agent session in the
    database is now attributable to a specific model.

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
