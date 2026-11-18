locals {
  state_bkt_arn = "arn:aws:s3:::${local.state_bucket}"
  art_bkt_arn   = aws_s3_bucket.artifacts.arn

  # The buckets this pipeline is allowed to manage. They must be named myproj-app-<anything>.
  # The state bucket and the artifact bucket do NOT match this prefix, so the pipeline cannot touch them.
  managed_buckets_arn = "arn:aws:s3:::${local.project}-app-*"

  state_key = "${local.state_bkt_arn}/infra/terraform.tfstate"
  lock_key  = "${local.state_bkt_arn}/infra/terraform.tfstate.tflock"

  # Read-only calls Terraform makes to refresh what it manages. Plan and apply both need them.
  # When you add a new resource type to infra/, add its Get/Describe/List actions here.
  read_statement = {
    Sid      = "ReadBucketsForRefresh"
    Effect   = "Allow"
    Action   = ["s3:Get*", "s3:List*"]
    Resource = [local.managed_buckets_arn, "${local.managed_buckets_arn}/*"]
  }

  list_all_buckets = {
    Sid      = "ListBuckets"
    Effect   = "Allow"
    Action   = ["s3:ListAllMyBuckets"]
    Resource = "*"
  }

  state_list = {
    Sid      = "StateBucketList"
    Effect   = "Allow"
    Action   = ["s3:ListBucket"]
    Resource = local.state_bkt_arn
  }

  # The lock file is written and removed on every plan and apply.
  state_lock = {
    Sid      = "StateLockFile"
    Effect   = "Allow"
    Action   = ["s3:PutObject", "s3:DeleteObject"]
    Resource = local.lock_key
  }

  artifact_files = {
    Sid      = "PipelineArtifactFiles"
    Effect   = "Allow"
    Action   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"]
    Resource = "${local.art_bkt_arn}/*"
  }

  artifact_bucket_info = {
    Sid      = "ArtifactBucketInfo"
    Effect   = "Allow"
    Action   = ["s3:GetBucketAcl", "s3:GetBucketLocation", "s3:ListBucket"]
    Resource = local.art_bkt_arn
  }

  build_logs = {
    Sid      = "OwnBuildLogs"
    Effect   = "Allow"
    Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    Resource = "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/codebuild/${local.project}_terraform*"
  }
}

# ---------------- CodePipeline role: starts the builds, nothing else ----------------

resource "aws_iam_role" "pipeline" {
  name = "${local.project}_terraform_pipeline_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codepipeline.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "pipeline" {
  name = "run-the-terraform-pipeline"
  role = aws_iam_role.pipeline.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ArtifactFiles"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"]
        Resource = "${local.art_bkt_arn}/*"
      },
      {
        Sid      = "ArtifactBucketInfo"
        Effect   = "Allow"
        Action   = ["s3:GetBucketLocation", "s3:GetBucketVersioning"]
        Resource = local.art_bkt_arn
      },
      {
        Sid      = "StartOurTwoBuilds"
        Effect   = "Allow"
        Action   = ["codebuild:StartBuild", "codebuild:BatchGetBuilds"]
        Resource = [aws_codebuild_project.plan.arn, aws_codebuild_project.apply.arn]
      },
      {
        Sid      = "UseTheGitHubConnection"
        Effect   = "Allow"
        Action   = ["codeconnections:UseConnection", "codestar-connections:UseConnection"]
        Resource = aws_codestarconnections_connection.github.arn
      }
    ]
  })
}

# ---------------- CodeBuild plan role: read only ----------------

resource "aws_iam_role" "codebuild_plan" {
  name = "${local.project}_terraform_plan_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "codebuild_plan" {
  name = "terraform-plan-read-only"
  role = aws_iam_role.codebuild_plan.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadState"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = local.state_key
      },
      local.state_list,
      local.state_lock,
      local.artifact_files,
      local.artifact_bucket_info,
      local.build_logs,
      local.list_all_buckets,
      local.read_statement
    ]
  })
}

# ---------------- CodeBuild apply role: can change only what infra/ manages ----------------

resource "aws_iam_role" "codebuild_apply" {
  name = "${local.project}_terraform_apply_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "codebuild_apply_base" {
  name = "terraform-apply-base"
  role = aws_iam_role.codebuild_apply.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "StateReadWrite"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = local.state_key
      },
      local.state_list,
      local.state_lock,
      local.artifact_files,
      local.artifact_bucket_info,
      local.build_logs,
      local.list_all_buckets,
      local.read_statement
    ]
  })
}

# When infra/ starts to manage a new kind of resource, the first run fails with AccessDenied.
# Read the denied action in the build log and add it here, scoped to the names the pipeline may touch.
resource "aws_iam_role_policy" "codebuild_apply_write" {
  name = "terraform-apply-write-only-what-infra-manages"
  role = aws_iam_role.codebuild_apply.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ManageAppBuckets"
        Effect = "Allow"
        Action = [
          "s3:CreateBucket", "s3:DeleteBucket", "s3:PutBucket*", "s3:DeleteBucket*",
          "s3:PutEncryptionConfiguration", "s3:PutLifecycleConfiguration",
          "s3:PutAccelerateConfiguration", "s3:PutReplicationConfiguration"
        ]
        Resource = local.managed_buckets_arn
      }
    ]
  })
}
