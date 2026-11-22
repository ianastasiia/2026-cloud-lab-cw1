# система архивирования

OpenAPI-спецификация, облачная функция и Terraform-конфигурация для Yandex Cloud.

```
openapi.yaml          # спецификация API-шлюза (OpenAPI 3.0)
function/             # функция архивирования (Python 3.12)
terraform/            # инфраструктура
```

## Развtртывание

```bash
export YC_TOKEN=$(yc iam create-token)
cd terraform
terraform init
terraform apply \
  -var cloud_id=<cloud_id> \
  -var folder_id=<folder_id> \
  -var bucket_name=vvot09-archives-<уникальный_суффикс>
```

Если нужен зеркальный реестр провайдеров, настройте `~/.terraformrc` (`provider_installation`).

## Проверка

```bash
API=$(terraform output -raw api_gateway_url)

# 1. создать задание (ожидается 202)
curl -i -X POST "$API/tasks" -H 'Content-Type: application/json' \
  -d '{"name":"dummy.pdf","url":"https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf"}'

# 2. некорректное задание (ожидается 400)
curl -i -X POST "$API/tasks" -H 'Content-Type: application/json' -d '{"name":"x.pdf"}'

# 3. список архивов (подождать ~10-20 с после шага 1)
curl -s "$API/archives"

# 4. информация об архиве и скачивание
curl -i "$API/archives/<key>"
curl -o result.zip "$API/download/<key>"

# 5. несуществующий ключ (ожидается 404)
curl -i "$API/archives/not-exists"
curl -i "$API/download/not-exists.zip"

# 6. ошибка в задании (недоступный URL) -> после неудачной попытки сообщение уходит в очередь необработанных
curl -i -X POST "$API/tasks" -H 'Content-Type: application/json' \
  -d '{"name":"bad.pdf","url":"https://invalid.example.invalid/bad.pdf"}'
```

Содержимое очереди необработанных заданий смотрите в консоли: Message Queue → `vvot09-tasks-dlq`.

## Удаление

```bash
terraform destroy -var cloud_id=<cloud_id> -var folder_id=<folder_id> -var bucket_name=<bucket_name>
```