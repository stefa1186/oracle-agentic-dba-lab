"""grade.py: the database side of the NL2SQL test (the model side is the harness).

  python3 grade.py schema bare|comments   print the schema as the model sees it
  python3 grade.py grade <runs folder>    grade every run's answer, write results.csv

Runs as the lab user, called by 02_build_inputs.sh and 05_grade.sh. The SQL
runs in the database container as the read-only user: SELECT on SH, nothing else.
"""

import csv          # the results file
import glob         # the harness's run folders
import json         # the log of every answer
import os           # settings from the environment
import re           # cleaning the model's answer
import subprocess   # SQL*Plus inside the database container
import sys          # arguments, exit code

# Settings from 02_run_nl2sql.sh.
CONTAINER = os.environ["DB_CONTAINER"]
RO_USER = os.environ["RO_USER"]
RO_PASSWORD = open(os.environ["RO_PASSWORD_FILE"]).read().strip()
# SH's 9 base tables: no Oracle Text index tables (DR$), no materialized views.
TABLE_FILTER = "t.owner = 'SH' and t.table_name not like 'DR$%' and t.table_name not like '%\\_MV' escape '\\'"

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
    # The questions: id -> (group, question, reference).
    questions = {l.split("|", 3)[0]: l.rstrip("\n").split("|", 3)[1:] for l in open(os.environ["QUESTIONS"])
                 if l.strip() and not l.startswith("#")}
    if sys.argv[1] == "schema":
        print(schema_text(sys.argv[2] == "comments"))
        return
    # grade: every run of the harness under the folder given.
    runs = sorted(glob.glob(os.path.join(sys.argv[2], "**", "events.jsonl"), recursive=True))
    out = os.path.join(sys.argv[2], "results.csv")
    with open(out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["model", "metadata", "qid", "group", "outcome", "detail", "tokens_in", "tokens_out", "sql", "run"])
        for path in runs:
            ev = [json.loads(l) for l in open(path)]
            start = next(e for e in ev if e.get("event") == "run_start")
            end = next((e for e in ev if e.get("event") == "run_end"), {})
            # The attached file names the setup: input_<metadata>_<question id>.txt.
            name = os.path.basename(start["attached"][0]["file"])
            meta, qid = re.match(r"input_(\w+?)_(\w+)\.txt", name).groups()
            group, question, reference = questions[qid]
            sql = clean(end.get("final_answer"))
            outcome, detail = grade(sql, reference.strip()) if end else ("ERROR", "no answer")
            w.writerow([start.get("model"), meta, qid, group, outcome, detail,
                        end.get("prompt_tokens_total", ""), end.get("completion_tokens_total", ""), sql, os.path.dirname(path)])
            print(f"  {start.get('model', ''):40.40} {meta:8} {qid}  {outcome:5}  {detail}", flush=True)
    print(f"Results: {out}")


if __name__ == "__main__":
    main()
