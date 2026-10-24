# Step 8: the cutover, as a sequence of shell commands. Each SQL file is in this folder.
psql "<SRC_URI>" -v ON_ERROR_STOP=1 -f 08_cutover_source.sql          # 1. block writes, 2. final marker
until [ -n "$(psql "<DST_URI>" -qtA -c "SELECT 1 FROM tap_log WHERE note LIKE 'cutover-%'")" ]; do sleep 0.5; done
bash 11_copy_large_objects.sh                                           # 3. large objects
psql "<SRC_URI>" -qtA -f 08_cutover_sequences.sql > setval.sql           # 4. sequences, generated on the source...
psql "<DST_URI>" -v ON_ERROR_STOP=1 -f setval.sql                        #    ...applied on the target
psql "<DST_URI>" -v ON_ERROR_STOP=1 -f 08_cutover_target.sql             # 5. ANALYZE
# 6. verify again (07_*.sql on both sides), then point the application at the target.
