STACK_NAME ?= gitlab-runner
REGION     ?= ap-northeast-1
TEMPLATE   ?= gitlab-runner.yaml
PARAMS     ?= parameters.json
CHANGE_SET ?= $(STACK_NAME)-preview

IAM_STACK_NAME ?= gitlab-runner-iam
IAM_TEMPLATE   ?= gitlab-runner-iam.yaml
IAM_PARAMS     ?= parameters-iam.json

AWS        ?= aws
AWSFLAGS    = --region $(REGION) --no-cli-pager
BASH       ?= bash
POWERSHELL ?= powershell -NoProfile

.DEFAULT_GOAL := help

.PHONY: help validate deploy delete outputs session changeset \
        deploy-iam changeset-iam delete-iam outputs-iam validate-iam

help: ## Show this help
	@$(POWERSHELL) -Command "$$lines = Get-Content '$(firstword $(MAKEFILE_LIST))'; Write-Host 'Usage:'; Write-Host '  make <target>'; Write-Host ''; Write-Host 'Targets:'; foreach ($$line in $$lines) { if ($$line -match '^([a-zA-Z_-]+):.*##\s*(.+)$$') { '{0,-12} {1}' -f $$matches[1], $$matches[2] } }"

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
	$(BASH) scripts/session.sh $(STACK_NAME) $(REGION)

validate-iam: ## Validate the IAM CloudFormation template
	$(AWS) cloudformation validate-template \
		--template-body file://$(IAM_TEMPLATE) $(AWSFLAGS)

deploy-iam: $(IAM_PARAMS) ## Deploy or update the IAM stack (requires IAM permissions)
	$(BASH) -c "CFN_CAPABILITIES=CAPABILITY_IAM $(BASH) scripts/cfn-deploy.sh deploy $(IAM_STACK_NAME) $(REGION) $(IAM_TEMPLATE) $(IAM_PARAMS)"

changeset-iam: $(IAM_PARAMS) ## Create a change set for the IAM stack (dry-run)
	$(BASH) -c "CFN_CAPABILITIES=CAPABILITY_IAM $(BASH) scripts/cfn-deploy.sh changeset $(IAM_STACK_NAME) $(REGION) $(IAM_TEMPLATE) $(IAM_PARAMS) $(IAM_STACK_NAME)-preview"

delete-iam: ## Delete the IAM stack
	$(AWS) cloudformation delete-stack --stack-name $(IAM_STACK_NAME) $(AWSFLAGS)
	$(AWS) cloudformation wait stack-delete-complete --stack-name $(IAM_STACK_NAME) $(AWSFLAGS)

outputs-iam: ## Print IAM stack outputs (RunnerInstanceProfileArn etc.)
	$(AWS) cloudformation describe-stacks \
		--stack-name $(IAM_STACK_NAME) $(AWSFLAGS) \
		--query 'Stacks[0].Outputs' --output table

$(PARAMS):
	@echo "ERROR: $(PARAMS) not found. Copy parameters.sample.json to $(PARAMS) and edit it." >&2
	@exit 1

$(IAM_PARAMS):
	@echo "ERROR: $(IAM_PARAMS) not found. Copy parameters-iam.sample.json to $(IAM_PARAMS) and edit it." >&2
	@exit 1
