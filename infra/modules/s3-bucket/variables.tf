variable "bucket_name" {
  type        = string
  description = "Globally unique bucket name. Must start with <project>-app- for the pipeline to manage it."
}

variable "tags" {
  type    = map(string)
  default = {}
}
