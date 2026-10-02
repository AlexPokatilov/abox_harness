# lab7 — GenAI observability: OTel vs MLflow vs Phoenix

**Гілка:** `feat/otel-demo_lab7` (від upstream `feat/otel-demo`)
**Середовище:** WSL2 + Docker + KinD (`make run`), власні ключі Gemini (Google AI Studio)

## Завдання

1. Ознайомитися з інтерфейсами OTel, MLflow і Phoenix.
2. Отримати трейси Astronomy Shop agent, власного retrieval/voice-агента або будь-якого агента kagent.
3. Порівняти три o11y-рішення — стандартний OTel, MLflow, Phoenix — з погляду GenAI.

---

## Хід виконання

### 2026-10-02 — стенд піднятий, наскрізний трейс у трьох бекендах ✅

| Фаза | Стан |
|---|---|
| 0 — WSL | ✅ 24 ГБ / 16 CPU, нативний Docker, інструменти |
| 1 — патчі | ✅ тег `0.11.33`, `lab7/patches/`, `check-patches.sh` |
| 2 — що патчити | ✅ Jaeger, Phoenix-експортер, kagent tracing, агент демо; ⏳ варіант А (шлюз) |
| 3 — ключі | ✅ `secrets.sh gemini` + `phoenix` |
| 4 — розгортання | ✅ `releases` Ready, 11/11 HelmRelease |

**Один і той самий трейс у всіх трьох** — запит до агента демо «What telescopes do you sell?», HTTP 200 за 12,6 с:

| | Jaeger | MLflow (exp 3) | Phoenix |
|---|---|---|---|
| trace | `acc3ce13ee13893adac6d96afa1644fd` | `tr-acc3ce13…` | той самий |
| спанів | 22, помилок 0 | — (одиниця — трейс) | 22 |
| стан / тривалість | — | `OK`, 12,566 с | 12 565 мс |
| токени | теги на спанах, без суми | **3281** на рівні трейсу (3112/169) | **по LLM-спанах**: 2592 + 689 = 3281 |
| типи спанів | немає | `AGENT`, `CHAT_MODEL`/`LLM`, `TOOL` (`mlflow.spanType`), HTTP — без типу | `agent`, `llm`, `tool`, решта `unknown` |

Також у всіх трьох є трейс **з помилкою LLM**: `a9e94b317548b91e9e0d07cd2612dce1` (Gemini 3, `thought_signature`) — Phoenix: невдалий `ChatLLM.chat` має `tokens=0`, вдалий — 689.

### Що зʼясувалось під час запуску

- **Gemini 3 не працює з агентом демо взагалі.** Агент кличе `list_products` навіть на простих питаннях, а кожна модель 3.x відкидає другий хід циклу тулів: `400 Function call is missing a thought_signature` — `langchain_openai` не повертає підпис. Відтворено на рівні API. **Gemini 2.5 для нових ключів закрито** (`404 … no longer available to new users`). **`gemma-4-31b-it`** на тому ж ключі й ендпоінті проходить цикл повністю → агент демо на Gemma. Побічний ефект: Gemma кладе `<thought>…</thought>` у текст відповіді.
- **Collector демо (ліміт 400Mi) відкидав трейси.** `memory_limiter` повертав `503`, і спани агента не доходили **до жодного** бекенду — видно лише як `Service Unavailable` у лозі самого агента. Причина — 5 експортерів, два з яких (`opensearch`, `otlp_http/prometheus`) ведуть у вимкнені бекенди і тримають черги. Ліміт піднято до 1Gi патчем.
- **MLflow на свіжому PVC має лише `Default` (0)**, а міст шле в захардкоджені id `2`/`3` → 404 на кожен експорт. Експерименти створено в порядку, що збігся з хардкодом: `1 lab7-placeholder · 2 triage-core · 3 otel-demo · 4 kagent`. Для kagent додано маршрут у міст.
- **Чотири HelmRelease впали на 5-хвилинному таймауті Helm** (kagent, MLflow, Phoenix, otel-demo) — образи тягнулись довше, при цьому навантаження були здорові. Лікується `reconcile.fluxcd.io/resetAt`.
- **DaemonSet collector'а демо — `otel-collector-agent`** (а Service — `otel-collector`). `secrets.sh` спершу перезапускав неіснуючий `otel-collector`, тож collector тримав порожній ключ Phoenix → `Unauthenticated`. Виправлено.
- **API Jaeger** — під `/jaeger/ui/api/...` (не `/api/`). `limit=1` **не гарантує найновіший** трейс — фільтрувати за часом старту.
- Phoenix REST `/v1/projects/{p}/spans` не фільтрує за `trace_id`; точковий пошук — GraphQL `Project.trace(traceId)`.

### 2026-10-02 — kagent ✅ (агент і A2A-делегування)

Агенти: [`manifests/agent-lab7-k8s.yaml`](manifests/agent-lab7-k8s.yaml) — `lab7-k8s-agent` (5 read-only тулів kagent-tool-server) і `lab7-orchestrator` (без тулів, делегує першому). ModelConfig: [`manifests/modelconfig-gemini-openai.yaml`](manifests/modelconfig-gemini-openai.yaml) — `gemini-openai-compat` і `gemma-openai-compat`, адаптер **OpenAI** на ендпоінті Gemini.

| Трейс | Jaeger | MLflow (exp 4) | Phoenix |
|---|---|---|---|
| `e9df1c7a…` — один агент, 1 тул | 8 спанів | `OK`, 3,678 с, **1895** токенів | 8 спанів; 1050 + 845 = 1895 по LLM-спанах |
| `65e49c8d…` — оркестратор → субагент, 3 тули | 20 спанів, 3 сервіси | `OK`, 13,872 с, **21626** токенів | 20 спанів; оркестратор 686, субагент — решта (сума 21626) |

Що зʼясувалось:
- **kagent на `gemini-3.6-flash` проходить цикл тулів** — його Go-адаптер OpenAI, на відміну від `langchain_openai` в агенті демо, не ламається на `thought_signature`. Gemma для kagent не знадобилась.
- **Промпт і відповідь є у спанах** (`generate_content …`) без `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT` — адаптер OpenAI пише їх за замовчуванням.
- **Контекст трейсу переживає A2A-перехід**: один трейс крізь контролер, оркестратор і субагента; делегування видно як `execute_tool kagent__NS__lab7_k8s_agent`.
- **Але MCP-виклик його розриває**: `kagent-tools` пише `mcp.tool.k8s_get_resources` в **окремий** трейс — агентський `execute_tool` і реальне виконання тула в різних трейсах.
- **Контролер kagent шумить**: на один запит ~18 односпанових трейсів (`POST /api/tasks`, `/api/sessions/…/events`). У MLflow вони лягають в exp 4 поруч з агентськими — 20 трейсів на кілька запитів.
- **Розбивку вартості по агентах дають MLflow і Phoenix** — токени на кожному LLM-спані (`mlflow.chat.tokenUsage` / `tokenCountTotal`) під своїм `invoke_agent`. У **списку** трейсів MLflow — одна сума; Jaeger — сирі теги без суми. ⚠️ Спершу я записав, що це вміє лише Phoenix — хибно, перевірено через спани MLflow (`ajax-api/2.0/mlflow/get-trace-artifact`).
- Побічно: агент сам знайшов, що под MLflow періодично провалює liveness/readiness-проби (`context deadline exceeded`) — відома нестабільність, див. коментарі `mlflow.yaml`.

