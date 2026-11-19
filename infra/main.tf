module "app_bucket" {
  source = "./modules/s3-bucket"

  bucket_name = "myproj-app-data-new"

  tags = {
    Environment = "chaging"
  }
}
