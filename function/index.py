"""Функция архивировани

Вызывается триггером очереди заданий (1 сообщение за вызов):
  1. разбирает задание {"name": ..., "url": ...};
  2. генерирует ключ <uuid_v7>.zip;
  3. скачивает файл по URL и упаковывает его в ZIP (в памяти);
  4. сохраняет архив в Object Storage (REST + AWS SigV4, без внешних зависимостей);
  5. добавляет запись {key, name, url} в документную таблицу YDB.

При любой ошибке исключение пробрасывается наружу: функция завершается с ошибкой,
и сообщение переносится в очередь необработанных заданий.
"""
import datetime
import hashlib
import hmac
import io
import json
import logging
import os
import time
import uuid
import zipfile
from urllib.error import HTTPError
from urllib.parse import quote, urlparse
from urllib.request import Request, urlopen

logger = logging.getLogger()
logger.setLevel(logging.INFO)

BUCKET = os.environ["BUCKET_NAME"]
TABLE_NAME = os.environ.get("TABLE_NAME", "archives")
DOCAPI_ENDPOINT = os.environ["DOCAPI_ENDPOINT"].rstrip("/")
S3_ENDPOINT = os.environ.get("S3_ENDPOINT", "https://storage.yandexcloud.net")
REGION = "ru-central1"

ACCESS_KEY = os.environ["AWS_ACCESS_KEY_ID"]
SECRET_KEY = os.environ["AWS_SECRET_ACCESS_KEY"]

DOWNLOAD_TIMEOUT = 60  # секунд
MAX_FILE_SIZE = 50 * 1024 * 1024  # 50 МБ: запас по памяти функции (256 МБ)


# --- AWS Signature V4 (только стандартная библиотека, без boto3) -----------------------

def _hmac(key: bytes, msg: str) -> bytes:
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def sigv4_headers(method, url, service, body=b"", extra_headers=None, now=None):
    """Возвращает заголовки запроса с подписью AWS Signature V4."""
    parsed = urlparse(url)
    now = now or datetime.datetime.now(datetime.timezone.utc)
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    date_stamp = now.strftime("%Y%m%d")
    payload_hash = hashlib.sha256(body).hexdigest()

    headers = {k.lower(): v.strip() for k, v in (extra_headers or {}).items()}
    headers["host"] = parsed.netloc
    headers["x-amz-date"] = amz_date
    headers["x-amz-content-sha256"] = payload_hash

    signed_names = sorted(headers)
    canonical_headers = "".join(f"{name}:{headers[name]}\n" for name in signed_names)
    signed_headers = ";".join(signed_names)
    canonical_request = "\n".join([
        method,
        quote(parsed.path or "/", safe="/-_.~"),
        parsed.query,
        canonical_headers,
        signed_headers,
        payload_hash,
    ])

    scope = f"{date_stamp}/{REGION}/{service}/aws4_request"
    string_to_sign = "\n".join([
        "AWS4-HMAC-SHA256",
        amz_date,
        scope,
        hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
    ])
    signing_key = _hmac(_hmac(_hmac(_hmac(
        ("AWS4" + SECRET_KEY).encode("utf-8"), date_stamp), REGION), service), "aws4_request")
    signature = hmac.new(signing_key, string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()

    headers["authorization"] = (
        f"AWS4-HMAC-SHA256 Credential={ACCESS_KEY}/{scope}, "
        f"SignedHeaders={signed_headers}, Signature={signature}"
    )
    return headers


def signed_request(method, url, service, body=b"", extra_headers=None):
    headers = sigv4_headers(method, url, service, body, extra_headers)
    request = Request(url, data=body or None, method=method, headers=headers)
    try:
        with urlopen(request, timeout=DOWNLOAD_TIMEOUT) as response:
            return response.read()
    except HTTPError as error:
        details = error.read().decode("utf-8", "replace")[:500]
        raise RuntimeError(f"{method} {url} -> {error.code}: {details}") from error


def put_object(key: str, data: bytes) -> None:
    url = f"{S3_ENDPOINT}/{BUCKET}/{quote(key, safe='')}"
    signed_request("PUT", url, "s3", data, {"Content-Type": "application/zip"})


def delete_object(key: str) -> None:
    signed_request("DELETE", f"{S3_ENDPOINT}/{BUCKET}/{quote(key, safe='')}", "s3")


def put_item(item: dict) -> None:
    """PutItem через Document API (DynamoDB-совместимый JSON)."""
    body = json.dumps({
        "TableName": TABLE_NAME,
        "Item": {name: {"S": value} for name, value in item.items()},
    }).encode("utf-8")
    signed_request("POST", DOCAPI_ENDPOINT, "dynamodb", body, {
        "Content-Type": "application/x-amz-json-1.0",
        "X-Amz-Target": "DynamoDB_20120810.PutItem",
    })


def uuid7() -> uuid.UUID:
    """UUID версии 7 (RFC 9562): 48 бит Unix-времени в мс + случайные биты."""
    timestamp_ms = time.time_ns() // 1_000_000
    value = bytearray(timestamp_ms.to_bytes(6, "big") + os.urandom(10))
    value[6] = (value[6] & 0x0F) | 0x70  # версия 7
    value[8] = (value[8] & 0x3F) | 0x80  # вариант RFC 4122/9562
    return uuid.UUID(bytes=bytes(value))


def parse_task(message: dict) -> dict:
    body = message["details"]["message"]["body"]
    task = json.loads(body)
    for field in ("name", "url"):
        if not isinstance(task.get(field), str) or not task[field].strip():
            raise ValueError(f"В задании отсутствует или пустое поле '{field}'")
    if urlparse(task["url"]).scheme not in ("http", "https"):
        raise ValueError("Поддерживаются только http/https URL")
    return task


def download(url: str) -> bytes:
    request = Request(url, headers={"User-Agent": "vvot09-archiver/1.0"})
    with urlopen(request, timeout=DOWNLOAD_TIMEOUT) as response:
        declared = response.headers.get("Content-Length")
        if declared and int(declared) > MAX_FILE_SIZE:
            raise ValueError(f"Файл слишком большой: {declared} байт")
        data = response.read(MAX_FILE_SIZE + 1)
    if len(data) > MAX_FILE_SIZE:
        raise ValueError("Файл превышает допустимый размер")
    return data


def make_zip(file_name: str, data: bytes) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(os.path.basename(file_name) or "file", data)
    return buffer.getvalue()


def process(task: dict) -> str:
    key = f"{uuid7()}.zip"
    logger.info("Архивирование %s -> %s", task["url"], key)

    archive = make_zip(task["name"], download(task["url"]))
    put_object(key, archive)
    try:
        put_item({"key": key, "name": task["name"], "url": task["url"]})
    except Exception:
        # не оставляем в хранилище архив без записи в БД
        delete_object(key)
        raise
    return key


def handler(event, context):
    messages = event.get("messages", [])
    if not messages:
        raise ValueError("В событии нет сообщений")
    keys = [process(parse_task(message)) for message in messages]
    return {"statusCode": 200, "body": json.dumps({"keys": keys})}