### 2026-10-02 — завдання 1: інтерфейси переглянуто ✅

- **Jaeger не знайшов трейси за id** — бо їх уже немає: сховище **в памʼяті**, `MEMORY_MAX_TRACES=25000` (Deployment `otel-demo/jaeger`). Демо безперервно генерує трафік, і за кілька годин усі три зафіксовані трейси (`acc3ce13…`, `a9e94b31…`, `65e49c8d…`) витіснено — `GET /api/traces/<id>` → 404. Свіжі трейси в потрібних сервісах при цьому видно.
- **MLflow ті самі id тримає** (`OK` / `ERROR` / `OK`) — SQLite на PVC. Phoenix — Postgres на PVC.
- Висновок для порівняння: у цій конфігурації Jaeger — **оперативний** інструмент («що відбувається зараз»), а не архів; відтворити розбір конкретного LLM-запиту через кілька годин можна лише в MLflow чи Phoenix. Це властивість **сховища** (in-memory за замовчуванням у демо), а не Jaeger як такого — з Badger/Elasticsearch/Cassandra він би зберігав.
- Практично: для завдання 2 id трейсів фіксувати **одразу** і робити знімки Jaeger під час прогону.

### 2026-10-02 — завдання 2: серія запитів ✅

Скрипт [`run-series.sh`](run-series.sh): 8 запитів до агента демо + 4 до kagent (3 до `lab7-k8s-agent`, 1 через `lab7-orchestrator`); id трейсу береться з Jaeger **одразу** (він in-memory), потім ті самі id — з MLflow і Phoenix.

| Прогін | Результат |
|---|---|
| [`results/series-20261002T101017Z-lossy.md`](results/series-20261002T101017Z-lossy.md) | collector 1Gi: 11/12 трейсів, у 5 **немає кореня**, 6 пакетів спанів втрачено агентом |
| [`results/series-20261002T102124Z.md`](results/series-20261002T102124Z.md) | collector 2Gi: **12/12**, корінь у всіх, MLflow `OK` у всіх, **0 втрат** |

У чистому прогоні по всіх 12 трейсах **кількість спанів (Jaeger = Phoenix) і сума токенів (Jaeger = MLflow = Phoenix) збігаються точно** — бекенди отримали однакові дані, різниця лише в поданні.

Що показали прогони:
- **Неповний трейс кожен показує по-своєму.** MLflow тримає його `IN_PROGRESS` з тривалістю лише отриманої частини — видно одразу, що щось не так. Jaeger і Phoenix показують дерево без кореня і нічим цього не позначають.
- **Помилка тула (k3, неіснуючий под):** Jaeger — `error=true` + текст помилки на двох спанах; Phoenix — `kind=tool, status=ERROR`; MLflow — у списку трейс `OK` (корінь успішний, агент коректно відповів «пода немає»), але **всередині** обидва спани `STATUS_CODE_ERROR` з тим самим текстом помилки.
- **Вартість шляху з помилкою:** k3 (пода немає) — 6 LLM-викликів, 25 199 токенів; k1 (звичайне питання) — 2 виклики, 2 012. Видно лише через токени на рівні трейсу/спанів.
- **Gemma «думає вголос»:** у відповідях d2–d4, d8 — міркування замість відповіді (`Looking through the results…`), d8 так і не додав товар у кошик (просить `user_id`). Для o11y це плюс: міркування видно в `gen_ai.output.messages`.
- Побічно: k2 знайшов `Unhealthy` події на подах `otel-collector-agent` — проби під час перезапусків з новим лімітом.

### Далі

- [x] Завдання 1 — інтерфейси переглянуто (див. вище).
- [x] kagent — агент і A2A-трейс у трьох бекендах (див. вище).
- [x] Завдання 2 — серія запитів (див. вище).
- [x] Завдання 3 — порівняння і рішення: [`ADR-o11y-genai.md`](ADR-o11y-genai.md).

---

## Що вже є в гілці

| Компонент | Версія | Файл | Що отримує зараз |
|---|---|---|---|
| OpenTelemetry Demo (Astronomy Shop) | chart `0.41.2`, demo `3.0.0` | `releases/opentelemetry-demo.yaml` | власний collector → `debug`, `span_metrics`, міст у MLflow |
| ↳ компонент `agent` (чатбот `/chatbot/`) | — | у чарті | LangGraph + Traceloop → collector демо по OTLP/HTTP `:4318` |
| MLflow | chart `0.1.0` | `releases/mlflow.yaml` | OTLP/HTTP `/v1/traces`, SQLite на PVC |
| Міст-collector для MLflow | collector `0.173.1` | `releases/mlflow-otel-collector.yaml` | gRPC `:4317` → роутинг → MLflow: `triage-core` → exp `2`, `otel-demo` → exp `3` |
| Phoenix | chart `12.0.14` | `releases/phoenix.yaml` | OTLP gRPC `:4317`, лише спани `agentgateway-llm` |
| agentgateway-llm | — | `releases/agentgateway-llm.yaml` | проксі до Gemini, спани з GenAI semconv → Phoenix |
| kagent | `0.10.1` | `releases/kagent.yaml` | **трейсинг не налаштований** |
| triage-core | — | `releases/triage-core.yaml` | спани → міст → MLflow exp `2` |

### Поточна топологія трейсів

```
Astronomy Shop agent ──OTLP/HTTP──► otel-demo collector ──┬─► otlp_grpc/jaeger   (бекенд вимкнено → помилки в лозі)
  (USE_VCR=True: без LLM)                                  ├─► debug, span_metrics
                                                           └─► mlflow-bridge ─► MLflow exp 3

triage-core ───────────OTLP/gRPC──► mlflow-bridge ─────────► MLflow exp 2

agentgateway-llm ──────OTLP/gRPC──────────────────────────► Phoenix

kagent агенти ─────────────────────────────────────────────► (нікуди)
```

### Чотири проблеми, які блокують порівняння

1. **Стандартного OTel UI немає.** У `opentelemetry-demo.yaml` вимкнено `jaeger`, `prometheus`, `grafana`, `opensearch` (заради памʼяті на KinD). `/jaeger/ui/` не працює.
2. **Кожен бекенд бачить різне джерело.** MLflow — Astronomy Shop і triage-core, Phoenix — лише шлюз. Порівнювати три UI на різних даних не можна: потрібен **fan-out однакових спанів у всі три**.
3. **Astronomy Shop agent не ходить у LLM.** `USE_VCR=True` програє записані касети (`agent-fixtures/azure_gpt-5.5_cassette.yaml`). Трейси будуть, але без реального виклику моделі, токенів і латентності.
4. **kagent не експортує трейсів узагалі** — в `kagent.yaml` немає блоку `otel`.

