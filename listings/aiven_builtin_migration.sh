# Alternative: let Aiven run the migration (aiven-db-migrate, logical replication under the hood,
# pg_dump fallback where the preconditions are not met). Large objects are not carried either.
avn service update --project <AVN_PROJECT> \
  -c migration.host=<SRC_HOST> \
  -c migration.port=5432 \
  -c migration.ssl=true \
  -c migration.username=<SRC_USER> \
  -c migration.password=<SRC_PASSWORD> \
  -c migration.dbname=beerdb \
  -c migration.method=replication \
  pg-target-18

avn service migration-status --project <AVN_PROJECT> pg-target-18

# When done, remove the migration config so the target stops following the source:
# avn service update --project <AVN_PROJECT> --remove-option migration pg-target-18
