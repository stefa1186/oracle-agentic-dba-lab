"""grade.py: grades every answer of a set of runs; writes results.csv.

  python3 grade.py <set folder>

Runs as the lab user, called by 04_grade.sh. The SQL runs exactly like the
agent's: through SQLcl's MCP server, with the saved connection "agent", by the
harness's own replay_sql.py (no model). That user can only SELECT on SH.
"""

import csv          # the results file
import glob         # the harness's run folders
import json         # the run logs, and replay_sql.py's output
import os           # settings from the environment
import re           # finding the SQL in the model's answer
import subprocess   # replay_sql.py
import sys          # arguments

# The harness folder, with its virtual environment and replay_sql.py.
HARNESS = os.environ["HARNESS_DIR"]


def clean(answer):
    """The model's final SQL, or NO_ANSWER."""
    text = (answer or "").strip()
    # The answer ends with NO_ANSWER: the model says the schema can't answer.
    if re.search(r"NO_ANSWER\W*$", text):
        return "NO_ANSWER"
    # Otherwise the last ```sql block holds the query (the whole text if none).
    blocks = re.findall(r"```(?:sql)?\s*\n(.*?)```", text, re.S | re.I)
    sql = blocks[-1] if blocks else text
    # Without a final semicolon or slash: the grader adds its own.
    return re.sub(r"[;/\s]+$", "", sql.strip())


def checks(generated, reference):
    """The three statements that grade one answer: does it run, and MINUS both ways."""
    return [f"select count(*) from (\n{generated}\n);",
            f"select count(*) from (select * from (\n{generated}\n) minus select * from ({reference}));",
            f"select count(*) from (select * from ({reference}) minus select * from (\n{generated}\n));"]


def count(result):
    """The count(*) in one replay result (SQLcl returns CSV: a header, then the value)."""
    found = re.findall(r'(?m)^"?(\d+)"?\s*$', result.get("output", ""))
    return found[-1] if found else "?"


def verdict(generated, reference, results):
    """PASS, WRONG, ERROR or SHAPE, and a short detail."""
    # The schema can't answer: the right answer is NO_ANSWER.
    if reference == "NO_ANSWER":
        return ("PASS", "said it can't") if generated == "NO_ANSWER" else ("WRONG", "answered anyway")
    if generated == "NO_ANSWER":
        return "WRONG", "said it can't"
    if results is None:
        return "ERROR", "not a query"
    run, a, b = results
    # It doesn't run: ERROR, with its ORA- code.
    if run["error"]:
        return "ERROR", run["error"]
    # It runs, but MINUS can't compare (columns differ in number or type): checked by hand.
    for r in (a, b):
        if r["error"]:
            return "SHAPE", r["error"]
    # The same rows in both directions: PASS. Otherwise WRONG.
    extra, missing = count(a), count(b)
    return ("PASS", "") if extra == missing == "0" else ("WRONG", f"{extra} extra, {missing} missing rows")


def main():
    set_dir = sys.argv[1]
    # The questions: id -> (group, question, reference).
    questions = {l.split("|", 3)[0]: l.rstrip("\n").split("|", 3)[1:] for l in open(os.environ["QUESTIONS"])
                 if l.strip() and not l.startswith("#")}
    # 1. Every run's answer, from the harness's log.
    answers = []
    for path in sorted(glob.glob(os.path.join(set_dir, "**", "events.jsonl"), recursive=True)):
        ev = [json.loads(l) for l in open(path)]
        start = next(e for e in ev if e.get("event") == "run_start")
        end = next((e for e in ev if e.get("event") == "run_end"), {})
        # The attached file names the question: question_<id>.txt.
        qid = re.match(r"question_(\w+)\.txt", os.path.basename(start["attached"][0]["file"])).group(1)
        answers.append({"path": path, "start": start, "end": end, "qid": qid,
                        "sql": clean(end.get("final_answer")) if end else "NO_RUN"})
    # 2. One statement file for the whole set: three checks per query answer.
    #    Only queries run (the user can only SELECT anyway).
    statements = []
    for a in answers:
        reference = questions[a["qid"]][2].strip()
        if reference != "NO_ANSWER" and re.match(r"(?is)^\s*(select|with)\b", a["sql"]):
            a["first"] = len(statements)
            statements += checks(a["sql"], reference)
    sql_file = os.path.join(set_dir, "grade.sql")
    with open(sql_file, "w") as f:
        f.write("\n".join(statements) + "\n")
    # 3. One replay, through SQLcl MCP and the saved connection "agent".
    replayed = []
    if statements:
        res = subprocess.run([os.path.join(HARNESS, ".venv", "bin", "python"), "replay_sql.py",
                              "--file", sql_file, "--connection", "agent", "--json"],
                             cwd=HARNESS, capture_output=True, text=True)
        replayed = [json.loads(l) for l in res.stdout.splitlines() if l.startswith("{")]
        if len(replayed) != len(statements):
            sys.exit(f"ERROR: replay_sql.py returned {len(replayed)} of {len(statements)} results.\n{res.stderr[-2000:]}")
    # 4. The verdicts, into results.csv.
    out = os.path.join(set_dir, "results.csv")
    with open(out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["model", "qid", "group", "outcome", "detail", "tokens_in", "tokens_out", "sql", "run"])
        for a in answers:
            group, _question, reference = questions[a["qid"]]
            results = replayed[a["first"]:a["first"] + 3] if "first" in a else None
            outcome, detail = verdict(a["sql"], reference.strip(), results) if a["end"] else ("ERROR", "no answer")
            w.writerow([a["start"].get("model"), a["qid"], group, outcome, detail,
                        a["end"].get("prompt_tokens_total", ""), a["end"].get("completion_tokens_total", ""),
                        a["sql"], os.path.dirname(a["path"])])
            print(f"  {a['start'].get('model', ''):40.40} {a['qid']}  {outcome:5}  {detail}", flush=True)
    print(f"Results: {out}")


if __name__ == "__main__":
    main()
