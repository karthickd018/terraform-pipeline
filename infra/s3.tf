data "aws_caller_identity" "current" {}

# The bucket name MUST start with <project>-app- (the apply role can only manage buckets with that prefix).
# Target it in the pipeline with: module.app_bucket
module "app_bucket" {
  source = "./modules/s3-bucket"

  bucket_name = "myproj-app-data-${data.aws_caller_identity.current.account_id}" # EDIT "myproj" to local.project

  tags = {
    Environment = "development"
  }
}
