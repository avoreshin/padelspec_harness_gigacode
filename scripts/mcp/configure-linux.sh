#!/bin/bash
set -euo pipefail

# =============================================================================
# configure-linux.sh — настройка окружения для работы с SberOSC,
# Confluence (Sigma + Delta) и Jira Delta на SberOS.
#
# Запускается из .gigacode/scripts/setup-mcp-atlassian.sh, но работает и сам по
# себе: если ${HOME}/.giga_sberosc отсутствует, скрипт спросит всё в терминале.
# =============================================================================

CREDENTIALS_FILE="${HOME}/.giga_sberosc"

echo "============================================="
echo " MCP Atlassian Setup — SberOS"
echo "============================================="
echo ""

# --- Проверка HOME ---
if [[ -z "${HOME:-}" ]]; then
    echo "ERROR: Переменная HOME не определена. Запустите скрипт под обычным пользователем."
    exit 1
fi
echo "    HOME = ${HOME}"

# --- 1-4. Запрос / загрузка конфиденциальных данных ---
if [[ -f "${CREDENTIALS_FILE}" ]]; then
    echo "[1/10] Чтение сохранённых учётных данных из ${CREDENTIALS_FILE}..."
    # shellcheck disable=SC1090
    source "${CREDENTIALS_FILE}"
    echo "    Учётные данные загружены."
else
    echo "[1/10] Введите API-токен Sigma (https://confluence.sberbank.ru/users/viewmysettings.action)"
    read -r sigma_token
    echo ""

    echo "[1.5/10] Введите API-токен Confluence Delta (https://confluence.delta.sbrf.ru/users/viewmysettings.action)"
    read -r delta_token
    echo ""

    echo "[2/10] Введите API-токен Jira Delta (https://jira.delta.sbrf.ru/secure/ViewProfile.jspa)"
    read -r jira_delta_token
    echo ""

    echo "[3/10] Введите API-токен SberOSC (https://sso.sberosc.sigma.sbrf.ru/dashboard/profile/)"
    read -r sberosc_token
    echo ""

    echo "[4/10] Введите адрес почты sigma (например, GBukin@sberbank.ru)"
    read -r mail_address
    echo ""

    # Сохраняем учётные данные в файл
    cat > "${CREDENTIALS_FILE}" <<EOF
sigma_token="${sigma_token}"
delta_token="${delta_token}"
jira_delta_token="${jira_delta_token}"
sberosc_token="${sberosc_token}"
mail_address="${mail_address}"
EOF
    echo "    Учётные данные сохранены в ${CREDENTIALS_FILE}."
fi

# --- 5. Определить work_dir ---
echo "[5/10] Определение рабочей директории..."
work_dir=$(find /home/work -maxdepth 1 -type d -name '*[0-9][0-9][0-9][0-9][0-9][0-9][0-9]*' | head -n 1)

if [[ -z "$work_dir" ]]; then
    echo "ERROR: Не найдена директория в /home/work, соответствующая шаблону '*[0-9]{7}*'"
    exit 1
fi
echo "    work_dir = $work_dir"

# --- 6. Base64-кодирование SberOSC токена ---
echo "[6/10] Кодирование SberOSC токена в base64..."
sberosc_base64_token=$(echo -n "token:${sberosc_token}" | base64)

# --- 7. Создание .npmrc ---
echo "[7/10] Создание файлов .npmrc..."

NPMRC_CONTENT='//sberosc.sigma.sbrf.ru/repo/npm/:_authToken="'${sberosc_base64_token}'"
registry=https://sberosc.sigma.sbrf.ru/repo/npm/
audit=false
always-auth=true
fetch-retries=5
strict-ssl=false
save-exact=true
loglevel=verbose
legacy-peer-deps=true'

echo "$NPMRC_CONTENT" > "${work_dir}/.npmrc"
echo "$NPMRC_CONTENT" > "${HOME}/.npmrc"

echo "    Создано: ${work_dir}/.npmrc"
echo "    Создано: ${HOME}/.npmrc"

# --- 8. Создание Python venv и установка пакетов ---
echo "[8/10] Создание Python venv и установка пакетов..."

cd "${work_dir}"

if [[ ! -d "${work_dir}/.venv" ]]; then
    python3 -m venv "${work_dir}/.venv"
    echo "    Venv создан: ${work_dir}/.venv"
else
    echo "    Venv уже существует: ${work_dir}/.venv"
fi

# Устанавливаем пакеты в активированном venv
"${work_dir}/.venv/bin/python3" -m pip install requests mcp-atlassian==0.21.0 redis==7.2.1 \
    -i "https://token:${sberosc_token}@sberosc.sigma.sbrf.ru/repo/pypi/simple" \
    --trusted-host sberosc.sigma.sbrf.ru  --only-binary :all:

echo "    Пакеты установлены."


# --- 10. Создание / обновление ~/.gigacode/settings.json ---
echo "[10/10] Настройка ~/.gigacode/settings.json..."

mkdir -p "${HOME}/.gigacode"
SETTINGS_FILE="${HOME}/.gigacode/settings.json"

