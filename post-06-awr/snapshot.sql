-- =============================================================================
-- snapshot.sql  (run by 02_generate_load.sh, as SYSDBA, in the root)
--
-- Takes one AWR snapshot for the instance and prints its ID as
-- &snap_label=<id> (BEGIN_SNAP or END_SNAP).
-- =============================================================================

-- Stop at the first real error, with a non-zero exit code for the shell.
whenever sqlerror exit failure
-- Plain output.
set verify off feedback off heading off pagesize 0 serveroutput on
declare
    l_snap number;
begin
    -- A manual snapshot, the same as the hourly automatic ones.
    l_snap := dbms_workload_repository.create_snapshot();
    dbms_output.put_line('&snap_label=' || l_snap);
end;
/
exit
