# SDD: <Название фичи / компонента / экрана>

> **Software Design Document — фронтенд (Angular).**
> Спецификация ценнее кода: компонент генерируется из этого документа.
> Совместим с harness `sdd-schema-gate` — нумерация секций `## 1/2/4/5/8/13`
> обязательна, не переименовывать и не менять номера (по ним валидируется frontmatter).

---

## 🛠 Skills по фазам (вызывать, если доступны в окружении)

| Фаза | Что делаем | Рекомендуемые skills |
|---|---|---|
| **0. Discovery** | превратить «хочу форму» в чёткий бриф | `design-brief`, `brainstorming`, `enhance-prompt` |
| **1. UI/UX design** | лэйаут, состояния, токены, a11y | `ui-ux-pro-max`, `web-design-guidelines`, `apple-hig`/`platform-design`, `color-expert`, `theme-factory`, `brand-guidelines` |
| **2. Build** | реализация компонента | `frontend-design`, `taste-skill`, `karpathy-guidelines` (не переусложнять) |
| **3. Review / QA** | визуальный аудит + прогон в браузере | `design-review`, `plan-design-review`, `agent-browser` (догфуд запущенного app), `full-page-screenshot`/`screenshot` для evidence |

> Harness-loop: `/sdd-new` → заполнить → `/plan` → `/test` → `/implement` → `/review` → `/evidence`.

---

## Metadata

| Поле             | Значение                                    |
| ---------------- | ------------------------------------------- |
| **ID**           | SDD-YYYYMMDD-<slug>                         |
| **Author**       | <имя>                                       |
| **Reviewers**    | <UX / frontend lead / a11y>                 |
| **Status**       | draft / approved / implemented / deprecated |
| **Risk class**   | R0 / R1 / R2 / R3 / R4 / R5                 |
| **Created**      | YYYY-MM-DD                                  |
| **Last update**  | YYYY-MM-DD                                  |
| **Component**    | `<selector>` — `path/to/xxx.component.ts`   |
| **Route / entry**| `<url или где встраивается>`                |
| **UI-kit**       | <Angular Material / Taiga UI / Tailwind / …>|
| **Design**       | <ссылка на Figma / макет / скрин>           |
| **Related ADRs** | <ссылки>                                    |

---

## 1. Goal (Что и зачем)

<Одно предложение: какую задачу пользователя решает этот экран/компонент и для кого.>

**Пользовательский контекст:** <какой сценарий закрываем, где в приложении>
**Why now:** <почему сейчас, цена отсутствия>

## 2. Non-goals (Что НЕ делаем)

- ❌ <фичи соседних экранов, которые сюда не входят>
- ❌ <бэкенд-изменения, если их не трогаем>
- ❌ <рефактор общего кода вне scope>

## 3. Пользователи и user stories

**Персоны:** <кто пользуется: аналитик / оператор / админ; уровень экспертизы; частота>

### US-1: <название>
**Как** <роль> **я хочу** <действие> **чтобы** <ценность>.

### US-2: <…>

## 4. Acceptance Criteria (Given-When-Then)

> Формулировать через **взаимодействие и наблюдаемый UI**, а не реализацию.

### AC-1 <happy path>
```gherkin
Given <начальное состояние экрана / данных>
When  <пользователь делает действие: клик / ввод / выбор>
Then  <что видно в UI: элемент, текст, состояние>
And   <побочные эффекты: запрос, тост, навигация>
```

### AC-2 <error path>
```gherkin
Given <бэкенд вернёт ошибку / невалидный ввод>
When  <действие>
Then  <как показана ошибка: inline / тост / баннер, текст сообщения>
And   <данные не потеряны, форма восстановима>
```

### AC-3 <edge / состояние загрузки>
```gherkin
Given <медленная сеть / пустой список / очень длинный текст>
When  <…>
Then  <skeleton / empty state / обрезка без сломанной вёрстки>
```

## 5. UI-инварианты (property-based)

Свойства, которые должны выполняться **всегда** (кандидаты в автотесты / a11y-проверки):

- **INV-1 (a11y):** все интерактивные элементы достижимы с клавиатуры, порядок фокуса логичен, видимый focus-ring не отключён.
- **INV-2 (no layout shift):** переключение состояний (loading→data→error) не вызывает скачков вёрстки / CLS.
- **INV-3 (state consistency):** UI — чистая функция состояния; при одинаковом `@Input()` рендер идентичен, нет рассинхрона (`ExpressionChangedAfterItHasBeenChecked` отсутствует).
- **INV-4 (нет утечек):** все подписки RxJS завершаются в `ngOnDestroy` (`takeUntil`/`async` pipe); диалоги закрываются.
- **INV-5 (i18n):** ни одной хардкод-строки в шаблоне — только ключи локализации.

