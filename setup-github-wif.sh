#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Config (override via env vars)
# -----------------------------
SA_NAME="${SA_NAME:-github-deploy-sa}"
# WIF/AUTH project (where workload identity pool/provider and service account live)
WIF_PROJECT_ID="${WIF_PROJECT_ID:-${PROJECT_ID:-$(gcloud config get-value project)}}"
# Deploy target project (Cloud Run/Functions/Cloud SQL resources live here)
DEPLOY_PROJECT_ID="${DEPLOY_PROJECT_ID:-${PROJECT_ID:-${WIF_PROJECT_ID}}}"

WIF_PROJECT_NUMBER="${WIF_PROJECT_NUMBER:-$(gcloud projects describe "${WIF_PROJECT_ID}" --format='value(projectNumber)')}"
DEPLOY_PROJECT_NUMBER="${DEPLOY_PROJECT_NUMBER:-$(gcloud projects describe "${DEPLOY_PROJECT_ID}" --format='value(projectNumber)')}"
WIF_POOL_ID="${WIF_POOL_ID:-github-pool-v1}"
WIF_PROVIDER_ID="${WIF_PROVIDER_ID:-github-provider-v1}"
GITHUB_OWNER="${GITHUB_OWNER:-Pawa-IT-Solutions}"
GITHUB_REPO="${GITHUB_REPO:-cloud-mastery-ecommerce-2026}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-${GITHUB_OWNER}/${GITHUB_REPO}}"
MYSQL_PRISMA_SECRET_NAME="${MYSQL_PRISMA_SECRET_NAME:-MYSQL_PRISMA_URL}"
BIGQUERY_CONNECTION_ID="${BIGQUERY_CONNECTION_ID:-agent-builder-conn}"
BIGQUERY_CONNECTION_LOCATION="${BIGQUERY_CONNECTION_LOCATION:-us}"
BIGQUERY_CONNECTION_DISPLAY_NAME="${BIGQUERY_CONNECTION_DISPLAY_NAME:-discoveryengine-connection}"
MAPS_API_ADMIN_ROLE="${MAPS_API_ADMIN_ROLE:-roles/mapsplatform.admin}"

# Optional DB inputs for secret bootstrap.
# If MYSQL_PRISMA_URL is provided, it is used directly.
# Otherwise, the script will build it from DB_* and CLOUDSQL_INSTANCE_CONNECTION_NAME.
MYSQL_PRISMA_URL="${MYSQL_PRISMA_URL:-}"
DB_NAME="${DB_NAME:-}"
DB_USER="${DB_USER:-}"
DB_PASSWORD="${DB_PASSWORD:-${DB_PASS:-}}"
CLOUDSQL_INSTANCE_CONNECTION_NAME="${CLOUDSQL_INSTANCE_CONNECTION_NAME:-}"

# -----------------------------
# Derived values
# -----------------------------
SA_EMAIL="${SA_NAME}@${WIF_PROJECT_ID}.iam.gserviceaccount.com"
REPO_PRINCIPAL="principalSet://iam.googleapis.com/projects/${WIF_PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL_ID}/attribute.repository/${GITHUB_REPOSITORY}"
WIF_PROVIDER_RESOURCE="projects/${WIF_PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL_ID}/providers/${WIF_PROVIDER_ID}"
DISCOVERY_ENGINE_SA="service-${DEPLOY_PROJECT_NUMBER}@gcp-sa-discoveryengine.iam.gserviceaccount.com"

echo "WIF Project: ${WIF_PROJECT_ID} (${WIF_PROJECT_NUMBER})"
echo "Deploy Project: ${DEPLOY_PROJECT_ID} (${DEPLOY_PROJECT_NUMBER})"
echo "Service Account: ${SA_EMAIL}"
echo "Discovery Engine SA: ${DISCOVERY_ENGINE_SA}"
echo "GitHub Repository: ${GITHUB_REPOSITORY}"
echo "Repo Principal: ${REPO_PRINCIPAL}"
echo "WIF Provider: ${WIF_PROVIDER_RESOURCE}"

echo "Enabling required APIs in WIF project..."
gcloud services enable \
  cloudresourcemanager.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  serviceusage.googleapis.com \
  --quiet \
  --project "${WIF_PROJECT_ID}"

echo "Enabling required APIs in deploy project..."
gcloud services enable \
  cloudresourcemanager.googleapis.com \
  cloudbuild.googleapis.com \
  run.googleapis.com \
  sqladmin.googleapis.com \
  sql-component.googleapis.com \
  cloudfunctions.googleapis.com \
  artifactregistry.googleapis.com \
  eventarc.googleapis.com \
  secretmanager.googleapis.com \
  storage.googleapis.com \
  --quiet \
  --project "${DEPLOY_PROJECT_ID}"

