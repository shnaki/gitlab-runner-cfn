#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 5 ] || [ "$#" -gt 6 ]; then
  echo "usage: $0 <deploy|changeset> <stack-name> <region> <template-file> <params-file> [change-set-name]" >&2
  exit 1
fi

mode=$1
stack_name=$2
region=$3
template_file=$4
params_file=$5
change_set_name=${6:-}

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "ERROR: aws CLI is required" >&2
  exit 1
fi

stack_exists=false
if aws cloudformation describe-stacks --stack-name "$stack_name" --region "$region" >/dev/null 2>&1; then
  stack_exists=true
fi

base_args=(
  --stack-name "$stack_name"
  --template-body "file://$template_file"
  --parameters "file://$params_file"
  --region "$region"
)
if [ -n "${CFN_CAPABILITIES:-}" ]; then
  base_args+=(--capabilities "$CFN_CAPABILITIES")
fi

if [ "$mode" = "changeset" ]; then
  if [ -z "$change_set_name" ]; then
    echo "ERROR: change set name is required in changeset mode" >&2
    exit 1
  fi

  change_set_type=CREATE
  if [ "$stack_exists" = true ]; then
    change_set_type=UPDATE
  fi

  aws cloudformation create-change-set \
    "${base_args[@]}" \
    --change-set-name "$change_set_name" \
    --change-set-type "$change_set_type"

  aws cloudformation wait change-set-create-complete \
    --stack-name "$stack_name" \
    --change-set-name "$change_set_name" \
    --region "$region"

  aws cloudformation describe-change-set \
    --stack-name "$stack_name" \
    --change-set-name "$change_set_name" \
    --region "$region" \
    --query '{Status:Status, ExecutionStatus:ExecutionStatus, Changes:Changes[].ResourceChange.{Action:Action,LogicalResourceId:LogicalResourceId,ResourceType:ResourceType,Replacement:Replacement}}'
  exit 0
fi

if [ "$mode" != "deploy" ]; then
  echo "ERROR: unsupported mode: $mode" >&2
  exit 1
fi

if [ "$stack_exists" = true ]; then
  set +e
  update_output=$(aws cloudformation update-stack "${base_args[@]}" 2>&1)
  update_status=$?
  set -e

  if [ "$update_status" -ne 0 ]; then
    if grep -Fq "No updates are to be performed" <<<"$update_output"; then
      echo "$update_output"
      exit 0
    fi

    echo "$update_output" >&2
    exit "$update_status"
  fi

  aws cloudformation wait stack-update-complete --stack-name "$stack_name" --region "$region"
  aws cloudformation describe-stacks --stack-name "$stack_name" --region "$region" --query 'Stacks[0].StackStatus'
  exit 0
fi

aws cloudformation create-stack "${base_args[@]}"
aws cloudformation wait stack-create-complete --stack-name "$stack_name" --region "$region"
aws cloudformation describe-stacks --stack-name "$stack_name" --region "$region" --query 'Stacks[0].StackStatus'
