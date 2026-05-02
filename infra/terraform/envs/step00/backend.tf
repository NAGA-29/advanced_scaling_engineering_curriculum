# -----------------------------------------------------------------------
# Terraform Backend Configuration
#
# For local learning, the default local backend is used — no configuration
# needed. State is stored in terraform.tfstate in this directory.
#
# For team use or when you want remote state, uncomment the block below
# and fill in your S3 bucket and DynamoDB table details:
#
# terraform {
#   backend "s3" {
#     bucket         = "my-terraform-state-bucket"   # must already exist
#     key            = "advanced-scaling/step00/terraform.tfstate"
#     region         = "ap-northeast-1"
#     encrypt        = true
#     dynamodb_table = "terraform-state-lock"        # for state locking
#   }
# }
#
# To create the S3 bucket + DynamoDB table you can use:
#   aws s3api create-bucket --bucket my-terraform-state-bucket --region ap-northeast-1 \
#     --create-bucket-configuration LocationConstraint=ap-northeast-1
#   aws s3api put-bucket-versioning --bucket my-terraform-state-bucket \
#     --versioning-configuration Status=Enabled
#   aws dynamodb create-table --table-name terraform-state-lock \
#     --attribute-definitions AttributeName=LockID,AttributeType=S \
#     --key-schema AttributeName=LockID,KeyType=HASH \
#     --billing-mode PAY_PER_REQUEST --region ap-northeast-1
# -----------------------------------------------------------------------
