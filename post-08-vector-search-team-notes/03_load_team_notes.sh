#!/usr/bin/env bash
# =============================================================================
# 03_load_team_notes.sh
#
# Loads the team notes into the database, as RAG_LAB:
#   1. TEAM_NOTE_CHUNKS: one row per team note section, with a VECTOR column
#   2. the chunks, from chunk_team_notes.py
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

step "Chunking ${TEAM_NOTES_DIR}"
inserts="$(python3 "${POST08_DIR}/chunk_team_notes.py" "${TEAM_NOTES_DIR}")"
info "$(grep -o 'CHUNKS=.*' <<< "${inserts}")"

step "Loading and embedding, as ${RAG_SCHEMA}"
if ! output="$( {
    cat <<'SQL'
set heading off pagesize 0 linesize 300 tab off
-- Start clean: the table, if a previous run left it.
begin
    execute immediate 'drop table team_note_chunks purge';
exception
    -- ORA-00942: no such table (first run).
    when others then if sqlcode != -942 then raise; end if;
end;
/
-- One row per team note section. EMBEDDING: a VECTOR, its size set by the model.
-- ID comes from the chunker (1, 2, 3...): an identity column would need the
-- CREATE SEQUENCE privilege, and this user has only what it needs.
create table team_note_chunks (
    id         number         primary key,
    team_note  varchar2(64)   not null,
    section    varchar2(200)  not null,
    chunk_text varchar2(4000) not null,
    embedding  vector
);
SQL
    # The chunks. Substitution off while they load: a "&" in a team note must
    # stay a "&", not become a prompt for a value.
    echo "set define off"
    echo "${inserts}"
    echo "set define on"
    cat <<'SQL'
-- The embeddings, computed by the model inside the database.
update team_note_chunks set embedding = vector_embedding(&model_name using chunk_text as data);
commit;
-- What's there now.
select 'ROW ' || rpad(team_note, 26) || ' | ' || rpad(section, 22) || ' | dims ' || vector_dimension_count(embedding)
from   team_note_chunks order by id;
select 'LOAD_COMPLETE' from dual;
exit
SQL
} | run_as_rag )"; then
    echo "${output}" | tail -20 >&2
    die "loading the team notes failed."
fi
grep -q LOAD_COMPLETE <<< "${output}" || { echo "${output}" | tail -20 >&2; die "unexpected output from SQL*Plus."; }
grep '^ROW ' <<< "${output}" | sed 's/^ROW /    /'

step "Done"
info "Next: ./04_search.sh"
