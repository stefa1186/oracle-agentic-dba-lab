#!/usr/bin/env bash
# =============================================================================
# 03_load_runbooks.sh
#
# Loads the runbooks into the database, as RAG_LAB:
#   1. RUNBOOK_CHUNKS: one row per runbook section, with a VECTOR column
#   2. the chunks, from chunk_runbooks.py
#   3. every chunk's embedding, computed INSIDE the database by the model:
#      UPDATE ... SET embedding = VECTOR_EMBEDDING(model USING chunk_text AS data)
# No vector index: with a few dozen rows, an exact search (every distance
# computed) is instant, and exact means deterministic.
#
# Run as the lab user. Rerunning replaces the table and its contents.
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read posts 01-08 settings.
load_post08_config
# Must be the lab user.
require_lab_user
# The database must be up.
require_database

step "Chunking ${RUNBOOKS_DIR}"
inserts="$(python3 "${POST08_DIR}/chunk_runbooks.py" "${RUNBOOKS_DIR}")"
info "$(grep -o 'CHUNKS=.*' <<< "${inserts}")"

step "Loading and embedding, as ${RAG_SCHEMA}"
if ! output="$( {
    cat <<'SQL'
set heading off pagesize 0 linesize 300 tab off
-- Start clean: the table, if a previous run left it.
begin
    execute immediate 'drop table runbook_chunks purge';
exception
    -- ORA-00942: no such table (first run).
    when others then if sqlcode != -942 then raise; end if;
end;
/
-- One row per runbook section. EMBEDDING: a VECTOR, its size set by the model.
-- ID comes from the chunker (1, 2, 3...): an identity column would need the
-- CREATE SEQUENCE privilege, and this user has only what it needs.
create table runbook_chunks (
    id         number         primary key,
    runbook    varchar2(64)   not null,
    section    varchar2(200)  not null,
    chunk_text varchar2(4000) not null,
    embedding  vector
);
SQL
    # The chunks. Substitution off while they load: a "&" in a runbook must
    # stay a "&", not become a prompt for a value.
    echo "set define off"
    echo "${inserts}"
    echo "set define on"
    cat <<'SQL'
-- The embeddings, computed by the model inside the database.
update runbook_chunks set embedding = vector_embedding(&model_name using chunk_text as data);
commit;
-- What's there now.
select 'ROW ' || rpad(runbook, 26) || ' | ' || rpad(section, 22) || ' | dims ' || vector_dimension_count(embedding)
from   runbook_chunks order by id;
select 'LOAD_COMPLETE' from dual;
exit
SQL
} | run_as_rag )"; then
    echo "${output}" | tail -20 >&2
    die "loading the runbooks failed."
fi
grep -q LOAD_COMPLETE <<< "${output}" || { echo "${output}" | tail -20 >&2; die "unexpected output from SQL*Plus."; }
grep '^ROW ' <<< "${output}" | sed 's/^ROW /    /'

step "Done"
info "Next: ./04_search.sh"
