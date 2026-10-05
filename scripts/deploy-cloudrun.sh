#!/usr/bin/env bash
# Google Cloud Run — same model as the old ipod *.run.app API
set -euo pipefail
SERVICE="${SERVICE:-cc-music-api}"
REGION="${REGION:-us-central1}"
PROJECT="${GCP_PROJECT:-$(gcloud config get-value project 2>/dev/null)}"

if [[ -z "$PROJECT" || "$PROJECT" == "(unset)" ]]; then
  echo "Set GCP project: gcloud config set project YOUR_PROJECT_ID"
  exit 1
fi

gcloud run deploy "$SERVICE" \
  --source . \
  --project "$PROJECT" \
  --region "$REGION" \
  --allow-unauthenticated \
  --memory 1Gi \
  --cpu 1 \
  --timeout 300 \
  --max-instances 3 \
  --set-env-vars "CACHE_TTL_MS=3600000,AUDIO_FORMAT=mp3,REQUIRE_CC_UA=true,CACHE_DIR=/tmp/cc-music-cache"

URL="$(gcloud run services describe "$SERVICE" --region "$REGION" --format='value(status.url)')"
echo ""
echo "Deployed: $URL"
echo "Set PUBLIC_BASE_URL and redeploy if stream links need a fixed origin:"
echo "  gcloud run services update $SERVICE --region $REGION --update-env-vars PUBLIC_BASE_URL=$URL"
