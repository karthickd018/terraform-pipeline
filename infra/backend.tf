terraform {
  backend "s3" {
    bucket       = "myproj-terraform-state" # EDIT: same as local.state_bucket in pipeline/main.tf
    key          = "infra/terraform.tfstate"
    region       = "ap-south-1" # EDIT
    use_lockfile = true
  }
}
