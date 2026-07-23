terraform {
  required_version = ">= 1.10"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.40"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.2"
    }
  }

  # LOCAL backend on purpose. This module bootstraps the `grove-tf-state` bucket
  # that every OTHER env (bootstrap, sandbox, production) uses as its remote
  # backend. Storing this module's own state in that same bucket would be
  # circular, so we keep its state as a small local file.
  #
  # The state file is .gitignored. If lost: every resource here is also visible
  # in the DO Cloud Panel + GitHub Secrets UI; `terraform import` them back.
  backend "local" {}
}
