#!/usr/bin/env bash
# =============================================================================
# 01_setup.sh
#
# Sets up the NL2SQL test, as the lab user:
#   1. Oracle's sample schemas, pinned and checksummed (SH lives in them)
#   2. the SH schema in FREEPDB1, installed with Oracle's own script
#   3. SELECT on SH for part 2's agent user, nothing else
#
# Needs part 1's lab and part 2's SQLcl, agent user and saved connection
# (Oracle's SH script loads its data with SQLcl's LOAD command).
# Safe to rerun: SH and the grants are recreated.
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read post 01, 02 and 13 settings.
load_post13_config
# Must be the lab user.
require_lab_user
# SQLcl comes from part 2.
[[ -x "${SQLCL_BIN}" ]] || die "SQLcl not found. Run post-02-plugging-in-mcp/01_install_sqlcl.sh first."

# -----------------------------------------------------------------------------
step "1/3 Oracle's sample schemas"
# -----------------------------------------------------------------------------
# The archive, downloaded once into the lab user's download folder.
install -d -m 700 "${DOWNLOAD_DIR}"
archive="${DOWNLOAD_DIR}/db-sample-schemas-$(basename "${SAMPLES_URL}").tar.gz"
if [[ ! -s "${archive}" ]]; then
    info "Downloading ${SAMPLES_URL}"
    # Into a temporary name first: an interrupted download never looks complete.
    curl -fsSL --retry 3 -o "${archive}.part" "${SAMPLES_URL}"
    mv "${archive}.part" "${archive}"
fi
# Its checksum: checked against the pin, or printed to pin it.
sha="$(sha256sum "${archive}" | cut -d' ' -f1)"
if [[ -z "${SAMPLES_SHA256}" ]]; then
    warn "SAMPLES_SHA256 is empty: pin it in env.example: SAMPLES_SHA256=${sha}"
else
    [[ "${sha}" == "${SAMPLES_SHA256}" ]] || die "the archive's SHA-256 is ${sha}, not the pinned ${SAMPLES_SHA256}."
    info "SHA-256 matches the pin."
fi
# Unpacked fresh into a work folder, every run.
work="${OUT_DIR}/samples"
rm -rf "${work}" && install -d -m 700 "${work}"
tar -xzf "${archive}" -C "${work}" --strip-components=1
info "Unpacked into ${work}"

# -----------------------------------------------------------------------------
step "2/3 The SH schema in FREEPDB1 (Oracle's sh_install.sql)"
# -----------------------------------------------------------------------------
# SH's password, generated once and kept private.
ensure_password "${SH_PASSWORD_FILE}"
# Oracle's script asks three questions with ACCEPT: SH's password, its
# tablespace and whether to overwrite an existing SH. SQLcl reads ACCEPT from
# the terminal, not from a pipe, so this working copy drops the three ACCEPT
# lines, and the answers come first as DEFINEs, on stdin with SYSTEM's login:
# no password on a command line. It runs in the script's folder, where its
# data files are.
sed -i '/^ACCEPT /d' "${work}/sales_history/sh_install.sql"
(
    cd "${work}/sales_history"
    "${SQLCL_BIN}" -S /nolog <<SQL
connect system/"$(cat "${DB_PASSWORD_FILE}")"@//127.0.0.1:${DB_PORT}/FREEPDB1
define pass = "$(cat "${SH_PASSWORD_FILE}")"
define tbs = USERS
define overwrite_schema = YES
@sh_install.sql
SQL
) > "${OUT_DIR}/sh_install.out" 2>&1 || { tail -20 "${OUT_DIR}/sh_install.out"; die "sh_install.sql failed (log: ${OUT_DIR}/sh_install.out)."; }
# What was loaded, read back as SYSDBA.
db_sqlplus <<'SQL'
set feedback off pagesize 50 linesize 100
alter session set container = FREEPDB1;
column table_name format a28
select table_name, num_rows from dba_tables where owner = 'SH' order by table_name;
SQL

# -----------------------------------------------------------------------------
step "3/3 SELECT on SH for the agent's user, ${AGENT_DB_USER}"
# -----------------------------------------------------------------------------
# The agent reads SH through SQLcl's MCP server, with part 2's saved connection
# "agent", like in every part. Its user gets SELECT on each of SH's 9 base
# tables: not the Oracle Text index tables (DR$...) and not the materialized
# views (..._MV). Nothing else. SH is recreated above, so the grants are too.
db_sqlplus <<SQL
whenever sqlerror exit failure
set feedback off heading off pagesize 0
alter session set container = FREEPDB1;
begin
    for t in (select table_name from dba_tables where owner = 'SH'
              and table_name not like 'DR\$%' and table_name not like '%\_MV' escape '\') loop
        execute immediate 'grant select on sh.' || t.table_name || ' to ${AGENT_DB_USER}';
    end loop;
end;
/
-- What it may read in SH, from the dictionary.
select 'SELECT on ' || owner || '.' || table_name from dba_tab_privs
where grantee = '${AGENT_DB_USER}' and owner = 'SH' order by 1;
SQL

step "Done"
info "Next: ./03_run_agent.sh"
