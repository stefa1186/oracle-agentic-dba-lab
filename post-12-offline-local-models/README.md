# Post 12 – The same agent, offline: local models

One more test, after the verdict (post 11): can the agent work with no
internet at all, on a model that runs on the lab server itself? And what
does it cost in answer quality and speed?

The test, in three phases:

1. **Online:** check the hardware, download everything (the model server, two
   local models pinned by digest, post 08's embedding model), and run the
   series' cloud model as the baseline.
2. **Offline:** root switches the lab user's network policy (post 01) to
   *offline*: loopback only. The scripts prove it (no internet, the lab still
   works), then run the same tests with each local model, and count every
   packet that tried to leave.
3. **Compare:** the same tables for every model.

The two tests reuse earlier prompts unchanged:

- **Test A, with tools:** post 02's first-session prompt (four questions the
  agent answers by querying the database). Scored against an answer key read
  from the database itself.
- **Test B, no tools:** post 08's three team note questions, without and with
  the team note excerpts that AI Vector Search found. Scored by post 08's own
  scorer. With a local model, this whole pipeline is offline: the embeddings
  are computed in the database (post 08), the answer on the server.

The models: the cloud baseline is the model of the whole series, NVIDIA
Nemotron 3 Ultra (550B parameters, through OpenRouter). The local ones are the
smallest members of the same family: **Nemotron 3 Nano 4B** (2.8 GB) and
**Nemotron 3 Nano 30B-A3B** (24.3 GB, 3B parameters active per token), in
Ollama 0.40.9 on the CPU.

Requires: posts 01 to 04, and post 08's scripts (this post runs them). Run
only in the isolated lab.

## Scripts (in order)

| Script | As | Network | Purpose |
|---|---|---|---|
| `01_check_hardware.sh` | oralab | any | CPU, GPU, memory, disk; does each model fit? |
| `02_prepare_online.sh` | oralab | online | The pins checked on the registry before any download, Ollama (pinned), the models (checked again against `model_pins.txt`), a tool-calling check, the agent's account (post 03 role, firewall in observe mode), post 08's team notes rebuilt, test A's answer key |
| `03_cloud_baseline.sh` | oralab | online | Both tests with the cloud model |
| `../post-01-why-and-the-cage/00_root_setup.sh --offline` | **root** | | The lab user goes offline: loopback only |
| `04_prove_offline.sh` | oralab | offline | The policy, three internet tests (must fail), the database and the models (must work: each model answers a fixed request, with its writing speed), the drop counter |
| `05_run_local.sh` | oralab | offline | Both tests with each local model; the drop counter before and after |
| `06_compare.sh [--answers]` | oralab | any | The comparison tables (`compare.py`), saved to `comparison.md` |
| `../post-01-why-and-the-cage/00_root_setup.sh` | **root** | | Back online |
| `99_cleanup.sh [--yes] [--purge-models]` | oralab | any | RAG_LAB dropped, role back to post 03, firewall enforcing, Ollama container removed (models kept unless `--purge-models`) |

```bash
# as root: a download window for Ollama and the models (closes by itself)
sudo /root/oracle-agentic-dba-lab/post-01-why-and-the-cage/00_root_setup.sh --download-window 120

# as oralab (online)
./01_check_hardware.sh
./02_prepare_online.sh
./03_cloud_baseline.sh
# as root
/root/oracle-agentic-dba-lab/post-01-why-and-the-cage/00_root_setup.sh --offline
# as oralab (offline)
./04_prove_offline.sh
./05_run_local.sh
./06_compare.sh --answers
# as root
/root/oracle-agentic-dba-lab/post-01-why-and-the-cage/00_root_setup.sh
# as oralab
./99_cleanup.sh
```

## Settings

