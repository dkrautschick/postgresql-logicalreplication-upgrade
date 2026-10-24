-- Step 8, part 4. Run on the SOURCE with psql -qtA; apply the output on the TARGET.
SELECT format('SELECT setval(%L, %s, true);',
              quote_ident(schemaname) || '.' || quote_ident(sequencename), last_value)
FROM pg_sequences
WHERE last_value IS NOT NULL AND schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY 1;