echo "Creating service account if missing..."
if ! gcloud iam service-accounts describe "${SA_EMAIL}" --project "${WIF_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud iam service-accounts create "${SA_NAME}" \
    --project "${WIF_PROJECT_ID}" \
    --display-name "GitHub Actions WIF Service Account" \
    --description "Privileged SA for GitHub Actions WIF deployment" \
    --quiet
else
  echo "Service account already exists: ${SA_EMAIL}"
fi

echo "Applying roles in WIF project..."
for ROLE in \
  roles/serviceusage.serviceUsageAdmin \
  roles/iam.serviceAccountUser \
  roles/viewer
 do
  gcloud projects add-iam-policy-binding "${WIF_PROJECT_ID}" \
    --member "serviceAccount:${SA_EMAIL}" \
    --role "${ROLE}" \
    --condition=None \
    --quiet \
    --format=none
  echo "Assigned in WIF project: ${ROLE}"
done

echo "Applying roles in deploy project..."
for ROLE in \
  roles/cloudbuild.builds.editor \
  roles/cloudbuild.builds.builder \
  roles/bigquery.admin \
  roles/bigquery.dataViewer \
  roles/bigquery.jobUser \
  roles/run.admin \
  roles/cloudfunctions.admin \
  roles/cloudsql.admin \
  roles/cloudsql.client \
  roles/iap.tunnelResourceAccessor \
  roles/iap.httpsResourceAccessor \
  roles/iam.workloadIdentityUser \
  roles/iam.serviceAccountTokenCreator \
  roles/iam.serviceAccountUser \
  roles/serviceusage.serviceUsageAdmin \
  roles/secretmanager.admin \
  roles/secretmanager.secretAccessor \
  roles/storage.admin \
  roles/logging.logWriter \
  roles/artifactregistry.writer \
  roles/artifactregistry.createOnPushWriter \
  roles/viewer
 do
  gcloud projects add-iam-policy-binding "${DEPLOY_PROJECT_ID}" \
    --member "serviceAccount:${SA_EMAIL}" \
    --role "${ROLE}" \
    --condition=None \
    --quiet \
    --format=none
  echo "Assigned in deploy project: ${ROLE}"
done

echo "Applying build roles to Cloud Build service identities in deploy project..."
BUILD_SERVICE_ACCOUNTS=(
  "${DEPLOY_PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"
  "service-${DEPLOY_PROJECT_NUMBER}@gcp-sa-cloudbuild.iam.gserviceaccount.com"
  "${DEPLOY_PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
)

for BUILD_SA in "${BUILD_SERVICE_ACCOUNTS[@]}"; do
  for ROLE in \
    roles/cloudbuild.builds.builder \
    roles/artifactregistry.writer \
    roles/storage.objectViewer \
    roles/logging.logWriter
  do
    gcloud projects add-iam-policy-binding "${DEPLOY_PROJECT_ID}" \
      --member "serviceAccount:${BUILD_SA}" \
      --role "${ROLE}" \
      --condition=None \
      --quiet \
      --format=none
    echo "Assigned to ${BUILD_SA}: ${ROLE}"
  done
done

echo "Ensuring BigQuery Cloud Resource connection exists..."
if ! bq show --connection --project_id="${DEPLOY_PROJECT_ID}" --location="${BIGQUERY_CONNECTION_LOCATION}" "${BIGQUERY_CONNECTION_ID}" >/dev/null 2>&1; then
  bq mk --connection \
    --display_name="${BIGQUERY_CONNECTION_DISPLAY_NAME}" \
    --connection_type=CLOUD_RESOURCE \
    --project_id="${DEPLOY_PROJECT_ID}" \
    --location="${BIGQUERY_CONNECTION_LOCATION}" \
    "${BIGQUERY_CONNECTION_ID}"
  echo "Created BigQuery connection: ${BIGQUERY_CONNECTION_ID} (${BIGQUERY_CONNECTION_LOCATION})"
else
  echo "BigQuery connection already exists: ${BIGQUERY_CONNECTION_ID} (${BIGQUERY_CONNECTION_LOCATION})"
fi