## 6. Component / UI contract (Angular)

**Селектор:** `<app-xxx>` · **тип:** module-declared / standalone · **ChangeDetection:** `OnPush` (рекомендуется)

### Inputs
| `@Input()` | Тип | Required | Default | Описание |
|---|---|---|---|---|
| `<name>` | `IXxx` | да/нет | `—` | <что задаёт> |

### Outputs
| `@Output()` | Payload | Когда эмитится |
|---|---|---|
| `<nameChange>` | `EventEmitter<IXxx>` | <по какому действию> |

### Content projection / слоты
- `<ng-content select="...">` — <что проецируется>

### Зависимости данных
- **Сервисы:** `<FeaturesControlService>` — <какие методы, какие Observable>
- **Модели:** `IDslFeatures`, `IDslFeatureDetails` — <ссылка на интерфейсы>
- **Backend endpoints (потребляемые):** `<GET /...>` — <контракт ответа, где документирован>

### Публичное состояние / события
- <селекция строк (SelectionModel), фильтры, режим (view/edit)>

### 6.1 Angular implementation notes

**Change Detection.** Цель — `ChangeDetectionStrategy.OnPush` + иммутабельные `@Input()` + `async` pipe в шаблоне. Ручной `cdRef.detectChanges()` — code smell (обычно значит, что данные меняются мутацией, а не заменой ссылки). Указать: `<OnPush | Default>` и почему.

**RxJS-гигиена.** Каждая подписка обязана иметь teardown:
- предпочтительно `| async` в шаблоне (авто-отписка);
- иначе `takeUntil(this.destroy$)` (`destroy$ = new Subject<void>()` + `complete()` в `ngOnDestroy`);
- на Angular 16+ — `takeUntilDestroyed(this.destroyRef)`.
- ❌ Голый `.subscribe()` без отписки в `ngOnInit`/подписки на сервисные стримы — утечка. Компонент обязан реализовывать `OnDestroy`, если есть ручные подписки.

**Модульность.** `<standalone: true>` (Angular 15+, предпочтительно) или объявление в `NgModule` — указать явно, версию Angular тоже (влияет на доступность signals/standalone/control-flow `@if/@for`).

**Signals (Angular 16+, если стек позволяет).** Локальное состояние → `signal()`, производное → `computed()`, входы/выходы → `input()`/`output()`/`model()`. Уменьшает ручной CD и рассинхрон (§5 INV-3). Если стек легаси (module-based, `@angular/material` без scope) — этот пункт помечается как «миграция, вне scope» и используется классический RxJS/`@Input`.

**Таблицы/списки.** `trackBy` обязателен; для больших наборов — CDK virtual scroll (`cdk-virtual-scroll-viewport`); `MatTableDataSource`/`TableVirtualScrollDataSource` с фильтром.

**Тестирование (§13).** `TestBed` + component test; для взаимодействий — CDK **component harnesses** (`@angular/cdk/testing`) вместо ручного дёргания DOM; HTTP — `HttpTestingController`; стримы — marble-тесты. Не мокать то, что можно проверить harness'ом.

## 7. UI/UX specification

> Ядро шаблона. Заполнять подробно — из этого рисуется компонент.

### 7.1 Layout & структура
```
<ASCII-wireframe или ссылка на Figma-фрейм>
┌───────────── toolbar: [фильтр] [действия] ─────────────┐
│ ┌ table (virtual scroll) ──────────────────────────┐   │
│ │ [☑] col1   col2   col3            [⋯ actions]     │   │
│ └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```
- Grid/flex-структура, основные зоны, порядок чтения.

### 7.2 Матрица состояний (обязательно все)
| Состояние | Триггер | Что показываем |
|---|---|---|
| **Empty** | нет данных | иллюстрация + текст + CTA |
| **Loading** | запрос в полёте | skeleton / spinner (без jump) |
| **Partial** | часть загрузилась | прогрессивный рендер |
| **Error** | запрос упал | баннер + retry, данные не теряются |
| **Success/Data** | данные есть | основной вид |
| **Disabled / Read-only** | нет прав / режим просмотра | элементы задизейблены, tooltip почему |

### 7.3 Взаимодействия и микро-анимации
- Hover / focus / active / pressed для каждого control.
- Клавиатура: Tab-порядок, Enter/Space/Esc, стрелки в таблице/списке.
- Drag&drop / inline-edit / multi-select — если есть.
- Motion: длительность/easing (напр. `200ms ease-out`), Angular `@trigger` анимации.

### 7.4 Адаптивность
| Breakpoint | Поведение |
|---|---|
| `< 768` (mobile) | <колонки схлопываются / скрытие вторичного> |
| `768–1200` (tablet) | <…> |
| `> 1200` (desktop) | <полный вид> |

