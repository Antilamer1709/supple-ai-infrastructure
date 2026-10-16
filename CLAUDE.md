# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

This repository holds the Terraform infrastructure for Supple AI. It is currently a scaffold with no Terraform code yet: only `README.md` and a Terraform `.gitignore`. Once modules, environments, a backend, or CI exist, update this file with the real layout and commands.

## Conventions implied by `.gitignore`

- **No state in git.** `*.tfstate` and `.terraform/` are ignored, so state is expected to live in a remote backend. None is configured yet.
- **No `*.tfvars` in git.** Variable values, including secrets, come from local files or the environment. A file like `terraform.tfvars.example` doesn't match the ignore pattern, so it can be committed as a template.
- **No `override.tf` / `*_override.tf` in git.** These are for local-only overrides.
- **`.terraform.lock.hcl` is not ignored.** Commit it so provider versions stay pinned.

## AWS target

- Default region: `eu-north-1`.
- Local AWS access goes through the `aws-mcp` server using the AWS profile `healthytech`. Use the aws-mcp tools instead of running the AWS CLI through Bash.

## Commands

Standard Terraform workflow, run from the directory that holds the root module:

```sh
terraform init          # install providers and configure the backend
terraform fmt -recursive
terraform validate
terraform plan
terraform apply
```
