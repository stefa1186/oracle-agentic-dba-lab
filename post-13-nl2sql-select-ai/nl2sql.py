"""nl2sql.py: the NL2SQL test, run by 02_run_nl2sql.sh (not on its own).

For each model, metadata level (bare, comments), repetition and question:
build one prompt from the data dictionary, ask the model for one SQL query
(temperature 0), run it as the read-only user, and grade it against the
reference with MINUS in both directions. Everything goes into one CSV.
"""

import csv          # the results file
import datetime     # the run folder's name
import json         # the log of every answer
import os           # settings from the environment
import re           # cleaning the model's answer
import subprocess   # SQL*Plus inside the database container
import sys          # arguments, exit code
import time         # how long each answer took

from dotenv import dotenv_values  # reads the harness .env (the API key)
from openai import OpenAI         # OpenAI-compatible client, pointed at OpenRouter

# Settings from 02_run_nl2sql.sh.
CONTAINER = os.environ["DB_CONTAINER"]
RO_USER = os.environ["RO_USER"]
RO_PASSWORD = open(os.environ["RO_PASSWORD_FILE"]).read().strip()
MODELS = os.environ["MODELS"].split()
REPEATS = int(os.environ["REPEATS"])
OUT_DIR = os.environ["OUT_DIR"]
# SH's 9 base tables: no Oracle Text index tables (DR$), no materialized views.
TABLE_FILTER = "t.owner = 'SH' and t.table_name not like 'DR$%' and t.table_name not like '%\\_MV' escape '\\'"

# The instructions, the same for every question and model.
SYSTEM = ("You write Oracle SQL for Oracle AI Database 26ai. Answer the question with one "
          "SELECT statement that uses only the tables below, each qualified with its owner, SH. "
          "Return only the SQL: no explanation, no code fences, no final semicolon. "
          "If the schema can't answer the question, return exactly: NO_ANSWER")


def sqlplus(script):
    """Run SQL as the read-only user, in the container; return the output."""
    # The login goes on stdin, never on a command line.
    stdin = f'connect {RO_USER}/"{RO_PASSWORD}"@//localhost:1521/FREEPDB1\n{script}\nexit\n'
    # -s: silent, -L: one login attempt only; 300 s at most per call.
    res = subprocess.run(["podman", "exec", "-i", CONTAINER, "sqlplus", "-s", "-L", "/nolog"],
                         input=stdin, capture_output=True, text=True, timeout=300)
    return res.stdout


def schema_text(with_comments):
    """The schema as the model sees it: one block per table, one line per column."""
    # Columns, types and, if asked, the column and table comments, from the dictionary.
    out = sqlplus(f"""set heading off feedback off pagesize 0 linesize 4000 trimspool on
select t.table_name || '|' || t.column_name || '|' || t.data_type || '|' ||
       replace(cc.comments, chr(10), ' ') || '|' || replace(tc.comments, chr(10), ' ')
from all_tab_columns t
left join all_col_comments cc on cc.owner = t.owner and cc.table_name = t.table_name and cc.column_name = t.column_name
left join all_tab_comments tc on tc.owner = t.owner and tc.table_name = t.table_name
where {TABLE_FILTER}
order by t.table_name, t.column_id;""")
    lines, current = [], None
    for row in out.splitlines():
        # Each row: table | column | type | column comment | table comment.
        parts = row.split("|")
        if len(parts) != 5:
            continue
        table, column, dtype, ccom, tcom = (p.strip() for p in parts)
        # A new table: its header line (with its comment, if asked).
        if table != current:
            current = table
            lines.append(f"\nTABLE SH.{table}" + (f"  -- {tcom}" if with_comments and tcom else ""))
        # The column line (with its comment, if asked).
        lines.append(f"  {column} {dtype}" + (f"  -- {ccom}" if with_comments and ccom else ""))
    return "\n".join(lines).strip()


def clean(answer):
    """The model's answer as one SQL text, or NO_ANSWER."""
    text = (answer or "").strip()
    # Code fences, if the model added them anyway.
    text = re.sub(r"^```[a-zA-Z]*\s*|\s*```$", "", text).strip()
    # A final semicolon or slash, which SQL*Plus would treat as a terminator.
    text = re.sub(r"[;/\s]+$", "", text)
    return "NO_ANSWER" if text.upper().startswith("NO_ANSWER") else text


