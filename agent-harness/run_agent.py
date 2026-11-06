#!/usr/bin/env python3
# =============================================================================
# run_agent.py
#
# Model-agnostic AI agent for the oracle-agentic-dba-lab test cases.
#
# What it does:
#   1. Starts the SQLcl MCP server (`sql -mcp`) as a child process.
#      Oracle analogy: SQLcl MCP is the listener; this script is the client
#      that asks it for a connection and calls the tools it publishes.
#   2. Reads the tool list the MCP server publishes.
#      Oracle analogy: like describing a package specification before calling it.
#   3. Sends the test prompt plus those tools to a model, through a PROVIDER:
#        - openrouter: hosted models from many vendors behind one API.
#        - local:      a model server on this machine (Ollama, vLLM,
#                      llama.cpp server, ...), so no lab data leaves the host.
#      Both speak the same OpenAI-compatible API, so the agent loop is
#      identical; only the endpoint changes.
#      Oracle analogy: the same connect-string format whether the database is
#      on-premises or in the cloud. The client code doesn't change.
#   4. Runs the agent loop: the model asks for a tool call, this script runs it
#      through MCP, returns the result, and repeats until the model answers.
#   5. Logs every step (provider, model, tokens, tool calls, results) to a
#      JSONL file and writes a readable Markdown transcript, so runs can be
#      compared across models and providers.
#
# Repeatability:
#   - temperature defaults to 0 to reduce run-to-run variation.
#   - every run writes to its own timestamped folder; nothing is overwritten.
#
# Usage examples:
#   ./run_agent.py --list-models                       (OpenRouter models with tool calling)
#   ./run_agent.py --provider local --list-models      (models pulled on the local server)
#   ./run_agent.py --list-tools                        (tools published by SQLcl MCP)
#   ./run_agent.py --provider openrouter --model <id> --prompt-file ../post-05-health-check/04_prompt.md
#   ./run_agent.py --provider local --model qwen3:8b  --prompt-file ../post-05-health-check/04_prompt.md
# =============================================================================

# argparse parses the command-line options (like the flags of sqlplus).
import argparse
# asyncio runs the MCP client, which is asynchronous by design.
import asyncio
# datetime builds the timestamps used in folder names and log events.
import datetime
# hashlib: fingerprint of attached files, so the log proves what the model read.
import hashlib
# json reads tool-call arguments and writes the JSONL event log.
import json
# os reads environment variables (API key, endpoints, SQLcl path, ...).
import os
# pathlib handles file and folder paths in a portable way.
import pathlib
# re builds filesystem-safe folder names from model IDs.
import re
# sys gives access to stderr and the exit code.
import sys
# time measures how long each model call and tool call takes.
import time

# httpx is the HTTP client used to list models; it comes with the openai package.
import httpx
# load_dotenv reads the harness .env file into environment variables,
# like sourcing oraenv before running a script.
from dotenv import load_dotenv
# ClientSession talks MCP; StdioServerParameters describes how to start the server.
from mcp import ClientSession, StdioServerParameters
# Implementation is how an MCP client introduces itself (name and version) during the handshake.
from mcp.types import Implementation
# stdio_client starts the MCP server as a child process and connects to its stdin/stdout.
from mcp.client.stdio import stdio_client
# OpenAI is the OpenAI-compatible client, pointed at whichever provider is chosen.
from openai import OpenAI
# The openai package itself, for its exception classes (call_model below).
import openai

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

# Folder that contains this script; every relative default is resolved from here,
# so the script behaves the same whatever the current directory is.
HARNESS_DIR = pathlib.Path(__file__).resolve().parent
# Default system prompt shared by every test case, so only the model changes between runs.
DEFAULT_SYSTEM_FILE = HARNESS_DIR / "system_prompt.md"
# Default root folder for run output (ignored by git).
DEFAULT_OUTPUT_ROOT = HARNESS_DIR.parent / "output"
# The providers this harness knows about.
PROVIDERS = ("openrouter", "local")
# MCP tools the agent may use when ALLOWED_TOOLS is empty or unset: the
# read-oriented minimum. Deliberately left out (SQLcl 26.x publishes them):
#   sqlcl_run            any SQLcl command: a large surface
#   skills_sync          downloads files from the internet into the home folder
#   annotation_generate  writes annotations into the database
#   context_retrieve     vector search; enabled explicitly in post 08
# Oracle analogy: a role with exactly the grants the job needs.
DEFAULT_ALLOWED_TOOLS = "connections_list,connect,disconnect,sql_run,schema_information,request_status"
# How this harness introduces itself to the MCP server (instead of the
# library's anonymous default), so SQLcl can tell which client is connected.
CLIENT_NAME = "oracle-agentic-dba-lab"
CLIENT_VERSION = "1.0"
# Tool parameters that identify WHO is calling, rather than WHAT to do. If a
# tool declares one of these, the harness hides it from the model and fills
# in the true value itself: the model can neither forget it nor invent it.
# Oracle analogy: DBMS_APPLICATION_INFO set by the application server, not
# typed in by the end user.
IDENTITY_PARAMS = ("model", "mcp_client")


