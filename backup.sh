#!/bin/bash

set -o errexit -o nounset -o pipefail

export AWS_PAGER=""

# Sentry cron monitoring (optional). Set SENTRY_CRONS_URL to the per-monitor
# ingest URL from Sentry (Settings -> Crons -> <monitor> -> "Direct ingest URL").
# Format: https://o<org>.ingest.sentry.io/api/<project>/cron/<slug>/<key>/
# All check-ins are best-effort: a Sentry outage must not break the backup.
SENTRY_CRONS_URL="${SENTRY_CRONS_URL:-}"
SENTRY_CHECKIN_ID=""

sentry_checkin_start() {
    [ -z "$SENTRY_CRONS_URL" ] && return 0
    SENTRY_CHECKIN_ID=$(
        curl -sS --max-time 5 -X POST "$SENTRY_CRONS_URL" \
            -H 'Content-Type: application/json' \
            -d '{"status":"in_progress"}' 2>/dev/null \
        | sed -n 's/.*"id":"\([^"]*\)".*/\1/p'
    ) || true
}

sentry_checkin_finish() {
    [ -z "$SENTRY_CRONS_URL" ] && return 0
    [ -z "$SENTRY_CHECKIN_ID" ] && return 0
    local status="$1"
    curl -sS --max-time 5 -X PUT "${SENTRY_CRONS_URL}${SENTRY_CHECKIN_ID}/" \
        -H 'Content-Type: application/json' \
        -d "{\"status\":\"$status\"}" >/dev/null 2>&1 || true
}

trap 'sentry_checkin_finish error' ERR

s3() {
    aws s3 --region "$AWS_REGION" "$@"
}

s3api() {
    aws s3api "$1" --region "$AWS_REGION" --bucket "$S3_BUCKET_NAME" "${@:2}"
}

bucket_exists() {
    s3 ls "$S3_BUCKET_NAME" &> /dev/null
}

create_bucket() {
    echo "Bucket $S3_BUCKET_NAME doesn't exist. Creating it now..."

    # create bucket
    s3api create-bucket \
        --create-bucket-configuration LocationConstraint="$AWS_REGION" \
        --object-ownership BucketOwnerEnforced

    # block public access
    s3api put-public-access-block \
        --public-access-block-configuration \
        "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

    # enable versioning for objects in the bucket 
    s3api put-bucket-versioning --versioning-configuration Status=Enabled

    # encrypt objects in the bucket
    s3api put-bucket-encryption \
      --server-side-encryption-configuration \
      '{"Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]}'
}

ensure_bucket_exists() {
    if bucket_exists; then
        return
    fi    
    create_bucket
}

pg_dump_database() {
    pg_dump  --no-owner --no-privileges --clean --if-exists --quote-all-identifiers "$DATABASE_URL"
}

upload_to_bucket() {
    # if the zipped backup file is larger than 50 GB add the --expected-size option
    # see https://docs.aws.amazon.com/cli/latest/reference/s3/cp.html
    s3 cp - "s3://$S3_BUCKET_NAME/$(date +%Y/%m/%d/backup-%H-%M-%S.sql.gz)"
}

main() {
    sentry_checkin_start
    ensure_bucket_exists
    echo "Taking backup and uploading it to S3..."
    pg_dump_database | gzip | upload_to_bucket
    echo "Done."
    sentry_checkin_finish ok
}

main
