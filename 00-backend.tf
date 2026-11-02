# S3 remote state. The bucket / key / region are supplied at init time by the
# namazu-cloud-addon-runner via `-backend-config=...` — the contract bijection
# fixes the key to tenants/<instances|sandboxes>/<tenant>/addon_<id>.tfstate
# where <id> is this repo's name suffix.

terraform {
  backend "s3" {
    encrypt = true
  }
}
