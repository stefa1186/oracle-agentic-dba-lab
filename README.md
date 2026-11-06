# oracle-agentic-dba-lab

An isolated, repeatable lab in which an Oracle DBA with 20 years of experience
tests AI agents against a real Oracle database, and decides with evidence what
they can be trusted with.

This repository holds the code behind the LinkedIn series
**"20 Years of Oracle, 0 Days of Agentic AI"**, written for Oracle DBAs
who are exploring AI. The articles and posts are published on LinkedIn;
here is every script behind them.

## What's inside

There is one folder per post. Each folder contains everything needed to set up
and run that post's test case, plus a README explaining the order to run them.

| Folder | Topic | Depends on |
|---|---|---|
| `post-01-why-and-the-cage/` | Build and destroy the isolated lab | — |
| `post-02-plugging-in-mcp/` | Connect an agent through the SQLcl MCP server | 01 |
| `post-03-least-privilege/` | Agent user, profile, SQL Firewall | 01, 02 |
| `post-04-auditing-the-agent/` | Unified Auditing vs. the agent's own account | 03 |
| `post-05-health-check/` | Agent health check vs. a DBA checklist | 03 |
| `post-06-awr/` | Agent reads an AWR report | 03 |
| `post-07-sql-tuning/` | Agent vs. SQL Tuning Advisor | 03 |
| `post-08-vector-search-runbooks/` | Runbooks in AI Vector Search | 03 |
| `post-09-breaking-it/` | Destructive requests and prompt injection | 03, 04 |
| `post-10-alert-log-rca/` | Alert log triage with human approval | 03 |
| `post-11-verdict/` | Every model-free guardrail rerun in one command, every agent run in one table, the verdict | all |
| `post-12-offline-local-models/` | After the verdict: the same agent offline, on local models | 01–04, 08 |
| `agent-harness/` | Model-agnostic agent (OpenRouter + SQLcl MCP) used by every test | 01 |
| `docs/` | Architecture notes and diagrams | — |

### Any model, same test

Every test case runs through `agent-harness/`, which reaches hosted models
through OpenRouter and local models through a model server on the lab host
(Ollama by default, in a rootless container bound to localhost). Both use the
same OpenAI-compatible API, so the prompt, tools, database and guardrails stay
fixed; only the model changes. With local models, no lab data leaves the
server. List the models to compare in `agent-harness/models.txt` and run any
test against all of them:

```bash
cd agent-harness
./run_matrix.sh ../post-05-health-check/04_prompt.md
```

See `agent-harness/README.md` for setup.

### Conventions in every post folder

- `README.md`: what the test does and the exact order to run the scripts.
- Numbered scripts (`01_...`, `02_...`) run in order; `99_cleanup...` reverts
  everything the folder created. All scripts are safe to run more than once.

## Principles

1. **Isolation.** The lab runs under a dedicated Linux user (`oralab`), in
   rootless containers on their own network, with ports bound to localhost
   and an outbound policy for that user: DNS and HTTPS only, nothing on the
   LAN. An offline mode (post 12) cuts it to loopback only. Nothing else on
   the host is touched.
2. **Non-root.** One setup script runs as root, once. Everything else runs
   as `oralab`, whose sudo rights are two read-only commands.
3. **Repeatability.** Every step is a script. One command builds the lab,
   one command destroys it, and running either twice is safe.
4. **Guardrails in the database, not in the prompt.** Privileges, SQL
   Firewall and auditing are what actually constrain the agent.
5. **Evidence over claims.** Every experiment records what the agent said
   *and* what the database recorded.
6. **Commented code.** Every line of every script is explained.

## Quick start

On the CentOS 10 server. Once, as root (the repository is public: no credentials needed):

```bash
dnf install -y git
git clone https://github.com/stefa1186/oracle-agentic-dba-lab.git /root/oracle-agentic-dba-lab
/root/oracle-agentic-dba-lab/post-01-why-and-the-cage/00_root_setup.sh   # creates user oralab and its copy of the repo
```

Then everything as the lab user, which gets the repository from a local
read-only mirror: no network and no credentials needed:

```bash
machinectl shell oralab@
cd ~/oracle-agentic-dba-lab/post-01-why-and-the-cage
./01_prereqs.sh     # checks
./02_build.sh       # Oracle AI Database 26ai Free in a rootless container
./03_verify.sh      # PASS/FAIL proof that it is up and isolated
```

`./99_destroy.sh --db-only` gives a fresh database. Details, including how
the user is created and how to update the scripts, in
`post-01-why-and-the-cage/README.md`.

## Requirements

- A dedicated server running CentOS 10 with root access
- Internet access to pull the Oracle container image and SQLcl

## Disclaimer

This is a personal learning lab. Never point an AI agent at a production
database based on these scripts without your own review. Oracle features such
as AWR, ASH and SQL Tuning Advisor require the appropriate licences on
Enterprise Edition.
