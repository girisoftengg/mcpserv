#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# deploy.sh — Deploy arithmetic-mcp CloudFormation stacks to AWS
#
# Usage:
#   ./aws/deploy.sh [ENVIRONMENT] [REGION]
#
# Examples:
#   ./aws/deploy.sh prod us-east-1
#   ./aws/deploy.sh dev  us-west-2
#
# Prerequisites:
#   - AWS CLI v2 configured with credentials (aws configure)
#   - Sufficient IAM permissions (CloudFormation, ECS, ECR, IAM, ACM, ALB, VPC)
#   - Update aws/parameters/ JSON files with your actual values before running
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ENVIRONMENT="${1:-prod}"
REGION="${2:-us-east-1}"
INFRA_STACK="${ENVIRONMENT}-arithmetic-mcp-infra"
PIPELINE_STACK="${ENVIRONMENT}-arithmetic-mcp-pipeline"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=================================================="
echo " arithmetic-mcp Deployment"
echo " Environment : $ENVIRONMENT"
echo " Region      : $REGION"
echo "=================================================="

# ── Helper: deploy or update a CloudFormation stack ───────────────────────────
deploy_stack() {
  local stack_name="$1"
  local template_file="$2"
  local params_file="$3"

  echo ""
  echo "──────────────────────────────────────────────────"
  echo "Deploying stack: $stack_name"
  echo "Template       : $template_file"
  echo "──────────────────────────────────────────────────"

  aws cloudformation deploy \
    --region "$REGION" \
    --stack-name "$stack_name" \
    --template-file "$template_file" \
    --parameter-overrides "file://$params_file" \
    --capabilities CAPABILITY_NAMED_IAM \
    --no-fail-on-empty-changeset

  echo "Stack $stack_name deployed successfully."
}

# ── Helper: wait for ACM DNS validation (may take a few minutes) ──────────────
wait_for_certificate() {
  local stack_name="$1"
  echo ""
  echo "Waiting for ACM certificate validation (may take several minutes)..."
  echo "Check your Route53 hosted zone for the CNAME record added automatically."

  CERT_ARN=$(aws cloudformation describe-stacks \
    --region "$REGION" \
    --stack-name "$stack_name" \
    --query "Stacks[0].Outputs[?OutputKey=='CertificateArn'].OutputValue" \
    --output text)

  if [ -n "$CERT_ARN" ] && [ "$CERT_ARN" != "None" ]; then
    aws acm wait certificate-validated \
      --region "$REGION" \
      --certificate-arn "$CERT_ARN"
    echo "Certificate validated: $CERT_ARN"
  fi
}

# ── Step 1: Deploy infrastructure (VPC, ECS, ALB, ACM) ───────────────────────
deploy_stack \
  "$INFRA_STACK" \
  "$SCRIPT_DIR/infrastructure.yaml" \
  "$SCRIPT_DIR/parameters/infrastructure-params.json"

wait_for_certificate "$INFRA_STACK"

# ── Step 2: Pull ECS outputs to auto-fill pipeline parameters ─────────────────
echo ""
echo "Fetching ECS outputs from $INFRA_STACK..."

ECS_CLUSTER=$(aws cloudformation describe-stacks \
  --region "$REGION" \
  --stack-name "$INFRA_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='ECSClusterName'].OutputValue" \
  --output text)

ECS_SERVICE=$(aws cloudformation describe-stacks \
  --region "$REGION" \
  --stack-name "$INFRA_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='ECSServiceName'].OutputValue" \
  --output text)

ALB_DNS=$(aws cloudformation describe-stacks \
  --region "$REGION" \
  --stack-name "$INFRA_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='LoadBalancerDNS'].OutputValue" \
  --output text)

echo "  ECS Cluster : $ECS_CLUSTER"
echo "  ECS Service : $ECS_SERVICE"
echo "  ALB DNS     : $ALB_DNS"

# Patch the pipeline parameters file with live ECS values
python3 - <<PYEOF
import json, sys

with open("$SCRIPT_DIR/parameters/pipeline-params.json") as f:
    params = json.load(f)

updates = {
    "ECSClusterName": "$ECS_CLUSTER",
    "ECSServiceName": "$ECS_SERVICE",
}

for p in params:
    if p["ParameterKey"] in updates:
        p["ParameterValue"] = updates[p["ParameterKey"]]

with open("$SCRIPT_DIR/parameters/pipeline-params.json", "w") as f:
    json.dump(params, f, indent=2)

print("Pipeline parameters updated.")
PYEOF

# ── Step 3: Deploy pipeline (ECR, CodeBuild, CodePipeline) ────────────────────
deploy_stack \
  "$PIPELINE_STACK" \
  "$SCRIPT_DIR/pipeline.yaml" \
  "$SCRIPT_DIR/parameters/pipeline-params.json"

# ── Step 4: Print next steps ───────────────────────────────────────────────────
CONN_ARN=$(aws cloudformation describe-stacks \
  --region "$REGION" \
  --stack-name "$PIPELINE_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='GitHubConnectionArn'].OutputValue" \
  --output text)

ECR_URI=$(aws cloudformation describe-stacks \
  --region "$REGION" \
  --stack-name "$PIPELINE_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='ECRRepositoryURI'].OutputValue" \
  --output text)

PIPELINE_URL=$(aws cloudformation describe-stacks \
  --region "$REGION" \
  --stack-name "$PIPELINE_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='PipelineURL'].OutputValue" \
  --output text)

echo ""
echo "=================================================="
echo " Deployment complete!"
echo "=================================================="
echo ""
echo " NEXT STEPS:"
echo ""
echo " 1. Authorise the GitHub connection in the AWS Console:"
echo "    https://$REGION.console.aws.amazon.com/codesuite/settings/connections"
echo "    Connection ARN: $CONN_ARN"
echo ""
echo " 2. Create a DNS CNAME record for your domain pointing to:"
echo "    $ALB_DNS"
echo "    (or an Route53 Alias record if the hosted zone is in AWS)"
echo ""
echo " 3. Push code to GitHub to trigger the pipeline:"
echo "    $PIPELINE_URL"
echo ""
echo " 4. Monitor the pipeline — on first success, the MCP server will be"
echo "    available at the HTTPS endpoint printed by the infrastructure stack."
echo ""
echo " ECR Repository: $ECR_URI"
echo "=================================================="
