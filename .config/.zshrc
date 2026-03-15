# Export SOPS AGE key from 1Password
function sops-age-key() {
  # Replace {VAULT_NAME} and {ITEM_NAME} with the actual vault and item name from 1Password
  export SOPS_AGE_KEY=$(op read "op://{VAULT_NAME}/{ITEM_NAME}/AGE/secret key")
}