# Формируем JSON-блок для двух серверов
ATLASSIAN_BLOCK="    \"atlassian\": {
      \"command\": \"${HOME}/.venv/bin/python\",
      \"args\": [\"${HOME}/.venv/bin/mcp-atlassian\"],
      \"env\": {
        \"CONFLUENCE_URL\": \"https://confluence.sberbank.ru\",
        \"CONFLUENCE_USERNAME\": \"${mail_address}\",
        \"CONFLUENCE_PERSONAL_TOKEN\": \"${sigma_token}\",
        \"CONFLUENCE_SSL_VERIFY\": false,
        \"JIRA_URL\": \"https://jira.delta.sbrf.ru\",
        \"JIRA_USERNAME\": \"${mail_address}\",
        \"JIRA_PERSONAL_TOKEN\": \"${jira_delta_token}\",
        \"JIRA_SSL_VERIFY\": false
      },
      \"timeout\": 60000,
      \"trust\": false
    },
    \"delta-confluence\": {
      \"command\": \"${HOME}/.venv/bin/python\",
      \"args\": [\"${HOME}/.venv/bin/mcp-atlassian\"],
      \"env\": {
        \"CONFLUENCE_URL\": \"https://confluence.delta.sbrf.ru\",
        \"CONFLUENCE_USERNAME\": \"${mail_address}\",
        \"CONFLUENCE_PERSONAL_TOKEN\": \"${delta_token}\",
        \"CONFLUENCE_SSL_VERIFY\": false
      },
      \"timeout\": 60000,
      \"trust\": false
    }"

if [[ ! -f "${SETTINGS_FILE}" ]]; then
    # Файл не существует — создаём новый
    cat > "${SETTINGS_FILE}" <<EOF
{
  "mcpServers": {
${ATLASSIAN_BLOCK}
  }
}
EOF
    echo "    Создан новый файл: ${SETTINGS_FILE}"

elif python3 -c "import json, sys; json.load(open('${SETTINGS_FILE}'))" 2>/dev/null; then
    # Файл существует и валиден — обновляем через Python/JSON
    python3 - "${SETTINGS_FILE}" "${HOME}" "${mail_address}" "${sigma_token}" "${delta_token}" "${jira_delta_token}" <<'PYEOF'
import json
import sys

settings_file = sys.argv[1]
home = sys.argv[2]
mail = sys.argv[3]
sigma_token = sys.argv[4]
delta_token = sys.argv[5]
jira_delta_token = sys.argv[6]

with open(settings_file, 'r') as f:
    data = json.load(f)

atlassian = {
    "command": f"{home}/.venv/bin/python",
    "args": [f"{home}/.venv/bin/mcp-atlassian"],
    "env": {
        "JIRA_URL": "https://jira.delta.sbrf.ru",
        "JIRA_USERNAME": mail,
        "JIRA_PERSONAL_TOKEN": jira_delta_token,
        "JIRA_SSL_VERIFY": False,
        "CONFLUENCE_URL": "https://confluence.sberbank.ru",
        "CONFLUENCE_USERNAME": mail,
        "CONFLUENCE_PERSONAL_TOKEN": sigma_token,
        "CONFLUENCE_SSL_VERIFY": False
    },
    "timeout": 60000,
    "trust": False
}

delta_confluence = {
    "command": f"{home}/.venv/bin/python",
    "args": [f"{home}/.venv/bin/mcp-atlassian"],
    "env": {
        "CONFLUENCE_URL": "https://confluence.delta.sbrf.ru",
        "CONFLUENCE_USERNAME": mail,
        "CONFLUENCE_PERSONAL_TOKEN": delta_token,
        "CONFLUENCE_SSL_VERIFY": False
    },
    "timeout": 60000,
    "trust": False
}

if "mcpServers" not in data:
    data["mcpServers"] = {}

data["mcpServers"]["atlassian"] = atlassian
data["mcpServers"]["delta-confluence"] = delta_confluence

with open(settings_file, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n')

PYEOF
    echo "    Обновлён существующий файл: ${SETTINGS_FILE}"
else
    # Файл существует, но невалидный JSON — перезаписываем
    cat > "${SETTINGS_FILE}" <<EOF
{
  "mcpServers": {
${ATLASSIAN_BLOCK}
  }
}
EOF
    echo "    Файл был невалидным JSON — перезаписан: ${SETTINGS_FILE}"
fi

# =============================================================================
# Удаление файла с учётными данными после успешного завершения
# =============================================================================
rm -f "${CREDENTIALS_FILE}"
echo ""
echo "    Файл учётных данных удалён: ${CREDENTIALS_FILE}"

# =============================================================================
# Итог
# =============================================================================
echo ""
echo "============================================="
echo "  Setup завершён успешно!"
echo "============================================="
echo ""
echo "Рабочая директория : ${work_dir}"
echo "Python venv        : ${work_dir}/.venv"
echo "Конфиг MCP         : ${SETTINGS_FILE}"
echo "Файл .npmrc        : ${HOME}/.npmrc, ${work_dir}/.npmrc"
echo ""
echo "Для активации venv запустите:"
echo "  source ${HOME}/.venv/bin/activate"
echo ""
