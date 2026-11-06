#!/usr/bin/env bash
# =============================================================================
# 04_search.sh
#
# AI Vector Search over the runbooks, in plain SQL, as RAG_LAB:
#   the question becomes a vector (VECTOR_EMBEDDING, the same model as the
#   chunks), and the TOP_K chunks with the smallest cosine distance to it
#   are the answer.
#
#   ./04_search.sh                    every question in questions.txt; writes,
#                                     per question <id>, the two files the agent gets:
#                                       question_<id>.txt   the question only
#                                       context_<id>.txt    the question + the TOP_K chunks
#                                     and retrieval.txt: was the expected runbook found?
#   ./04_search.sh "any question"     just the search, printed
#
# Run as the lab user. Read-only.
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

# The TOP_K chunks closest to a question, one line each:
#   #HIT#|rank|runbook|section|distance|chunk text
search() {
    local question="$1"
    # The question goes into a q-quoted literal: it must not contain "~'".
    [[ "${question}" != *"~'"* ]] || die "the question must not contain ~'"
    # ...and no "&": SQL*Plus would read it as a substitution variable.
    [[ "${question}" != *"&"* ]] || die "the question must not contain &"
    run_as_rag <<SQL
set heading off pagesize 0 linesize 4000 trimspool on tab off define on
variable q varchar2(4000)
exec :q := q'~${question}~'
-- The question's vector, computed once, compared with every chunk's.
select '#HIT#|' || rownum || '|' || runbook || '|' || section || '|' || to_char(dist, 'fm0.0000') || '|' || chunk_text
from  (select runbook, section, chunk_text,
              vector_distance(embedding, vector_embedding(&model_name using :q as data), cosine) dist
       from   runbook_chunks
       order  by dist
       fetch  first &top_k rows only);
exit
SQL
}

# Show hits readably: rank, distance, runbook, section.
show_hits() {
    awk -F'|' '$1 == "#HIT#" { printf "    %s. %s  %-26s %s\n", $2, $5, $3, $4 }'
}

# ---- A single free-text question ----------------------------------------------
if [[ $# -gt 0 ]]; then
    step "Search: $1"
    if ! hits="$(search "$1")"; then
        echo "${hits}" | tail -10 >&2
        die "the search failed: did ./03_load_runbooks.sh complete?"
    fi
    show_hits <<< "${hits}"
    exit 0
fi

# ---- Every question in questions.txt ------------------------------------------
retrieval="${POST08_OUT}/retrieval.txt"
: > "${retrieval}"
for id in $(question_ids); do
    IFS='|' read -r expected question <<< "$(question_by_id "${id}")"
    step "Question '${id}': ${question}"
    # A failed search (no table yet, no model) shows the Oracle error, not silence.
    if ! hits="$(search "${question}")"; then
        echo "${hits}" | tail -10 >&2
        die "the search failed: did ./03_load_runbooks.sh complete?"
    fi
    grep -q '^#HIT#' <<< "${hits}" || { echo "${hits}" >&2; die "the search returned nothing."; }
    show_hits <<< "${hits}"

    # Was the runbook that answers it found, and at which rank?
    rank="$(awk -F'|' -v e="${expected}" '$1 == "#HIT#" && $3 == e { print $2; exit }' <<< "${hits}")"
    if [[ "${rank}" == "1" ]]; then
        verdict="found first"
    elif [[ -n "${rank}" ]]; then
        verdict="found at rank ${rank}"
    else
        verdict="NOT in the top ${TOP_K}"
    fi
    info "Expected runbook ${expected}: ${verdict}."
    echo "${id} | expected ${expected} | ${verdict}" >> "${retrieval}"

    # The two files the agent gets: without and with the runbooks.
    printf '=== Incident question\n%s\n' "${question}" > "${POST08_OUT}/question_${id}.txt"
    {
        printf '=== Incident question\n%s\n\n' "${question}"
        printf "=== Excerpts from our team's runbooks: the %s closest to the question (AI Vector Search, cosine distance)\n" "${TOP_K}"
        awk -F'|' '$1 == "#HIT#" {
            # The chunk text is everything after the fifth "|" (it may contain "|").
            text = $0; for (i = 1; i <= 5; i++) sub(/^[^|]*\|/, "", text)
            printf "\n[%s] runbook: %s, section: %s (distance %s)\n%s\n", $2, $3, $4, $5, text
        }' <<< "${hits}"
    } > "${POST08_OUT}/context_${id}.txt"
done

step "Retrieval"
sed 's/^/    /' "${retrieval}"
info "Saved: ${retrieval}, question_<id>.txt, context_<id>.txt in ${POST08_OUT}"
info "Next: ./06_run_agent.sh"
