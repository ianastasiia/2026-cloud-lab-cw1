terraform {
  required_version = ">= 1.3"

  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }
    # Документные таблицы YDB создаются через DynamoDB-совместимый Document API
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source = "hashicorp/archive"
    }
  }
}

locals {
  prefix     = "vvot09-"
  table_name = "archives"
}

# Аутентификация: IAM-токен из переменной окружения YC_TOKEN
provider "yandex" {
  cloud_id  = var.cloud_id
  folder_id = var.folder_id
  zone      = "ru-central1-a"
}

provider "aws" {
  region     = "ru-central1"
  access_key = yandex_iam_service_account_static_access_key.provisioner.access_key
  secret_key = yandex_iam_service_account_static_access_key.provisioner.secret_key

  endpoints {
    dynamodb = yandex_ydb_database_serverless.db.document_api_endpoint
  }

  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_requesting_account_id  = true
}

# ---------------------------------------------------------------------------
# Сервисные аккаунты, статические ключи и роли
# ---------------------------------------------------------------------------

# Используется самим Terraform для создания бакета, очередей и документной таблицы
resource "yandex_iam_service_account" "provisioner" {
  name = "${local.prefix}provisioner-sa"
}

resource "yandex_iam_service_account" "function" {
  name = "${local.prefix}function-sa"
}

resource "yandex_iam_service_account" "trigger" {
  name = "${local.prefix}trigger-sa"
}

resource "yandex_iam_service_account" "gateway" {
  name = "${local.prefix}gateway-sa"
}

resource "yandex_iam_service_account_static_access_key" "provisioner" {
  service_account_id = yandex_iam_service_account.provisioner.id
}

resource "yandex_iam_service_account_static_access_key" "function" {
  service_account_id = yandex_iam_service_account.function.id
}

locals {
  roles = {
    provisioner_storage_admin = { sa = yandex_iam_service_account.provisioner.id, role = "storage.admin" }
    provisioner_ymq_admin     = { sa = yandex_iam_service_account.provisioner.id, role = "ymq.admin" }
    provisioner_ydb_editor    = { sa = yandex_iam_service_account.provisioner.id, role = "ydb.editor" }

    function_storage_uploader = { sa = yandex_iam_service_account.function.id, role = "storage.uploader" }
    function_ydb_editor       = { sa = yandex_iam_service_account.function.id, role = "ydb.editor" }

    trigger_ymq_reader        = { sa = yandex_iam_service_account.trigger.id, role = "ymq.reader" }
    trigger_function_invoker  = { sa = yandex_iam_service_account.trigger.id, role = "functions.functionInvoker" }

    gateway_ymq_writer     = { sa = yandex_iam_service_account.gateway.id, role = "ymq.writer" }
    gateway_ydb_viewer     = { sa = yandex_iam_service_account.gateway.id, role = "ydb.viewer" }
    gateway_storage_viewer = { sa = yandex_iam_service_account.gateway.id, role = "storage.viewer" }
  }
}

resource "yandex_resourcemanager_folder_iam_member" "roles" {
  for_each = local.roles

  folder_id = var.folder_id
  role      = each.value.role
  member    = "serviceAccount:${each.value.sa}"
}

# ---------------------------------------------------------------------------
# Object Storage (хранилище файлов)
# ---------------------------------------------------------------------------

resource "yandex_storage_bucket" "files" {
  bucket     = var.bucket_name
  access_key = yandex_iam_service_account_static_access_key.provisioner.access_key
  secret_key = yandex_iam_service_account_static_access_key.provisioner.secret_key

  max_size      = 10 * 1024 * 1024 * 1024 # 10 ГБ
  force_destroy = true                    # чтобы terraform destroy удалял бакет с архивами
  # Доступ с авторизацией: публичный доступ не настраивается (по умолчанию приватный)

  depends_on = [yandex_resourcemanager_folder_iam_member.roles]
}

# ---------------------------------------------------------------------------
# Message Queue
# ---------------------------------------------------------------------------