### Ще одна пастка: `make run` розгортає НЕ файли `releases/` з диска

`bootstrap/variables.tf` тягне **готовий upstream-артефакт**:

```
oci_registry      = "oci://ghcr.io/den-vasyliev/abox"
releases_artifact = "releases-otel-demo"
```

Правки у `releases/` на диску **не потраплять у кластер** — Flux читає артефакт з GHCR, а не робочу копію. Ручний `kubectl edit` HelmRelease Flux відкотить при наступній реконсиляції.

Але сам bootstrap (`bootstrap/flux.tf`) виконується **локально** через `tofu apply` — і саме в ньому визначено Kustomization'и `releases-crds` і `releases`, що застосовують артефакт. Тому всі зміни лаби робляться **патчами в цих Kustomization'ах** поверх upstream-артефакту. Нічого не публікується, усе локально (фаза 1).

---

## Фаза 0 — підготовка WSL

- [x] `.wslconfig`: **24 ГБ / 16 CPU** — вже налаштовано. Демо (~25 подів) + MLflow (ліміт `2Gi`) + Phoenix + Postgres + kagent + Neo4j + Qdrant + Jaeger (~600Mi) мають вміститись, особливо після розвантаження з п.2.4. Заміряти фактичне споживання (`kubectl top nodes`) після розгортання.
- [x] Docker у WSL працює: нативний Docker `29.8.1` в Ubuntu 22.04 (не Docker Desktop), 16 CPU / ~23 ГБ, користувач `alex` у групі `docker`.
- [x] Репо — **одна копія** на Windows, `make` запускається з `/mnt/c/Users/sasha/My Projects/AlexPokatilov/harness/abox_harness`. Другий клон у `~/` не потрібен: tofu читає кілька файлів, KinD нічого з репо не монтує, тож повільний I/O `/mnt/c` тут не відчутний, а правки з IDE одразу видно у WSL. Закінчення рядків — LF (`core.autocrlf=false`), bash-скрипти не ламаються.
- [x] `make tools` + окремо `flux` і `jq` (потрібні для `flux build --dry-run` і команд з TODO): OpenTofu `1.13.1`, kind `v0.33.0`, k9s `v0.51.0`, flux `v2.9.6`, kubectl `v1.35.9`, helm `v4.3.0`, jq `1.6`. k9s ставиться в `~/.local/bin` — у новому терміналі PATH підхопиться сам.
- [x] `make run` перевстановлює OpenTofu через `sudo`. Тут **sudo без пароля**, тож не зависне — але запускати однаково краще в інтерактивному терміналі Ubuntu, щоб бачити хід (~10-15 хв).
- [x] Перед `make run` переконатись, що немає напівзнищеного кластера (ноди KinD живі, а стан OpenTofu порожній — тоді `tofu apply` падає з `already exists`):
  ```bash
  kind get clusters                    # abox є?
  (cd bootstrap && tofu state list)    # ...а стан порожній?
  kind delete cluster --name abox      # тоді прибрати вручну
  ```
- [ ] `make fix-egress` у WSL не потрібен (проблема nested Docker у Codespaces). `make fix-docker-acl` — лише якщо non-root образи падають на правах до `/tmp`.
- [ ] Kubeconfig для Windows-інструментів (Lens, `kubectl.exe`) перевипускати **після кожного створення кластера** — порт API-сервера щоразу новий:
  ```bash
  kind get kubeconfig --name abox > /mnt/c/Users/<user>/.kube/abox.config
  ```

## Фаза 1 — локальні патчі поверх upstream-артефакту

Без публікації артефакту, без GHCR і CI. Цикл правки — `make apply` (кілька секунд) замість тегу й очікування CI.

### 1.1 Зафіксувати тег upstream ✅

- [x] `bootstrap/flux.tf` → `ResourceSetInputProvider releases-image`: `semver: ">=0.0.0"` → **`semver: "=0.11.33"`** (з коментарем чому).

Навіщо: RSIP кожні 5 хв бере найновіший тег. Якщо автор опублікує нову версію зі зміненою структурою, патчі мовчки перестануть лягати, а кластер перезапустить поди посеред замірів.

Чому саме `0.11.33`: це тег **HEAD гілки** (`ce50380`, `git describe` → `v0.11.33`). Отже локальний `releases/` — **точне дзеркало** того, що розгорнеться, і патчі пишуться по живих файлах. У GHCR є новіші `0.11.34–0.11.36`, але вони лише додають `triage-ui` і `graph-triage` (які ми однаково прибираємо), а їхні коміти не належать жодній гілці.

### 1.2 Патчі в окремих файлах ✅

- [x] `lab7/patches/crds.yaml` — 3 патчі для Kustomization `releases-crds` (ngrok).
- [x] `lab7/patches/releases.yaml` — 23 патчі для Kustomization `releases` (споживачі ngrok, triage, xray-memory, llm-d). Згенеровано з `releases/` тегу `v0.11.33`.
- [x] Підключено в `bootstrap/flux.tf` — по одному рядку в кожну Kustomization ResourceSet:
  ```hcl
  patches: ${jsonencode(yamldecode(file("${path.module}/../lab7/patches/releases.yaml")))}
  ```

Чому `jsonencode(yamldecode(...))`, а не вставка YAML з `indent()`:
- список вставляється **одним рядком JSON** — це валідний YAML flow style, тож відступи в heredoc підбирати не треба;
- `yamldecode` валить `tofu plan`, якщо файл патчів зіпсований — помилка ловиться до кластера;
- вміст `file()` **не інтерполюється** HCL, тож `${env:PHOENIX_API_KEY}` у патчах collector'а доживе як є (у самому heredoc його довелося б писати як `$${...}`);
- ResourceSet має власний шаблонізатор з роздільниками `<< >>` — у патчах їх немає, а `jsonencode` однаково екранує `<`/`>` у `<`/`>`.

### 1.3 Формат патчів

Flux `Kustomization.spec.patches` — список `{target, patch}`, застосовується **після** збірки артефакту.

**Видалити обʼєкт** (перевірено: працює й для CRD-типів — HelmRelease, OCIRepository, Domain, InferenceObjective…):
```yaml
- target:
    kind: HelmRelease
    name: ngrok-operator
    namespace: ngrok-operator
  patch: |
    $patch: delete
    apiVersion: helm.toolkit.fluxcd.io/v2
    kind: HelmRelease
    metadata:
      name: ngrok-operator
      namespace: ngrok-operator
```

