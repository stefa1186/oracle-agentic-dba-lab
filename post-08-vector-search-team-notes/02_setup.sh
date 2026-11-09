#!/usr/bin/env bash
# =============================================================================
# 02_setup.sh
#
# Puts the embedding model into the database:
#   1. copies the ONNX file into the container (/tmp/post08_model), where the
#      database server can read it
#   2. creates the application user RAG_LAB (new random password, kept in
#      ~/.config/oralab/rag_lab_pwd, mode 600) and the directory object
#   3. as RAG_LAB, loads the model with DBMS_VECTOR.LOAD_ONNX_MODEL and
#      proves it works: one sentence in, one vector out
#
# Run as the lab user. SQL runs as SYSDBA, then as RAG_LAB.
# Deterministic: rerunning drops and rebuilds the user, model and table.
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

onnx="${MODEL_DIR}/${MODEL_FILE}"
[[ -s "${onnx}" ]] || die "no model file at ${onnx}: run ./01_get_model.sh first."

step "1/3 The model file into the container"
# A fresh folder inside the container, then the file, readable by the database's OS user.
podman exec "${DB_CONTAINER}" bash -c "rm -rf '${CONTAINER_MODEL_DIR}' && mkdir -p '${CONTAINER_MODEL_DIR}'"
podman cp "${onnx}" "${DB_CONTAINER}:${CONTAINER_MODEL_DIR}/${MODEL_FILE}"
podman exec -u 0 "${DB_CONTAINER}" chmod -R a+rX "${CONTAINER_MODEL_DIR}"
info "$(podman exec "${DB_CONTAINER}" ls -l "${CONTAINER_MODEL_DIR}/${MODEL_FILE}")"

step "2/3 The application user ${RAG_SCHEMA} and the directory"
mkdir -p "$(dirname "${RAG_PWD_FILE}")"
chmod 700 "$(dirname "${RAG_PWD_FILE}")"
# A new password for every setup: "Rg" + 30 random hex characters, mode 600 from the start.
( umask 077; echo "Rg$(od -An -N15 -tx1 /dev/urandom | tr -d ' \n')" > "${RAG_PWD_FILE}" )
if ! output="$(run_post08_sql setup_schema.sql "define rag_pwd = $(rag_password)")"; then
    echo "${output}" >&2
    die "setup failed."
fi
grep -q SCHEMA_READY <<< "${output}" || { echo "${output}" >&2; die "unexpected output from SQL*Plus."; }
info "${RAG_SCHEMA} created; directory RAG_MODEL_DIR -> ${CONTAINER_MODEL_DIR}; password in ${RAG_PWD_FILE} (mode 600)."

step "3/3 Loading the model as ${RAG_SCHEMA}"
if ! output="$(run_as_rag <<'SQL'
set heading off pagesize 0 linesize 300 tab off serveroutput on
-- The ONNX file becomes a mining model in RAG_LAB's schema.
begin
    dbms_vector.load_onnx_model(
        directory  => 'RAG_MODEL_DIR',
        file_name  => '&model_file',
        model_name => '&model_name');
end;
/
-- What the dictionary says about it.
select 'MODEL ' || model_name || ' | ' || mining_function || ' | ' || algorithm
from   user_mining_models where model_name = '&model_name';
-- The proof: one sentence in, one vector out, and its size.
select 'VECTOR dimensions=' || vector_dimension_count(v) || ' format=' || vector_dimension_format(v)
from  (select vector_embedding(&model_name using 'The archive destination is full' as data) v from dual);
select 'MODEL_READY' from dual;
exit
SQL
)"; then
    echo "${output}" >&2
    die "loading the model failed."
fi
grep -q MODEL_READY <<< "${output}" || { echo "${output}" >&2; die "unexpected output from SQL*Plus."; }
grep -E '^(MODEL|VECTOR) ' <<< "${output}" | sed 's/^/    /'

step "Done"
info "Next: ./03_load_team_notes.sh"