resource "yandex_message_queue" "dead_letter" {
  name                       = "${local.prefix}tasks-dlq"
  message_retention_seconds  = 14 * 24 * 60 * 60 # 14 суток
  access_key                 = yandex_iam_service_account_static_access_key.provisioner.access_key
  secret_key                 = yandex_iam_service_account_static_access_key.provisioner.secret_key

  depends_on = [yandex_resourcemanager_folder_iam_member.roles]
}

resource "yandex_message_queue" "tasks" {
  name                       = "${local.prefix}tasks"
  visibility_timeout_seconds = 900
  receive_wait_time_seconds  = 20
  message_retention_seconds  = 24 * 60 * 60 # 1 сутки
  access_key                 = yandex_iam_service_account_static_access_key.provisioner.access_key
  secret_key                 = yandex_iam_service_account_static_access_key.provisioner.secret_key

  # перенос в очередь необработанных заданий после 1-й неудачной попытки
  redrive_policy = jsonencode({
    deadLetterTargetArn = yandex_message_queue.dead_letter.arn
    maxReceiveCount     = 1
  })

  depends_on = [yandex_resourcemanager_folder_iam_member.roles]
}

# ---------------------------------------------------------------------------
# YDB (Serverless, OLTP) и документная таблица archives
# ---------------------------------------------------------------------------

resource "yandex_ydb_database_serverless" "db" {
  name      = "${local.prefix}db"
  folder_id = var.folder_id

  serverless_database {
    enable_throttling_rcu_limit = true
    throttling_rcu_limit        = 10 # 10 RU/с
    storage_size_limit          = 1  # 1 ГБ
  }
}

resource "aws_dynamodb_table" "archives" {
  name         = local.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "key"

  attribute {
    name = "key"
    type = "S"
  }

  depends_on = [yandex_resourcemanager_folder_iam_member.roles]
}

# ---------------------------------------------------------------------------
# Cloud Functions (функция архивирования) и триггер
# ---------------------------------------------------------------------------

data "archive_file" "function" {
  type        = "zip"
  source_dir  = "${path.module}/../function"
  output_path = "${path.module}/function.zip"
  excludes    = ["__pycache__"]
}

resource "yandex_function" "archiver" {
  name               = "${local.prefix}archiver"
  user_hash          = data.archive_file.function.output_base64sha256
  runtime            = "python312"
  entrypoint         = "index.handler"
  memory             = 256
  execution_timeout  = 600
  service_account_id = yandex_iam_service_account.function.id

  environment = {
    BUCKET_NAME           = yandex_storage_bucket.files.bucket
    TABLE_NAME            = local.table_name
    DOCAPI_ENDPOINT       = yandex_ydb_database_serverless.db.document_api_endpoint
    AWS_ACCESS_KEY_ID     = yandex_iam_service_account_static_access_key.function.access_key
    AWS_SECRET_ACCESS_KEY = yandex_iam_service_account_static_access_key.function.secret_key
  }

  content {
    zip_filename = data.archive_file.function.output_path
  }

  depends_on = [
    yandex_resourcemanager_folder_iam_member.roles,
    aws_dynamodb_table.archives,
  ]
}

resource "yandex_function_trigger" "tasks" {
  name = "${local.prefix}tasks-trigger"

  function {
    id                 = yandex_function.archiver.id
    service_account_id = yandex_iam_service_account.trigger.id
  }

  message_queue {
    queue_id           = yandex_message_queue.tasks.arn
    service_account_id = yandex_iam_service_account.trigger.id
    batch_size         = "1"
    batch_cutoff       = "0"
  }

  depends_on = [yandex_resourcemanager_folder_iam_member.roles]
}

# ---------------------------------------------------------------------------
# API Gateway
# ---------------------------------------------------------------------------

resource "yandex_api_gateway" "gateway" {
  name      = "${local.prefix}api-gateway"
  folder_id = var.folder_id

  spec = templatefile("${path.module}/../openapi.yaml", {
    service_account_id = yandex_iam_service_account.gateway.id
    folder_id          = var.folder_id
    queue_url          = yandex_message_queue.tasks.id
    database           = yandex_ydb_database_serverless.db.database_path
    bucket             = yandex_storage_bucket.files.bucket
  })

  depends_on = [
    yandex_resourcemanager_folder_iam_member.roles,
    aws_dynamodb_table.archives,
  ]
}