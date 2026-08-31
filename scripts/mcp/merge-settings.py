#!/usr/bin/env python3
"""Дописывает серверы atlassian и delta-confluence в settings.json GigaCode.

Существующие ключи mcpServers сохраняются: конфиг пользователя может уже
содержать чужие серверы, и настройка Atlassian не должна их терять. Если файла
нет или он невалиден — создаётся заново.

Все значения приходят через окружение, а не через argv: токены в аргументах
видны в выводе ps и в истории команд.

  MCP_SETTINGS      путь к settings.json
  MCP_PYTHON        интерпретатор, которым запускается сервер
  MCP_ATLASSIAN     точка входа mcp-atlassian
  MCP_MAIL          адрес почты sigma
  MCP_SIGMA_TOKEN   токен Confluence Sigma
  MCP_DELTA_TOKEN   токен Confluence Delta
  MCP_JIRA_TOKEN    токен Jira Delta

Код возврата: 0 — записано, 2 — не хватает переменных окружения.
"""
import json
import os
import sys

REQUIRED = (
    "MCP_SETTINGS", "MCP_PYTHON", "MCP_ATLASSIAN", "MCP_MAIL",
    "MCP_SIGMA_TOKEN", "MCP_DELTA_TOKEN", "MCP_JIRA_TOKEN",
)

missing = [k for k in REQUIRED if not os.environ.get(k)]
if missing:
    sys.stderr.write("merge-settings: не заданы переменные: %s\n" % ", ".join(missing))
    sys.exit(2)

settings_file = os.environ["MCP_SETTINGS"]
python_cmd = os.environ["MCP_PYTHON"]
atlassian_entry = os.environ["MCP_ATLASSIAN"]
mail = os.environ["MCP_MAIL"]
sigma_token = os.environ["MCP_SIGMA_TOKEN"]
delta_token = os.environ["MCP_DELTA_TOKEN"]
jira_token = os.environ["MCP_JIRA_TOKEN"]

data = {}
status = "создан"
if os.path.isfile(settings_file):
    try:
        with open(settings_file, "r", encoding="utf-8") as f:
            data = json.load(f)
        status = "обновлён"
    except (ValueError, OSError):
        # Невалидный JSON перезаписываем: чинить чужой сломанный конфиг
        # автоматически опаснее, чем положить рядом рабочий.
        data = {}
        status = "перезаписан (был невалидный JSON)"

if not isinstance(data, dict):
    data = {}
    status = "перезаписан (корень не объект)"

atlassian = {
    "command": python_cmd,
    "args": [atlassian_entry],
    "env": {
        "CONFLUENCE_URL": "https://confluence.sberbank.ru",
        "CONFLUENCE_USERNAME": mail,
        "CONFLUENCE_PERSONAL_TOKEN": sigma_token,
        "CONFLUENCE_SSL_VERIFY": False,
        "JIRA_URL": "https://jira.delta.sbrf.ru",
        "JIRA_USERNAME": mail,
        "JIRA_PERSONAL_TOKEN": jira_token,
        "JIRA_SSL_VERIFY": False,
    },
    "timeout": 60000,
    "trust": False,
}

delta_confluence = {
    "command": python_cmd,
    "args": [atlassian_entry],
    "env": {
        "CONFLUENCE_URL": "https://confluence.delta.sbrf.ru",
        "CONFLUENCE_USERNAME": mail,
        "CONFLUENCE_PERSONAL_TOKEN": delta_token,
        "CONFLUENCE_SSL_VERIFY": False,
    },
    "timeout": 60000,
    "trust": False,
}

servers = data.get("mcpServers")
if not isinstance(servers, dict):
    servers = {}
servers["atlassian"] = atlassian
servers["delta-confluence"] = delta_confluence
data["mcpServers"] = servers

target_dir = os.path.dirname(os.path.abspath(settings_file))
if target_dir and not os.path.isdir(target_dir):
    os.makedirs(target_dir)

with open(settings_file, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")

sys.stdout.write("    %s: %s (серверов всего: %d)\n" % (status, settings_file, len(servers)))
