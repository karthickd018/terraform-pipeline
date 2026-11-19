module "ec2" {
  source = "./modules/ec2"

  name               = "dev-server"
  ami_id             = "ami-0f5ee92e2d63afc18"
  instance_type      = "t3.micro"
  subnet_id          = "subnet-xxxxxxxx"
  security_group_ids = ["sg-xxxxxxxx"]

  tags = {
    Environment = "Dev"
    Project     = "myproj"
  }
}