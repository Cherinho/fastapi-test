#!/usr/bin/env bash
set -Eeuo pipefail

ROLE_NAME="ghost-blog-one-click-ssm-role"
PROFILE_NAME="ghost-blog-one-click-profile"
SG_NAME="ghost-blog-one-click-sg"
PROJECT_TAG="GhostBlogOneClick"

usage() {
  cat <<'EOF'
Usage: ./one-click-deploy/deploy.sh [--region REGION]

Creates an Amazon Linux 2023 EC2 instance for a local-only Ghost deployment.
The instance has no public inbound rules and is accessed through AWS SSM.
EOF
}

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"

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
      echo "Error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if ! command -v aws >/dev/null 2>&1; then
  echo "Error: AWS CLI is not installed. Install AWS CLI v2 and try again." >&2
  exit 1
fi

AWS=(aws)
if [[ -n "$REGION" ]]; then
  AWS+=(--region "$REGION")
fi

if ! "${AWS[@]}" sts get-caller-identity >/dev/null 2>&1; then
  echo "Error: AWS credentials are unavailable or invalid." >&2
  echo "Configure credentials with 'aws configure', an AWS profile, or IAM identity." >&2
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
INSTALL_FILE="$SCRIPT_DIR/scripts/install.sh"

[[ -f "$COMPOSE_FILE" ]] || { echo "Error: missing $COMPOSE_FILE" >&2; exit 1; }
[[ -f "$INSTALL_FILE" ]] || { echo "Error: missing $INSTALL_FILE" >&2; exit 1; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat >"$TMP_DIR/user-data.sh" <<'USER_DATA_HEADER'
#!/bin/bash
set -Eeuo pipefail
USER_DATA_HEADER

cat >>"$TMP_DIR/user-data.sh" <<EOF
install -d -m 0755 /opt/ghost-blog
base64 --decode <<'COMPOSE_B64' > /opt/ghost-blog/docker-compose.yml
$(base64 <"$COMPOSE_FILE" | tr -d '\n')
COMPOSE_B64
base64 --decode <<'INSTALL_B64' > /tmp/ghost-install.sh
$(base64 <"$INSTALL_FILE" | tr -d '\n')
INSTALL_B64
bash /tmp/ghost-install.sh
rm -f /tmp/ghost-install.sh
EOF

TRUST_POLICY="$TMP_DIR/role-trust-policy.json"
cat >"$TRUST_POLICY" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"Service": "ec2.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

echo "Ensuring IAM role..."
if "${AWS[@]}" iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "Reusing IAM role $ROLE_NAME."
else
  "${AWS[@]}" iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://$TRUST_POLICY" \
    --tags "Key=Project,Value=$PROJECT_TAG" >/dev/null
fi

"${AWS[@]}" iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"

echo "Ensuring IAM instance profile..."
if "${AWS[@]}" iam get-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1; then
  echo "Reusing IAM instance profile $PROFILE_NAME."
else
  "${AWS[@]}" iam create-instance-profile \
    --instance-profile-name "$PROFILE_NAME" \
    --tags "Key=Project,Value=$PROJECT_TAG" >/dev/null
fi

PROFILE_STATE="$("${AWS[@]}" iam get-instance-profile --instance-profile-name "$PROFILE_NAME" \
  --query 'InstanceProfile.Roles[].RoleName' --output text)"
if [[ "$PROFILE_STATE" == "None" || -z "$PROFILE_STATE" ]]; then
  "${AWS[@]}" iam add-role-to-instance-profile \
    --role-name "$ROLE_NAME" \
    --instance-profile-name "$PROFILE_NAME"
elif [[ " $PROFILE_STATE " != *" $ROLE_NAME "* ]]; then
  echo "Error: instance profile $PROFILE_NAME exists and is associated with a different role: $PROFILE_STATE" >&2
  exit 1
fi

VPC_ID="$("${AWS[@]}" ec2 describe-vpcs --filters "Name=is-default,Values=true" \
  --query 'Vpcs[0].VpcId' --output text)"
if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
  echo "Error: no default VPC is available in $REGION." >&2
  exit 1
fi

echo "Ensuring Security Group..."
SG_ID="$("${AWS[@]}" ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$SG_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text)"
if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
  SG_ID="$("${AWS[@]}" ec2 create-security-group \
    --group-name "$SG_NAME" \
    --description "Ghost Blog one-click deployment: no inbound access" \
    --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Project,Value=$PROJECT_TAG}]" \
    --query 'GroupId' --output text)"
else
  TAG_PROJECT="$("${AWS[@]}" ec2 describe-tags \
    --filters "Name=resource-id,Values=$SG_ID" "Name=key,Values=Project" \
    --query 'Tags[0].Value' --output text)"
  if [[ "$TAG_PROJECT" != "$PROJECT_TAG" ]]; then
    echo "Error: existing Security Group $SG_ID was not created by this project." >&2
    exit 1
  fi
fi

PERMISSIONS="$("${AWS[@]}" ec2 describe-security-groups --group-ids "$SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' --output json)"
if [[ "$PERMISSIONS" != "[]" && -n "$PERMISSIONS" ]]; then
  "${AWS[@]}" ec2 revoke-security-group-ingress \
    --group-id "$SG_ID" --ip-permissions "$PERMISSIONS" >/dev/null
fi

INGRESS_COUNT="$("${AWS[@]}" ec2 describe-security-groups --group-ids "$SG_ID" \
  --query 'length(SecurityGroups[0].IpPermissions)' --output text)"
if [[ "$INGRESS_COUNT" != "0" ]]; then
  echo "Error: Security Group $SG_ID still has inbound rules." >&2
  exit 1
fi

echo "Finding the latest Amazon Linux 2023 AMI..."
AMI_ID="$("${AWS[@]}" ssm get-parameters \
  --names "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query 'Parameters[0].Value' --output text)"
if [[ -z "$AMI_ID" || "$AMI_ID" == "None" ]]; then
  echo "Error: could not resolve the Amazon Linux 2023 AMI." >&2
  exit 1
fi

SUBNET_ID="$("${AWS[@]}" ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=default-for-az,Values=true" \
  --query 'Subnets[0].SubnetId' --output text)"
if [[ -z "$SUBNET_ID" || "$SUBNET_ID" == "None" ]]; then
  echo "Error: no default subnet is available in $VPC_ID." >&2
  exit 1
fi

echo "Launching EC2 instance..."
INSTANCE_ID="$("${AWS[@]}" ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --subnet-id "$SUBNET_ID" \
  --security-group-ids "$SG_ID" \
  --iam-instance-profile "Name=$PROFILE_NAME" \
  --associate-public-ip-address \
  --user-data "file://$TMP_DIR/user-data.sh" \
  --metadata-options "HttpEndpoint=enabled,HttpTokens=required" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Project,Value=$PROJECT_TAG},{Key=Name,Value=Ghost-Blog-One-Click}]" \
  --query 'Instances[0].InstanceId' --output text)"

echo "Instance ID: $INSTANCE_ID"
echo "Region: $REGION"
echo "Waiting for instance state to become running..."
"${AWS[@]}" ec2 wait instance-running --instance-ids "$INSTANCE_ID"

echo
echo "Ghost is being installed and started. This can take several minutes."
echo "After the SSM agent reports Online, connect with:"
echo "  ./one-click-deploy/connect.sh --region $REGION $INSTANCE_ID"
