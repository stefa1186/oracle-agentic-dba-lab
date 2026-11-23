-- =============================================================================
-- setup_schema.sql  (run by 01_setup.sh, as SYSDBA)
--
-- The application user &tune_schema and one table, ORDERS, with &tune_rows rows:
-- 1,000 orders a day, each day's orders stored together (in ID order), five
-- statuses, a time of day on every ORDER_DATE. Indexes on ORDER_DATE and on
-- CUSTOMER_ID, fresh statistics.
--
-- The slow query (query_original.sql) filters on TRUNC(ORDER_DATE): the
-- index on ORDER_DATE exists, but the function on the column keeps the
-- optimizer from using it. That's the planted problem.
--
-- Deterministic: the user is dropped first; data is generated from ROWNUM,
-- not random values. &tune_pwd arrives through stdin, never on a command line.
-- =============================================================================

-- Stop at the first real error, with a non-zero exit code for the shell.
whenever sqlerror exit failure
-- Plain output: no substitution echo (it would print the password), no feedback.
set verify off feedback off heading off pagesize 0 linesize 300 trimspool on tab off
alter session set container = FREEPDB1;

-- -----------------------------------------------------------------------------
-- 0. Start clean: its sessions killed, then the user dropped (absent is fine).
-- -----------------------------------------------------------------------------
begin
    for s in (select sid, serial# from v$session where username = '&tune_schema') loop
        begin
            execute immediate 'alter system kill session ''' || s.sid || ',' || s.serial# || ''' immediate';
        exception
            -- ORA-00030: the session is already gone. Fine.
            when others then if sqlcode != -30 then raise; end if;
        end;
    end loop;
end;
/
declare
    l_left pls_integer;
begin
    -- KILL SESSION returns before the session is gone: wait (at most 60 s).
    for i in 1 .. 60 loop
        select count(*) into l_left from v$session where username = '&tune_schema';
        exit when l_left = 0;
        dbms_session.sleep(1);
    end loop;
    -- The user, its table and indexes.
    execute immediate 'drop user &tune_schema cascade';
exception
    -- ORA-01918: user does not exist (first run).
    when others then if sqlcode != -1918 then raise; end if;
end;
/

-- -----------------------------------------------------------------------------
-- 1. The application user: connects, owns its table, nothing else, plus SELECT
--    on the four V$ views DBMS_XPLAN.DISPLAY_CURSOR needs to show a plan with
--    runtime statistics for its own statements.
-- -----------------------------------------------------------------------------
create user &tune_schema identified by "&tune_pwd"
    default tablespace users
    quota unlimited on users;
grant create session to &tune_schema;
grant select on sys.v_$session to &tune_schema;
grant select on sys.v_$sql to &tune_schema;
grant select on sys.v_$sql_plan to &tune_schema;
grant select on sys.v_$sql_plan_statistics_all to &tune_schema;

-- -----------------------------------------------------------------------------
-- 2. ORDERS: &tune_rows rows, generated from ROWNUM.
--    ORDER_DATE: day = (id - 1) / 1000 from 2024-01-01, plus a time of day,
--                so rows of the same day sit together (a good clustering factor).
--    STATUS:     NEW, PAID, SHIPPED, DELIVERED, CANCELLED, in turn.
-- -----------------------------------------------------------------------------
create table &tune_schema..orders (
    id          number        not null,
    customer_id number        not null,
    order_date  date          not null,
    status      varchar2(10)  not null,
    amount      number(10, 2) not null,
    note        varchar2(60),
    constraint orders_pk primary key (id)
);
insert /*+ append */ into &tune_schema..orders (id, customer_id, order_date, status, amount, note)
select n,
       mod(n * 7919, 50000) + 1,
       date '2024-01-01' + trunc((n - 1) / 1000) + mod(n * 37, 86400) / 86400,
       case mod(n, 5) when 0 then 'NEW' when 1 then 'PAID' when 2 then 'SHIPPED'
                      when 3 then 'DELIVERED' else 'CANCELLED' end,
       mod(n * 13, 100000) / 100,
       'order ' || n
-- n: 1 .. &tune_rows, from two small row generators combined (1,000 x days).
from  (select (b.m - 1) * 1000 + a.r n
       from   (select rownum r from dual connect by level <= 1000) a,
              (select rownum m from dual connect by level <= &tune_rows / 1000) b);
commit;

-- The indexes an application like this would typically have.
create index &tune_schema..orders_date_ix on &tune_schema..orders (order_date);
create index &tune_schema..orders_customer_ix on &tune_schema..orders (customer_id);

-- Fresh statistics: the optimizer knows exactly what's there.
exec dbms_stats.gather_table_stats('&tune_schema', 'ORDERS', cascade => true)

-- What was built, for the record.
select 'ROWS=' || count(*) || ' DAYS=' || count(distinct trunc(order_date))
       || ' FROM=' || to_char(min(order_date), 'YYYY-MM-DD') || ' TO=' || to_char(max(order_date), 'YYYY-MM-DD')
from   &tune_schema..orders;
select 'SCHEMA_READY' from dual;
exit
