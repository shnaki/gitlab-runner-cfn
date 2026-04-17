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

tmp_params_file=
cleanup() {
  if [ -n "${tmp_params_file:-}" ] && [ -f "$tmp_params_file" ]; then
    rm -f "$tmp_params_file"
  fi
}
trap cleanup EXIT

param_value() {
  local key=$1
  jq -r --arg key "$key" '.[] | select(.ParameterKey == $key) | .ParameterValue' "$params_file" | head -n1
}

template_param_keys=$(aws cloudformation validate-template \
  --template-body "file://$template_file" \
  --region "$region" \
  --query 'Parameters[].ParameterKey' \
  --output json)

template_has_param() {
  local key=$1
  jq -e --arg key "$key" 'index($key) != null' <<<"$template_param_keys" >/dev/null
}

if template_has_param "RunnerStateVolumeAvailabilityZone"; then
  runner_state_volume_id=$(param_value "RunnerStateVolumeId")
  runner_state_volume_az=$(param_value "RunnerStateVolumeAvailabilityZone")
  subnet_id=$(param_value "SubnetId")

  if [ -z "$runner_state_volume_id" ] && [ -z "$runner_state_volume_az" ]; then
    if [ -z "$subnet_id" ]; then
      echo "ERROR: SubnetId parameter is required to derive RunnerStateVolumeAvailabilityZone" >&2
      exit 1
    fi

    runner_state_volume_az=$(aws ec2 describe-subnets \
      --subnet-ids "$subnet_id" \
      --region "$region" \
      --query 'Subnets[0].AvailabilityZone' \
      --output text)

    if [ -z "$runner_state_volume_az" ] || [ "$runner_state_volume_az" = "None" ]; then
      echo "ERROR: failed to resolve AvailabilityZone for subnet $subnet_id" >&2
      exit 1
    fi

    tmp_params_file=$(mktemp)
    jq --arg az "$runner_state_volume_az" '
      if any(.[]; .ParameterKey == "RunnerStateVolumeAvailabilityZone") then
        map(if .ParameterKey == "RunnerStateVolumeAvailabilityZone" then .ParameterValue = $az else . end)
      else
        . + [{ParameterKey: "RunnerStateVolumeAvailabilityZone", ParameterValue: $az}]
      end
    ' "$params_file" > "$tmp_params_file"
    params_file=$tmp_params_file
  fi
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
