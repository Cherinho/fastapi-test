#!/usr/bin/env bash
set -Eeuo pipefail

ROLE_NAME="ghost-blog-one-click-ssm-role"
PROFILE_NAME="ghost-blog-one-click-profile"
PROJECT_TAG="GhostBlogOneClick"

usage() {
  cat <<'EOF'
Usage: ./one-click-deploy/cleanup.sh [--region REGION] INSTANCE_ID

Explicitly confirms and removes resources identified as belonging to this deployment.
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

if ! "${AWS[@]}" ec2 describe-instances --instance-ids "$INSTANCE_ID" >/dev/null 2>&1; then
  echo "Error: instance $INSTANCE_ID was not found." >&2
  exit 1
fi
INSTANCE_PROJECT="$("${AWS[@]}" ec2 describe-tags \
  --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=Project" \
  --query 'Tags[0].Value' --output text 2>/dev/null || true)"
if [[ "$INSTANCE_PROJECT" != "$PROJECT_TAG" ]]; then
  echo "Refusing cleanup: instance $INSTANCE_ID is not tagged $PROJECT_TAG." >&2
  exit 1
fi

read -r -p "Terminate instance $INSTANCE_ID and remove project-owned IAM and Security Group resources? Type 'yes' to confirm: " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
  echo "Cleanup cancelled."
  exit 0
fi

VPC_ID="$("${AWS[@]}" ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].VpcId' --output text 2>/dev/null || true)"
SG_IDS="$("${AWS[@]}" ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' --output text 2>/dev/null || true)"

"${AWS[@]}" ec2 terminate-instances --instance-ids "$INSTANCE_ID" >/dev/null
echo "Termination requested for $INSTANCE_ID."
"${AWS[@]}" ec2 wait instance-terminated --instance-ids "$INSTANCE_ID"

if [[ -n "$VPC_ID" && -n "$SG_IDS" ]]; then
  for SG_ID in $SG_IDS; do
    SG_NAME="$("${AWS[@]}" ec2 describe-security-groups --group-ids "$SG_ID" \
      --query 'SecurityGroups[0].GroupName' --output text 2>/dev/null || true)"
    SG_PROJECT="$("${AWS[@]}" ec2 describe-tags \
      --filters "Name=resource-id,Values=$SG_ID" "Name=key,Values=Project" \
      --query 'Tags[0].Value' --output text 2>/dev/null || true)"
    if [[ "$SG_NAME" == "ghost-blog-one-click-sg" && "$SG_PROJECT" == "$PROJECT_TAG" ]]; then
      if "${AWS[@]}" ec2 delete-security-group --group-id "$SG_ID" >/dev/null 2>&1; then
        echo "Deleted project Security Group $SG_ID."
      else
        echo "Warning: Security Group $SG_ID could not be deleted; it may still be in use." >&2
      fi
    else
      echo "Leaving unrelated or untagged Security Group $SG_ID."
    fi
  done
fi

if "${AWS[@]}" iam get-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1; then
  PROFILE_PROJECT="$("${AWS[@]}" iam list-instance-profile-tags --instance-profile-name "$PROFILE_NAME" \
    --query "Tags[?Key=='Project'].Value | [0]" --output text 2>/dev/null || true)"
  if [[ "$PROFILE_PROJECT" != "$PROJECT_TAG" ]]; then
    echo "Leaving IAM instance profile $PROFILE_NAME because it is not identified as project-owned."
  else
    for ROLE in $("${AWS[@]}" iam get-instance-profile --instance-profile-name "$PROFILE_NAME" \
      --query 'InstanceProfile.Roles[].RoleName' --output text 2>/dev/null); do
      "${AWS[@]}" iam remove-role-from-instance-profile \
        --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE" >/dev/null 2>&1 || true
    done
    "${AWS[@]}" iam delete-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1 || true
    echo "Removed project IAM instance profile $PROFILE_NAME when deletion was allowed."
  fi
fi

if "${AWS[@]}" iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  ROLE_PROJECT="$("${AWS[@]}" iam list-role-tags --role-name "$ROLE_NAME" \
    --query "Tags[?Key=='Project'].Value | [0]" --output text 2>/dev/null || true)"
  if [[ "$ROLE_PROJECT" != "$PROJECT_TAG" ]]; then
    echo "Leaving IAM role $ROLE_NAME because it is not identified as project-owned."
  else
    "${AWS[@]}" iam detach-role-policy \
      --role-name "$ROLE_NAME" \
      --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" \
      >/dev/null 2>&1 || true
    "${AWS[@]}" iam delete-role --role-name "$ROLE_NAME" >/dev/null 2>&1 || true
    echo "Removed project IAM role $ROLE_NAME when deletion was allowed."
  fi
fi

echo "Cleanup complete."