`env.example` (override in `.env`): the cloud and local models, and the
limits every run gets (tool output, steps, timeout), the same for every model.
Two settings follow where the model runs:
- **Retries** after a temporary error: none for local models (a CPU that
  timed out won't be faster the second time); cloud models keep the
  harness's `MODEL_RETRIES`.
- **Thinking** (`TEST_LOCAL_REASONING_EFFORT`, `TEST_CLOUD_REASONING_EFFORT`,
  passed as the harness's `REASONING_EFFORT`): off for local models, the
  endpoint's default for the cloud model, as in the whole series. With
  Ollama's default, the 4B thought for about 9,000 tokens on step 1 of test A
  and ran into the 30-minute timeout; the cloud endpoint thinks 50 to 270
  tokens per step. NVIDIA recommends greedy decoding (temperature 0, the
  series' setting) with thinking off.

A run that ends with an error (no answer within `TEST_REQUEST_TIMEOUT`) is a
result: `03` and `05` count it and go on, and `06_compare.sh` shows how every
run ended.
`model_pins.txt`: the exact digest and size of each local model. The Ollama
image and its settings are pinned in `../agent-harness/local-models/ollama.conf`.

If `01_check_hardware.sh` says the 30B model doesn't fit, test only the 4B:

```bash
echo 'LOCAL_MODELS="nemotron-3-nano:4b-q4_K_M"' >> .env
```

## Status

Run on the lab on 2026-11-06, every script in order, offline phase included;
the real output is in the article. Found and fixed on the way:
- post 01's cage dropped the kernel's own packets and broke IPv6 for the
  whole host (fixed there, with a new test, `04_test_policy.sh`)
- `02` probed a registry URL that answers 404; it now checks the pins on the
  registry before downloading
- a failed run stopped `05`; thinking is now off for the local models
- `compare.py` missed SQLcl's "SQL Error: ORA-" lines, and found
  `AI_AGENT` inside `AI_AGENT_READ`

Results, one run per model and test: in test A (7 facts), the cloud model 7,
the 4B 2, the 30B no answer (30-minute timeout at step 8); in test B with the
team notes (12 markers), 11, 8 and 10. Zero packets dropped during the local
runs.

Then one more local model, of another family in the same size class:
Alibaba's Qwen3.6-35B-A3B (`LOCAL_MODELS="qwen3.6:35b-a3b"` in `.env`, pinned
in `model_pins.txt`), the same phases without the cloud baseline: test A 3 of
7, test B 11 of 12, both tests in 21 min 40 s, zero packets dropped.

Then the search for the best local model for the job: open weights, fits in
the 27 GiB free, passes 02's tool check, a mixture of experts. Three
candidates, plus one dense model to measure its speed, all pinned:

```bash
# online: the four candidates (root: 00_root_setup.sh, then 00_root_setup.sh --download-window 120)
echo 'LOCAL_MODELS="gpt-oss:20b gemma4:26b qwen3-coder:30b qwen3.8:27b"' > .env
./01_check_hardware.sh
./02_prepare_online.sh
# offline (root: 00_root_setup.sh --offline)
./04_prove_offline.sh
# run 1: gpt-oss can't switch its thinking off; its lowest level is "low"
printf '%s\n' 'LOCAL_MODELS="gpt-oss:20b"' 'TEST_LOCAL_REASONING_EFFORT="low"' > .env
./05_run_local.sh
# run 2: thinking off (qwen3.8:27b, dense, is only measured by 04)
printf '%s\n' 'LOCAL_MODELS="gemma4:26b qwen3-coder:30b"' 'TEST_LOCAL_REASONING_EFFORT="none"' > .env
./05_run_local.sh
./06_compare.sh --answers
rm .env
```

Results: the dense Qwen3.8-27B wrote 2.8 tokens/s in 04's probe, against
12 for the mixtures of experts: not run further. Test A (7 facts): Google's
Gemma 4 26B 7, Alibaba's Qwen3-Coder 30B 7 by the scorer but 6 by reading
(it excluded PDBADMIN as Oracle's; the scorer found the word inside its
`NOT IN` list), OpenAI's gpt-oss 20B 5 (wrong PDB). Test B with the team notes
(12 markers): 11, 10, 10. Both tests: 16, 34 and 25 minutes. Zero packets
dropped. The best local model for this job, on this server: **Gemma 4 26B**,
with the cloud model's scores (7 and 11) in 16 minutes instead of 4.5.
Found on the way: `99_cleanup.sh` named the inner script's `--purge` as the
way to delete the models; it now names its own `--purge-models` too.