echo "Resolving BigQuery connection service account..."
CONNECTION_SERVICE_ACCOUNT="$(bq show --format=prettyjson --connection --project_id="${DEPLOY_PROJECT_ID}" --location="${BIGQUERY_CONNECTION_LOCATION}" "${BIGQUERY_CONNECTION_ID}" | sed -n 's/.*"serviceAccountId": "\([^"]*\)".*/\1/p' | head -n1)"

if [[ -z "${CONNECTION_SERVICE_ACCOUNT}" ]]; then
  echo "Failed to read serviceAccountId from BigQuery connection ${BIGQUERY_CONNECTION_ID}."
  echo "Ensure the connection exists and that bq CLI has access."
  exit 1
fi

echo "Granting BigQuery Data Viewer to BigQuery connection service account..."
echo "Connection service account member: serviceAccount:${CONNECTION_SERVICE_ACCOUNT}"
gcloud projects add-iam-policy-binding "${DEPLOY_PROJECT_ID}" \
  --member "serviceAccount:${CONNECTION_SERVICE_ACCOUNT}" \
  --role "roles/bigquery.dataViewer" \
  --condition=None \
  --quiet \
  --format=none

echo "Granting Discovery Engine service account BigQuery + logging + Artifact Registry roles..."
echo "Discovery Engine member: serviceAccount:${DISCOVERY_ENGINE_SA}"
for ROLE in \
  roles/artifactregistry.admin \
  roles/artifactregistry.writer \
  roles/bigquery.connectionUser \
  roles/bigquery.dataViewer \
  roles/bigquery.jobUser \
  roles/bigquery.readSessionUser \
  roles/logging.admin \
  roles/logging.bucketWriter \
  roles/logging.viewer
do
  gcloud projects add-iam-policy-binding "${DEPLOY_PROJECT_ID}" \
    --member "serviceAccount:${DISCOVERY_ENGINE_SA}" \
    --role "${ROLE}" \
    --condition=None \
    --quiet \
    --format=none
  echo "Assigned to ${DISCOVERY_ENGINE_SA}: ${ROLE}"
done

echo "Validating workload identity provider exists..."
gcloud iam workload-identity-pools providers describe "${WIF_PROVIDER_ID}" \
  --project "${WIF_PROJECT_ID}" \
  --location global \
  --workload-identity-pool "${WIF_POOL_ID}" \
  --format='value(name)' >/dev/null

echo "Granting WIF principal impersonation permissions on service account..."
gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
  --project "${WIF_PROJECT_ID}" \
  --member "${REPO_PRINCIPAL}" \
  --role roles/iam.workloadIdentityUser \
  --quiet

gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
  --project "${WIF_PROJECT_ID}" \
  --member "${REPO_PRINCIPAL}" \
  --role roles/iam.serviceAccountTokenCreator \
  --quiet

echo "Granting service account self token-creator binding (iam.serviceAccounts.getAccessToken)..."
gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
  --project "${WIF_PROJECT_ID}" \
  --member "serviceAccount:${SA_EMAIL}" \
  --role roles/iam.serviceAccountTokenCreator \
  --quiet

echo "Verifying required IAM roles and bindings for ${SA_EMAIL}..."
IAM_VERIFY_FAILED=0

for ROLE in \
  roles/serviceusage.serviceUsageAdmin \
  roles/iam.serviceAccountUser \
  roles/viewer
do
  if ! gcloud projects get-iam-policy "${WIF_PROJECT_ID}" \
    --flatten="bindings[].members" \
    --filter="bindings.role=${ROLE} AND bindings.members=serviceAccount:${SA_EMAIL}" \
    --format='value(bindings.role)' | grep -q .; then
    echo "Missing WIF project role for ${SA_EMAIL}: ${ROLE}"
    IAM_VERIFY_FAILED=1
  fi
done

for ROLE in \
  roles/cloudbuild.builds.editor \
  roles/cloudbuild.builds.builder \
  roles/bigquery.admin \
  roles/bigquery.dataViewer \
  roles/bigquery.jobUser \
  roles/run.admin \
  roles/cloudfunctions.admin \
  roles/cloudsql.admin \
  roles/cloudsql.client \
  roles/iap.tunnelResourceAccessor \
  roles/iap.httpsResourceAccessor \
  roles/iam.workloadIdentityUser \
  roles/iam.serviceAccountTokenCreator \
  roles/iam.serviceAccountUser \
  roles/serviceusage.serviceUsageAdmin \
  roles/secretmanager.admin \
  roles/secretmanager.secretAccessor \
  roles/storage.admin \
  roles/logging.logWriter \
  roles/artifactregistry.writer \
  roles/artifactregistry.createOnPushWriter \
  roles/viewer
do
  if ! gcloud projects get-iam-policy "${DEPLOY_PROJECT_ID}" \
    --flatten="bindings[].members" \
    --filter="bindings.role=${ROLE} AND bindings.members=serviceAccount:${SA_EMAIL}" \
    --format='value(bindings.role)' | grep -q .; then
    echo "Missing deploy project role for ${SA_EMAIL}: ${ROLE}"
    IAM_VERIFY_FAILED=1
  fi
done

if ! gcloud iam service-accounts get-iam-policy "${SA_EMAIL}" \
  --project "${WIF_PROJECT_ID}" \
  --flatten="bindings[].members" \
  --filter="bindings.role=roles/iam.workloadIdentityUser AND bindings.members=${REPO_PRINCIPAL}" \
  --format='value(bindings.role)' | grep -q .; then
  echo "Missing service-account binding: ${REPO_PRINCIPAL} -> roles/iam.workloadIdentityUser"
  IAM_VERIFY_FAILED=1
fi

if ! gcloud iam service-accounts get-iam-policy "${SA_EMAIL}" \
  --project "${WIF_PROJECT_ID}" \
  --flatten="bindings[].members" \
  --filter="bindings.role=roles/iam.serviceAccountTokenCreator AND bindings.members=${REPO_PRINCIPAL}" \
  --format='value(bindings.role)' | grep -q .; then
  echo "Missing service-account binding: ${REPO_PRINCIPAL} -> roles/iam.serviceAccountTokenCreator"
  IAM_VERIFY_FAILED=1
fi

if ! gcloud iam service-accounts get-iam-policy "${SA_EMAIL}" \
  --project "${WIF_PROJECT_ID}" \
  --flatten="bindings[].members" \
  --filter="bindings.role=roles/iam.serviceAccountTokenCreator AND bindings.members=serviceAccount:${SA_EMAIL}" \
  --format='value(bindings.role)' | grep -q .; then
  echo "Missing self binding: serviceAccount:${SA_EMAIL} -> roles/iam.serviceAccountTokenCreator"
  IAM_VERIFY_FAILED=1
fi

if [[ "${IAM_VERIFY_FAILED}" -ne 0 ]]; then
  echo "IAM verification failed. Fix missing bindings above and rerun."
  exit 1
fi

echo "IAM verification passed for ${SA_EMAIL}."

echo "Ensuring ${MYSQL_PRISMA_SECRET_NAME} exists in deploy project..."
if [[ -z "${MYSQL_PRISMA_URL}" ]]; then
  if [[ -n "${DB_USER}" && -n "${DB_PASSWORD}" && -n "${DB_NAME}" && -n "${CLOUDSQL_INSTANCE_CONNECTION_NAME}" ]]; then
    MYSQL_PRISMA_URL="mysql://${DB_USER}:${DB_PASSWORD}@localhost:3306/${DB_NAME}?socket=/cloudsql/${CLOUDSQL_INSTANCE_CONNECTION_NAME}"
    echo "Built MYSQL_PRISMA_URL from DB_* and CLOUDSQL_INSTANCE_CONNECTION_NAME"
  else
    echo "Skipping secret value bootstrap: set MYSQL_PRISMA_URL or provide DB_USER, DB_PASSWORD (or DB_PASS), DB_NAME, CLOUDSQL_INSTANCE_CONNECTION_NAME"
  fi
fi

if [[ -n "${MYSQL_PRISMA_URL}" ]]; then
  if gcloud secrets describe "${MYSQL_PRISMA_SECRET_NAME}" --project "${DEPLOY_PROJECT_ID}" >/dev/null 2>&1; then
    echo -n "${MYSQL_PRISMA_URL}" | gcloud secrets versions add "${MYSQL_PRISMA_SECRET_NAME}" \
      --project "${DEPLOY_PROJECT_ID}" \
      --data-file=- \
      --quiet >/dev/null
    echo "Added new secret version: ${MYSQL_PRISMA_SECRET_NAME}"
  else
    echo -n "${MYSQL_PRISMA_URL}" | gcloud secrets create "${MYSQL_PRISMA_SECRET_NAME}" \
      --project "${DEPLOY_PROJECT_ID}" \
      --data-file=- \
      --replication-policy=automatic \
      --quiet >/dev/null
    echo "Created secret: ${MYSQL_PRISMA_SECRET_NAME}"
  fi
fi

echo
printf '%s\n' "Done. Set these GitHub secrets:" \
  "GCP_PROJECT_ID=${DEPLOY_PROJECT_ID}" \
  "GCP_DEPLOYER_SERVICE_ACCOUNT_EMAIL=${SA_EMAIL}" \
  "GCP_WORKLOAD_IDENTITY_PROVIDER=${WIF_PROVIDER_RESOURCE}"

echo "Optional overrides for reruns: SA_NAME, WIF_PROJECT_ID, WIF_PROJECT_NUMBER, DEPLOY_PROJECT_ID, WIF_POOL_ID, WIF_PROVIDER_ID, GITHUB_OWNER, GITHUB_REPO, BIGQUERY_CONNECTION_ID, BIGQUERY_CONNECTION_LOCATION, BIGQUERY_CONNECTION_DISPLAY_NAME, MAPS_API_ADMIN_ROLE"
echo "Also supported override: GITHUB_REPOSITORY (owner/repo)"