def parse_args() -> argparse.Namespace:
    """Define and parse the command-line options."""
    # Create the parser with a short description shown by --help.
    p = argparse.ArgumentParser(description="Run one test-case prompt against one model (OpenRouter or local) through the SQLcl MCP server.")
    # Which provider serves the model. Falls back to DEFAULT_PROVIDER from .env, then to openrouter.
    p.add_argument("--provider", choices=PROVIDERS, default=None, help="Model provider (default: DEFAULT_PROVIDER from .env, else openrouter)")
    # The model ID at that provider. Falls back to DEFAULT_MODEL from .env.
    p.add_argument("--model", default=None, help="Model ID at the provider (default: DEFAULT_MODEL from .env)")
    # The file with the test-case prompt, normally the NN_prompt.md of a post folder.
    p.add_argument("--prompt-file", type=pathlib.Path, help="File containing the user prompt for this test case")
    # Optional override of the shared system prompt.
    p.add_argument("--system-file", type=pathlib.Path, default=DEFAULT_SYSTEM_FILE, help="System prompt file (default: system_prompt.md)")
    # Where to write the logs of this run; created if missing.
    p.add_argument("--out-dir", type=pathlib.Path, default=None, help="Output folder for this run (default: output/<timestamp>_<provider>_<model>)")
    # Upper bound on agent loop iterations, like a resource limit in a profile.
    p.add_argument("--max-steps", type=int, default=None, help="Maximum model calls per run (default: MAX_STEPS from .env)")
    # Sampling temperature; 0 makes answers as repeatable as the provider allows.
    p.add_argument("--temperature", type=float, default=None, help="Sampling temperature (default: TEMPERATURE from .env)")
    # Comma-separated list of MCP tools the agent may use; empty means all published tools.
    p.add_argument("--allow-tools", default=None, help="Comma-separated MCP tool allow-list (default: ALLOWED_TOOLS from .env)")
    # Files appended to the prompt, e.g. an AWR report the agent must read (post 06).
    # Repeatable. Each is logged in run_start with its size and SHA-256.
    p.add_argument("--attach", action="append", type=pathlib.Path, default=[], help="Append this text file to the prompt (repeatable)")
    # At the step limit, one more model call WITHOUT tools, asking for the final
    # answer from what was already gathered. Off by default: post 03's "it never
    # stopped" stays observable. The extra call is logged and labelled.
    p.add_argument("--final-on-limit", action="store_true", help="At MAX_STEPS, ask once (no tools) for a final answer from the results so far")
    # Human approval before every tool call (used in post 10).
    p.add_argument("--confirm", action="store_true", help="Ask for human approval before every tool call")
    # Print the tool list published by SQLcl MCP and exit, without calling any model.
    p.add_argument("--list-tools", action="store_true", help="List the MCP tools published by SQLcl and exit")
    # Same, plus each tool's full description and parameter schema (to see what SQLcl asks for).
    p.add_argument("--show-schemas", action="store_true", help="List the tools with their full descriptions and parameter schemas, and exit")
    # Print the models available at the chosen provider and exit.
    p.add_argument("--list-models", action="store_true", help="List the models available at the chosen provider and exit")
    # Return the parsed options.
    return p.parse_args()


def env(name: str, default: str | None = None, required: bool = False) -> str | None:
    """Read one setting from the environment, failing clearly if a required one is missing."""
    # Read the variable, falling back to the default.
    value = os.environ.get(name, default)
    # A required setting that is empty stops the run with a clear message (like ORA-01034 instead of a hang).
    if required and not value:
        sys.exit(f"ERROR: {name} is not set. Copy env.example to .env and fill it in.")
    # Return the value (possibly None for optional settings).
    return value


def provider_settings(provider: str) -> dict:
    """Return endpoint, key and extra headers for a provider, read from .env."""
    # Hosted models through OpenRouter.
    if provider == "openrouter":
        return {
            # OpenRouter's OpenAI-compatible endpoint (overridable only for testing).
            "base_url": env("OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1"),
            # The API key is required for real runs; read lazily so --list-models works without it.
            "api_key_var": "OPENROUTER_API_KEY",
            # Optional attribution header OpenRouter shows in its dashboard.
            "headers": {"X-Title": "oracle-agentic-dba-lab"},
        }
    # A local OpenAI-compatible server: Ollama by default, or vLLM / llama.cpp server.
    return {
        # Default is the Ollama container started by local-models/01_start_ollama.sh.
        "base_url": env("LOCAL_BASE_URL", "http://127.0.0.1:11434/v1"),
        # Local servers usually ignore the key, but the client needs a non-empty value.
        "api_key_var": "LOCAL_API_KEY",
        # No extra headers for local servers.
        "headers": {},
    }


