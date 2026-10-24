# Step 5: write load on the SOURCE while replication runs (needs pgbench and ../sql/load.pgbench).
pgbench "<SRC_URI>" --no-vacuum --client=4 --jobs=2 --time=120 --progress=10 --file=../sql/load.pgbench
