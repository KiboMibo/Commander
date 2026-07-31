#!/usr/bin/env bash
# Прогон сканеров безопасности по репозиторию.
#
# Использование:
#   scan.sh [путь-к-репо] [--full] [--no-install] [--out КАТАЛОГ]
#
#   --full        сканировать историю git на секреты (режим полного аудита)
#   --no-install  не устанавливать недостающие инструменты, только использовать имеющиеся
#   --out DIR     каталог для вывода (по умолчанию /tmp/coding-secure-scan-<имя-репо>)
#
# Сырой вывод намеренно кладётся ВНЕ проверяемого репозитория: ревьюер не должен
# оставлять мусор в чужом рабочем дереве и создавать риск случайного коммита.
#
# Скрипт никогда не прерывается из-за находок или отсутствия инструмента: он делает
# что может и печатает в конце сводку — что отработало, а что нет. Раздел «не отработало»
# обязан попасть в отчёт, иначе пропуск проверки будет прочитан как её успешное прохождение.

set -uo pipefail

REPO="."
FULL=0
INSTALL=1
OUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --full) FULL=1; shift ;;
    --no-install) INSTALL=0; shift ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) REPO="$1"; shift ;;
  esac
done

REPO="$(cd "$REPO" 2>/dev/null && pwd)" || { echo "Каталог не найден"; exit 1; }
# Имя каталога уникально по пути репозитория и PID: иначе два параллельных ревью
# разных репозиториев с одинаковым basename (типично для eval-прогонов и монорепо)
# пишут в один каталог, и один читает чужие результаты как свои.
if [[ -z "$OUT" ]]; then
  TAG="$(printf '%s' "$REPO" | cksum | cut -d' ' -f1)"
  OUT="${TMPDIR:-/tmp}/coding-secure-scan-$(basename "$REPO")-$TAG-$$"
fi
mkdir -p "$OUT"

RAN=()
SKIPPED=()

have() { command -v "$1" >/dev/null 2>&1; }
note_ran() { RAN+=("$1"); }
note_skip() { SKIPPED+=("$1 — $2"); }

# Инструмент считается отработавшим, только если он оставил непустой осмысленный вывод.
# Ненулевой код возврата у сканеров обычно значит «нашёл проблемы», а не «упал», поэтому
# судить надо по файлу. Иначе скрипт отрапортует «✓», а в отчёт уйдёт «проверено и чисто»
# там, где на самом деле не проверялось ничего.
ok_output() {  # ok_output <файл> [строка-маркер-ошибки ...]
  local f="$1"; shift
  [[ -s "$f" ]] || return 1
  local marker
  for marker in "$@"; do
    grep -q "$marker" "$f" 2>/dev/null && return 1
  done
  return 0
}

# ── определение стека ────────────────────────────────────────────────────────
has_file() { find "$REPO" -maxdepth 3 -name "$1" -not -path "*/node_modules/*" -not -path "*/vendor/*" -not -path "*/.venv/*" -print -quit 2>/dev/null | grep -q .; }

IS_JS=0;    has_file "package.json"     && IS_JS=1
IS_PY=0;  { has_file "requirements*.txt" || has_file "pyproject.toml" || has_file "setup.py"; } && IS_PY=1
IS_GO=0;    has_file "go.mod"           && IS_GO=1
IS_RS=0;    has_file "Cargo.toml"       && IS_RS=1
IS_DOCKER=0; has_file "Dockerfile"      && IS_DOCKER=1
IS_IAC=0;  { has_file "*.tf" || has_file "*.yaml" || has_file "*.yml"; } && IS_IAC=1

echo "Репозиторий: $REPO"
echo "Стек: JS=$IS_JS PY=$IS_PY GO=$IS_GO RS=$IS_RS DOCKER=$IS_DOCKER IAC=$IS_IAC"
echo "Вывод: $OUT"
echo

# ── секреты ──────────────────────────────────────────────────────────────────
if ! have gitleaks && [[ $INSTALL -eq 1 ]]; then
  echo "→ ставлю gitleaks"
  if have brew; then brew install gitleaks >/dev/null 2>&1
  elif have go; then go install github.com/gitleaks/gitleaks/v8@latest >/dev/null 2>&1 && export PATH="$PATH:$(go env GOPATH)/bin"
  fi
fi

if have gitleaks; then
  gitleaks detect --no-git --source "$REPO" --report-format json \
    --report-path "$OUT/gitleaks.json" --redact >/dev/null 2>&1
  ok_output "$OUT/gitleaks.json" && note_ran "gitleaks (рабочее дерево)" || note_skip "gitleaks (рабочее дерево)" "вывод пуст — либо находок нет, либо прогон не состоялся; проверь $OUT/gitleaks.json"
  if [[ $FULL -eq 1 && -d "$REPO/.git" ]]; then
    gitleaks detect --source "$REPO" --report-format json \
      --report-path "$OUT/gitleaks-history.json" --redact >/dev/null 2>&1
    ok_output "$OUT/gitleaks-history.json" && note_ran "gitleaks (история git)" || note_skip "gitleaks (история git)" "вывод пуст — проверь $OUT/gitleaks-history.json"
  fi