**Змінити values HelmRelease:**
```yaml
- target:
    kind: HelmRelease
    name: opentelemetry-demo
  patch: |
    apiVersion: helm.toolkit.fluxcd.io/v2
    kind: HelmRelease
    metadata:
      name: opentelemetry-demo
      namespace: otel-demo
    spec:
      values:
        jaeger:
          enabled: true
```

⚠️ HelmRelease — це CRD, тож Kustomize застосовує до нього **merge-патч, а він замінює списки цілком**. Щоб додати один експортер у пайплайн, треба вказати **весь** список `exporters`. Мапи (`values.jaeger`, `config.exporters`) мерджаться нормально.

### 1.4 Перевіряти до застосування

- [x] **`bash lab7/check-patches.sh`** (у WSL) — офлайн, без кластера: збирає обидві Kustomization'и через `flux build --dry-run` з патчами і без, показує, які обʼєкти зникли, і перевіряє, що `Namespace flux-system` вцілів. `render` — повний відрендерений YAML.

  Поточний результат:
  ```
  === releases-crds: 13 → 10 objects ===   (- ngrok: HelmRelease, HelmRepository, Namespace)
  === releases: 63 → 40 objects ===        (- 23 обʼєкти: ngrok-споживачі, triage, xray-memory, llm-d)
  === guard: flux-system Namespace must survive ===
    ✓ present
  ```
  ⚠️ Скрипт збирає з **локального** `releases/` — валідний, поки checkout = тег, на якому зафіксовано RSIP.
- [x] `tofu init` + `tofu validate` + `tofu plan` у `bootstrap/`: `Plan: 6 to add` (кластера ще немає), RSIP з `semver: =0.11.33`, у `yaml_body` ResourceSet — `patches` з 3 і 23 записами, `$patch: delete` на місці.
- [ ] Застосування — у фазі 4 (`make run` створить кластер уже з патчами). Подальші правки патчів — **`make apply`**: ResourceSet оновить Kustomization'и, Flux перезбере релізи.

## Фаза 2 — що саме патчити

Усе нижче — патчі в `lab7/patches/*.yaml` (фаза 1). Файли в `releases/` **не редагуються**: вони лише дзеркало артефакту `0.11.33`, по якому зручно писати патчі.

### 2.1 Повернути стандартний OTel UI (Jaeger) ✅

- [x] HelmRelease `otel-demo/opentelemetry-demo`: `values.jaeger.enabled: true`. Експортер `otlp_grpc/jaeger` уже в пайплайні — бекенд знову зʼявиться, помилки зʼєднання в лозі зникнуть.
- [x] Prometheus/Grafana/OpenSearch лишити вимкненими — для трейсів не потрібні.

### 2.2 Fan-out: однакові спани у всі три бекенди

**Спершу обрати топологію** і записати вибір у порівняння — від неї залежить, наскільки «однакові» спани отримують бекенди:

| | Експортер Phoenix у collector демо | Окремий fan-out collector |
|---|---|---|
| Шлях | агент → `otel-collector.otel-demo` → Jaeger + MLflow + Phoenix | агент → fan-out → (collector демо → Jaeger), (міст → MLflow), Phoenix напряму |
| Обробка | **однакова** для всіх трьох (`gen_ai_normalizer`, `transform` демо) | різна: Jaeger отримує нормалізовані спани, Phoenix — сирі |
| Плюс | рівніше порівняння | Phoenix бачить вихідну інструментацію без змін |
| Зміна | один експортер у патчі `opentelemetry-demo` | новий Deployment + перенаправлення агента |

Рекомендую перший — порівнюються інструменти, а не різна обробка. Другий варіант — як контрольний, якщо Phoenix погано читає нормалізовані атрибути.

- [x] **Astronomy Shop:** патч HelmRelease `opentelemetry-demo` → `values.opentelemetry-collector.config`: додати експортер у Phoenix і вписати його в `service.pipelines.traces.exporters` — **повним списком** (merge-патч замінює списки): `[otlp_grpc/jaeger, debug, span_metrics, otlp_grpc/mlflow-bridge, otlp_grpc/phoenix]`. Експортер:
  ```yaml
  otlp_grpc/phoenix:
    endpoint: phoenix-svc.phoenix.svc.cluster.local:4317
    tls:
      insecure: true
    headers:
      authorization: "Bearer ${env:PHOENIX_API_KEY}"
  ```
  **Phoenix — єдиний із трьох, хто вимагає автентифікацію на прийомі.** Без заголовка кожен експорт отримує `rpc error: code = Unauthenticated`, і помилку видно **лише в лозі collector'а** — у самому Phoenix просто порожньо. `PHOENIX_API_KEY` — з Secret через `extraEnvs` collector'а (див. фазу 3), не літералом.
  ⚠️ Не використовувати `key: null` для видалення експортерів — у цьому umbrella-чарті null потрапляє в ConfigMap буквально і ламає старт collector'а (описано в коментарі файлу).
- [ ] ⏳ **`agentgateway-llm` → Phoenix** (відкладено разом з варіантом А) теж налаштований **без заголовка** автентифікації — найімовірніше, Phoenix відкидає і ці спани, тобто зараз не отримує нічого. Перевірити лог шлюзу і чи підтримує `frontendPolicies.tracing` заголовки; без цього шар спанів шлюзу для порівняння втрачено.
- [x] Service collector'а демо — **`otel-collector`** (чарт ставить усім компонентам `OTEL_COLLECTOR_NAME=otel-collector`, і `TRACELOOP_BASE_URL` агента будується з неї). Тож агента можна перенаправити однією змінною — `OTEL_COLLECTOR_NAME`.
- [x] **kagent:** трейсинг вмикається значенням чарту `otel.tracing.enabled`. Чарт рендерить його в ConfigMap **`kagent-controller`**, а контролер копіює ключі `OTEL_*` з неї в Deployment кожного агента. Патч HelmRelease `kagent/kagent` → `values` (⚠️ точну форму звірити з `helm show values oci://ghcr.io/kagent-dev/kagent/helm/kagent --version 0.10.1`):
  ```yaml
  otel:
    tracing:
      enabled: true
      exporter:
        otlp:
          endpoint: http://otel-collector.otel-demo.svc.cluster.local:4317
          insecure: true
  ```
  У ConfigMap мають зʼявитись `OTEL_TRACING_ENABLED=true`, `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`, `_INSECURE`, `_PROTOCOL=grpc`. Додати `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=true` — саме він вмикає запис промптів і відповідей у спани.
  - ❌ **Не працює:** `spec.declarative.deployment.env` в Agent CR. Контролер дописує свій `OTEL_TRACING_ENABLED=false` **після** користувацького, а Kubernetes бере останнє значення з однаковим імʼям. Патч Deployment напряму контролер одразу відкочує.
  - ❌ **Не довговічно:** ручний патч ConfigMap `kagent-controller` + `rollout restart deploy/kagent-controller`. Працює, але ConfigMap під Helm — зникне при наступному апгрейді чарту. Довговічно — лише патчем values HelmRelease.
  - Після зміни — `rollout restart deploy/kagent-controller`: агенти перерендеряться.
