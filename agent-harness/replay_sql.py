#!/usr/bin/env python3
# =============================================================================
# replay_sql.py
#
# Runs a FIXED list of SQL statements through the SQLcl MCP server, exactly
# as the agent would (same server, same restrict level, same saved
# connection, same tools), but WITHOUT a model. Nothing is generated, so the
# result is the same every time.
#
# Used for:
#   - SQL Firewall capture (post 03): teach the firewall the approved queries
#     through the same path the agent uses
#   - deterministic tests (post 03 and later): each statement can carry an
#     expected outcome, and the script reports PASS/FAIL
#
# Oracle analogy: Database Replay for the agent's connection path, with a
# workload you wrote yourself.
#
# Statement file format:
#   - each statement ends with ";" at the end of a line (it may span lines)
#   - lines starting with "--" are comments
#   - an optional "-- expect: ok", "-- expect: error" (any Oracle error) or
#     "-- expect: ORA-00942" line sets the expected outcome of the NEXT statement
#
# --json prints one object per statement, with the elapsed seconds and the
# full tool output as well (post 09 uses both as evidence).
#
# Usage:
#   .venv/bin/python replay_sql.py --file statements.sql [--connection agent] [--json]
# Exit code: 0 if every statement with an expectation met it, 1 otherwise.
# =============================================================================

# argparse parses the command-line options.
import argparse
# asyncio runs the MCP client.
import asyncio
# json writes the machine-readable result lines.
import json
# os passes the environment to SQLcl.
import os
# pathlib reads the statement file.
import pathlib
# re finds Oracle error codes in tool output.
import re
# sys gives the exit code and stderr.
import sys
# time measures how long each statement took (post 09 uses it as evidence).
import time

# The same .env loader the agent uses.
from dotenv import load_dotenv
# MCP client pieces, as in run_agent.py.
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from mcp.types import Implementation

# Reuse the agent's own helpers, so the replay follows exactly the same rules:
# settings, identity parameters, result flattening, client name.
from run_agent import CLIENT_NAME, CLIENT_VERSION, HARNESS_DIR, env, identity_params_of, result_text

# Value written into SQLcl's "model" parameter (V$SESSION.MODULE) during a
# replay, so these sessions are never mistaken for a real model's.
REPLAY_MODEL = "replay (no model)"
# First Oracle error in a text, e.g. "ORA-00942: table or view does not exist".
# Only "ORA-nnnnn" followed by a colon counts, as in run_summary.py: SQLcl echoes
# a failed statement, and an "ORA-nnnnn" inside its text is not an error.
ORA_CODE = re.compile(r"ORA-\d{5}(?=:)")


def parse_statements(text: str) -> list[dict]:
    """Split a statement file into [{'sql': ..., 'expect': ...}, ...]."""
    statements = []
    buffer = []
    expect = None
    for line in text.splitlines():
        stripped = line.strip()
        # An expectation for the next statement.
        if stripped.lower().startswith("-- expect:"):
            expect = stripped.split(":", 1)[1].strip()
            continue
        # Any other comment, or a blank line outside a statement: skip.
        if stripped.startswith("--") or (not stripped and not buffer):
            continue
        # Part of a statement.
        buffer.append(line)
        # A trailing ";" ends the statement.
        if stripped.endswith(";"):
            sql = "\n".join(buffer).strip()
            # SQL statements are sent without the ";" terminator. A PL/SQL block
            # (BEGIN/DECLARE ... END;) needs its final ";", so it is kept.
            if not sql.upper().startswith(("BEGIN", "DECLARE")):
                sql = sql[:-1].strip()
            statements.append({"sql": sql, "expect": expect})
            buffer, expect = [], None
    # A statement without a final ";" is a mistake in the file: refuse it.
    if buffer:
        sys.exit("ERROR: the last statement in the file does not end with ';'.")
    return statements


def judge(expect: str | None, error: str | None) -> bool | None:
    """True/False if the outcome met the expectation, None if there was none."""
    if expect is None:
        return None
    # "ok": the statement must succeed.
    if expect.lower() == "ok":
        return error is None
    # "error": any error is the expected outcome (the actual code is reported).
    if expect.lower() == "error":
        return error is not None
    # A specific code, e.g. ORA-00942.
    return error == expect.upper()


