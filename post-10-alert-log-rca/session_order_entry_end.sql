-- =============================================================================
-- session_order_entry_end.sql  (sent by incident_session.sh to the held order
-- entry session when the incident time is over)
--
-- The application finally gives the connection back: a lab, so the open
-- transaction is rolled back, and the session ends.
-- =============================================================================

-- Undo the reservation of item 42, still open since the deadlock.
rollback;
-- Marker in the session log.
select 'SESSION_DONE' from dual;
exit