- [x] **`kagent-tools`** за замовчуванням шле на `http://host.docker.internal:4317` — адреса з docker-compose, з пода не резолвиться. Перенаправити на `otel-collector.otel-demo` теж через values.
- [x] Форма ключів звірена з чартом kagent `0.10.1` (`helm show values`, `templates/controller-configmap.yaml`): `otel.tracing.exporter.otlp.{endpoint,protocol,insecure,timeout}`. Порожній `endpoint` → ключі `OTEL_EXPORTER_OTLP_TRACES_*` у ConfigMap **не рендеряться взагалі**.
- [x] ⚠️ `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT` у шаблоні ConfigMap **немає**, а в `controller.agentDeployment` немає поля для env агентів — через values чарту його не задати. Перевірити на першому трейсі агента kagent, чи промпт/відповідь потрапляють у спан і без нього.
- [ ] ⚠️ **Провайдер `Gemini` у kagent 0.10.1 не пише зміст у спани.** Лише адаптери OpenAI, Anthropic, Bedrock і Ollama викликають `telemetry.SetLLMRequestAttributes` / `SetLLMResponseAttributes`. Спани через провайдера Gemini матимуть токени, але **без промпту й відповіді** — `CAPTURE_MESSAGE_CONTENT` на цей шлях не впливає. Для порівняння потрібен ModelConfig з адаптером OpenAI на OpenAI-сумісному ендпоінті Gemini (той самий ключ):
  ```yaml
  apiVersion: kagent.dev/v1alpha2
  kind: ModelConfig
  metadata:
    name: gemini-openai-compat
    namespace: kagent
  spec:
    provider: OpenAI
    model: gemini-3.5-flash
    apiKeySecret: <secret з ключем Gemini>
    apiKeySecretKey: GEMINI_API_KEY
    openAI:
      baseUrl: https://generativelanguage.googleapis.com/v1beta/openai/
  ```
  ⚠️ На цьому шляху, імовірно, зʼявиться та сама проблема `thought_signature` з тулами, що й у демо (п.2.3).
- [ ] ⏳ **Маршрутизація kagent у MLflow** (у фазі 4 — потрібен id експерименту, який існує лише після старту MLflow). Міст має свідомо **без catch-all**: роутить лише `service.name == "triage-core"` і `k8s.namespace.name == "otel-demo"`, усе інше — тихий drop (видно лише в `debug`). Для kagent:
  - створити експеримент: `POST /api/2.0/mlflow/experiments/create` з `{"name":"kagent"}` → отримати id;
  - додати в `mlflow-otel-collector.yaml` маршрут `k8s.namespace.name == "kagent"` + окремий `otlp_http/mlflow-kagent` з цим id у `x-mlflow-experiment-id`.

  ⚠️ Id експериментів не детерміновані: при знищенні PVC MLflow (`make down`) їх треба створити заново і оновити хардкод.

### 2.3 Astronomy Shop agent — реальний Gemini замість касет

Агент говорить у форматі OpenAI chat-completions (з касети: `"object": "chat.completion"`, `tools`, `tool_calls`), тож Gemini підключається через OpenAI-сумісний ендпоінт.

- [x] Через `components.agent.envOverrides` (мерджиться по імені, а не замінює весь `env`):
  - `USE_VCR` → `"False"`
  - `LLM_BASE_URL`, `LLM_MODEL`, `API_KEY` — див. варіанти нижче.
- [ ] ⚠️ **`gemini-2.5-flash` знято з обігу** — API радить `gemini-3.6-flash`. Перевірити актуальний список: `curl "https://generativelanguage.googleapis.com/v1beta/models?key=$KEY" | jq -r '.models[].name'`.
- [ ] ⏳ **Варіант А — через `agentgateway-llm`** (відкладено — стартуємо з Б):
  ⚠️ **`agentgateway-llm` — не HelmRelease.** Це ConfigMap-«зерно» `agentgateway-llm-seed` з усім конфігом **одним рядком** `config.yaml` + PVC `agentgateway-llm-config` (SQLite). Патч означає заміну **всього** `config.yaml` (merge-патч ConfigMap замінює ключ `data` цілком). Ще треба зʼясувати, чи Deployment перечитує зерно на кожному старті, чи лише копіює його в порожній PVC — інакше зміна моделі не дійде до шлюзу без очистки PVC.
  - `LLM_BASE_URL=http://agentgateway-llm.agentgateway-system.svc.cluster.local/v1`
  - `LLM_MODEL` = модель з `allowedModels`
  - `API_KEY` = `TRIAGE_LLM_KEY` (віртуальний ключ шлюзу, **не** ключ Gemini)

  ⚠️ Конфіг шлюзу (`agentgateway-llm.yaml`) прописує **лише `gemini-2.5-flash`** — у `modelCatalog`, `allowedModels` і `models[].name/model`. Без заміни на `gemini-3.6-flash` патчем HelmRelease `agentgateway-llm` кожен виклик через шлюз падатиме. ⚠️ `models` і `allowedModels` — списки: у патчі вказувати повністю. Ціни в `modelCatalog` теж оновити під нову модель, інакше вартість у шлюзі буде хибною.

  Плюси після заміни: справжній ключ Gemini живе в одному Secret; шлюз додає **другий шар спанів** (GenAI semconv) у Phoenix і рахує вартість. Це прямо корисно для п.3 — порівняти інструментацію на рівні застосунку (Traceloop) і на рівні шлюзу.
- [x] **Варіант Б — напряму в Gemini** (працює без змін шлюзу, стартувати з нього):
  - `LLM_BASE_URL=https://generativelanguage.googleapis.com/v1beta/openai/`
  - `LLM_MODEL=gemma-4-31b-it` — **не Gemini 3**: див. «Хід виконання»
  - `API_KEY` = ключ Google AI Studio
- [ ] ⚠️ **Тул-виклики на Gemini 3, імовірно, падатимуть.** Gemini 3 вимагає `thought_signature` на викликах тулів, а OpenAI-подібний клієнт демо його не передає. Очікування: прості питання — `OK`, питання з тулами — `ERROR`. Це гіпотеза — підтвердити або спростувати за атрибутами exception на спані `ChatLLM.chat` (Jaeger / Phoenix). Якщо підтвердиться — це сам по собі результат для порівняння: який із трьох UI швидше показує **причину** помилки LLM.
- [x] Формат `LLM_MODEL` / `LLM_BASE_URL` — **зʼясовано** в `src/agent/src/agents/llm.py` (демо `3.0.0`): `ChatLLM` наслідує `langchain_openai.ChatOpenAI`, модель передається **як є, без префікса провайдера**; `LLM_BASE_URL` іде в `openai_api_base`, OpenAI SDK сам дописує `/chat/completions`; ключ читається з `API_KEY`. Тож `LLM_MODEL=gemini-3.6-flash` і `LLM_BASE_URL=…/v1beta/openai/` — правильні.
- [x] ⚠️ **`API_KEY` не писати літералом у values** — патч лежить у `lab7/patches/`, тобто в git. Використати `valueFrom.secretKeyRef` в `envOverrides` (⚠️ перевірити, що хелпер `otel-demo.envOverriden` пропускає `valueFrom`).
- [ ] За бажанням — `MCP_ENABLED: "True"`: агент отримає MCP-тули, і в трейсах зʼявляться спани викликів тулів (цікаво для порівняння).