def safe_name(text: str) -> str:
    """Turn a model ID such as 'vendor/model:variant' into a folder-safe name."""
    # Replace every character that is not a letter, digit, dot or dash with an underscore.
    return re.sub(r"[^A-Za-z0-9.\-]+", "_", text)


def list_models(provider: str) -> None:
    """Print the models available at the provider."""
    # Endpoint and key for this provider.
    ps = provider_settings(provider)
    # Send the key if one is configured; OpenRouter's catalogue doesn't need it, local servers may.
    key = os.environ.get(ps["api_key_var"]) or ("local" if provider == "local" else "")
    headers = {"Authorization": f"Bearer {key}"} if key else {}
    # Both providers expose the OpenAI-style GET /models.
    resp = httpx.get(f"{ps['base_url']}/models", headers=headers, timeout=30)
    # Stop with an error if the server did not answer 200 OK.
    resp.raise_for_status()
    # The list is under the "data" key in both cases.
    models = resp.json().get("data", [])
    if provider == "openrouter":
        # OpenRouter says which models accept the "tools" parameter; others cannot drive an agent.
        models = [m for m in models if "tools" in (m.get("supported_parameters") or [])]
        note = "support tool calling"
    else:
        # Local servers don't report tool support; check each model's card before using it.
        note = "are available locally (check each one supports tool calling)"
    # Print one model ID per line, sorted, ready to paste into models.txt.
    for m in sorted(models, key=lambda m: m["id"]):
        print(m["id"])
    # Report the count on stderr so stdout stays clean for piping.
    print(f"\n{len(models)} models {note}.", file=sys.stderr)


def identity_params_of(tool) -> list[str]:
    """Return the identity parameters (IDENTITY_PARAMS) this tool declares."""
    # The tool's declared parameters, from its JSON Schema.
    props = (tool.inputSchema or {}).get("properties") or {}
    # Keep only the identity ones, in a fixed order.
    return [p for p in IDENTITY_PARAMS if p in props]


def mcp_tool_to_openai(tool) -> dict:
    """Convert one MCP tool description into the OpenAI 'function' tool format,
    without the identity parameters (the harness fills those in itself)."""
    # Copy the schema so the original tool description stays untouched.
    schema = json.loads(json.dumps(tool.inputSchema or {"type": "object", "properties": {}}))
    # Remove identity parameters from the properties the model sees ...
    for p in IDENTITY_PARAMS:
        (schema.get("properties") or {}).pop(p, None)
    # ... and from the list of required parameters, if they were required.
    if "required" in schema:
        schema["required"] = [r for r in schema["required"] if r not in IDENTITY_PARAMS]
    # MCP and the OpenAI format both describe parameters with JSON Schema,
    # so this is a field-by-field mapping, like a view over the same table.
    return {
        "type": "function",
        "function": {
            # The tool name the model will use when it asks for a call.
            "name": tool.name,
            # The description is what the model reads to decide when to use the tool.
            "description": tool.description or "",
            # The JSON Schema of the arguments the model must supply.
            "parameters": schema,
        },
    }


def result_text(result) -> str:
    """Flatten an MCP tool result into plain text for the model."""
    # An MCP result holds a list of content items; keep the text of each text item.
    parts = [getattr(item, "text", "") for item in result.content]
    # Join the parts with newlines into one string.
    text = "\n".join(p for p in parts if p)
    # Mark errors explicitly so the model and the log both see them.
    if getattr(result, "isError", False):
        text = "TOOL ERROR:\n" + text
    # Return the flattened text.
    return text


class ModelUnavailable(Exception):
    """Raised by call_model() when every attempt failed: the run ends as "model_error"."""


# Errors worth another attempt: the request timed out, the connection failed, the
# provider is rate-limiting, or it had an internal error. Anything else (a bad
# request, a wrong key, a prompt too long for the model) is a result, not bad
# luck, and is never retried.
RETRYABLE_ERRORS = (openai.APITimeoutError, openai.APIConnectionError,
                    openai.RateLimitError, openai.InternalServerError)


