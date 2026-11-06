# The hand-written fix files

`06_try_fix.sh` reads fix lines (`REWRITE | ...`, `DDL | ...`) from an agent
run, from SQL Tuning Advisor's script, or from one of these files. They are
written by a person, and say so:

| File | What it is |
|---|---|
| `advisor_text_fixes.txt` | SQL Tuning Advisor's two **text-only** recommendations, translated into statements by me: "Rewrite the predicate into an equivalent form to take advantage of indices" (a date range on ORDER_DATE) and "Alternatively, create a function-based index on the expression" (an index on TRUNC(ORDER_DATE)). The advisor's own script had no actions (observed 2026-11-05). |
| `dba_fixes.txt` | My own fix as a DBA: the same date range, and an index on (ORDER_DATE, STATUS), so only the 200 matching rows are fetched from the table. With this table's clustering factor (999,998 on ORDERS_DATE_IX), that difference should show. |

Run them like any other source:

```bash
./06_try_fix.sh advisor_text_fixes.txt
./06_try_fix.sh dba_fixes.txt
```
