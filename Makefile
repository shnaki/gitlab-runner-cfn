STACK_NAME ?= gitlab-runner
REGION     ?= ap-northeast-1
TEMPLATE   ?= gitlab-runner.yaml
PARAMS     ?= parameters.json

AWS        ?= aws
AWSFLAGS    = --region $(REGION)

.DEFAULT_GOAL := help

.PHONY: help validate deploy delete outputs session changeset

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "Usage:\n  make \033[36m<target>\033[0m\n\nTargets:\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

validate: ## Validate the CloudFormation template
	$(AWS) cloudformation validate-template \
		--template-body file://$(TEMPLATE) $(AWSFLAGS)

deploy: $(PARAMS) ## Deploy or update the stack (uses parameters.json)
	$(AWS) cloudformation deploy \
		--stack-name $(STACK_NAME) \
		--template-file $(TEMPLATE) \
		--capabilities CAPABILITY_IAM \
		--parameter-overrides $$(jq -r '.[] | "\(.ParameterKey)=\(.ParameterValue)"' $(PARAMS)) \
		$(AWSFLAGS)

changeset: $(PARAMS) ## Create a change set without executing (dry-run)
	$(AWS) cloudformation deploy \
		--stack-name $(STACK_NAME) \
		--template-file $(TEMPLATE) \
		--capabilities CAPABILITY_IAM \
		--no-execute-changeset \
		--parameter-overrides $$(jq -r '.[] | "\(.ParameterKey)=\(.ParameterValue)"' $(PARAMS)) \
		$(AWSFLAGS)

delete: ## Delete the stack and wait for completion
	$(AWS) cloudformation delete-stack --stack-name $(STACK_NAME) $(AWSFLAGS)
	$(AWS) cloudformation wait stack-delete-complete --stack-name $(STACK_NAME) $(AWSFLAGS)

outputs: ## Print stack outputs
	$(AWS) cloudformation describe-stacks \
		--stack-name $(STACK_NAME) $(AWSFLAGS) \
		--query 'Stacks[0].Outputs' --output table

session: ## Open SSM Session Manager to the runner instance
	@INSTANCE_ID=$$($(AWS) cloudformation describe-stacks \
		--stack-name $(STACK_NAME) $(AWSFLAGS) \
		--query 'Stacks[0].Outputs[?OutputKey==`InstanceId`].OutputValue' --output text); \
	echo "Connecting to $$INSTANCE_ID..."; \
	$(AWS) ssm start-session --target $$INSTANCE_ID $(AWSFLAGS)

$(PARAMS):
	@echo "ERROR: $(PARAMS) not found. Copy parameters.sample.json to $(PARAMS) and edit it." >&2
	@exit 1
