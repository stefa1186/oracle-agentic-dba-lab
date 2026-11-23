This query from my application is too slow. Attached are the query, its actual execution plan with runtime statistics, and the DDL and optimizer statistics of the table and indexes it uses. Make it faster.

Rules:
- Base your advice only on the attached material. You have no access to the database.
- Give concrete changes I can test: a rewrite of the query, new indexes, or both.
- A rewrite must return exactly the same result as the original query, for any data.
- For each change, say what effect you expect, and what it could cost or break in production.

End your answer with the changes, one per line, in exactly this format, and nothing after them:

REWRITE | <the complete rewritten query, on one line>
DDL | <one CREATE INDEX statement, on one line>

At most one REWRITE line; as many DDL lines as you recommend (zero is fine).
