@echo off
setlocal EnableDelayedExpansion

:: -----------------------------
:: Config (override via env vars)
:: -----------------------------
IF NOT DEFINED SA_NAME SET "SA_NAME=github-deploy-sa"

IF NOT DEFINED WIF_PROJECT_ID (
    IF DEFINED PROJECT_ID (
        SET "WIF_PROJECT_ID=!PROJECT_ID!"
    ) ELSE (
        FOR /F "tokens=*" %%i IN ('gcloud config get-value project') DO SET "WIF_PROJECT_ID=%%i"
    )
)

IF NOT DEFINED DEPLOY_PROJECT_ID (
    IF DEFINED PROJECT_ID (
        SET "DEPLOY_PROJECT_ID=!PROJECT_ID!"
    ) ELSE (
        SET "DEPLOY_PROJECT_ID=!WIF_PROJECT_ID!"
    )
)

IF NOT DEFINED WIF_PROJECT_NUMBER (
    FOR /F "tokens=*" %%i IN ('gcloud projects describe "!WIF_PROJECT_ID!" --format="value(projectNumber)"') DO SET "WIF_PROJECT_NUMBER=%%i"
)

IF NOT DEFINED DEPLOY_PROJECT_NUMBER (
    FOR /F "tokens=*" %%i IN ('gcloud projects describe "!DEPLOY_PROJECT_ID!" --format="value(projectNumber)"') DO SET "DEPLOY_PROJECT_NUMBER=%%i"
)

IF NOT DEFINED WIF_POOL_ID SET "WIF_POOL_ID=github-pool-v1"
IF NOT DEFINED WIF_PROVIDER_ID SET "WIF_PROVIDER_ID=github-provider-v1"
IF NOT DEFINED GITHUB_OWNER SET "GITHUB_OWNER=Pawa-IT-Solutions"
IF NOT DEFINED GITHUB_REPO SET "GITHUB_REPO=cloud-mastery-ecommerce-2026"
IF NOT DEFINED GITHUB_REPOSITORY SET "GITHUB_REPOSITORY=!GITHUB_OWNER!/!GITHUB_REPO!"
IF NOT DEFINED MYSQL_PRISMA_SECRET_NAME SET "MYSQL_PRISMA_SECRET_NAME=MYSQL_PRISMA_URL"
IF NOT DEFINED BIGQUERY_CONNECTION_ID SET "BIGQUERY_CONNECTION_ID=agent-builder-conn"
IF NOT DEFINED BIGQUERY_CONNECTION_LOCATION SET "BIGQUERY_CONNECTION_LOCATION=us"
IF NOT DEFINED BIGQUERY_CONNECTION_DISPLAY_NAME SET "BIGQUERY_CONNECTION_DISPLAY_NAME=discoveryengine-connection"
IF NOT DEFINED MAPS_API_ADMIN_ROLE SET "MAPS_API_ADMIN_ROLE=roles/mapsplatform.admin"

:: Optional DB inputs for secret bootstrap.
IF NOT DEFINED MYSQL_PRISMA_URL SET "MYSQL_PRISMA_URL="
IF NOT DEFINED DB_NAME SET "DB_NAME="
IF NOT DEFINED DB_USER SET "DB_USER="
IF NOT DEFINED DB_PASSWORD (
    IF DEFINED DB_PASS (
        SET "DB_PASSWORD=!DB_PASS!"
    ) ELSE (
        SET "DB_PASSWORD="
    )
)
IF NOT DEFINED CLOUDSQL_INSTANCE_CONNECTION_NAME SET "CLOUDSQL_INSTANCE_CONNECTION_NAME="

:: -----------------------------
:: Derived values
:: -----------------------------
SET "SA_EMAIL=!SA_NAME!@!WIF_PROJECT_ID!.iam.gserviceaccount.com"
SET "REPO_PRINCIPAL=principalSet://iam.googleapis.com/projects/!WIF_PROJECT_NUMBER!/locations/global/workloadIdentityPools/!WIF_POOL_ID!/attribute.repository/!GITHUB_REPOSITORY!"
SET "WIF_PROVIDER_RESOURCE=projects/!WIF_PROJECT_NUMBER!/locations/global/workloadIdentityPools/!WIF_POOL_ID!/providers/!WIF_PROVIDER_ID!"
SET "DISCOVERY_ENGINE_SA=service-!DEPLOY_PROJECT_NUMBER!@gcp-sa-discoveryengine.iam.gserviceaccount.com"

