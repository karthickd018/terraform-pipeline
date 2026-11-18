# Terraform pipeline with targeted apply (template)

An AWS pipeline that makes changes to an account for you.
You push Terraform code to GitHub. The pipeline shows what will change. A person approves it. Then the pipeline applies it.

```
Source  ->  Plan  ->  Approve  ->  Apply
GitHub      preview   a person    makes the
code        of the    says yes    change
            change
```

**Targeted apply only.** Every run must name what to change (`TF_TARGETS`). A plan with no target stops with an error.
There is no push trigger: a run is started by hand with **Release change**.

## What is in this folder

| Path | What it is |
|---|---|
| `pipeline/` | The pipeline itself (CodePipeline, 2 CodeBuild projects, IAM roles, artifact bucket, GitHub connection) |
| `infra/` | The code the pipeline applies. It has one example: an S3 bucket module, `module.app_bucket` |
| `pipeline/buildspec-plan.yml`, `buildspec-apply.yml` | The commands each build runs (read from the repo on every run) |

Put both folders at the root of your Git repo (so the paths `pipeline/...` and `infra/...` exist).
The pipeline has its own state (`pipeline/terraform.tfstate`). What it applies has another (`infra/terraform.tfstate`).

## Setup, step by step (one time)

You need: an AWS account, AWS CLI, Terraform 1.10 or newer, a GitHub repo, and permission to create IAM roles in the account.

**1. Log in, and check you are in the right account**
```
aws login            # or: aws sso login --profile <profile>
aws sts get-caller-identity
```

**2. Create the state bucket by hand** (the pipeline cannot create its own state bucket)
```
aws s3api create-bucket --bucket myproj-terraform-state --region ap-south-1 \
  --create-bucket-configuration LocationConstraint=ap-south-1
aws s3api put-bucket-versioning --bucket myproj-terraform-state --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket myproj-terraform-state --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-encryption --bucket myproj-terraform-state --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
```

**3. Edit the names** (search for `EDIT` in the files)
- `pipeline/main.tf`: the `locals` block (`project`, `region`, `source_repo`, `source_branch`, `state_bucket`).
- `pipeline/backend.tf` and `infra/backend.tf`: the state bucket and region (backend blocks cannot use locals).
- `infra/versions.tf`: the region.
- `infra/s3.tf`: change `myproj` in the bucket name to your `project`. **Bucket names must start with `<project>-app-`**, because the apply role can only manage buckets with that prefix.

**4. Create the pipeline from your laptop** (the first time, nothing else can)
```
cd pipeline
terraform init
terraform plan -out=pipeline.tfplan     # read it: roles, 2 CodeBuild projects, pipeline, buckets, connection
terraform apply pipeline.tfplan
rm pipeline.tfplan                      # plan files can hold secrets
```

**5. Authorize the GitHub connection** (once, in the console)
Console, then **Developer Tools**, then **Settings**, then **Connections**. Open `<project>-github` (status **Pending**), click **Update pending connection**, and sign in to GitHub. The status becomes **Available**.

**6. Push the code to the branch you set in `source_branch`** (both `pipeline/` and `infra/`). The buildspecs are read from the repo, so they must be pushed before the first run.

## How to make a change (every time)

1. Change the files in `infra/` and push them to the branch.
2. Console, then **CodePipeline**, then `<project>_terraform_pipeline`, then **Release change**.
3. Set the variable `TF_TARGETS` to what you want to change, for example:
   - `module.app_bucket` (the whole module)
   - `module.app_bucket.aws_s3_bucket_versioning.this` (one resource)
   - `module.a,module.b` (several; commas, **no spaces**)
4. Wait for the **Approve** stage to say it is waiting. Click **Review**, open the link, and read the plan.
   Look at the last line: `Plan: X to add, Y to change, Z to destroy.`
   - It is what you expect: click **Approve**.
   - It is not: click **Reject**, and find out why.
5. **Apply** runs. When it is green, the change is done.
6. Check: `cd infra && terraform plan` should say there is nothing left to change for what you targeted.

### What to type in TF_TARGETS
It is the **address**, not the folder. Use the name from the `module "..."` line: `module.app_bucket`.
Not `./modules/s3-bucket` and not `infra/modules/...`.

## If something goes wrong

| What you see | What to do |
|---|---|
| `TF_TARGETS is empty...` in Plan | Release change again and set `TF_TARGETS`. |
| `Invalid target address` | Use letters, digits and `_ . [ ] " -` only, no spaces. |
| Plan or Apply fails with `AccessDenied` | Open the CodeBuild log and find the denied action. Add it to the right role in `pipeline/iam.tf` (see below), then apply `pipeline/` from your laptop again. |
| Approve fails: "variables could not be resolved" | The plan buildspec must export `CODEBUILD_BUILD_ID`, and the Plan action must have `namespace = "PlanNs"` (both are already set). |
| Apply fails: "saved plan is stale" | The state changed after the plan was made. Run the pipeline again. |
| Source fails | Check that the connection is **Available** (step 5). |
| Apply fails: a file is missing | A module built a file during the plan (for example a Lambda zip). Add it to `artifacts.files` in `buildspec-plan.yml` and copy it back in `buildspec-apply.yml`. |

## Adding a new kind of resource (the permissions loop)

The apply role is limited on purpose. It can only manage S3 buckets named `<project>-app-*`.
When you add something else (a queue, a Lambda, ...):
1. Write the code in `infra/` and push it.
2. Run the pipeline targeted at it. The first run fails with `AccessDenied`. Copy the action name from the log.
3. In `pipeline/iam.tf`, add the **read** actions to `read_statement` and the **write** actions to `codebuild_apply_write`, scoped to the names the pipeline may touch (not `*`).
4. Apply `pipeline/` from the laptop (step 4), then run the pipeline again.
Plan and apply both need the read actions, so that Terraform can refresh what it manages.

## Safety notes

- The plan role is read only. The apply role can only create or change what `iam.tf` allows.
- The state bucket and the artifact bucket do not match `<project>-app-*`, so the pipeline cannot touch them.
- A person must click **Approve**. Anyone with access to the pipeline can approve, so read the plan, do not click blindly.
- The plan file can contain secrets. The artifact bucket deletes files after 30 days. Never paste a whole plan into a chat or a ticket.
- Do not apply from a laptop while a pipeline run is going. The S3 lock file (`use_lockfile`) blocks two applies at once, but it will make one of them fail.
- Targeted runs ignore everything else. A full `terraform plan` can still show other changes. That is normal.

## To allow a full plan again (not recommended here)

1. In `pipeline/buildspec-plan.yml`, remove the `if [ -z "$TF_TARGETS" ] ...` block, and run `terraform plan` without `TARGET_ARGS` when there are no targets (our own pipeline does this).
2. Optional: add a `trigger` block to `aws_codepipeline.this` so that a push to `infra/**` starts a plan.

## Tested and not tested

- `terraform validate` and `terraform fmt` pass on `pipeline/` and `infra/`, both buildspec files parse as YAML, and the target check was run with sample inputs.
- **Not tested:** a real apply in an AWS account. Expect to hit one or two `AccessDenied` messages on the first run and to add the action names in `iam.tf`.