### 2.4 Розвантажити кластер (обовʼязково) ✅ — патчі в `lab7/patches/`

Не лише заради памʼяті — без цього платформа не стане Ready.

Обʼєкти видаляються патчами `$patch: delete` (формат — п.1.3). Перелік знято з файлів `releases/` тегу `0.11.33`.

- [x] **`ngrok-operator` блокує все.** `releases-crds` має `wait: true` — чекає Ready **кожного** застосованого обʼєкта, включно з HelmRelease ngrok. Без Secret `ngrok-operator-credentials` (API key + authtoken ngrok) він вічно `InProgress`, а `releases` залежить від `releases-crds` — і **не стартує взагалі**: ні kagent, ні Phoenix, ні otel-demo. Для лаби ngrok не потрібен.

  `lab7/patches/crds.yaml`:

  | Kind | Namespace / Name |
  |---|---|
  | HelmRelease | `ngrok-operator/ngrok-operator` |
  | HelmRepository | `flux-system/ngrok` |
  | Namespace | `ngrok-operator` |

  `lab7/patches/releases.yaml` — ресурси ngrok, яким без CRD нікуди застосуватись (інакше `no matches for kind`):

  | Kind | Namespace / Name |
  |---|---|
  | Domain | `agentgateway-system/triageagent-ngrok-dev` |
  | AgentEndpoint | `agentgateway-system/triageagent-ngrok-dev` |

- [x] **triage і xray-memory** тягнуть приватні пакети GHCR і ключ знімка автора — лишаться червоними назавжди, і `releases` ніколи не буде Ready. `lab7/patches/releases.yaml`:

  | Kind | Namespace / Name | Звідки |
  |---|---|---|
  | Namespace | `triage` | `triage.yaml` |
  | ServiceAccount | `triage/default` | `triage.yaml` |
  | OCIRepository | `flux-system/triage-agent` | `triage-agent.yaml` |
  | HelmRelease | `triage/triage-agent` | `triage-agent.yaml` |
  | OCIRepository | `flux-system/triage-core` | `triage-core.yaml` |
  | HelmRelease | `triage/triage-core` | `triage-core.yaml` |
  | OCIRepository | `triage/pages-triage` | `pages-triage.yaml` |
  | Kustomization | `triage/pages-triage` | `pages-triage.yaml` |
  | OCIRepository | `triage/graph-otel-demo` | `graph-otel-demo.yaml` |
  | Kustomization | `triage/graph-otel-demo` | `graph-otel-demo.yaml` |
  | Namespace | `xray-memory` | `xray-memory.yaml` |
  | OCIRepository | `flux-system/xray-memory` | `xray-memory.yaml` |
  | HelmRelease | `xray-memory/xray-memory` | `xray-memory.yaml` |

  🔴 **`triage.yaml` оголошує ще й `Namespace flux-system`** (з анотацією тенанта). Його **НЕ видаляти** — патч `$patch: delete` на нього прибере namespace самого Flux. Таргет патча завжди з `name`, ніколи лише за `kind: Namespace`.

  `graph-otel-demo.yaml` за назвою схожий на частину демо, але це triage: живе в namespace `triage` і тягне приватний `triage-ghcr-pull`.

  ⚠️ Без triage-core міст MLflow лишиться без джерела для exp `2` — маршрут просто простоюватиме.

  Анотації `triageagent.dev/*` на namespace'ах `otel-demo` і `agentgateway-system` та віртуальний ключ `triage` у `agentgateway-llm` — нешкідливі, не чіпати.

- [x] **llm-d** — прибрано (не блокує, але звільняє памʼять і два великі образи, що перевищують таймаут Helm). `qdrant-mcp` ходить у `llama-cpp-embeddings`, не в llm-d. Прибрані обʼєкти:

  | Kind | Namespace / Name |
  |---|---|
  | Namespace | `llm-d` |
  | HelmRepository | `flux-system/llm-d-modelservice` |
  | OCIRepository | `flux-system/inferencepool` |
  | HelmRelease | `llm-d/llm-d-embedding`, `llm-d/llm-d-pool` |
  | Service | `llm-d/llm-d-embedding` |
  | InferenceObjective | `llm-d/nomic-embed-text` |
  | HTTPRoute | `llm-d/llm-d-embedding` |

- [ ] Після `make apply`: `flux get kustomizations` — `releases-crds` і `releases` **Ready**, без жодного з прибраних обʼєктів у `flux tree kustomization releases`.

## Фаза 3 — ключі (Secret'и, не git)

Ключі вводити через `read -s`, щоб не лишались в історії шелу. ⚠️ Вставляти **по одному рядку**: якщо вставити блоком, `read` забере наступний рядок як ввід, і Secret створиться з **порожніми значеннями** — Kubernetes прийме це без жодної помилки. Тому перевіряти довжину перед створенням.

- [ ] **`agentgateway-llm-secrets`** — без нього `releases` не стає Ready навіть для варіанту Б. `TRIAGE_LLM_KEY` — не зовнішній ключ, а той, що клієнти показують шлюзу, тож генерується:
  ```bash
  read -s -p "Gemini key: " GEMINI_KEY; echo
  echo "len=${#GEMINI_KEY}"                       # має бути > 0
  kubectl -n agentgateway-system create secret generic agentgateway-llm-secrets \
    --from-literal=GEMINI_API_KEY="$GEMINI_KEY" \
    --from-literal=TRIAGE_LLM_KEY="$(openssl rand -hex 24)"
  unset GEMINI_KEY
  ```
- [ ] **Phoenix ingest key.** Створюється в UI Phoenix: Settings → API Keys → System key. **Показується один раз** — одразу в Secret у namespace collector'а:
  ```bash
  read -s -p "Phoenix key: " PX; echo; echo "len=${#PX}"
  kubectl -n otel-demo create secret generic phoenix-ingest --from-literal=api-key="$PX"
  unset PX
  ```
  Курка і яйце: ключ зʼявляється лише після розгортання Phoenix, тож collector демо стартує з порожнім `PHOENIX_API_KEY`, а після створення Secret — `rollout restart`. Посилання на Secret у `extraEnvs` зробити з `optional: true`, інакше collector не стартує до появи ключа.