echo WIF Project: !WIF_PROJECT_ID! (!WIF_PROJECT_NUMBER!)
echo Deploy Project: !DEPLOY_PROJECT_ID! (!DEPLOY_PROJECT_NUMBER!)
echo Service Account: !SA_EMAIL!
echo Discovery Engine SA: !DISCOVERY_ENGINE_SA!
echo GitHub Repository: !GITHUB_REPOSITORY!
echo Repo Principal: !REPO_PRINCIPAL!
echo WIF Provider: !WIF_PROVIDER_RESOURCE!

echo.
echo Enabling required APIs in WIF project...
call gcloud services enable ^
  cloudresourcemanager.googleapis.com ^
  iam.googleapis.com ^
  iamcredentials.googleapis.com ^
  sts.googleapis.com ^
  serviceusage.googleapis.com ^
  --quiet ^
  --project "!WIF_PROJECT_ID!"

echo.
echo Enabling required APIs in deploy project...
call gcloud services enable ^
  cloudresourcemanager.googleapis.com ^
  cloudbuild.googleapis.com ^
  run.googleapis.com ^
  sqladmin.googleapis.com ^
  sql-component.googleapis.com ^
  cloudfunctions.googleapis.com ^
  artifactregistry.googleapis.com ^
  eventarc.googleapis.com ^
  secretmanager.googleapis.com ^
  storage.googleapis.com ^
  --quiet ^
  --project "!DEPLOY_PROJECT_ID!"

echo.
echo Creating service account if missing...
call gcloud iam service-accounts describe "!SA_EMAIL!" --project "!WIF_PROJECT_ID!" >NUL 2>&1
IF ERRORLEVEL 1 (
  call gcloud iam service-accounts create "!SA_NAME!" ^
    --project "!WIF_PROJECT_ID!" ^
    --display-name "GitHub Actions WIF Service Account" ^
    --description "Privileged SA for GitHub Actions WIF deployment" ^
    --quiet
) ELSE (
  echo Service account already exists: !SA_EMAIL!
)

echo.
echo Applying roles in WIF project...
FOR %%R IN (
  roles/serviceusage.serviceUsageAdmin
  roles/iam.serviceAccountUser
  roles/viewer
) DO (
  call gcloud projects add-iam-policy-binding "!WIF_PROJECT_ID!" ^
    --member "serviceAccount:!SA_EMAIL!" ^
    --role "%%R" ^
    --condition=None ^
    --quiet ^
    --format=none
  echo Assigned in WIF project: %%R
)

echo.
echo Applying roles in deploy project...
FOR %%R IN (
  roles/cloudbuild.builds.editor
  roles/cloudbuild.builds.builder
  roles/bigquery.admin
  roles/bigquery.dataViewer
  roles/bigquery.jobUser
  roles/run.admin
  roles/cloudfunctions.admin
  roles/cloudsql.admin
  roles/cloudsql.client
  roles/iap.tunnelResourceAccessor
  roles/iap.httpsResourceAccessor
  roles/iam.workloadIdentityUser
  roles/iam.serviceAccountTokenCreator
  roles/iam.serviceAccountUser
  roles/serviceusage.serviceUsageAdmin
  roles/secretmanager.admin
  roles/secretmanager.secretAccessor
  roles/storage.admin
  roles/logging.logWriter
  roles/artifactregistry.writer
  roles/artifactregistry.createOnPushWriter
  roles/viewer
) DO (
  call gcloud projects add-iam-policy-binding "!DEPLOY_PROJECT_ID!" ^
    --member "serviceAccount:!SA_EMAIL!" ^
    --role "%%R" ^
    --condition=None ^
    --quiet ^
    --format=none
  echo Assigned in deploy project: %%R
)

echo.
echo Applying build roles to Cloud Build service identities in deploy project...
SET "BUILD_SERVICE_ACCOUNTS=!DEPLOY_PROJECT_NUMBER!@cloudbuild.gserviceaccount.com service-!DEPLOY_PROJECT_NUMBER!@gcp-sa-cloudbuild.iam.gserviceaccount.com !DEPLOY_PROJECT_NUMBER!-compute@developer.gserviceaccount.com"