def call_model(client: OpenAI, log: "RunLog", step: int, retries: int, **request):
    """One chat completion, with up to `retries` more attempts on temporary errors.

    The waits between attempts are fixed (15, 30, 60, ... seconds), so two runs
    behave the same way, and every failed attempt is logged (event "model_error").
    A reply without choices counts as failed: OpenRouter sends one, with an
    "error" object and HTTP 200, when the provider behind it fails.
    A permanent error (HTTP 4xx other than 429) is logged once and not retried.
    Returns (response, seconds the successful attempt took).
    Oracle analogy: a connect string with RETRY_COUNT and RETRY_DELAY, where
    every failed attempt also goes to the alert log."""
    # Attempt 1 is the call itself; then up to `retries` more.
    for attempt in range(1, retries + 2):
        # Time this attempt.
        t0 = time.monotonic()
        try:
            # The request exactly as the caller built it (model, messages, tools, ...).
            resp = client.chat.completions.create(**request)
            # A normal answer: return it with the time it took.
            if resp.choices:
                return resp, round(time.monotonic() - t0, 2)
            # No choices: the reason is in the body's "error" field, kept by the
            # openai client in model_extra (fields it doesn't know).
            extra = getattr(resp, "model_extra", None) or {}
            error = extra.get("error") or "the reply contained no choices"
        except RETRYABLE_ERRORS as exc:
            # A temporary error raised by the client: keep its type and message.
            error = f"{type(exc).__name__}: {exc}"
        except openai.APIStatusError as exc:
            # A permanent error (bad request, no credits, wrong key, prompt too
            # long...): retrying can't help. Log it and end the run cleanly.
            error = f"{type(exc).__name__}: {exc}"
            log.event("model_error", step=step, attempt=attempt, seconds=round(time.monotonic() - t0, 2),
                      error=error, retry_in=None)
            print(f"Model call failed (step {step}, attempt {attempt}): {error}; not retried", file=sys.stderr)
            raise ModelUnavailable(f"permanent error: {error}") from None
        # Wait before the next attempt: 15 s, then doubling. None after the last one.
        wait = 15 * 2 ** (attempt - 1) if attempt <= retries else None
        # Every failed attempt goes into the run log, with what happened next.
        log.event("model_error", step=step, attempt=attempt, seconds=round(time.monotonic() - t0, 2),
                  error=error, retry_in=wait)
        # And to the terminal, so an operator watching the run knows why it pauses.
        print(f"Model call failed (step {step}, attempt {attempt}): {error}"
              + (f"; retrying in {wait} s" if wait else "; giving up"), file=sys.stderr)
        # Out of attempts: the caller ends the run.
        if wait is None:
            raise ModelUnavailable(f"{attempt} attempts failed; last error: {error}")
        # Pause, then try again.
        time.sleep(wait)


class RunLog:
    """Writes the JSONL event log and the Markdown transcript of one run."""

    def __init__(self, out_dir: pathlib.Path):
        # Create the run folder (and parents) if needed; existing folders are fine.
        out_dir.mkdir(parents=True, exist_ok=True)
        # Remember the folder for the final summary message.
        self.out_dir = out_dir
        # Open the machine-readable event log, one JSON object per line.
        self.events = open(out_dir / "events.jsonl", "w", encoding="utf-8")
        # Open the human-readable transcript.
        self.transcript = open(out_dir / "transcript.md", "w", encoding="utf-8")

    def event(self, kind: str, **data) -> None:
        """Append one event, with a UTC timestamp, to events.jsonl."""
        # Build the record: what happened, when, and its details.
        record = {"ts": datetime.datetime.now(datetime.timezone.utc).isoformat(), "event": kind, **data}
        # Write it as a single JSON line; default=str handles non-JSON types.
        self.events.write(json.dumps(record, default=str) + "\n")
        # Flush immediately so a crashed run still leaves its log, like a committed redo record.
        self.events.flush()

    def md(self, text: str) -> None:
        """Append a block of Markdown to transcript.md."""
        # Write the text followed by a blank line.
        self.transcript.write(text + "\n\n")
        # Flush so the transcript can be followed live with tail -f.
        self.transcript.flush()

    def close(self) -> None:
        """Close both files."""
        # Close the event log.
        self.events.close()
        # Close the transcript.
        self.transcript.close()


