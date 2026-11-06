-- =============================================================================
-- setup_load.sql  (run by 02_generate_load.sh, as SYSDBA)
--
-- Prepares the workload's schema: the application user &awr_schema with the
-- one password this run uses, and the two tables the workload sessions use.
-- The sessions themselves are started by the shell (session_*.sql), so the
-- workload doesn't depend on the job scheduler.
--
-- Deterministic: a previous run's sessions are killed and its schema dropped
-- first; data is generated with CONNECT BY.
-- Substitution variables (&awr_schema, &awr_pwd) are defined by lib.sh and
-- 02_generate_load.sh; the password arrives through stdin, never on a command line.
-- =============================================================================

-- Stop at the first real error, with a non-zero exit code for the shell.
whenever sqlerror exit failure
-- Plain output: no substitution echo (it would print the password), no feedback, no tabs.
set verify off feedback off heading off pagesize 0 linesize 300 trimspool on tab off
-- The workload lives in the pluggable database.
alter session set container = FREEPDB1;
-- DBMS_OUTPUT belongs to the container session: enable it after the switch.
set serveroutput on

-- -----------------------------------------------------------------------------
-- 0. Start clean: drop a previous run's schema (absent is fine). Its jobs and
--    sessions were already ended by stop_workload.sql, run just before this.
-- -----------------------------------------------------------------------------
begin
    -- The schema and its tables.
    execute immediate 'drop user &awr_schema cascade';
exception
    -- ORA-01918: user does not exist (first run). Anything else is a real error.
    when others then if sqlcode != -1918 then raise; end if;
end;
/

-- -----------------------------------------------------------------------------
-- 1. The application user: can connect, owns its tables, nothing else.
--    DBMS_SESSION for the lock holder's sleep (granted explicitly, not assumed).
-- -----------------------------------------------------------------------------
create user &awr_schema identified by "&awr_pwd"
    default tablespace users
    quota unlimited on users;
grant create session to &awr_schema;
grant execute on sys.dbms_session to &awr_schema;

-- ACCOUNTS: the table whose row 1 everyone fights over.
create table &awr_schema..accounts (
    id      number primary key,
    balance number not null
);
insert into &awr_schema..accounts (id, balance)
select level, 1000 from dual connect by level <= 1000;

-- ORDERS: the table the literal-SQL query reads, through an index.
create table &awr_schema..orders (
    id          number primary key,
    customer_id number not null,
    amount      number not null
);
insert into &awr_schema..orders (id, customer_id, amount)
select level, mod(level * 7, 10000), mod(level * 13, 500)
from   dual connect by level <= 100000;
create index &awr_schema..orders_customer_ix on &awr_schema..orders (customer_id);
commit;
-- Statistics, so the optimizer has a normal starting point.
exec dbms_stats.gather_schema_stats('&awr_schema')

-- Marker: the shell checks for it.
select 'SCHEMA_READY' from dual;
exit