FOR %%A IN (!BUILD_SERVICE_ACCOUNTS!) DO (
  FOR %%R IN (
    roles/cloudbuild.builds.builder
    roles/artifactregistry.writer
    roles/storage.objectViewer
    roles/logging.logWriter
  ) DO (
    call gcloud projects add-iam-policy-binding "!DEPLOY_PROJECT_ID!" ^
      --member "serviceAccount:%%A" ^
      --role "%%R" ^
      --condition=None ^
      --quiet ^
      --format=none
    echo Assigned to %%A: %%R
  )
)

echo.
echo Ensuring BigQuery Cloud Resource connection exists...
call bq show --connection --project_id="!DEPLOY_PROJECT_ID!" --location="!BIGQUERY_CONNECTION_LOCATION!" "!BIGQUERY_CONNECTION_ID!" >NUL 2>&1
IF ERRORLEVEL 1 (
  call bq mk --connection ^
    --display_name="!BIGQUERY_CONNECTION_DISPLAY_NAME!" ^
    --connection_type=CLOUD_RESOURCE ^
    --project_id="!DEPLOY_PROJECT_ID!" ^
    --location="!BIGQUERY_CONNECTION_LOCATION!" ^
    "!BIGQUERY_CONNECTION_ID!"
  echo Created BigQuery connection: !BIGQUERY_CONNECTION_ID! (!BIGQUERY_CONNECTION_LOCATION!)
) ELSE (
  echo BigQuery connection already exists: !BIGQUERY_CONNECTION_ID! (!BIGQUERY_CONNECTION_LOCATION!)
)

echo.
echo Resolving BigQuery connection service account...
SET "CONNECTION_SERVICE_ACCOUNT="
FOR /F "tokens=2 delims=:" %%A IN ('bq show --format^=prettyjson --connection --project_id^="!DEPLOY_PROJECT_ID!" --location^="!BIGQUERY_CONNECTION_LOCATION!" "!BIGQUERY_CONNECTION_ID!" ^| findstr "serviceAccountId"') DO (
    SET "RAW_SA=%%A"
)
:: Clean up RAW_SA string to extract email (removes spaces, quotes, and commas)
IF DEFINED RAW_SA (
    SET "RAW_SA=!RAW_SA: =!"
    SET "RAW_SA=!RAW_SA:"=!"
    SET "CONNECTION_SERVICE_ACCOUNT=!RAW_SA:,=!"
)

IF NOT DEFINED CONNECTION_SERVICE_ACCOUNT (
  echo Failed to read serviceAccountId from BigQuery connection !BIGQUERY_CONNECTION_ID!.
  echo Ensure the connection exists and that bq CLI has access.
  exit /b 1
)

echo.
echo Granting BigQuery Data Viewer to BigQuery connection service account...
echo Connection service account member: serviceAccount:!CONNECTION_SERVICE_ACCOUNT!
call gcloud projects add-iam-policy-binding "!DEPLOY_PROJECT_ID!" ^
  --member "serviceAccount:!CONNECTION_SERVICE_ACCOUNT!" ^
  --role "roles/bigquery.dataViewer" ^
  --condition=None ^
  --quiet ^
  --format=none

echo.
echo Granting Discovery Engine service account BigQuery + logging + Artifact Registry roles...
echo Discovery Engine member: serviceAccount:!DISCOVERY_ENGINE_SA!
FOR %%R IN (
  roles/artifactregistry.admin
  roles/artifactregistry.writer
  roles/bigquery.connectionUser
  roles/bigquery.dataViewer
  roles/bigquery.jobUser
  roles/bigquery.readSessionUser
  roles/logging.admin
  roles/logging.bucketWriter
  roles/logging.viewer
) DO (
  call gcloud projects add-iam-policy-binding "!DEPLOY_PROJECT_ID!" ^
    --member "serviceAccount:!DISCOVERY_ENGINE_SA!" ^
    --role "%%R" ^
    --condition=None ^
    --quiet ^
    --format=none
  echo Assigned to !DISCOVERY_ENGINE_SA!: %%R
)

echo.
echo Validating workload identity provider exists...
call gcloud iam workload-identity-pools providers describe "!WIF_PROVIDER_ID!" ^
  --project "!WIF_PROJECT_ID!" ^
  --location global ^
  --workload-identity-pool "!WIF_POOL_ID!" ^
  --format="value(name)" >NUL

