# Backend blocks cannot use variables or locals, so type the real values here.
# The state bucket is created by hand once (see README, step 1).
terraform {
  backend "s3" {
    bucket       = "myproj-terraform-state" # EDIT: same as local.state_bucket in main.tf
    key          = "pipeline/terraform.tfstate"
    region       = "ap-south-1" # EDIT: same as local.region
    use_lockfile = true         # S3 lock file, stops two applies at the same time
  }
}
