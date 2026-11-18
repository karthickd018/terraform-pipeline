data "aws_caller_identity" "current" {}

locals {
  # ============ EDIT THESE ============
  project           = "myproj" # short, lowercase, letters and digits. Used in every name.
  region            = "ap-south-1"
  source_repo       = "my-org/my-repo" # GitHub "owner/repo"
  source_branch     = "main"
  state_bucket      = "myproj-terraform-state" # created by hand (README step 1)
  terraform_version = "1.10.5"                 # the version CodeBuild installs
  # ====================================

  account_id    = data.aws_caller_identity.current.account_id
  pipeline_name = "${local.project}_terraform_pipeline"
}

# ---------------- Artifact bucket: the plan file travels from Plan to Apply through it ----------------

resource "aws_s3_bucket" "artifacts" {
  bucket = "${local.project}-pipeline-artifacts-${local.account_id}"
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Plan files can hold secrets, so do not keep them for long.
resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    id     = "expire-old-artifacts"
    status = "Enabled"
    filter {}
    expiration {
      days = 30
    }
  }
}

# ---------------- GitHub connection ----------------
# It is created in the PENDING state. Someone must authorize it once in the console (README step 4).

resource "aws_codestarconnections_connection" "github" {
  name          = "${local.project}-github"
  provider_type = "GitHub"
}

# ---------------- CodeBuild: one project to plan, one to apply ----------------

resource "aws_codebuild_project" "plan" {
  name          = "${local.project}_terraform_plan"
  service_role  = aws_iam_role.codebuild_plan.arn
  build_timeout = 30

  source {
    type      = "CODEPIPELINE"
    buildspec = "pipeline/buildspec-plan.yml"
  }

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    type            = "ARM_CONTAINER"
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/amazonlinux-aarch64-standard:3.0"
    privileged_mode = false

    environment_variable {
      name  = "TF_VERSION"
      value = local.terraform_version
    }
  }

  logs_config {
    cloudwatch_logs {
      status = "ENABLED"
    }
  }
}

resource "aws_codebuild_project" "apply" {
  name          = "${local.project}_terraform_apply"
  service_role  = aws_iam_role.codebuild_apply.arn
  build_timeout = 60

  source {
    type      = "CODEPIPELINE"
    buildspec = "pipeline/buildspec-apply.yml"
  }

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    type            = "ARM_CONTAINER"
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/amazonlinux-aarch64-standard:3.0"
    privileged_mode = false

    environment_variable {
      name  = "TF_VERSION"
      value = local.terraform_version
    }
  }

  logs_config {
    cloudwatch_logs {
      status = "ENABLED"
    }
  }
}

# ---------------- The pipeline: Source > Plan > Approve > Apply ----------------
# There is no push trigger on purpose. A run is started by hand with "Release change", and TF_TARGETS
# must be set, because the plan stage refuses to run without a target.

resource "aws_codepipeline" "this" {
  name           = local.pipeline_name
  role_arn       = aws_iam_role.pipeline.arn
  pipeline_type  = "V2"
  execution_mode = "QUEUED"

  artifact_store {
    type     = "S3"
    location = aws_s3_bucket.artifacts.bucket
  }

  variable {
    name          = "TF_TARGETS"
    default_value = "none"
    description   = "Required. Comma-separated Terraform addresses to plan and apply, for example module.app_bucket"
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["SourceArtifact"]

      configuration = {
        ConnectionArn        = aws_codestarconnections_connection.github.arn
        FullRepositoryId     = local.source_repo
        BranchName           = local.source_branch
        DetectChanges        = "false"
        OutputArtifactFormat = "CODE_ZIP"
      }
    }
  }

  stage {
    name = "Plan"

    action {
      name             = "Plan"
      namespace        = "PlanNs" # the Approve link below needs this name
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["SourceArtifact"]
      output_artifacts = ["PlanArtifact"]

      configuration = {
        ProjectName          = aws_codebuild_project.plan.name
        EnvironmentVariables = jsonencode([{ name = "TF_TARGETS", value = "#{variables.TF_TARGETS}", type = "PLAINTEXT" }])
      }
    }
  }

  stage {
    name = "Approve"

    action {
      name     = "Approve"
      category = "Approval"
      owner    = "AWS"
      provider = "Manual"
      version  = "1"

      configuration = {
        CustomData         = "Targets: #{variables.TF_TARGETS}. Open the link and read the plan output. Approve only if it matches what you expect."
        ExternalEntityLink = "https://${local.region}.console.aws.amazon.com/codesuite/codebuild/${local.account_id}/projects/${aws_codebuild_project.plan.name}/build/#{PlanNs.CODEBUILD_BUILD_ID}/?region=${local.region}"
      }
    }
  }

  stage {
    name = "Apply"

    action {
      name            = "Apply"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["SourceArtifact", "PlanArtifact"]

      configuration = {
        ProjectName   = aws_codebuild_project.apply.name
        PrimarySource = "SourceArtifact"
      }
    }
  }
}
