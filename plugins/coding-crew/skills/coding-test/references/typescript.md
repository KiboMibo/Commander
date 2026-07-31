# TypeScript / JavaScript

## Определить, что используется

Смотри в таком порядке — первый ответ верный:

1. `package.json` → `scripts.test`, `devDependencies` (это команда, которой пользуется команда, — используй её, а не свою);
2. конфиги в корне: `vitest.config.*`, `jest.config.*`, `playwright.config.*`, `karma.conf.js`, `.mocharc.*`;
3. существующие тесты — по импортам видно раннер и стиль (`describe/it` vs `test`, `expect` из чего);
4. CI-конфиг (`.github/workflows/*.yml`) — что реально гоняется на PR.

Монорепо: у каждого пакета может быть свой раннер. Смотри `pnpm-workspace.yaml`, `turbo.json`, `nx.json`, `workspaces` в корневом `package.json`, и запускай тесты в контексте нужного пакета (`pnpm --filter <pkg> test`).

## Команды

| Задача | Vitest | Jest |
|--------|--------|------|
| Прогон | `npx vitest run` | `npx jest` |
| Один файл | `npx vitest run path/to/file.test.ts` | `npx jest path/to/file.test.ts` |
| По имени теста | `npx vitest run -t "returns 401"` | `npx jest -t "returns 401"` |
| Покрытие | `npx vitest run --coverage` | `npx jest --coverage` |
| Стабильность | `npx vitest run --sequence.shuffle` | `npx jest --randomize` |
| Без кеша | `npx vitest run --no-cache` | `npx jest --ci --no-cache` |

Watch-режим (`vitest` без `run`) в агентской работе не запускай — процесс не завершится.

## Покрытие

Нужен репортер `lcov` — его понимает `scripts/diff_coverage.py`.

Vitest (`vitest.config.ts`):

```ts
test: {
  coverage: {
    provider: 'v8',              // 'istanbul', если нужна точность по веткам
    reporter: ['text', 'lcov'],
    reportsDirectory: './coverage',
  },
}
```

Jest (`jest.config.js`): `coverageReporters: ['text', 'lcov']`.

Разово, не трогая конфиг: `npx vitest run --coverage --coverage.reporter=lcov`.

Результат — `coverage/lcov.info`:

```bash
python scripts/diff_coverage.py --coverage coverage/lcov.info --base origin/main --min 80
```

Провайдер `v8` иногда считает покрытыми строки типов и декларации — если проценты выглядят подозрительно щедро, перепроверь на `istanbul`.

## Конвенции

- Расположение: рядом с кодом (`foo.ts` + `foo.test.ts`) или в `__tests__/`. Посмотри, как уже сделано, и не смешивай два подхода.
- Общие фикстуры — `test/setup.ts`, подключается через `setupFiles`. Проверь, что там уже настроено, прежде чем настраивать заново.
- Типы: тесты тоже проходят `tsc`. Убедись, что `npm run typecheck` (или `tsc --noEmit`) зелёный — тест, не проходящий проверку типов, сломает CI даже будучи «зелёным» у раннера.

## Моки

- Модули: `vi.mock('./api')` / `jest.mock('./api')`. Помни про подъём вызова наверх файла — фабрика мока не видит переменные, объявленные ниже.
- Время: `vi.useFakeTimers()` + `vi.setSystemTime(new Date('2026-01-01'))`. Обязательно `vi.useRealTimers()` в `afterEach`, иначе поедет соседний тест.
- HTTP: предпочитай MSW (`msw`) моканью `fetch` — он проверяет и то, какой запрос ушёл, а не только что ответ подставился.
- `vi.restoreAllMocks()` / `jest.restoreAllMocks()` в `afterEach` — дешёвая страховка от протечки состояния между тестами.

## Типичные грабли

**Незаawaitенный промис.** Тест зелёный, потому что закончился раньше проверки. Признак — ассерт после `await` не влияет на результат. Проверяй: сломай логику, тест обязан покраснеть (фаза 6).

**`expect` внутри колбэка без счётчика.** Если колбэк не вызвался, тест пройдёт молча. Используй `expect.assertions(n)` или `await expect(...).rejects`.

**Плавающее время и часовые пояса.** `new Date()` в коде + реальные таймеры = тест, падающий в полночь или в другом TZ. Фиксируй время.

**Общее состояние модуля.** Модули в ESM кешируются: счётчик или синглтон переживёт тест. `vi.resetModules()` между тестами, если модуль хранит состояние.

**Тест на снапшот вместо теста на поведение.** `toMatchSnapshot()` фиксирует что угодно, включая баг; при падении его обычно просто обновляют. Для проверки логики пиши явные ассерты.

## Интеграционные тесты

- HTTP-слой: `supertest` поверх приложения (без реального порта) — быстро и без гонок за портами.
- БД: `testcontainers` для настоящей базы либо транзакция с откатом в `afterEach`. In-memory замена (sqlite вместо postgres) экономит время, но не ловит диалектные различия — если тест про SQL, бери настоящую БД.
- React-компоненты: `@testing-library/react` — запрос по роли и тексту, а не по классам; это ровно граница «публичное поведение против деталей реализации».

## Mutation

Stryker, если он уже настроен (`stryker.config.json`):

```bash
npx stryker run --mutate "src/path/changed/**/*.ts"
```

Не настроен — не ставь ради одного прогона, ограничься точечной проверкой чувствительности.
