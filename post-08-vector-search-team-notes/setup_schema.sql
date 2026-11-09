-- =============================================================================
-- setup_schema.sql  (run by 02_setup.sh, as SYSDBA)
--
-- The application user &rag_schema: it owns the team note table and the
-- embedding model, and needs exactly the privileges for that:
--   CREATE SESSION, CREATE TABLE, CREATE MINING MODEL (an ONNX model is a
--   mining model in the dictionary), READ on the directory holding the model file.
-- Plus the directory object RAG_MODEL_DIR, pointing at &model_dir inside
-- the container, where 02_setup.sh copied the ONNX file.
--
-- Deterministic: the user (and with it the model and the table) is dropped
-- first. &rag_pwd arrives through stdin, never on a command line.
-- =============================================================================

-- Stop at the first real error, with a non-zero exit code for the shell.
whenever sqlerror exit failure
-- No substitution echo (it would print the password), no feedback.
set verify off feedback off heading off pagesize 0 linesize 300 trimspool on tab off
alter session set container = FREEPDB1;

-- 0. Start clean: sessions killed, then the user dropped (absent is fine).
begin
    for s in (select sid, serial# from v$session where username = '&rag_schema') loop
        begin
            execute immediate 'alter system kill session ''' || s.sid || ',' || s.serial# || ''' immediate';
        exception
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
        select count(*) into l_left from v$session where username = '&rag_schema';
        exit when l_left = 0;
        dbms_session.sleep(1);
    end loop;
    execute immediate 'drop user &rag_schema cascade';
exception
    -- ORA-01918: user does not exist (first run).
    when others then if sqlcode != -1918 then raise; end if;
end;
/

-- 1. The directory the database reads the ONNX file from.
create or replace directory rag_model_dir as '&model_dir';

-- 2. The application user and its privileges.
create user &rag_schema identified by "&rag_pwd"
    default tablespace users
    quota unlimited on users;
grant create session, create table, create mining model to &rag_schema;
grant read on directory rag_model_dir to &rag_schema;

select 'SCHEMA_READY' from dual;
exit
