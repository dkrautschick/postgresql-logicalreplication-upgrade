# Step 1: two Aiven for PostgreSQL services, old major as source, new major as target.
avn service create --project <AVN_PROJECT> --service-type pg --plan startup-4 \
  --cloud google-europe-west1 -c pg_version=15 pg-source-15
avn service create --project <AVN_PROJECT> --service-type pg --plan startup-4 \
  --cloud google-europe-west1 -c pg_version=18 pg-target-18

avn service wait --project <AVN_PROJECT> pg-source-15
avn service wait --project <AVN_PROJECT> pg-target-18

avn service database-create --project <AVN_PROJECT> --dbname beerdb pg-source-15
avn service database-create --project <AVN_PROJECT> --dbname beerdb pg-target-18

# connection details (host, port, user, password, default URI)
avn service get --project <AVN_PROJECT> --json pg-source-15 | jq '.connection_info.pg_params[0], .service_uri'
avn service get --project <AVN_PROJECT> --json pg-target-18 | jq '.connection_info.pg_params[0], .service_uri'
