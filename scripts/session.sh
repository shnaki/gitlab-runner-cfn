#!/usr/bin/env bash
set -euo pipefail
export AWS_PAGER=

stack_name=$1
region=$2

instance_id=$(aws cloudformation describe-stacks \
  --stack-name "$stack_name" \
  --region "$region" \
  --query 'Stacks[0].Outputs[?OutputKey==`InstanceId`].OutputValue' \
  --output text)

if [ -z "$instance_id" ] || [ "$instance_id" = "None" ]; then
  echo "ERROR: could not find InstanceId in stack outputs for $stack_name" >&2
  exit 1
fi

echo "Connecting to $instance_id..."
exec aws ssm start-session --target "$instance_id" --region "$region"