echo.
echo Granting WIF principal impersonation permissions on service account...
call gcloud iam service-accounts add-iam-policy-binding "!SA_EMAIL!" ^
  --project "!WIF_PROJECT_ID!" ^
  --member "!REPO_PRINCIPAL!" ^
  --role roles/iam.workloadIdentityUser ^
  --quiet

call gcloud iam service-accounts add-iam-policy-binding "!SA_EMAIL!" ^
  --project "!WIF_PROJECT_ID!" ^
  --member "!REPO_PRINCIPAL!" ^
  --role roles/iam.serviceAccountTokenCreator ^
  --quiet

echo.
echo Granting service account self token-creator binding ^(iam.serviceAccounts.getAccessToken^)...
call gcloud iam service-accounts add-iam-policy-binding "!SA_EMAIL!" ^
  --project "!WIF_PROJECT_ID!" ^
  --member "serviceAccount:!SA_EMAIL!" ^
  --role roles/iam.serviceAccountTokenCreator ^
  --quiet

echo.
echo Verifying required IAM roles and bindings for !SA_EMAIL!...
SET "IAM_VERIFY_FAILED=0"

FOR %%R IN (
  roles/serviceusage.serviceUsageAdmin
  roles/iam.serviceAccountUser
  roles/viewer
) DO (
  call gcloud projects get-iam-policy "!WIF_PROJECT_ID!" --flatten="bindings[].members" --filter="bindings.role=%%R AND bindings.members=serviceAccount:!SA_EMAIL!" --format="value(bindings.role)" | findstr /R /C:"roles/" >NUL
  IF ERRORLEVEL 1 (
    echo Missing WIF project role for !SA_EMAIL!: %%R
    SET "IAM_VERIFY_FAILED=1"
  )
)

FOR %%R IN (
  roles/cloudbuild.builds.editor
  roles/cloudbuild.builds.builder
  roles/bigquery.admin
  roles/bigquery.dataViewer
  roles/bigquery.jobUser
  roles/run.admin
  roles/cloudfunctions.admin
  roles/cloudsql.admin
  roles/cloudsql.client
  roles/iap.tunnelResourceAccessor
  roles/iap.httpsResourceAccessor
  roles/iam.workloadIdentityUser
  roles/iam.serviceAccountTokenCreator
  roles/iam.serviceAccountUser
  roles/serviceusage.serviceUsageAdmin
  roles/secretmanager.admin
  roles/secretmanager.secretAccessor
  roles/storage.admin
  roles/logging.logWriter
  roles/artifactregistry.writer
  roles/artifactregistry.createOnPushWriter
  roles/viewer
) DO (
  call gcloud projects get-iam-policy "!DEPLOY_PROJECT_ID!" --flatten="bindings[].members" --filter="bindings.role=%%R AND bindings.members=serviceAccount:!SA_EMAIL!" --format="value(bindings.role)" | findstr /R /C:"roles/" >NUL
  IF ERRORLEVEL 1 (
    echo Missing deploy project role for !SA_EMAIL!: %%R
    SET "IAM_VERIFY_FAILED=1"
  )
)

call gcloud iam service-accounts get-iam-policy "!SA_EMAIL!" --project "!WIF_PROJECT_ID!" --flatten="bindings[].members" --filter="bindings.role=roles/iam.workloadIdentityUser AND bindings.members=!REPO_PRINCIPAL!" --format="value(bindings.role)" | findstr /C:"roles/iam.workloadIdentityUser" >NUL
IF ERRORLEVEL 1 (
  echo Missing service-account binding: !REPO_PRINCIPAL! ^-> roles/iam.workloadIdentityUser
  SET "IAM_VERIFY_FAILED=1"
)

call gcloud iam service-accounts get-iam-policy "!SA_EMAIL!" --project "!WIF_PROJECT_ID!" --flatten="bindings[].members" --filter="bindings.role=roles/iam.serviceAccountTokenCreator AND bindings.members=!REPO_PRINCIPAL!" --format="value(bindings.role)" | findstr /C:"roles/iam.serviceAccountTokenCreator" >NUL
IF ERRORLEVEL 1 (
  echo Missing service-account binding: !REPO_PRINCIPAL! ^-> roles/iam.serviceAccountTokenCreator
  SET "IAM_VERIFY_FAILED=1"
)