else
  note_skip "gitleaks" "не установлен; ищи секреты вручную по scanners.md"
fi

# Самодельные секреты, которые gitleaks не ловит по шаблонам провайдеров.
grep -rIn --binary-files=without-match \
  --exclude-dir={node_modules,vendor,.venv,.git,dist,build,target,__pycache__} \
  -E '(password|passwd|secret|api[_-]?key|token|access[_-]?key|private[_-]?key|conn(ection)?[_-]?str|dsn)[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"']{6,}' \
  "$REPO" > "$OUT/grep-secrets.txt" 2>/dev/null
grep -rIn --binary-files=without-match \
  --exclude-dir={node_modules,vendor,.venv,.git,dist,build,target} \
  -E '[a-z]+://[^/[:space:]:]+:[^@[:space:]]+@' \
  "$REPO" >> "$OUT/grep-secrets.txt" 2>/dev/null
note_ran "grep по типовым именам секретов и URL с credentials"

# ── зависимости ──────────────────────────────────────────────────────────────
if ! have osv-scanner && [[ $INSTALL -eq 1 ]] && have go; then
  echo "→ ставлю osv-scanner"
  go install github.com/google/osv-scanner/cmd/osv-scanner@latest >/dev/null 2>&1 && export PATH="$PATH:$(go env GOPATH)/bin"
fi
if have osv-scanner; then
  osv-scanner --format json --recursive "$REPO" > "$OUT/osv.json" 2>/dev/null
  ok_output "$OUT/osv.json" && note_ran "osv-scanner" || note_skip "osv-scanner" "вывод пуст (нет lock-файлов или нет сети к api.osv.dev)"
else
  note_skip "osv-scanner" "не установлен; CVE проверены только родными аудитами"
fi

if [[ $IS_JS -eq 1 ]]; then
  if have npm; then
    (cd "$REPO" && npm audit --json > "$OUT/npm-audit.json" 2>/dev/null)
    if ok_output "$OUT/npm-audit.json" "ENOLOCK" "EUSAGE"; then
      note_ran "npm audit"
    elif [[ $INSTALL -eq 1 ]]; then
      # Нет lock-файла — аудит по дереву, восстановленному во временной копии.
      # Это законная замена, но в отчёте она должна быть названа своим именем.
      LOCKDIR="$OUT/npm-lock-tmp"; mkdir -p "$LOCKDIR"
      cp "$REPO/package.json" "$LOCKDIR/" 2>/dev/null
      (cd "$LOCKDIR" && npm install --package-lock-only --ignore-scripts >/dev/null 2>&1 \
        && npm audit --json > "$OUT/npm-audit.json" 2>/dev/null)
      if ok_output "$OUT/npm-audit.json" "ENOLOCK" "EUSAGE"; then
        note_ran "npm audit (по lock-файлу, сгенерированному во временной копии — в репозитории lock отсутствует)"
      else
        note_skip "npm audit" "нет lock-файла, восстановить дерево не удалось"
      fi
    else
      note_skip "npm audit" "в репозитории нет lock-файла (ENOLOCK)"
    fi
  else note_skip "npm audit" "npm недоступен"; fi
fi

if [[ $IS_PY -eq 1 ]]; then
  if ! have pip-audit && [[ $INSTALL -eq 1 ]]; then pip install pip-audit --break-system-packages >/dev/null 2>&1; fi
  if have pip-audit; then
    (cd "$REPO" && pip-audit --format json --output "$OUT/pip-audit.json" >/dev/null 2>&1)
    ok_output "$OUT/pip-audit.json" && note_ran "pip-audit" || note_skip "pip-audit" "вывод пуст"
  else note_skip "pip-audit" "не установлен"; fi
fi

if [[ $IS_GO -eq 1 ]]; then
  if ! have govulncheck && [[ $INSTALL -eq 1 ]] && have go; then
    go install golang.org/x/vuln/cmd/govulncheck@latest >/dev/null 2>&1 && export PATH="$PATH:$(go env GOPATH)/bin"
  fi
  if have govulncheck; then
    (cd "$REPO" && govulncheck -json ./... > "$OUT/govulncheck.json" 2>/dev/null)
    ok_output "$OUT/govulncheck.json" && note_ran "govulncheck (с анализом достижимости)" || note_skip "govulncheck" "вывод пуст"
  else note_skip "govulncheck" "не установлен"; fi
