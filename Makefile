# Makefile for Argus-Watch Project
# Provides convenience targets for packaging, deployment, and cleanup.

.PHONY: all package deploy destroy clean

# Variables
CHECK_RDS_LAMBDA_DIR = src/check_rds_backups
CHECK_RDS_ZIP_FILE = check_rds_backups.zip
REMEDIATION_LAMBDA_DIR = src/remediation_handler
REMEDIATION_ZIP_FILE = remediation_handler.zip
POLICY_FILE = policies/remediation.rego

all: package

# Target: package
# Description: Packages both Lambda functions into zip files for deployment.
# This target creates a clean package directory, installs dependencies, copies
# source code into it, and then zips the contents from within that directory
# to ensure a flat structure required by AWS Lambda.
package: clean
	@echo "Packaging Lambda functions..."
	# Package check_rds_backups Lambda
	mkdir -p $(CHECK_RDS_LAMBDA_DIR)/package
	pip install --target $(CHECK_RDS_LAMBDA_DIR)/package -r $(CHECK_RDS_LAMBDA_DIR)/requirements.txt
	cp $(CHECK_RDS_LAMBDA_DIR)/app.py $(CHECK_RDS_LAMBDA_DIR)/package/
	cd $(CHECK_RDS_LAMBDA_DIR)/package && zip -r ../../../$(CHECK_RDS_ZIP_FILE) .

	# Package remediation_handler Lambda
	mkdir -p $(REMEDIATION_LAMBDA_DIR)/package
	pip install --target $(REMEDIATION_LAMBDA_DIR)/package -r $(REMEDIATION_LAMBDA_DIR)/requirements.txt
	cp $(REMEDIATION_LAMBDA_DIR)/app.py $(REMEDIATION_LAMBDA_DIR)/package/
	cp $(POLICY_FILE) $(REMEDIATION_LAMBDA_DIR)/package/remediation.rego
	cd $(REMEDIATION_LAMBDA_DIR)/package && zip -r ../../../$(REMEDIATION_ZIP_FILE) .
	@echo "Packaging complete."

# Target: deploy
# Description: Deploys the infrastructure using Terraform. Assumes 'package' has been run.
deploy: package
	@echo "Deploying infrastructure with Terraform..."
	cd terraform && terraform init && terraform apply -auto-approve
	@echo "Deployment complete."

# Target: destroy
# Description: Destroys the infrastructure using Terraform.
destroy:
	@echo "Destroying infrastructure with Terraform..."
	cd terraform && terraform destroy -auto-approve
	@echo "Destruction complete."

# Target: clean
# Description: Removes all build artifacts and Terraform state.
clean:
	@echo "Cleaning up build artifacts and Terraform state..."
	rm -f $(CHECK_RDS_ZIP_FILE) $(REMEDIATION_ZIP_FILE)
	rm -rf $(CHECK_RDS_LAMBDA_DIR)/package
	rm -rf $(REMEDIATION_LAMBDA_DIR)/package
	rm -rf .terraform* terraform/*.tfstate* terraform/.terraform
	@echo "Cleanup complete."
