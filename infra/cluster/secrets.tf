resource "random_password" "root" {
  length  = 48
  special = false
}
resource "random_password" "app" {
  length  = 48
  special = false
}

resource "aws_secretsmanager_secret" "db" {
  name                    = var.secret_name
  recovery_window_in_days = 0 # delete immediately on destroy, so the name can be reused at once
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    MONGO_INITDB_ROOT_USERNAME = "appadmin"
    MONGO_INITDB_ROOT_PASSWORD = random_password.root.result
    MONGO_INITDB_DATABASE      = "appdb"
    MONGO_APP_USERNAME         = "appuser"
    MONGO_APP_PASSWORD         = random_password.app.result
  })
}