def grade(generated, reference):
    """PASS, WRONG, ERROR or SHAPE, and a short detail."""
    # The schema can't answer: the right answer is NO_ANSWER.
    if reference == "NO_ANSWER":
        return ("PASS", "said it can't") if generated == "NO_ANSWER" else ("WRONG", "answered anyway")
    if generated == "NO_ANSWER":
        return "WRONG", "said it can't"
    # Only a query may run (the user can only SELECT anyway).
    if not re.match(r"(?is)^\s*(select|with)\b", generated):
        return "ERROR", "not a query"
    # One session: does it run, and the two MINUS counts. Markers split the output.
    out = sqlplus(f"""set heading off feedback off pagesize 0 linesize 32767 sqlblanklines on define off
prompt @@G
select count(*) from (
{generated}
);
prompt @@A
select count(*) from (select * from (
{generated}
) minus select * from ({reference}));
prompt @@B
select count(*) from (select * from ({reference}) minus select * from (
{generated}
));""")
    part = dict(re.findall(r"@@([GAB])\s*\n(.*?)(?=\n@@|\Z)", out, re.S))
    # It doesn't run: ERROR, with its ORA- code.
    err = re.search(r"(ORA-\d{5}|SP2-\d{4})", part.get("G", "ORA-?"))
    if err or not part.get("G", "").strip():
        return "ERROR", err.group(1) if err else "no result"
    # It runs, but MINUS can't compare (columns differ in number or type): checked by hand.
    for k in "AB":
        err = re.search(r"(ORA-\d{5})", part.get(k, ""))
        if err:
            return "SHAPE", err.group(1)
    # The same rows in both directions: PASS. Otherwise WRONG.
    a, b = part["A"].split()[0], part["B"].split()[0]
    return ("PASS", "") if a == b == "0" else ("WRONG", f"{a} extra, {b} missing rows")


def main():
    # The questions: id | group | question | reference.
    questions = [l.rstrip("\n").split("|", 3) for l in open(os.environ["QUESTIONS"])
                 if l.strip() and not l.startswith("#")]
    # Only some questions, if named on the command line.
    if sys.argv[1:]:
        questions = [q for q in questions if q[0] in sys.argv[1:]]
    # The OpenRouter client, with the key from the harness .env.
    key = dotenv_values(os.environ["HARNESS_ENV"]).get("OPENROUTER_API_KEY") or sys.exit("No OPENROUTER_API_KEY in agent-harness/.env.")
    client = OpenAI(base_url="https://openrouter.ai/api/v1", api_key=key, timeout=300, max_retries=2)
    # The run folder, named by the start time in UTC.
    run = os.path.join(OUT_DIR, datetime.datetime.now(datetime.timezone.utc).strftime("run_%Y%m%dT%H%M%SZ"))
    os.makedirs(run)
    # The two schema texts, built once, and saved: this is what the model reads.
    schemas = {m: schema_text(m == "comments") for m in ("bare", "comments")}
    for m, text in schemas.items():
        open(os.path.join(run, f"prompt_{m}.txt"), "w").write(SYSTEM + "\n\n" + text + "\n")
    print(f"Run folder: {run}")
    with open(os.path.join(run, "results.csv"), "w", newline="") as f, open(os.path.join(run, "answers.jsonl"), "w") as log:
        w = csv.writer(f)
        w.writerow(["model", "metadata", "rep", "qid", "group", "outcome", "detail", "seconds", "tokens_in", "tokens_out", "sql"])
        for model in MODELS:
            for meta, schema in schemas.items():
                for rep in range(1, REPEATS + 1):
                    for qid, group, question, reference in questions:
                        start = time.time()
                        try:
                            # One call: instructions, then schema and question.
                            r = client.chat.completions.create(model=model, temperature=0, messages=[
                                {"role": "system", "content": SYSTEM},
                                {"role": "user", "content": f"{schema}\n\nQuestion: {question}"}])
                            answer, usage = r.choices[0].message.content, r.usage
                            sql = clean(answer)
                            outcome, detail = grade(sql, reference.strip())
                        except Exception as e:  # a failed call is a result too
                            answer, usage, sql = "", None, ""
                            outcome, detail = "ERROR", f"call failed: {type(e).__name__}"
                        secs = round(time.time() - start, 1)
                        tin, tout = (usage.prompt_tokens, usage.completion_tokens) if usage else ("", "")
                        w.writerow([model, meta, rep, qid, group, outcome, detail, secs, tin, tout, sql])
                        f.flush()
                        log.write(json.dumps({"model": model, "metadata": meta, "rep": rep, "qid": qid, "answer": answer}) + "\n")
                        print(f"  {model:40.40} {meta:8} rep {rep}  {qid}  {outcome:5}  {detail}", flush=True)
    print(f"Results: {run}/results.csv. Next: ./03_report.sh")


if __name__ == "__main__":
    main()