call gcloud iam service-accounts get-iam-policy "!SA_EMAIL!" --project "!WIF_PROJECT_ID!" --flatten="bindings[].members" --filter="bindings.role=roles/iam.serviceAccountTokenCreator AND bindings.members=serviceAccount:!SA_EMAIL!" --format="value(bindings.role)" | findstr /C:"roles/iam.serviceAccountTokenCreator" >NUL
IF ERRORLEVEL 1 (
  echo Missing self binding: serviceAccount:!SA_EMAIL! ^-> roles/iam.serviceAccountTokenCreator
  SET "IAM_VERIFY_FAILED=1"
)

IF NOT "!IAM_VERIFY_FAILED!"=="0" (
  echo IAM verification failed. Fix missing bindings above and rerun.
  exit /b 1
)

echo IAM verification passed for !SA_EMAIL!.

echo.
echo Ensuring !MYSQL_PRISMA_SECRET_NAME! exists in deploy project...
IF "!MYSQL_PRISMA_URL!"=="" (
  IF NOT "!DB_USER!"=="" IF NOT "!DB_PASSWORD!"=="" IF NOT "!DB_NAME!"=="" IF NOT "!CLOUDSQL_INSTANCE_CONNECTION_NAME!"=="" (
    SET "MYSQL_PRISMA_URL=mysql://!DB_USER!:!DB_PASSWORD!@localhost:3306/!DB_NAME!?socket=/cloudsql/!CLOUDSQL_INSTANCE_CONNECTION_NAME!"
    echo Built MYSQL_PRISMA_URL from DB_* and CLOUDSQL_INSTANCE_CONNECTION_NAME
  ) ELSE (
    echo Skipping secret value bootstrap: set MYSQL_PRISMA_URL or provide DB_USER, DB_PASSWORD ^(or DB_PASS^), DB_NAME, CLOUDSQL_INSTANCE_CONNECTION_NAME
  )
)

IF NOT "!MYSQL_PRISMA_URL!"=="" (
  call gcloud secrets describe "!MYSQL_PRISMA_SECRET_NAME!" --project "!DEPLOY_PROJECT_ID!" >NUL 2>&1
  
  :: Write secret to temporary file without trailing newline
  <nul set /p ="!MYSQL_PRISMA_URL!" > "%TEMP%\wif_temp_secret.txt"
  
  IF ERRORLEVEL 1 (
    call gcloud secrets create "!MYSQL_PRISMA_SECRET_NAME!" ^
      --project "!DEPLOY_PROJECT_ID!" ^
      --data-file="%TEMP%\wif_temp_secret.txt" ^
      --replication-policy=automatic ^
      --quiet >NUL
    echo Created secret: !MYSQL_PRISMA_SECRET_NAME!
  ) ELSE (
    call gcloud secrets versions add "!MYSQL_PRISMA_SECRET_NAME!" ^
      --project "!DEPLOY_PROJECT_ID!" ^
      --data-file="%TEMP%\wif_temp_secret.txt" ^
      --quiet >NUL
    echo Added new secret version: !MYSQL_PRISMA_SECRET_NAME!
  )
  :: Clean up temporary file
  del "%TEMP%\wif_temp_secret.txt" >NUL 2>&1
)

echo.
echo Done. Set these GitHub secrets:
echo GCP_PROJECT_ID=!DEPLOY_PROJECT_ID!
echo GCP_DEPLOYER_SERVICE_ACCOUNT_EMAIL=!SA_EMAIL!
echo GCP_WORKLOAD_IDENTITY_PROVIDER=!WIF_PROVIDER_RESOURCE!
echo.
echo Optional overrides for reruns: SA_NAME, WIF_PROJECT_ID, WIF_PROJECT_NUMBER, DEPLOY_PROJECT_ID, WIF_POOL_ID, WIF_PROVIDER_ID, GITHUB_OWNER, GITHUB_REPO, BIGQUERY_CONNECTION_ID, BIGQUERY_CONNECTION_LOCATION, BIGQUERY_CONNECTION_DISPLAY_NAME, MAPS_API_ADMIN_ROLE
echo Also supported override: GITHUB_REPOSITORY (owner/repo)

endlocal
