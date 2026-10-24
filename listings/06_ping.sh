# Step 6, end-to-end ping: write a marker on the source, wait for it on the target, print the round trip.
MARKER="ping-$(date +%s%N)"; T0=$(date +%s%N)
psql "<SRC_URI>" -qtA -c "INSERT INTO tap_log(note) VALUES ('$MARKER');"
until [ -n "$(psql "<DST_URI>" -qtA -c "SELECT 1 FROM tap_log WHERE note = '$MARKER'")" ]; do sleep 0.1; done
echo "replicated in $(( ($(date +%s%N) - T0) / 1000000 )) ms"
