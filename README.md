# Coding Crew

Набор скилов для Claude Code / Cowork — команда кодинг-агентов, которая ведёт задачу от постановки до смерженного кода с документацией.

Репозиторий одновременно является маркетплейсом плагинов (`kibo-skills`) и содержит сам плагин `coding-crew`.

## Скилы

| Скилл | Роль | Когда звать |
| :--- | :--- | :--- |
| `/coding-plan` | Планировщик | Разобрать задачу и составить план в `docs/plans/` — атомарные задачи, граф зависимостей, волны параллельного выполнения, критерии приёмки |
| `/coding-architect` | Архитектор | Проработать архитектуру по плану или с нуля, провести аудит, сверить реализацию с зафиксированными решениями |
| `/coding-writer` | Исполнитель | Взять задачу или волну из плана, написать код, прогнать тесты, закоммитить в ветку и открыть MR/PR |
| `/coding-test` | Тестовый инженер | Покрыть изменённый код тестами, посчитать покрытие по изменённым строкам, отчёт PASS/FAIL |
| `/coding-secure` | Секьюрити-ревью | Секреты, CVE в зависимостях, инъекции, дыры в авторизации, небезопасный конфиг Docker/K8s/CI |
| `/coding-qa` | QA | Интеграционные тесты, качество кода, документация проекта, отчёт в `docs/qa/` |
| `/commander` | Оркестратор | Довести задачу целиком: план → архитектура → параллельные writer'ы → проверочная волна → мерж → итоговый отчёт |

Типовой сценарий: `/coding-plan` → `/commander` — дальше командир сам вызывает остальных.

## Установка

```
/plugin marketplace add KiboMibo/<repo>
/plugin install coding-crew@kibo-skills
/reload-plugins
```

Скилы плагина доступны с неймспейсом, например `/coding-crew:commander`.

### Локально, без плагина

Скопировать нужные папки из `plugins/coding-crew/skills/` в `~/.claude/skills/` (глобально) или `.claude/skills/` в проекте.

## Структура

```
.claude-plugin/marketplace.json      каталог маркетплейса
plugins/coding-crew/
  .claude-plugin/plugin.json         манифест плагина
  skills/
    coding-plan/SKILL.md
    coding-architect/{SKILL.md,references/}
    coding-writer/{SKILL.md,references/}
    coding-test/{SKILL.md,references/,scripts/}
    coding-secure/{SKILL.md,references/,scripts/}
    coding-qa/{SKILL.md,references/}
    commander/{SKILL.md,references/}
```

## Лицензия

MIT — см. [LICENSE](LICENSE).