async def replay(conn_name: str, statements: list[dict], as_json: bool) -> int:
    """Connect through SQLcl MCP and run each statement; return the exit code."""
    # Start SQLcl exactly as run_agent.py does: same binary, explicit restrict level.
    restrict = env("SQLCL_RESTRICT", "4")
    if restrict not in {"0", "1", "2", "3", "4"}:
        sys.exit(f"ERROR: SQLCL_RESTRICT must be 0-4, got '{restrict}'.")
    server = StdioServerParameters(command=env("SQLCL_BIN", "sql"), args=["-R", restrict, "-mcp"], env=dict(os.environ))

    async with stdio_client(server) as (read_stream, write_stream):
        async with ClientSession(read_stream, write_stream,
                                 client_info=Implementation(name=CLIENT_NAME, version=CLIENT_VERSION)) as session:
            # Handshake and tool list.
            await session.initialize()
            tools = {t.name: t for t in (await session.list_tools()).tools}
            # The two tools a replay needs.
            for needed in ("connect", "sql_run"):
                if needed not in tools:
                    sys.exit(f"ERROR: SQLcl does not publish the '{needed}' tool.")
            # Identity values filled in exactly as the agent's harness does.
            identity = {"model": REPLAY_MODEL, "mcp_client": CLIENT_NAME}

            def with_identity(tool_name: str, arguments: dict) -> dict:
                # Add the identity parameters this tool declares.
                return {**arguments, **{p: identity[p] for p in identity_params_of(tools[tool_name])}}

            # Connect by name, like the agent.
            result = await session.call_tool("connect", with_identity("connect", {"connection_name": conn_name}))
            text = result_text(result)
            if getattr(result, "isError", False) or "ESTABLISHED" not in text.upper():
                print(text, file=sys.stderr)
                sys.exit(f"ERROR: could not connect to the saved connection '{conn_name}'.")

            failures = 0
            for n, st in enumerate(statements, start=1):
                # Run the statement through the same tool the agent uses.
                # Wall-clock time of the call: client -> SQLcl -> database and back.
                started = time.monotonic()
                result = await session.call_tool("sql_run", with_identity("sql_run", {"sql": st["sql"]}))
                elapsed = time.monotonic() - started
                output = result_text(result)
                # The first Oracle error in the output, if any.
                match = ORA_CODE.search(output)
                error = match.group(0) if match else ("TOOL-ERROR" if getattr(result, "isError", False) else None)
                verdict = judge(st["expect"], error)
                if verdict is False:
                    failures += 1
                if as_json:
                    # One JSON object per statement, for scripts.
                    # "elapsed" (seconds) and "output" (what SQLcl returned) are
                    # extra evidence; the readable mode below does not show them.
                    print(json.dumps({"n": n, "sql": st["sql"], "expect": st["expect"],
                                      "error": error, "pass": verdict,
                                      "elapsed": round(elapsed, 2), "output": output}))
                else:
                    # One readable line per statement.
                    label = {True: "PASS", False: "FAIL", None: "    "}[verdict]
                    outcome = error or "ok"
                    shown = " ".join(st["sql"].split())
                    shown = shown if len(shown) <= 70 else shown[:67] + "..."
                    expected = f" (expected {st['expect']})" if st["expect"] else ""
                    print(f"  {label}  {outcome:<10} {shown}{expected}")

            # Close the database session cleanly.
            if "disconnect" in tools:
                await session.call_tool("disconnect", with_identity("disconnect", {}))
            return 1 if failures else 0


def main() -> int:
    """Parse the options, read the statement file, run the replay."""
    # Same settings file as the agent (SQLcl path, restrict level).
    load_dotenv(HARNESS_DIR / ".env")
    p = argparse.ArgumentParser(description="Replay a fixed SQL list through SQLcl MCP as the agent, without a model.")
    p.add_argument("--file", type=pathlib.Path, required=True, help="Statement file (see the header of this script)")
    p.add_argument("--connection", default="agent", help="Saved SQLcl connection to use (default: agent)")
    p.add_argument("--json", action="store_true", help="One JSON object per statement instead of readable lines")
    args = p.parse_args()
    statements = parse_statements(args.file.read_text(encoding="utf-8"))
    if not statements:
        sys.exit(f"ERROR: no statements found in {args.file}.")
    return asyncio.run(replay(args.connection, statements, args.json))


# Run main() only when executed, not when imported.
if __name__ == "__main__":
    sys.exit(main())
