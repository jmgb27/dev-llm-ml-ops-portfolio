# Cloudflare R2 bucket + scoped S3 credentials for LiteLLM audit log export (s3_v2 callback).
#
# Terraform API token needs:
#   - Workers R2 Storage → Edit   (create bucket)
#   - API Tokens → Edit           (create bucket-scoped S3 token)
#
# Permission group IDs are global Cloudflare constants (no lookup API call required).

locals {
  litellm_r2_read_permission_id  = var.litellm_r2_read_permission_group_id
  litellm_r2_write_permission_id = var.litellm_r2_write_permission_group_id
}

resource "cloudflare_r2_bucket" "litellm_audit_logs" {
  count = var.enable_litellm_r2_logs ? 1 : 0

  account_id = var.cloudflare_account_id
  name       = var.litellm_r2_bucket_name
  location   = var.litellm_r2_location
}

resource "cloudflare_api_token" "litellm_audit_logs" {
  count = var.enable_litellm_r2_logs ? 1 : 0

  name = "litellm-audit-logs-s3 (${var.litellm_r2_bucket_name})"

  policies = [{
    effect = "allow"
    permission_groups = [
      { id = local.litellm_r2_read_permission_id },
      { id = local.litellm_r2_write_permission_id },
    ]
    resources = jsonencode({
      "com.cloudflare.edge.r2.bucket.${var.cloudflare_account_id}_default_${cloudflare_r2_bucket.litellm_audit_logs[0].name}" = "*"
    })
  }]
}