- [ ] Секрет для Astronomy Shop agent у `otel-demo` (той самий `TRIAGE_LLM_KEY` для А або ключ Gemini для Б).
- [ ] Для kagent — Secret з ключем Gemini у `kagent` і `ModelConfig` `gemini-openai-compat` (п.2.2 — саме адаптер OpenAI, щоб спани мали зміст). Перевести на нього агента, якого трасуватимемо. Стоковий `default-model-config` = OpenAI з **плейсхолдером** ключа — агенти на ньому падають мовчки.
- [ ] Ключі не потрапляють у файли репо, історію шелу (`HISTCONTROL=ignorespace` + пробіл перед командою) чи скріншоти UI.

## Фаза 4 — розгортання і перевірка

- [ ] `make run` — з уже внесеними патчами і фіксацією тегу (фаза 1). Подальші правки патчів — `make apply`, без перестворення кластера.
- [ ] `flux get all -A` — усе `Ready`. Особливо `opentelemetry-demo`, `mlflow`, `otel-collector`, `phoenix`, `kagent`.
- [ ] Спани доходять до мосту: `kubectl -n mlflow logs deploy/otel-collector | grep -c Span` > 0.
- [ ] Немає тихих drop'ів: у тому ж лозі шукати спани з `k8s.namespace.name`, для яких немає маршруту.
- [ ] MLflow не в crash-loop: `kubectl -n mlflow get pod` — `RESTARTS` не росте під навантаженням демо. Гілка вже несе `--allowed-hosts` з DNS-імʼям Service (без нього міст отримує **HTTP 403**, і видно це **лише в лозі мосту**), `workers: 2` і probe timeout 5s через postRenderer. Якщо crash-loop повернеться — `workers: 1` і ще мʼякша проба (історія — у коментарях `mlflow.yaml`).
- [ ] Phoenix приймає: у лозі collector'а демо немає `Unauthenticated`.
- [ ] kagent шле: `kubectl -n kagent get cm kagent-controller -o yaml | grep OTEL_` → `OTEL_TRACING_ENABLED: "true"`; у Deployment агента — та сама змінна **одна**, без дубля з `false`.
- [ ] HelmRelease, у яких перший pull не вклався в таймаут, лишаються `Failed`, навіть коли поди вже здорові. Не чекати годину:
  ```bash
  T=$(date +%s)
  kubectl -n <ns> annotate helmrelease <name> --overwrite \
    reconcile.fluxcd.io/requestedAt="$T" reconcile.fluxcd.io/resetAt="$T"
  ```
- [ ] Якщо в кластері `lookup ... on 10.96.0.10:53: server misbehaving` (агенти втрачають модель, Flux — ghcr.io), а з WSL імена резолвляться — завис DNS-проксі Docker. Направити CoreDNS на публічні резолвери (зберегти бекап):
  ```bash
  kubectl -n kube-system get cm coredns -o yaml > /tmp/coredns-backup.yaml
  kubectl -n kube-system get cm coredns -o json \
    | jq '.data.Corefile |= sub("forward \\. /etc/resolv\\.conf"; "forward . 8.8.8.8 1.1.1.1")' \
    | kubectl apply -f -
  kubectl -n kube-system rollout restart deploy/coredns
  ```

### Доступ до UI

У WSL2 `localhost` прокидається у Windows, тож port-forward у WSL відкривається в браузері Windows.

| UI | Команда | URL |
|---|---|---|
| Astronomy Shop + чатбот + Jaeger | `kubectl -n otel-demo port-forward svc/frontend-proxy 8080:8080` | `localhost:8080`, `/chatbot/`, `/jaeger/ui/` |
| Locust (навантаження) | `kubectl -n otel-demo port-forward svc/load-generator 8089:8089` | `localhost:8089` |
| MLflow | `kubectl -n mlflow port-forward svc/mlflow-mlflow 5000:5000` | `localhost:5000` |
| Phoenix | `kubectl -n phoenix port-forward svc/phoenix-svc 6006:6006` | `localhost:6006` |
| kagent | через gateway або port-forward `svc/kagent-ui` | — |

⚠️ MLflow пускає лише хости з `--allowed-hosts` — `localhost` і `127.0.0.1` там є, інші імена дадуть `403 Invalid Host header`.

---

## Завдання 1 — ознайомлення з інтерфейсами

Для кожного UI зафіксувати (скріншот + 2-3 речення):

- [ ] **Jaeger (стандартний OTel):** пошук трейсу за сервісом/операцією, timeline спанів, атрибути спану, порівняння двох трейсів, граф залежностей сервісів.
- [ ] **MLflow:** Experiments → Traces; дерево спанів, вкладки Inputs/Outputs, теги, звʼязок трейсу з run/експериментом, оцінки (assessments/feedback).
- [ ] **Phoenix:** Projects → Traces; вид LLM-спану (промпт, відповідь, токени), Sessions, evals, Prompt Playground (відкрити спан у плейграунді й перезапустити).

## Завдання 2 — отримати трейси

Мінімум два джерела, щоб порівняння не залежало від одного типу інструментації:

- [ ] **Astronomy Shop agent** (обовʼязково — Traceloop, LangGraph, тул-виклики): 5-10 запитів у `/chatbot/` різної складності — простий («що є в магазині»), з тулами («знайди телескоп до $500»), з помилкою (неіснуючий товар). Запит з тулами, імовірно, впаде на `thought_signature` (п.2.3) — **не пропускати**: це готовий трейс з помилкою LLM для порівняння.
- [ ] **Агент kagent** (`k8s-agent` або свій retrieval-агент з lab4 на `gemini-openai-compat`): 3-5 запитів, щонайменше один з A2A-делегуванням — подивитись, як кожен UI показує трейс через межу агентів.
- [ ] ⚠️ Читати трейс **лише після його закриття**. Відкритий трейс у MLflow показує `state=IN_PROGRESS` і `duration=0s` — легко записати хибний замір. Почекати, поки стан стане `OK`/`ERROR`.
- [ ] **Voice-агент:** ⚠️ з ключами Gemini недоступний — шапка `agentgateway-llm.yaml` прямо каже, що Gemini Live (native audio) не проходить через шлюз, підтримується лише OpenAI Realtime. Зафіксувати як обмеження, а не пропускати мовчки.
- [ ] Один **однаковий трейс** знайти в усіх трьох UI (за `trace_id`) — база для порівняння.
- [ ] Фон: Locust у headless-режимі вимкнено (`LOCUST_HEADLESS=false`) — запускати навантаження вручну через UI на `:8089`, щоб бачити GenAI-трейси на фоні звичайного трафіку магазину.

## Завдання 3 — порівняння з погляду GenAI
> ✅ **Виконано** — заповнене порівняння, рішення й наслідки: [`ADR-o11y-genai.md`](ADR-o11y-genai.md). Таблиця нижче — вихідний план критеріїв; виміряні значення — в ADR.

Заповнити таблицю на **одних і тих самих трейсах**:

