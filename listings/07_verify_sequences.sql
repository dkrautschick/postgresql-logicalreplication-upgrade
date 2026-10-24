-- Step 7. Sequences are NOT replicated before PostgreSQL 19. Compare both sides; the gap closes at cutover.
SELECT schemaname, sequencename, last_value FROM pg_sequences ORDER BY 1, 2;
