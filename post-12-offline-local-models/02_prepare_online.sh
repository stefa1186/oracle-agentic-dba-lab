#!/usr/bin/env bash
# =============================================================================
# 02_prepare_online.sh
#
# Everything that needs the internet, done BEFORE going offline:
#   1. the internet must work for the lab user (this step downloads), and
#      the registry must still serve the pinned models (checked on their
#      manifests, before any download)
#   2. the local model server: Ollama in a rootless container, version and
#      settings pinned in agent-harness/local-models/ollama.conf
#   3. the local models: pulled from Ollama's registry, then checked against
#      their pinned digests (model_pins.txt). Like checking an RU's checksum
#      before you apply it
#   4. a first test: can each model ask for a tool at all?
#   5. the agent's account in its post 12 state: post 03's role, SQL
#      Firewall in OBSERVE mode (other models write other SQL: the firewall
#      logs it instead of blocking it), auditing checked
#   6. post 08's team notes, rebuilt with post 08's own scripts: its embedding
#      model (downloaded once), the table, the vectors, and the search that
#      writes the files test B attaches
#   7. test A's answer key, from the database itself (as SYSDBA)
#
# Run as the lab user, after ./01_check_hardware.sh. Safe to rerun: every
# step either checks or rebuilds.
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read posts 01-12 settings.
load_post12_config
# Must be the lab user.
require_lab_user
# The downloads (Ollama, the models) need root's download window.
"$(dirname "${BASH_SOURCE[0]}")/../post-01-why-and-the-cage/require_download_window.sh"
# The database must be up.
require_database

