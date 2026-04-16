STACK_NAME ?= gitlab-runner
REGION     ?= ap-northeast-1
TEMPLATE   ?= gitlab-runner.yaml
PARAMS     ?= parameters.json
CHANGE_SET ?= $(STACK_NAME)-preview

AWS        ?= aws
AWSFLAGS    = --region $(REGION)
BASH       ?= bash

.DEFAULT_GOAL := help

.PHONY: help validate deploy delete outputs session changeset

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "Usage:\n  make \033[36m<target>\033[0m\n\nTargets:\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

validate: ## Validate the CloudFormation template
	$(AWS) cloudformation validate-template \
		--template-body file://$(TEMPLATE) $(AWSFLAGS)

deploy: $(PARAMS) ## Deploy or update the stack (uses parameters.json)
	$(BASH) scripts/cfn-deploy.sh deploy $(STACK_NAME) $(REGION) $(TEMPLATE) $(PARAMS)

changeset: $(PARAMS) ## Create a change set without executing (dry-run)
	$(BASH) scripts/cfn-deploy.sh changeset $(STACK_NAME) $(REGION) $(TEMPLATE) $(PARAMS) $(CHANGE_SET)

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
