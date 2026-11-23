-- =============================================================================
-- context_pack.sql  (run by 03_context_pack.sh, as SYSDBA)
--
-- The table and index DDL and the optimizer statistics of &tune_schema.ORDERS:
-- what a developer would paste next to a slow query when asking for help.
-- Read-only.
-- =============================================================================

-- Stop at the first real error, with a non-zero exit code for the shell.
whenever sqlerror exit failure
set verify off feedback off pagesize 100 linesize 200 trimspool on tab off long 100000 longchunksize 100000
alter session set container = FREEPDB1;

-- DDL without storage clauses: the logical definition, easier to read.
begin
    dbms_metadata.set_transform_param(dbms_metadata.session_transform, 'SEGMENT_ATTRIBUTES', false);
    dbms_metadata.set_transform_param(dbms_metadata.session_transform, 'SQLTERMINATOR', true);
    dbms_metadata.set_transform_param(dbms_metadata.session_transform, 'PRETTY', true);
end;
/

prompt === Table and index DDL
set heading off
select dbms_metadata.get_ddl('TABLE', 'ORDERS', '&tune_schema') from dual;
select dbms_metadata.get_ddl('INDEX', index_name, '&tune_schema')
from   dba_indexes
where  owner = '&tune_schema' and table_name = 'ORDERS'
order  by index_name;
set heading on

prompt
prompt === Table statistics
column table_name format a12
select table_name, num_rows, blocks, avg_row_len, to_char(last_analyzed, 'YYYY-MM-DD HH24:MI') last_analyzed
from   dba_tab_statistics
where  owner = '&tune_schema' and table_name = 'ORDERS' and object_type = 'TABLE';

prompt
prompt === Column statistics
column column_name format a12
column histogram   format a15
select column_name, num_distinct, num_nulls, round(density, 8) density, histogram
from   dba_tab_col_statistics
where  owner = '&tune_schema' and table_name = 'ORDERS'
order  by column_name;

prompt
prompt === Index statistics
column index_name format a20
column columns    format a24
select i.index_name,
       (select listagg(c.column_name, ', ') within group (order by c.column_position)
        from dba_ind_columns c
        where c.index_owner = i.owner and c.index_name = i.index_name) columns,
       i.blevel, i.leaf_blocks, i.distinct_keys, i.clustering_factor
from   dba_ind_statistics i
where  i.owner = '&tune_schema' and i.table_name = 'ORDERS'
order  by i.index_name;

prompt #PACK_COMPLETE#
exit