async def run(args: argparse.Namespace, provider: str) -> int:
    """Start SQLcl MCP, then either list tools or run the agent loop."""
    # Path to the SQLcl launcher; the MCP server is SQLcl started with -mcp.
    sqlcl_bin = env("SQLCL_BIN", "sql")
    # Restrict level, ALWAYS passed explicitly. Since SQLcl 26.1.2 MCP mode
    # starts unrestricted by default, which would let the agent run OS
    # commands as the lab user. Level 4 (the most restrictive) blocks host
    # commands, scripts and other sensitive operations.
    restrict = env("SQLCL_RESTRICT", "4")
    # Accept only a single digit 0-4, so nothing else can reach the command line.
    if restrict not in {"0", "1", "2", "3", "4"}:
        sys.exit(f"ERROR: SQLCL_RESTRICT must be 0-4, got '{restrict}'.")
    # Describe how to start the MCP server as a child process.
    server = StdioServerParameters(
        # The executable to start.
        command=sqlcl_bin,
        # -R sets the restrict level; -mcp switches SQLcl into MCP server mode.
        args=["-R", restrict, "-mcp"],
        # Pass the current environment so SQLcl finds JAVA_HOME and its saved connections.
        env=dict(os.environ),
    )

    # Start the server and open the stdin/stdout pipes to it.
    async with stdio_client(server) as (read_stream, write_stream):
        # Open an MCP session over those pipes.
        # Introduce the harness by name, so the server knows which client this is.
        async with ClientSession(read_stream, write_stream,
                                 client_info=Implementation(name=CLIENT_NAME, version=CLIENT_VERSION)) as session:
            # MCP handshake: client and server agree on protocol version and capabilities.
            await session.initialize()
            # Ask the server for the tools it publishes (the "package spec").
            published = (await session.list_tools()).tools

            # Build the tool allow-list from the option or .env. Safe by default:
            # empty or unset means DEFAULT_ALLOWED_TOOLS, never "everything";
            # "ALL" must be written explicitly to allow every published tool.
            allow_raw = (args.allow_tools if args.allow_tools is not None else env("ALLOWED_TOOLS", "")).strip()
            if allow_raw.upper() == "ALL":
                # Explicit opt-in: no filtering (None means "everything").
                allowed = None
            elif allow_raw.upper() == "NONE":
                # No tools at all: the model can only read the prompt and answer (post 06).
                allowed = set()
            else:
                # The given list, or the default list when nothing was given.
                allowed = {t.strip() for t in (allow_raw or DEFAULT_ALLOWED_TOOLS).split(",") if t.strip()}
            # Keep only allowed tools; the model never even sees the others.
            # Oracle analogy: not granting EXECUTE on a package, rather than asking nicely not to call it.
            tools = [t for t in published if allowed is None or t.name in allowed]

            # --list-tools: print each published tool, marked as visible to the
            # agent or hidden by the allow-list, then stop.
            if args.list_tools:
                for t in published:
                    # First line of the description, or nothing if the tool has none.
                    first_line = ((t.description or "").strip().splitlines() or [""])[0]
                    # Mark it: ALLOWED (the model sees it) or hidden.
                    mark = "ALLOWED" if t in tools else "hidden "
                    # Note the identity parameters the harness fills in for this tool.
                    ids = identity_params_of(t)
                    filled = f"  [harness fills: {', '.join(ids)}]" if ids else ""
                    # One tool per line.
                    print(f"[{mark}] {t.name}: {first_line}{filled}")
                    # --show-schemas: the full description and parameter schema too.
                    if args.show_schemas:
                        print("  description:")
                        for line in (t.description or "").strip().splitlines():
                            print(f"    {line}")
                        print("  input schema:")
                        for line in json.dumps(t.inputSchema or {}, indent=2).splitlines():
                            print(f"    {line}")
                        print()
                # Warn about allow-list entries SQLcl doesn't publish (typos, renamed tools).
                if allowed is not None:
                    for name in sorted(allowed - {t.name for t in published}):
                        print(f"WARNING: allow-list entry '{name}' is not published by this SQLcl.", file=sys.stderr)
                return 0
            # Convert the kept tools to the format both providers expect.
            openai_tools = [mcp_tool_to_openai(t) for t in tools]
            # Look up a tool's description by name (used to fill in identity parameters).
            tool_by_name = {t.name: t for t in tools}

            # Resolve the remaining settings: model, step limit, temperature, output cap, timeout.
            model = args.model or env("DEFAULT_MODEL", required=True)
            max_steps = args.max_steps or int(env("MAX_STEPS", "20"))
            temperature = args.temperature if args.temperature is not None else float(env("TEMPERATURE", "0"))
            max_tool_chars = int(env("MAX_TOOL_OUTPUT_CHARS", "20000"))
            # Seconds to wait for one model answer; local CPU-only models can be slow.
            timeout = float(env("REQUEST_TIMEOUT", "600"))
            # Extra attempts after a temporary provider error (call_model); 0 = none.
            retries = int(env("MODEL_RETRIES", "3"))
            # How much a reasoning model may think before it answers, for servers
            # that take the OpenAI-style "reasoning_effort" field (e.g. "none":
            # no thinking at all, on Ollama). Empty: nothing is sent, so the
            # model runs with its server's default, as in every post before 12.
            reasoning_effort = env("REASONING_EFFORT", "") or None
            # The extra request field, sent with every model call of the run (or nothing).
            extra_body = {"reasoning_effort": reasoning_effort} if reasoning_effort else None

            # A prompt file is mandatory for a real run.
            if not args.prompt_file:
                sys.exit("ERROR: --prompt-file is required (or use --list-tools / --list-models).")
            # Read the system prompt shared by all test cases.
            system_prompt = args.system_file.read_text(encoding="utf-8")
            # Read the test-case prompt.
            user_prompt = args.prompt_file.read_text(encoding="utf-8")
            # Append each attached file, clearly delimited, and keep its fingerprint for the log.
            attached = []
            for path in args.attach:
                if not path.is_file():
                    sys.exit(f"ERROR: attached file not found: {path}")
                content = path.read_text(encoding="utf-8", errors="replace")
                user_prompt += (f"\n\n----- BEGIN ATTACHED FILE: {path.name} -----\n{content}"
                                f"\n----- END ATTACHED FILE: {path.name} -----\n")
                attached.append({"file": str(path), "chars": len(content),
                                 "sha256": hashlib.sha256(content.encode("utf-8")).hexdigest()})

            # Default output folder: output/<UTC timestamp>_<provider>_<model>, unique per run.
            stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
            out_dir = args.out_dir or DEFAULT_OUTPUT_ROOT / f"{stamp}_{provider}_{safe_name(model)}"
            # Open the logs for this run.
            log = RunLog(out_dir)

            # Endpoint, key variable and headers for the chosen provider.
            ps = provider_settings(provider)
            # The key: required for OpenRouter; for local servers any non-empty placeholder works.
            api_key = env(ps["api_key_var"], "local" if provider == "local" else None, required=(provider == "openrouter"))
            # Create the OpenAI-compatible client pointed at the provider.
            client = OpenAI(
                # Provider endpoint instead of the OpenAI default.
                base_url=ps["base_url"],
                # The key comes from .env and is never written to the logs.
                api_key=api_key,
                # Provider-specific extra headers.
                default_headers=ps["headers"],
                # Per-request timeout, so a stuck model call fails instead of hanging forever.
                timeout=timeout,
                # No silent retries inside the client: call_model() retries on a fixed
                # schedule and logs every failed attempt.
                max_retries=0,
            )

            # Record the run configuration first, so every log is self-describing.
            log.event("run_start", provider=provider, base_url=ps["base_url"], model=model, sqlcl_restrict=restrict,
                      prompt_file=str(args.prompt_file), system_file=str(args.system_file),
                      temperature=temperature, max_steps=max_steps, tools=[t.name for t in tools], confirm=args.confirm,
                      final_on_limit=args.final_on_limit, attached=attached,
                      request_timeout=timeout, model_retries=retries, reasoning_effort=reasoning_effort)
            # Start the transcript with the same information.
            log.md(f"# Run {stamp}\n\n- Provider: `{provider}` ({ps['base_url']})\n- Model: `{model}`\n- Prompt: `{args.prompt_file}`\n- Temperature: {temperature}\n- Tools: {', '.join(t.name for t in tools)}"
                   + (f"\n- Reasoning effort: {reasoning_effort}" if reasoning_effort else ""))
            # The transcript shows the prompt as written, and each attachment by name and
            # fingerprint only (an AWR report would bury the transcript); the model got it all.
            log.md(f"## Prompt\n\n{args.prompt_file.read_text(encoding='utf-8')}")
            for a in attached:
                log.md(f"Attached: `{a['file']}` ({a['chars']} characters, sha256 {a['sha256']})")

            # The conversation starts with the system prompt and the test-case prompt.
            messages = [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt},
            ]
            # Running totals of tokens across the run, for cost comparison between models.
            total_in = total_out = 0
            # The model's final answer, once it stops asking for tools.
            final_answer = None
            # Step counter, kept outside the loop so it is defined even if the loop never runs.
            step = 0
            # Set when the model could not be reached at all (call_model gave up).
            model_error = None

            # The agent loop, bounded by max_steps like CPU_PER_CALL bounds a runaway session.
            for step in range(1, max_steps + 1):
                # Ask the model for its next move, retrying temporary provider errors
                # (call_model). The client call is blocking, so run it in a thread.
                try:
                    resp, elapsed = await asyncio.to_thread(
                        call_model, client, log, step, retries,
                        model=model, messages=messages, tools=openai_tools or None, temperature=temperature,
                        extra_body=extra_body,
                    )
                except ModelUnavailable as exc:
                    # Every attempt failed: stop here; the run ends as "model_error".
                    model_error = str(exc)
                    break
                # The single answer choice returned by the model.
                msg = resp.choices[0].message
                # Token usage, if the provider reported it.
                usage = resp.usage
                # Add this call's tokens to the totals.
                total_in += getattr(usage, "prompt_tokens", 0) or 0
                total_out += getattr(usage, "completion_tokens", 0) or 0
                # Log the model call: which model and which provider actually answered
                # (OpenRouter names the provider in a field of its own, kept in
                # model_extra), timing, tokens, and its text.
                log.event("model_call", step=step, model_returned=resp.model,
                          provider_returned=(getattr(resp, "model_extra", None) or {}).get("provider"),
                          seconds=elapsed,
                          prompt_tokens=getattr(usage, "prompt_tokens", None),
                          completion_tokens=getattr(usage, "completion_tokens", None),
                          content=msg.content, tool_calls=len(msg.tool_calls or []))

                # Keep the assistant message in the conversation, rebuilt as a plain dict
                # so only fields every provider understands are sent back.
                assistant = {"role": "assistant", "content": msg.content or ""}
                if msg.tool_calls:
                    assistant["tool_calls"] = [
                        {"id": tc.id, "type": "function",
                         "function": {"name": tc.function.name, "arguments": tc.function.arguments or "{}"}}
                        for tc in msg.tool_calls
                    ]
                messages.append(assistant)

                # No tool calls means the model has finished: this is the final answer.
                if not msg.tool_calls:
                    final_answer = msg.content or ""
                    break

                # Any text the model wrote alongside its tool calls goes to the transcript.
                if msg.content:
                    log.md(f"### Step {step}: model says\n\n{msg.content}")
                    # In approval mode the human sees the model's stated reason
                    # (the system prompt asks for one) before deciding.
                    if args.confirm:
                        print(f"\nModel says (step {step}):\n{msg.content.strip()}")

                # Execute each requested tool call in order.
                for tc in msg.tool_calls:
                    # The tool the model wants to call.
                    name = tc.function.name
                    # Parse its JSON arguments; malformed JSON becomes an error returned to the model.
                    # (Small local models produce malformed arguments more often; this keeps the run going.)
                    try:
                        arguments = json.loads(tc.function.arguments or "{}")
                    except json.JSONDecodeError as exc:
                        arguments, output = None, f"TOOL ERROR: arguments are not valid JSON ({exc})"

                    # Write the request to the transcript before running it.
                    log.md(f"### Step {step}: tool call `{name}`\n\n```json\n{json.dumps(arguments, indent=2)}\n```")

                    if arguments is not None:
                        # Refuse any tool outside the allow-list, even if the model invents its name.
                        if allowed is not None and name not in allowed:
                            output = f"TOOL ERROR: tool '{name}' is not allowed in this test."
                        # Human approval mode: show the call and wait for an explicit yes.
                        elif args.confirm and not ask_approval(log, step, name, arguments):
                            output = "TOOL ERROR: the human operator rejected this tool call."
                        else:
                            # Fill in the identity parameters this tool declares, with the
                            # TRUE values, overriding anything the model might have sent.
                            identity = {"model": model, "mcp_client": CLIENT_NAME}
                            ids = identity_params_of(tool_by_name[name]) if name in tool_by_name else []
                            injected = {p: identity[p] for p in ids}
                            arguments.update(injected)
                            # Record what the harness added, so the log shows exactly what SQLcl received.
                            if injected:
                                log.md(f"Harness added: `{json.dumps(injected)}`")
                            # Time the tool call.
                            t1 = time.monotonic()
                            # Run the tool through SQLcl MCP; SQLcl executes it in the database.
                            result = await session.call_tool(name, arguments)
                            # Flatten the result to text.
                            output = result_text(result)
                            # Log the tool timing.
                            log.event("tool_timing", step=step, tool=name, seconds=round(time.monotonic() - t1, 2))

                    # Cap very large outputs so one huge result can't flood the model's context
                    # (the agent's "PGA"), and say so explicitly.
                    if len(output) > max_tool_chars:
                        output = output[:max_tool_chars] + f"\n[OUTPUT TRUNCATED at {max_tool_chars} characters]"

                    # Log the call and its full (capped) output.
                    log.event("tool_call", step=step, tool=name, arguments=arguments, output=output)
                    # Show the output in the transcript.
                    log.md(f"Result:\n\n```\n{output}\n```")
                    # Return the result to the model, linked to the call it answers.
                    messages.append({"role": "tool", "tool_call_id": tc.id, "content": output})

            # How the run ended, recorded in run_end: "answer" (the model stopped on
            # its own), "final_on_limit" (asked for its answer at the limit),
            # "max_steps" (stopped with no answer) or "model_error" (the model
            # could not be reached, after every retry).
            ended = "answer"

            # Out of steps, and asked to: one last call with no tools, so the model
            # can only write text. Like a resumable space allocation that, instead
            # of waiting forever, tells the session to finish with what it has.
            if final_answer is None and model_error is None and args.final_on_limit:
                # The instruction is part of the conversation, so it is in the log too.
                notice = (f"You have reached the limit of {max_steps} steps: no more tool calls are possible. "
                          "Write your final answer now, using only the results you have already received, "
                          "in the format the task asks for. Say what you could not check.")
                messages.append({"role": "user", "content": notice})
                log.md(f"### Step limit reached: the harness asks for the final answer\n\n> {notice}")
                # This call has its own step number.
                step = max_steps + 1
                # No tools offered: the only possible reply is text. Same retries as above.
                try:
                    resp, elapsed = await asyncio.to_thread(
                        call_model, client, log, step, retries,
                        model=model, messages=messages, temperature=temperature,
                        extra_body=extra_body,
                    )
                except ModelUnavailable as exc:
                    # Every attempt failed: no answer; the run ends as "model_error".
                    model_error = str(exc)
                    resp = None
                if resp is not None:
                    # Count and log it like any other model call.
                    usage = resp.usage
                    total_in += getattr(usage, "prompt_tokens", 0) or 0
                    total_out += getattr(usage, "completion_tokens", 0) or 0
                    log.event("model_call", step=step, model_returned=resp.model,
                              provider_returned=(getattr(resp, "model_extra", None) or {}).get("provider"),
                              seconds=elapsed,
                              prompt_tokens=getattr(usage, "prompt_tokens", None),
                              completion_tokens=getattr(usage, "completion_tokens", None),
                              content=resp.choices[0].message.content, tool_calls=0, final_on_limit=True)
                    final_answer = resp.choices[0].message.content or ""
                    ended = "final_on_limit"

            # The model could not be reached: record that instead of a final answer.
            if model_error is not None:
                final_answer = f"[STOPPED: no answer from the model at step {step}: {model_error}]"
                ended = "model_error"
            # If the loop ran out of steps, record that instead of a final answer.
            elif final_answer is None:
                final_answer = f"[STOPPED: reached MAX_STEPS={max_steps} without a final answer]"
                ended = "max_steps"

            # Log the end of the run with token totals for cost comparison.
            log.event("run_end", steps=step, prompt_tokens_total=total_in, completion_tokens_total=total_out,
                      ended=ended, final_answer=final_answer)
            # Write the final answer to the transcript.
            log.md(f"## Final answer\n\n{final_answer}\n\n---\nSteps: {step} · Tokens in/out: {total_in}/{total_out}")
            # Close the log files.
            log.close()
            # Tell the operator where the run is stored.
            print(f"Run complete: {out_dir}")
            # The model never answered: say so and fail, so scripts can tell.
            if ended == "model_error":
                print(f"ERROR: {final_answer}", file=sys.stderr)
                return 1
            # Success exit code.
            return 0