| Критерій | Jaeger (OTel) | MLflow | Phoenix |
|---|---|---|---|
| Промпт і відповідь видно без копання в атрибутах | | | |
| Токени (input/output) | | | |
| Вартість запиту | | | |
| Тул-виклики як окремі спани з аргументами | | | |
| Дерево агентного циклу (LangGraph-ноди) | | | |
| Трейс через межу A2A | | | |
| Сесії / розмова з кількох трейсів | | | |
| Оцінки (evals, LLM-as-judge, feedback) | | | |
| Prompt playground / replay | | | |
| Розуміння GenAI semconv (`gen_ai.*`) | | | |
| Типізація спанів (LLM / agent / tool / HTTP) | | | |
| Сума токенів і вартість на рівні трейсу | | | |
| Як видно причину помилки LLM | | | |
| Одиниця перегляду (спан / трейс / сесія) | | | |
| Автентифікація на прийомі | | | |
| Де видно, що прийом зламаний | | | |
| Звичайні (не-LLM) сервіси в тому ж трейсі | | | |
| Пошук і фільтрація за атрибутами | | | |
| Протоколи прийому (gRPC / HTTP) | | | |
| Вимоги до ресурсів у цьому кластері | | | |
| Зберігання (бекенд, персистентність) | in-memory, `MEMORY_MAX_TRACES=25000` — трейси витісняються за години | SQLite на PVC — зберігає | Postgres на PVC — зберігає |

Те, що вже відомо з репо і варто підтвердити або спростувати:

- [ ] MLflow приймає **лише OTLP/HTTP** (`/v1/traces`), gRPC — ні; потрібен міст-collector і заголовок `x-mlflow-experiment-id`. Phoenix і Jaeger приймають gRPC напряму.
- [ ] MLflow на SQLite і одному процесі нестабільний під навантаженням ~25-30 сервісів демо (історія з `workers`, OOMKill на 1Gi, probe timeout 1s — коментарі в `mlflow.yaml`).
- [ ] Jaeger показує все, але **не розуміє** GenAI: промпт/токени — сирі атрибути спану.
- [ ] Phoenix не отримує `service.name`-роутингу на проєкти без `projectName` — перевірити, в який проєкт лягають спани демо.
- [ ] Порівняти шар інструментації: Traceloop (у застосунку) проти agentgateway (на шлюзі) — що бачить кожен і чого не бачить.
- [ ] Jaeger має всі `gen_ai.usage.*_tokens` як теги, але **не може їх скласти** — не знає, який спан був викликом моделі. Перевірити, чи Phoenix рахує токени лише на LLM-спанах (на невдалому виклику — `tokens=0`, тобто вартість лише там, де вона була).
- [ ] **Не зупинятись на трейсах.** Порівняння трейсів не торкається того, заради чого MLflow і Phoenix існують. Окремо спробувати:
  - Phoenix: evals (LLM-as-judge на кількох трейсах), Prompt Playground — перезапуск промпту з LLM-спану;
  - MLflow: оцінки/feedback на трейсі, групування за експериментами, порівняння прогонів;
  - зафіксувати, де ці фічі потребують окремого ключа LLM для судді.
- [ ] Чого ця лаба не вимірює — записати чесно: один агент, кілька викликів, без пропускної здатності, retention і вартості на обсязі.

Результат оформити як **ADR** («яке o11y-рішення для GenAI-навантажень у abox і чому»): контекст, рішення, наслідки (плюси **і** мінуси), відкинуті альтернативи.

---

## Пауза без втрати даних

`make down` знищує ноди KinD **разом з усіма PV**: трейси Phoenix і MLflow, Qdrant, Neo4j, а також id експериментів MLflow. Щоб зупинити і повернутись до того самого стану — зупиняти контейнери:

```bash
# пауза
docker stop abox-worker abox-worker2 abox-control-plane
docker stop $(docker ps -q --filter name=kindccm)    # LB від cloud-provider-kind: stop, НЕ rm

# відновлення
docker start abox-control-plane abox-worker abox-worker2
docker start $(docker ps -aq --filter name=kindccm)
kubectl get nodes                                      # Ready за хвилину-дві
kubectl get pods -A | grep -vE 'Running|Completed'     # Unknown / ImagePullBackOff — видалити, Deployment перестворить
```

- Ноди мають restart policy `on-failure:1`: після краху піднімаються самі, після чистого `docker stop` — **ні**, лише явним `docker start`.
- Після перезавантаження Windows Docker Desktop сам не стартує — у WSL `docker` «не знайдено», доки його не запустити.
- На відновленні `make run` **не потрібен**. `make apply` — безпечний (перезастосує bootstrap разом із патчами і фіксацією тегу), але й без нього кластер піднімається в тому самому стані. **`make down` — ніколи**, якщо дані ще потрібні.

## Відкриті питання — перевірити до початку

- [x] Ключі `otel.tracing.*` у чарті kagent `0.10.1` — звірено; `kagent-tools` має власний блок `kagent-tools.otel`, патчиться окремо (п.2.2).
- [ ] Чи експортує Go-рантайм kagent (`runtime: go`) спани так само, як Python.
- [x] Формат `LLM_MODEL` / `LLM_BASE_URL` агента демо — без префікса, SDK дописує `/chat/completions` (п.2.3).
- [x] `envOverrides` пропускає `valueFrom`: хелпер `otel-demo.envOverriden` віддає записи цілими (`mustToJson`), перевірено в рендері (п.2.3).
- [ ] Чи підтримує `frontendPolicies.tracing` в agentgateway заголовки (для автентифікації в Phoenix).
- [x] `$patch: delete` для CRD-типів у Flux `spec.patches` — **працює** (перевірено `flux build --dry-run`, п.1.4).
- [x] ~~Відступ `indent()` у heredoc~~ — знято: патчі вставляються як `jsonencode(yamldecode(...))`, без відступів (п.1.2).
- [ ] Причина `ERROR`-трейсів на тул-викликах — `thought_signature` чи щось інше.
- [ ] Фактичне споживання памʼяті з увімкненим Jaeger (`kubectl top nodes`) — вміщається в 24 ГБ?

## Definition of done

- [x] Однаковий трейс Astronomy Shop agent з реальною моделлю видно в Jaeger, MLflow і Phoenix — модель **Gemma 4** на ключі Gemini (Gemini 3 з агентом демо несумісний, 2.5 закрито).
- [x] Трейси kagent у всіх трьох — один агент і A2A-делегування, на `gemini-3.6-flash`.
- [x] Інтерфейси переглянуто (завдання 1); нотатки — у «Хід виконання». Скріншоти — за бажанням.
- [x] Порівняння + ADR: [`ADR-o11y-genai.md`](ADR-o11y-genai.md).
- [x] Жодного ключа в git, зокрема в `lab7/patches/` (`git grep -i 'AIza'` порожній).
- [x] Нічого не опубліковано: артефакт — upstream `0.11.33`, усі зміни — локальні патчі.
