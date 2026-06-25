locals {
  # Cloudflare provider rejects an empty api_token; use a placeholder when R2 is off.
  cloudflare_api_token = (
    var.cloudflare_api_token != null && var.cloudflare_api_token != ""
    ? var.cloudflare_api_token
    : "000000000000000000000000000000000000"
  )
}
