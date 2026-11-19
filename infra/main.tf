module "app_bucket" {
  source = "./modules/s3-bucket"

  bucket_name = "myproj-app-data-new"

  tags = {
    Environment = "chaging"
  }
}

module "ec2" {
  source = "./modules/ec2"

  name          = "myproj-ec2"
  ami_id        = "ami-05295b6e6c790593e"
  instance_type = "t3.micro"

  tags = {
    Environment = "chaging"
  }
}