#!/usr/bin/env bash
# Empty the two buckets so the stacks can be deleted. CloudFormation will not
# delete a bucket that still holds objects, and has no way to empty one.
#
# The artifact bucket is versioned, because a CodePipeline S3 source action
# requires it. `aws s3 rm --recursive` only writes delete markers there, so
# the bucket stays non-empty; every version has to go explicitly.
#
#   scripts/empty-buckets.sh <artifact-bucket> <template-bucket>
set -euo pipefail

ARTIFACTS="${1:?usage: empty-buckets.sh <artifact-bucket> <template-bucket>}"
TEMPLATES="${2:?missing template bucket}"

purge_versions() {
  local bucket="$1" batch
  while :; do
    batch="$(aws s3api list-object-versions --bucket "$bucket" --max-keys 500 \
      --query '{Objects: (Versions || `[]`)[].{Key: Key, VersionId: VersionId} + (DeleteMarkers || `[]`)[].{Key: Key, VersionId: VersionId}}' \
      --output json 2>/dev/null)" || return 0
    case "$batch" in
      *'"Key"'*) ;;
      *) return 0 ;;
    esac
    aws s3api delete-objects --bucket "$bucket" --delete "$batch" >/dev/null || return 0
  done
}

for b in "$ARTIFACTS" "$TEMPLATES"; do
  if ! aws s3api head-bucket --bucket "$b" 2>/dev/null; then
    echo "skipping $b: does not exist or is not yours"
    continue
  fi
  aws s3 rm "s3://$b" --recursive >/dev/null || true
  purge_versions "$b"
  echo "emptied $b"
done
