-- =============================================================================
-- setup_shop.sql  (run by 02_create_incident.sh as SYSDBA)
--
-- The shop application: user &shop_schema (password &shop_pwd, for this run
-- only, through stdin) with two tables:
--   STOCK   one row per item: what order entry reserves
--   ORDERS  one row per order: what the invoicing batch updates
-- Fixed rows, so every run starts from the same data. Rerunning drops and
-- recreates everything (02_create_incident.sh stops the old sessions first).
-- =============================================================================

-- Stop at the first error, with a non-zero exit code for the shell.
whenever sqlerror exit failure
-- No substitution echo (it would print the password), no feedback.
set verify off feedback off heading off pagesize 0
alter session set container = FREEPDB1;

-- Start clean.
begin
    execute immediate 'drop user &shop_schema cascade';
exception
    -- ORA-01918: user does not exist (first run).
    when others then if sqlcode != -1918 then raise; end if;
end;
/

-- The application account: connect and own its two tables, nothing more.
create user &shop_schema identified by "&shop_pwd"
    default tablespace users
    quota 10m on users;
grant create session to &shop_schema;

create table &shop_schema..stock (
    item_id     number        primary key,
    description varchar2(100) not null,
    qty         number        not null
);
create table &shop_schema..orders (
    order_id    number        primary key,
    item_id     number        not null references &shop_schema..stock,
    status      varchar2(20)  not null
);

-- 50 items, 1,000 orders (order 1001 is for item 42: the two rows of the incident).
insert into &shop_schema..stock
select level, 'Item ' || level, 100 from dual connect by level <= 50;
insert into &shop_schema..orders
select 1000 + level, mod(level - 1, 50) + 1, 'NEW' from dual connect by level <= 1000;
update &shop_schema..orders set item_id = 42 where order_id = 1001;
commit;

-- Marker: the shell checks for it.
select 'SHOP_READY' from dual;
exit