def ask_approval(log, step: int, name: str, arguments: dict) -> bool:
    """Human approval mode (--confirm): show the tool call, wait for an explicit
    "y", and log the decision with the time the human took (event "approval").
    Anything but "y" (Enter included) is a rejection.

    Keys typed BEFORE the question appeared are thrown away first: without
    that, a "y" typed ahead (while the model was thinking) approves a call
    nobody has read yet. Post 10's first run did exactly that."""
    # Discard typeahead, when stdin is a terminal (termios is Unix-only, as is the lab).
    if sys.stdin.isatty():
        import termios
        termios.tcflush(sys.stdin, termios.TCIFLUSH)
    started = time.monotonic()
    answer = input(f"\nApprove {name} {json.dumps(arguments)}? [y = run it / anything else, Enter included = reject] ").strip().lower()
    approved = answer == "y"
    log.event("approval", step=step, tool=name, approved=approved, seconds=round(time.monotonic() - started, 2))
    return approved

def main() -> int:
    """Entry point: load settings, then dispatch."""
    # Load the harness .env (keys, endpoints, defaults); existing environment variables win.
    load_dotenv(HARNESS_DIR / ".env")
    # Parse the command-line options.
    args = parse_args()
    # --show-schemas is --list-tools with more detail.
    args.list_tools = args.list_tools or args.show_schemas
    # Provider: command line first, then .env, then openrouter.
    provider = args.provider or env("DEFAULT_PROVIDER", "openrouter")
    # Reject a misspelt DEFAULT_PROVIDER clearly instead of failing later.
    if provider not in PROVIDERS:
        sys.exit(f"ERROR: unknown provider '{provider}'. Use one of: {', '.join(PROVIDERS)}")
    # --list-models needs neither SQLcl nor (for OpenRouter) an API key.
    if args.list_models:
        list_models(provider)
        return 0
    # Everything else needs the MCP server, so run the async part.
    return asyncio.run(run(args, provider))


# Run main() only when the file is executed, not when it is imported.
if __name__ == "__main__":
    # Exit with main()'s return code so shell scripts can test success.
    sys.exit(main())
