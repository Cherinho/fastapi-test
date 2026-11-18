#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: ./one-click-deploy/connect.sh [--region REGION] INSTANCE_ID

Opens an AWS SSM Session Manager tunnel for Ghost on local port 2368.
EOF
}

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
INSTANCE_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)
      [[ $# -ge 2 ]] || { echo "Error: --region requires a value." >&2; exit 1; }
      REGION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -n "$INSTANCE_ID" ]]; then
        echo "Error: only one EC2 instance ID may be supplied." >&2
        exit 1
      fi
      INSTANCE_ID="$1"
      shift
      ;;
  esac
done

if [[ -z "$INSTANCE_ID" ]]; then
  echo "Error: EC2 instance ID is required." >&2
  usage >&2
  exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "Error: AWS CLI is not installed." >&2
  exit 1
fi
if ! command -v session-manager-plugin >/dev/null 2>&1; then
  echo "Error: AWS Session Manager plugin is not installed." >&2
  exit 1
fi

AWS=(aws)
if [[ -n "$REGION" ]]; then
  AWS+=(--region "$REGION")
fi
if ! "${AWS[@]}" sts get-caller-identity >/dev/null 2>&1; then
  echo "Error: AWS credentials are unavailable or invalid." >&2
  exit 1
fi

if [[ -z "$REGION" ]]; then
  REGION="$("${AWS[@]}" configure get region 2>/dev/null || true)"
fi
if [[ -z "$REGION" ]]; then
  echo "Error: no AWS region configured. Use --region or set AWS_REGION." >&2
  exit 1
fi
AWS=(aws --region "$REGION")

"${AWS[@]}" ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text >/dev/null

echo "Starting an SSM port-forwarding session..."
echo "Keep this process running. Ghost will be available at:"
echo "  http://localhost:2368"
echo

"${AWS[@]}" ssm start-session \
  --target "$INSTANCE_ID" \
  --document-name "AWS-StartPortForwardingSession" \
  --parameters "{\"portNumber\":[\"2368\"],\"localPortNumber\":[\"2368\"]}"