step "1/7 Is the lab user online? Does the registry still serve the pinned models?"
# The network mode of the root-owned policy.
info "Network mode: $(egress_mode)"
# A real download test that also checks the pins BEFORE downloading gigabytes:
# each model's manifest (its small table of contents), fetched from Ollama's
# registry as Ollama itself asks for it. Its SHA-256 is the model's digest. If
# it isn't the pinned one, the tag was re-published: stop. (The registry's
# bare /v2/ answers 404, so it can't serve as a test.)
for tag in ${LOCAL_MODELS}; do
    # "name:tag" -> registry path. Official models live under "library/".
    name="${tag%%:*}"
    [[ "${tag}" == *:* ]] && version="${tag#*:}" || version="latest"
    [[ "${name}" == */* ]] || name="library/${name}"
    # Hash the bytes exactly as received (piped: nothing added or stripped).
    digest="$(curl -fsS --max-time 30 -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
                  "https://registry.ollama.ai/v2/${name}/manifests/${version}" | sha256sum | cut -c1-64)" \
        || die "the lab user can't read ${tag}'s manifest from registry.ollama.ai. If you are offline, go back online first (as root: post-01-why-and-the-cage/00_root_setup.sh, without --offline)."
    [[ "${digest}" == "$(pin_digest "${tag}")" ]] \
        || die "${tag}: the registry now serves manifest ${digest:0:12}..., not the pinned $(pin_digest "${tag}" | cut -c1-12)...: the tag was re-published. Check the new version before you pin it."
    info "${tag}: the registry serves the pinned manifest (${digest:0:12}...)."
done

step "2/7 The local model server (Ollama)"
"${OLLAMA_DIR}/01_start_ollama.sh" | sed 's/^/    /'

step "3/7 The local models, checked against their pins"
for tag in ${LOCAL_MODELS}; do
    want="$(pin_digest "${tag}")"
    have="$(local_digest "${tag}")"
    if [[ "${have#sha256:}" == "${want}" ]]; then
        info "${tag}: already here."
    else
        info "${tag}: pulling $(( ($(pin_bytes "${tag}") + 536870912) / 1073741824 )) GiB..."
        # The pull's progress bar is long: it goes to a log, and only its last
        # line is shown (or its end, if the pull fails), made readable first
        # (readable_log: the bar is drawn with terminal control codes).
        log="${POST12_OUT}/pull_$(sed 's/[^A-Za-z0-9.-]\+/_/g' <<< "${tag}").log"
        started=${SECONDS}
        if ! podman exec "${OLLAMA_CONTAINER}" ollama pull "${tag}" > "${log}" 2>&1; then
            readable_log "${log}" | tail -5 >&2
            die "pulling ${tag} failed (log: ${log})."
        fi
        info "${tag}: $(readable_log "${log}" | tail -1), in $(( SECONDS - started )) s."
        have="$(local_digest "${tag}")"
    fi
    # The digest Ollama reports must be the pinned one, exactly.
    [[ "${have#sha256:}" == "${want}" ]] \
        || die "${tag}: digest ${have:-<none>} is not the pinned ${want}. The tag was re-published, or the pull failed: check before using it."
    info "${tag}: digest ${want:0:12}... matches model_pins.txt."
done
echo
# What Ollama now holds: name, ID (the digest's first 12 characters), size.
podman exec "${OLLAMA_CONTAINER}" ollama list | sed 's/^/    /'

step "4/7 Can each model ask for a tool?"
# The harness's own check: one fake tool, one question; PASS if the model asks for the tool.
# A FAIL is a result too: it is shown, and test A will show what it means.
# (LOCAL_MODELS unquoted on purpose: one argument per model.)
# shellcheck disable=SC2086
"${OLLAMA_DIR}/03_check_tool_calling.sh" ${LOCAL_MODELS} | sed 's/^/    /' \
    || warn "a model did not pass the tool-calling check (see above)."

step "5/7 The agent's account in its post 12 state"
# Post 03's role (the narrowest of the series), from post 03's script.
env -u EXTRA_VIEW_FILES "${POST03_DIR}/01_least_privilege.sh" | grep -E 'SELECT on|AI_AGENT:' | sed 's/^/    /'
# SQL Firewall in observe mode: logged, not blocked.
"${POST03_DIR}/04_sql_firewall.sh" observe | grep -A4 '=== Allow-list' | sed 's/^/    /'
# Post 04's audit policy must be enabled for the agent.
enabled="$(db_sqlplus <<SQL | tr -d '[:space:]'
set heading off feedback off pagesize 0
alter session set container = FREEPDB1;
select count(*) from audit_unified_enabled_policies
where  policy_name = '${AUDIT_POLICY}' and entity_name = '${AGENT_DB_USER}';
exit
SQL
)"
[[ "${enabled}" == "1" ]] || die "audit policy ${AUDIT_POLICY} is not enabled for ${AGENT_DB_USER}: run ../post-04-auditing-the-agent/01_audit_policy.sh first."
info "Audit policy ${AUDIT_POLICY} is enabled for ${AGENT_DB_USER}."

step "6/7 Post 08's team notes, rebuilt with post 08's scripts"
# The embedding model (downloaded once, checksum verified), the schema, the
# table and its vectors, then the search that writes test B's files.
"${POST08_DIR}/01_get_model.sh"
"${POST08_DIR}/02_setup.sh"
"${POST08_DIR}/03_load_team_notes.sh"
"${POST08_DIR}/04_search.sh"

step "7/7 Test A's answer key, from the database"
# What a correct answer to post 02's four questions must contain, read as
# SYSDBA: MARK lines are checked in the answers; INFO lines are the truth
# about the schemas' tables (the agent can't see most of them).
if ! key="$(db_sqlplus <<SQL
whenever sqlerror exit failure
set heading off feedback off pagesize 0 linesize 300 trimspool on
alter session set container = FREEPDB1;
-- 1. Product and version: the version number, e.g. 23.26.3.
select 'MARK|version|' || regexp_substr(version_full, '^[0-9]+\.[0-9]+\.[0-9]+') from v\$instance;
-- 2. The PDB and the user.
select 'MARK|pdb|' || sys_context('USERENV', 'CON_NAME') from dual;
select 'MARK|user|${AGENT_DB_USER}' from dual;
-- 3. Its privileges and roles.
select 'MARK|privilege|' || privilege    from dba_sys_privs  where grantee = '${AGENT_DB_USER}' order by 1;
select 'MARK|role|'      || granted_role from dba_role_privs where grantee = '${AGENT_DB_USER}' order by 1;
-- 4. The non-Oracle-maintained schemas (other than its own), and how many
--    tables each really has.
select 'MARK|schema|' || username from dba_users
where  oracle_maintained = 'N' and username <> '${AGENT_DB_USER}' order by 1;
select 'INFO|tables|' || u.username || '|' || count(t.table_name)
from   dba_users u left join dba_tables t on t.owner = u.username
where  u.oracle_maintained = 'N' group by u.username order by 1;
select 'KEY_COMPLETE' from dual;
exit
SQL
)"; then
    echo "${key}" >&2
    die "reading the answer key failed."
fi
grep -q KEY_COMPLETE <<< "${key}" || { echo "${key}" >&2; die "unexpected output from SQL*Plus."; }
grep -E '^(MARK|INFO)\|' <<< "${key}" > "${ANSWER_KEY}"
sed 's/^/    /' "${ANSWER_KEY}"

step "Done"
info "Saved: ${ANSWER_KEY}"
info "Next: ./03_cloud_baseline.sh (still online)"
