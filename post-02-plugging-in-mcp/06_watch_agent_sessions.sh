#!/usr/bin/env bash
# =============================================================================
# 06_watch_agent_sessions.sh
#
# Shows the AI agent's database sessions in V$SESSION while it works: who it
# is connected as, which program, and the module/action SQLcl's MCP server
# sets for each tool call. Run it in a second terminal during the first contact.
#
#   ./06_watch_agent_sessions.sh          refresh every 2 seconds (Ctrl-C to stop)
#   ./06_watch_agent_sessions.sh --once   one snapshot (good for a screenshot)
#
# Oracle analogy: the classic "who is connected and what are they doing"
# query, pointed at a new kind of client.
#
# Run as the lab user. Reads only; queries run as SYSDBA inside the container.
# =============================================================================

# Stop on errors (-e), unset variables (-u) and failures inside pipelines.
set -euo pipefail

# Load the shared helpers and settings.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Read post 01 and post 02 settings.
load_post02_config
# Must be the lab user, in a proper login session.
require_lab_user
# The database must be up.
require_database

# One snapshot or continuous refresh.
case "${1:-}" in
    "")     once=0 ;;
    --once) once=1 ;;
    *)      die "usage: $0 [--once]" ;;
esac

# Print one snapshot: sessions of the agent's user, or of any MCP client.
snapshot() {
    db_sqlplus <<SQL
-- tab off: spaces instead of tabs, so a snapshot pastes into a post unchanged.
set linesize 220 pagesize 100 feedback off tab off
column sid      format 99999
column username format a12
column program  format a12
-- MODULE holds the model ID (filled in by the harness), e.g.
-- nvidia/nemotron-3-ultra-550b-a55b:free: wide enough to fit on one line.
column module   format a48
column action   format a20
column status   format a8
column sql_id   format a13
alter session set container = FREEPDB1;
select sid, username, program, module, action, status, sql_id
from   v\$session
where  username = '${AGENT_DB_USER}'
   or  lower(program) like '%mcp%'
   or  lower(module)  like '%mcp%'
order  by sid;
exit
SQL
}

if (( once )); then
    # Single snapshot with a timestamp.
    echo "Agent sessions at $(date '+%H:%M:%S'):"
    snapshot
else
    # Continuous: clear, timestamp, snapshot, wait 2 s, repeat until Ctrl-C.
    while true; do
        clear
        echo "Agent sessions at $(date '+%H:%M:%S')   (Ctrl-C to stop)"
        snapshot
        sleep 2
    done
fi
