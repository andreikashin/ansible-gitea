#!/usr/bin/env python3
"""Сквозная проверка почтовика: письмо через SMTP, чтение через IMAP.

Проверяет ровно то, ради чего сервис существует, а не то, что процесс жив:
приём на 25-м, доставку в ящик и выдачу по IMAP. Тестовое письмо после
проверки удаляется, чтобы прогон плейбука не засорял ящик.

Аргументы: <адрес> <пароль> [smtp-порт] [imap-порт]
Печатает JSON, чтобы плейбук мог разобрать результат.
"""
import imaplib
import json
import smtplib
import ssl
import sys
import time
import uuid
from email.message import EmailMessage

address, password = sys.argv[1], sys.argv[2]
smtp_port = int(sys.argv[3]) if len(sys.argv) > 3 else 25
imap_port = int(sys.argv[4]) if len(sys.argv) > 4 else 993

marker = f"ansible-smoke-{uuid.uuid4().hex[:12]}"
result = {"delivered": False, "folder": None, "marker": marker}

message = EmailMessage()
message["From"] = f"postmaster@{address.split('@')[1]}"
message["To"] = address
message["Subject"] = marker
message.set_content("Проверка доставки из плейбука. Письмо удаляется сразу после проверки.")

with smtplib.SMTP("127.0.0.1", smtp_port, timeout=30) as smtp:
    smtp.send_message(message)

context = ssl.create_default_context()
context.check_hostname = False
context.verify_mode = ssl.CERT_NONE

# Доставка асинхронная: письмо проходит очередь и спам-фильтр, поэтому ждём,
# а не читаем сразу. Проверяем и Junk: письмо от самого себя без SPF и DKIM
# фильтр вполне может положить туда, для проверки тракта это не важно.
imap = imaplib.IMAP4_SSL("127.0.0.1", imap_port, ssl_context=context)
imap.login(address, password)
try:
    for _ in range(30):
        for folder in ("INBOX", "Junk Mail"):
            imap.select(f'"{folder}"')
            _, data = imap.search(None, "HEADER", "Subject", marker)
            if data and data[0]:
                result["delivered"] = True
                result["folder"] = folder
                for num in data[0].split():
                    imap.store(num, "+FLAGS", r"\Deleted")
                imap.expunge()
                break
        if result["delivered"]:
            break
        time.sleep(2)
finally:
    imap.logout()

print(json.dumps(result, ensure_ascii=False))
sys.exit(0 if result["delivered"] else 1)