fi

if [[ $IS_RS -eq 1 ]]; then
  if ! have cargo-audit && [[ $INSTALL -eq 1 ]] && have cargo; then cargo install cargo-audit >/dev/null 2>&1; fi
  if have cargo-audit || cargo audit --version >/dev/null 2>&1; then
    (cd "$REPO" && cargo audit --json > "$OUT/cargo-audit.json" 2>/dev/null)
    ok_output "$OUT/cargo-audit.json" && note_ran "cargo audit" || note_skip "cargo audit" "вывод пуст"
  else note_skip "cargo audit" "не установлен"; fi
fi

# ── код ──────────────────────────────────────────────────────────────────────
if ! have semgrep && [[ $INSTALL -eq 1 ]]; then
  echo "→ ставлю semgrep"
  pip install semgrep --break-system-packages >/dev/null 2>&1
fi
if have semgrep; then
  semgrep --config=auto --json --output "$OUT/semgrep.json" \
    --exclude=node_modules --exclude=vendor --exclude=.venv --exclude=dist \
    --exclude=build --exclude=target --metrics=off "$REPO" >"$OUT/semgrep.log" 2>&1
  # Судим по логу, а не по числу находок: пустой список результатов на чистом коде —
  # законный исход, а вот не загрузившиеся правила означают, что не проверялось ничего.
  if grep -qiE "proxyerror|403 forbidden|failed to (download|resolve)|connection (error|refused)|unable to (load|fetch)" "$OUT/semgrep.log" 2>/dev/null; then
    note_skip "semgrep" "правила из реестра не загрузились (сеть/прокси) — прогон неполный, см. $OUT/semgrep.log; напиши локальные правила или разбирай код вручную по чек-листу"
  elif ok_output "$OUT/semgrep.json"; then
    note_ran "semgrep (--config=auto)"
  else
    note_skip "semgrep" "прогон не дал вывода, см. $OUT/semgrep.log"
  fi
else
  note_skip "semgrep" "не установлен; статический анализ шаблонов не выполнялся"
fi

if [[ $IS_PY -eq 1 ]]; then
  if ! have bandit && [[ $INSTALL -eq 1 ]]; then pip install bandit --break-system-packages >/dev/null 2>&1; fi
  if have bandit; then
    bandit -r "$REPO" -f json -o "$OUT/bandit.json" -x "$REPO/tests,$REPO/.venv" -q >/dev/null 2>&1
    ok_output "$OUT/bandit.json" && note_ran "bandit" || note_skip "bandit" "вывод пуст"
  else note_skip "bandit" "не установлен"; fi
fi

# ── инфраструктура ───────────────────────────────────────────────────────────
if [[ $IS_DOCKER -eq 1 || $IS_IAC -eq 1 ]]; then
  if have trivy; then
    trivy fs --format json --output "$OUT/trivy-fs.json" --scanners vuln,secret,misconfig \
      --skip-dirs node_modules,vendor,.venv "$REPO" >/dev/null 2>&1
    if [[ -s "$OUT/trivy-fs.json" ]] && grep -q '"Results"' "$OUT/trivy-fs.json" 2>/dev/null; then
      note_ran "trivy fs"
    else
      note_skip "trivy" "запустился, но база уязвимостей не загрузилась (нужна сеть) — результат недостоверен"
    fi
  else
    note_skip "trivy" "не установлен; конфигурацию разбирай вручную по checklist-infra.md"
  fi

  if have hadolint && [[ $IS_DOCKER -eq 1 ]]; then
    find "$REPO" -maxdepth 3 -name "Dockerfile*" -not -path "*/node_modules/*" \
      -exec hadolint --format json {} \; > "$OUT/hadolint.json" 2>/dev/null
    note_ran "hadolint"
  fi
fi

# ── сводка ───────────────────────────────────────────────────────────────────
echo
echo "════ ОТРАБОТАЛО ════"
printf '  ✓ %s\n' "${RAN[@]:-нет}"
echo
echo "════ НЕ ОТРАБОТАЛО (перенеси в раздел «Не проверено» отчёта) ════"
if [[ ${#SKIPPED[@]} -eq 0 ]]; then echo "  —"; else printf '  ✗ %s\n' "${SKIPPED[@]}"; fi
echo
echo "Сырой вывод: $OUT"
echo "ВАЖНО: всё из блока «не отработало» обязано попасть в раздел «Не проверено» отчёта."
echo "Отсутствие находок у не отработавшего инструмента — это не «чисто»."
echo "Дальше: это только фундамент. Логические дыры — авторизацию, IDOR, гонки —"
echo "сканеры не находят; читай код от точек входа по чек-листу стека."
