# main.yaml references its children by path; CloudFormation only accepts S3
# URLs for a nested TemplateURL, so CI packages before Git sync reads it.
PROJECT  ?= docket
REGION    = $(shell aws configure get region)
ACCOUNT   = $(shell aws sts get-caller-identity --query Account --output text 2>/dev/null)
BUCKET    = $(shell aws ssm get-parameter --name /$(PROJECT)/template-bucket \
              --query Parameter.Value --output text 2>/dev/null)
# Staging always overwrites the same prefix, so there is nothing to look up.
PREFIX    = latest
ARTIFACTS = $(PROJECT)-artifacts-$(ACCOUNT)-$(REGION)
VERSIONS  = --query '{Objects: (Versions||`[]`)[].{Key:Key,VersionId:VersionId} + (DeleteMarkers||`[]`)[].{Key:Key,VersionId:VersionId}}' --output json

.PHONY: lint package verify empty

# Sources only. *.yaml would sweep in main.packaged.yaml, and a stale
# artefact would then block the very target that regenerates it.
# bootstrap.yaml lives in Docket-bootstrap and is linted there.
lint:
	cfn-lint main.yaml templates/*.yaml

# Run before every push, then commit main.packaged.yaml alongside your
# change. Linting first keeps a broken template out of S3.
package: lint
	@test -n "$(BUCKET)" || (echo "no /$(PROJECT)/template-bucket found. wrong region, or bootstrap not deployed"; exit 1)
	aws cloudformation package \
	  --template-file main.yaml \
	  --s3-bucket "$(BUCKET)" \
	  --s3-prefix "$(PREFIX)" \
	  --output-template-file main.packaged.yaml

# CI runs this. Repackaging must be a no-op, or the committed file is stale.
verify: package
	@git diff --exit-code -- main.packaged.yaml \
	  || (echo "main.packaged.yaml is stale: run 'make package' and commit it"; exit 1)

# CloudFormation cannot empty a bucket, and will not delete one that still
# holds objects. That gap is the only part of teardown worth automating.
# Deleting the stacks is a decision, not a chore, so it stays yours.
#
# The artifact bucket is versioned, because a CodePipeline S3 source action
# requires that. `rm --recursive` only writes delete markers there, so the
# bucket stays non-empty and the stack delete stalls on it; the loop below
# drops every version and marker a page at a time.
empty:
	@test "$(CONFIRM)" = "$(PROJECT)" || (echo "refusing. run: make empty CONFIRM=$(PROJECT)"; exit 1)
	@test -n "$(ACCOUNT)" || (echo "cannot resolve the account. no credentials?"; exit 1)
	@test -n "$(BUCKET)" || (echo "cannot resolve the template bucket. wrong region?"; exit 1)
	-aws s3 rm "s3://$(ARTIFACTS)" --recursive
	aws s3 rm "s3://$(BUCKET)" --recursive
	@batch=$$(aws s3api list-object-versions --bucket "$(ARTIFACTS)" $(VERSIONS) 2>/dev/null); \
	while echo "$$batch" | grep -q '"Key"'; do \
	  aws s3api delete-objects --bucket "$(ARTIFACTS)" --delete "$$batch" >/dev/null; \
	  batch=$$(aws s3api list-object-versions --bucket "$(ARTIFACTS)" $(VERSIONS) 2>/dev/null); \
	done
	@echo "emptied. now delete $(PROJECT)-main, then $(PROJECT)-bootstrap"
