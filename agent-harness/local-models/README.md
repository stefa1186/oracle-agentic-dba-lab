# agent-harness/local-models/

Runs a local model server so the agent can use models on this machine instead
of (or alongside) hosted models from OpenRouter.

**Why:** with a local model, nothing the agent reads from the database leaves
the server. Oracle analogy: pointing a TNS alias at another database. The
client and the API are the same; only where the data goes changes.

The scripts use **Ollama** in a rootless Podman container, with its API
published on `127.0.0.1` only. Any other OpenAI-compatible server (vLLM,
llama.cpp server) works too: set `LOCAL_BASE_URL` in `agent-harness/.env`.

## Scripts (run as the lab user, in order)

| Script | Purpose |
|---|---|
| `ollama.conf` | Shared settings: image (pinned by version and digest), port, context window, parallel requests, models in memory, memory cap, GPU |
| `01_start_ollama.sh` | Creates or starts the container (recreates it if `ollama.conf` changed; models are kept) and waits until the API answers |
| `02_pull_model.sh <model>...` | Downloads models into the models volume (needs internet) |
| `03_check_tool_calling.sh <model>...` | Proves each model can make a tool call before a real test |
| `99_remove_ollama.sh [--purge]` | Removes the container; `--purge` also deletes the models |

All scripts are safe to run more than once.

## Typical use

```bash
cd agent-harness/local-models
./01_start_ollama.sh
./02_pull_model.sh <model>
./03_check_tool_calling.sh <model>
```

Then add the model to `agent-harness/models.txt`:

```
local  <model>
```

and run any test with local models only, or mixed with hosted ones:

```bash
cd ..
./run_matrix.sh -p local ../post-05-health-check/04_prompt.md   # local only
./run_matrix.sh ../post-05-health-check/04_prompt.md            # everything in models.txt
```

## Things to know

- **Tool calling is required.** Not every model can call tools. Choose models
  the Ollama library tags with "tools", and confirm with
  `03_check_tool_calling.sh`.
- **Hardware.** CPU-only works but is slow; small models (a few billion
  parameters) are practical on a CPU server. Set `OLLAMA_GPU=1` if the server
  has an NVIDIA GPU with the Container Toolkit installed.
- **Context window.** `OLLAMA_CONTEXT_LENGTH` (default 32768 tokens) sets how
  much the model can hold in mind. Larger values need more RAM. If a small
  model loses track of long SQL output, also lower `MAX_TOOL_OUTPUT_CHARS` in
  `agent-harness/.env`.
- **Repeatability.** The image is pinned in `ollama.conf` by version and
  digest. `01_start_ollama.sh` labels the container with a fingerprint of the
  settings and recreates it when `ollama.conf` changes, so the running server
  always matches the file. Pin models by digest too: a tag can be
  re-published (post 12's `model_pins.txt` shows how).
- **Memory.** `OLLAMA_NUM_PARALLEL=1` and `OLLAMA_MAX_LOADED_MODELS=1`: one
  request at a time, one model in memory at a time. Predictable, and two
  large models never compete with each other or with the database.
- **Network.** Only `02_pull_model.sh` needs internet access. Serving models
  is entirely local.
