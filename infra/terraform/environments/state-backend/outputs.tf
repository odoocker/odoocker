output "bucket_name" {
  description = "Name of the state bucket. Use this in other envs' backend.hcl as `bucket = \"...\"`."
  value       = digitalocean_spaces_bucket.tf_state.name
}

output "bucket_endpoint" {
  description = "S3-compatible endpoint to use in other envs' backend.hcl as `endpoint = \"...\"`."
  value       = "https://${var.region}.digitaloceanspaces.com"
}

output "github_secrets_synced" {
  description = "Names of the GitHub Actions secrets this env wrote. Values are masked in tfstate (sensitive=true on the provider attributes) and not echoed here."
  value       = keys(local.gh_secrets)
}

output "spaces_key_name" {
  description = "Name of the Spaces access key, for cross-referencing in the DO Cloud Panel if you need to manually inspect or rotate."
  value       = digitalocean_spaces_key.tf_state_rw.name
}