### 7.5 Design tokens (UI-kit-agnostic)
Указать источник токенов по стеку:
- **Angular Material:** theme palette (primary/accent/warn), typography levels, elevation.
- **Taiga UI:** `tuiTheme`, `--tui-*` CSS-переменные, `tuiCard*`, встроенные размеры.
- **Tailwind:** `tailwind.config.js` → `theme` (цвета/spacing/radius); только utility-классы из конфига, без произвольных `[#hex]`/`[13px]`.
- **Общее:** цвет (fg/bg/border/state), типографика (h/body/caption), spacing (4/8-pt), радиусы, elevation.
> ❌ Никаких magic-number'ов в SCSS/LESS и произвольных значений Tailwind — только токены из конфига/темы.

### 7.6 Accessibility (WCAG 2.2 AA)
- Роли и ARIA: `role`, `aria-label`, `aria-live` для async-обновлений.
- Контраст текста ≥ 4.5:1 (крупный ≥ 3:1).
- Управление фокусом в диалогах (focus-trap, возврат фокуса на триггер).
- Все иконки-кнопки имеют текстовую метку для screen-reader.
- Ошибки формы связаны с полями (`aria-describedby`).

### 7.7 i18n / RTL / контент
- Ключи локализации (без хардкода), учёт длины строк в других языках.
- RTL-совместимость, если требуется.
- **Тексты и сообщения об ошибках** (микрокопирайт) — перечислить явно.

### 7.8 Темизация (light / dark), если поддерживается
- Источник темы и персист: `<localStorage / cookie / система>` (напр. `tuiTheme`, `data-theme`, класс `.dark`).
- Оба режима проходят контраст AA; проверить состояния (hover/focus/disabled) в обеих темах.
- Цвета только из токенов темы — никаких хардкод-hex, ломающихся в dark.
- Отсутствие «вспышки» неверной темы при загрузке (тема применяется до первого рендера).

## 8. Risk classification

**Класс:** R<N>

**Обоснование:** <для чистого UI без auth/PII/оплат — обычно R0 (косметика/верстка) или R1 (новый компонент, локальная логика). R2+ если трогает shared-компоненты, роутинг-гварды, обработку прав/ролей, или общий state.>

**Следствия (permission ladder):** <какой review нужен: R0/R1 — авто с hooks; R2 — PR+human; R3+ — security review при работе с правами/данными пользователя.>

## 9. Negative / edge UI cases

- Очень длинный текст / имя фичи → обрезка `text-overflow`, tooltip, без разрушения сетки.
- 0 элементов / 10 000 элементов (virtual scroll не деградирует).
- Медленная сеть / таймаут / offline.
- Двойной клик / быстрые повторные действия (защита от дабл-сабмита).
- Одновременные async-ответы (гонки) — актуальность отображаемых данных.
- Некорректный/частичный ответ backend.

## 10. Dependencies

- **Дизайн-система / UI-kit:** Angular Material (`Mat*`), CDK (virtual scroll, SelectionModel, overlay).
- **Shared-компоненты:** `<all-feature-details>`, `<word-filter>`, `<dialog-info>` — переиспользуем, не дублируем.
- **Сервисы / state:** `<FeaturesControlService>`, `ChangeModuleTypeService`.
- **Backend:** <какие эндпоинты, кто владелец контракта>.
- **Пакеты:** `rxjs`, `ngx-logger`, `@angular/animations`.

## 11. Out of scope

- <явно вынесенное за рамки этой задачи>

## 12. Open questions

- [ ] <нужен ли режим bulk-edit?>
- [ ] <источник истины для прав доступа?>
- [ ] <дизайн empty-state утверждён?>

## 13. Definition of Done

- [ ] Все AC покрыты компонентными тестами (Jasmine + TestBed) и тесты зелёные
- [ ] Все состояния из §7.2 (empty/loading/error/success/disabled) реализованы и визуально проверены
- [ ] Навигация только с клавиатуры работает; порядок фокуса корректен (§5 INV-1)
- [ ] A11y-аудит без critical (axe / Lighthouse), контраст AA
- [ ] Адаптивность проверена на брейкпоинтах из §7.4
- [ ] Нет ошибок/warning в консоли; нет `ExpressionChangedAfterItHasBeenChecked`
- [ ] Подписки RxJS завершаются (§5 INV-4) — проверено
- [ ] Строки локализованы (§5 INV-5), хардкода нет
- [ ] `ng lint` чистый; SCSS без magic-number'ов (токены §7.5)
- [ ] Design review пройден (skill `design-review`) — приложены before/after скрины
- [ ] Evidence bundle сформирован (скриншоты состояний + результаты тестов) и приложен к PR
- [ ] Risk-appropriate review пройден (§8)
