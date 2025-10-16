# Token Price Service

Production-ready сервис для обновления цен токенов, работающий на Kubernetes с автоматическим обновлением через CronJob каждые 5 минут.

## Что сделано по коду?

- Привел код к Clean Architecture
- Оптимизировал горячий путь под пагинацию и обновления цен

## Что сделано для production?

- Заполнил базу ВСЕМИ токенами которые существуют (~15 тыс. шт). Почему? Production - это значит нужны реальные данные в production-окружении + ценность для конечного юзера.
- Купил домен для тестового задания (dsavin.tech)
- Арендовал кластер Kubernetes (https://cloud.vk.com/)
- Настроил CI/CD - при релизе по тегу кластер подхватывает релиз и разворачивает у себя

Список токенов:
https://dsavin.tech/pricing/tokens?page=1&limit=10
(цены меняются каждую минуту)

Статус сервиса:
https://dsavin.tech/pricing/status

#### Состояние кластера

![Kubernetes ресурсы (namespace token-price-service)](kube.png)

## Быстрый старт

### Требования
- Node.js 18+ и npm
- Kubernetes кластер (минимум 1 worker node)
- kubectl настроен и подключен к кластеру
- ArgoCD установлен в кластере (для GitOps)
- Docker для локальной разработки

### Development (локальная разработка)
```bash
# Установка зависимостей
npm install

# Запуск зависимостей (Postgres + Kafka)
docker-compose up -d postgres kafka

# Миграции базы данных
npx prisma migrate dev
npx prisma generate

# Запуск приложения
npm run start:dev
```

### Production (развертывание в Kubernetes-кластере)

## Технологический стек

- Node.js + TypeScript + NestJS
- PostgreSQL + Prisma
- Kafka для messaging
- Zod для валидации
- Docker + Kubernetes
- OpenTelemetry для телеметрии
- Jest для тестирования

## Архитектура

Приложение использует Clean Architecture с разделением на слои:
- Domain Layer: сущности, Value Objects, доменные сервисы
- Application Layer: use cases, команды, обработчики
- Infrastructure Layer: репозитории, внешние сервисы, messaging
- Interface Layer: REST контроллеры, API endpoints

## Разработка

### Структура проекта

```
src/
├── app/                   # Конфигурация приложения
├── contexts/              # Bounded Contexts (DDD)
│   └── pricing/           # Pricing Context
│       ├── domain/        # Domain Layer
│       ├── application/   # Application Layer
│       ├── infrastructure/# Infrastructure Layer
│       └── interface/     # Interface Layer
├── shared/                # Shared Kernel
│   ├── domain/           # Shared Value Objects
│   ├── infrastructure/   # Shared Infrastructure
│   ├── kernel/           # Core Abstractions
│   └── utils/            # Utilities
└── services/             # Legacy Services
```

### Команды разработки

```bash
npm run build              # Сборка проекта
npm run start:dev          # Development режим
npm run start:prod         # Production режим
npm run lint               # Линтинг
npm run format             # Форматирование кода
npm run prisma:migrate     # Миграции БД
npm run prisma:studio      # Prisma Studio
```

### Добавление новых токенов

Схема Prisma уже готова для добавления новых токенов. Просто добавьте новую запись в таблицу `tokens`:

```sql
INSERT INTO tokens (
  contract_address, symbol, display_name, decimal_places,
  is_native_token, chain_id, is_system_protected,
  last_modified_by, display_priority, current_price
) VALUES (
  '\x1234...', 'NEW', 'New Token', 18,
  false, 'chain-id', false,
  'admin', 100, 0
);
```

### CI/CD Pipeline

Проект использует **GitHub Actions** для полностью автоматизированного CI/CD процесса.

#### Workflow: `.github/workflows/ci-cd.yml`

**Триггеры:**
- `pull_request` → `main` (игнорирует изменения в `gitops/**`)
- `push` тегов формата `v*.*.*`

**Этапы (Jobs):**

1. **test** - Запускается на PR и при создании тега
   - Устанавливает Node.js 18
   - Устанавливает зависимости (`npm ci`)
   - Запускает линтинг (`npm run lint`)
   - Запускает unit тесты (`npm run test`)
   - Запускает e2e тесты (`npm run test:e2e`)
   - Требует работающие Postgres и Kafka (через Docker services)

2. **build** - Запускается только для тегов после успешных тестов
   - Собирает Docker образ для `linux/amd64`
   - Публикует в GitHub Container Registry: `ghcr.io/uniwertz/token-price-service:v1.0.0`
   - Также создает тег `:latest`
   - Использует `docker buildx` для кросс-платформенной сборки

3. **security-scan** - Запускается после build
   - Сканирует Docker образ через **Trivy**
   - Проверяет уязвимости в зависимостях
   - Генерирует SARIF отчет

4. **gitops-update** - Запускается после security-scan
   - Обновляет версию образа в `gitops/overlays/production/deployment-patch.yaml`
   - **Создает Pull Request** с названием "🚀 Deploy v1.0.0 to production"
   - PR содержит описание изменений и версию образа
   - Использует action `peter-evans/create-pull-request@v6`
   - После мержа PR, ArgoCD автоматически синхронизирует изменения с кластером

#### Процесс релиза

```bash
# 1. Убедитесь что все изменения в main
git checkout main
git pull origin main

# 2. Создайте тег версии (следуя Semantic Versioning)
git tag v1.0.0
git push origin v1.0.0

# 3. GitHub Actions автоматически:
#    ✓ Запустит тесты
#    ✓ Соберет Docker образ
#    ✓ Опубликует в GHCR
#    ✓ Проверит безопасность
#    ✓ Создаст PR с обновлением production манифеста

# 4. Проверьте созданный PR и смержьте его
#    https://github.com/uniwertz/token-price-service/pulls

# 5. ArgoCD автоматически задеплоит новую версию в кластер
#    (если настроен syncPolicy.automated: true)

# 6. Проверьте статус деплоя
kubectl -n token-price-service get pods
kubectl -n token-price-service rollout status deploy/token-price-service
```

#### Мониторинг CI/CD

- **GitHub Actions**: `https://github.com/uniwertz/token-price-service/actions`
  - `CI/CD Pipeline` - тесты, сборка, деплой
  - `Price Updater` - автоматическое обновление цен каждые 5 минут
- **Pull Requests**: `https://github.com/uniwertz/token-price-service/pulls`
- **Container Registry**: `https://github.com/uniwertz/token-price-service/pkgs/container/token-price-service`
- **ArgoCD UI**: `kubectl -n argocd port-forward svc/argocd-server 8080:443`

#### Откат версии

Если нужно откатить деплой:

```bash
# Вариант 1: Через revert PR
git revert <commit-hash>
git push origin main

# Вариант 2: Создать новый тег с предыдущей версией кода
git tag -d v1.0.1  # удалить локально
git push origin :refs/tags/v1.0.1  # удалить на GitHub
git checkout v1.0.0  # вернуться к предыдущей версии
git tag v1.0.2  # создать новый тег
git push origin v1.0.2

# Вариант 3: Ручное изменение манифеста (не рекомендуется)
kubectl -n token-price-service set image deployment/token-price-service \
  token-price-service=ghcr.io/uniwertz/token-price-service:v1.0.0
```


### Ручная настройка кластера (первичная установка)

```bash
# 1. Создание секрета для GHCR (однократно)
kubectl -n token-price-service create secret docker-registry ghcr-cred \
  --docker-server=ghcr.io \
  --docker-username=uniwertz \
  --docker-password=$GITHUB_TOKEN \
  --docker-email=your-email@example.com

# 2. Создание секрета для Postgres
kubectl -n token-price-service create secret generic postgres-secret \
  --from-literal=password=postgres

# 3. Применение ArgoCD Application
kubectl apply -f gitops/argocd/application.yaml

# 4. ArgoCD автоматически развернет все ресурсы из gitops/overlays/production

# 5. Проверка статуса
kubectl -n token-price-service rollout status deploy/postgres
kubectl -n token-price-service rollout status deploy/kafka
kubectl -n token-price-service rollout status deploy/token-price-service
```


## Конфигурация

### Переменные окружения

| Переменная | Описание | По умолчанию |
|------------|----------|--------------|
| NODE_ENV | Окружение | development |
| PORT | Порт сервиса | 3000 |
| DATABASE_URL | URL базы данных | postgresql://postgres:postgres@postgres:5432/tokens |
| KAFKA_BROKERS | Kafka брокеры | kafka:9092 |
| KAFKA_CLIENT_ID | ID клиента Kafka | token-price-service |
| KAFKA_TOPIC | Топик Kafka | token-price-updates |
| KAFKAJS_NO_PARTITIONER_WARNING | Отключить предупреждение KafkaJS | 1 |
| AUTO_SEED_ON_STARTUP | Автоматическое заполнение данных | false |
| UPDATE_INTERVAL_SECONDS | Интервал обновления | 60 |
| MAX_RETRIES | Количество попыток | 5 |
| TIMEOUT_MS | Таймаут запросов | 60000 |

### GitOps конфигурация

Приложение использует **GitOps** подход с **ArgoCD** и **Kustomize**:

- `gitops/base/` - базовые манифесты (Deployment, Service, ConfigMap, Secret, PVC, Kafka, Zookeeper, Postgres)
- `gitops/overlays/production/` - конфигурация для production (оптимизированные ресурсы, образы из GHCR)
- `gitops/argocd/application.yaml` - ArgoCD Application для автоматического деплоя

**Преимущества GitOps:**
- Декларативная конфигурация инфраструктуры
- Автоматическая синхронизация с кластером (automated sync + self-heal)
- История изменений через Git
- Откат через revert коммита
- Review процесс через Pull Requests

#### Структура GitOps
```
gitops/
├── argocd/
│   └── application.yaml          # ArgoCD Application manifest
├── base/                          # Базовые манифесты
│   ├── kustomization.yaml        # Список ресурсов
│   ├── deployment.yaml           # Основное приложение
│   ├── service.yaml              # Service для приложения
│   ├── serviceaccount.yaml       # Service Account для CronJob
│   ├── configmap.yaml            # Конфигурация
│   ├── pvc-data.yaml             # PVC для данных
│   ├── pvc-logs.yaml             # PVC для логов
│   ├── cronjob.yaml              # CronJob для обновления цен каждые 5 минут
│   ├── kafka-deployment.yaml     # Kafka в кластере
│   ├── kafka-service.yaml        # Service для Kafka
│   ├── zookeeper-deployment.yaml # Zookeeper для Kafka
│   ├── zookeeper-service.yaml    # Service для Zookeeper
│   ├── postgres-deployment.yaml  # Postgres в кластере
│   ├── postgres-service.yaml     # Service для Postgres
│   ├── postgres-pvc.yaml         # PVC для Postgres
│   └── ingress.yaml              # Ingress (базовый)
└── overlays/
    └── production/               # Production overlay
        ├── kustomization.yaml    # Патчи для production
        ├── deployment-patch.yaml # Оптимизированные ресурсы, образ из GHCR
        ├── configmap-patch.yaml  # Production переменные
        ├── cronjob-patch.yaml    # Контроль suspend для CronJob
        ├── ingress-patch.yaml    # Домены и TLS
        └── pvc-patch.yaml        # StorageClass для PVC
```

**Важно:** Версия образа в `deployment-patch.yaml` обновляется автоматически через CI/CD pipeline при создании релиза.


## Workflow разработки (Developer Guide)

### Обзор процесса

Проект использует **GitFlow-подобный workflow** с автоматизированным CI/CD через GitHub Actions и GitOps через ArgoCD.

```
feature/* ──PR──> dev ──PR──> main ──tag──> CI/CD ──GitOps PR──> ArgoCD ──> Production
```

### Ветки и их назначение

| Ветка | Назначение | Защита | Деплой |
|-------|-----------|--------|--------|
| `main` | Production-ready код, только через PR | Защищена | Автоматически через ArgoCD |
| `dev` | Integration-ветка для разработки | Защищена | Нет |
| `feature/*` | Feature-разработка | Нет | Нет |
| `gitops/deploy-*` | Автоматические PR для деплоя | Авто-мерж | Да |

---

### 1. Локальная разработка (Feature)

**Начало работы:**
```bash
# Обновить dev
git checkout dev
git pull origin dev

# Создать feature-ветку
git checkout -b feature/add-new-endpoint

# Установить зависимости (если нужно)
npm install
```

**Разработка:**
```bash
# Запустить локальную инфраструктуру (PostgreSQL, Kafka)
docker-compose up -d

# Запустить приложение в dev-режиме
npm run start:dev

# Писать код, тесты
# ...

# Прогнать тесты локально
npm test                # Unit тесты
npm run test:e2e        # E2E тесты
npm run lint            # Линтер

# Коммиты (Conventional Commits)
git add .
git commit -m "feat(pricing): add endpoint for token metadata"
git commit -m "test(pricing): add e2e tests for metadata endpoint"
```

**Conventional Commits формат:**
- `feat:` — новая функциональность
- `fix:` — исправление бага
- `test:` — добавление/изменение тестов
- `refactor:` — рефакторинг без изменения функциональности
- `docs:` — изменения в документации
- `chore:` — инфраструктурные изменения (deps, config)

---

### 2. Pull Request в `dev`

**Создание PR:**
```bash
# Push feature-ветки
git push origin feature/add-new-endpoint

# Создать PR через GitHub UI или CLI
gh pr create --base dev --head feature/add-new-endpoint \
  --title "feat(pricing): add endpoint for token metadata" \
  --body "### Changes:
- Added GET /pricing/tokens/:id/metadata endpoint
- Added unit and e2e tests
- Updated OpenAPI spec

### Testing:
- Unit tests pass
- E2E tests pass
- Lint pass"
```

**CI проверки на PR → dev:**
- Lint (TypeScript, ESLint, Prettier)
- Unit тесты
- E2E тесты
- **Образ НЕ публикуется** (только проверки)

**После апрува:**
```bash
# Merge через GitHub UI (Squash and Merge рекомендуется)
# Или через CLI:
gh pr merge <PR_NUMBER> --squash --delete-branch
```

---

### 3. Pull Request из `dev` в `main`

**Когда:** После накопления фич в `dev`, готовность к релизу.

**Создание PR:**
```bash
# Убедиться что dev актуален
git checkout dev
git pull origin dev

# Создать PR dev → main
gh pr create --base main --head dev \
  --title "chore(release): prepare v1.0.8" \
  --body "### Release v1.0.8

**Features:**
- feat(pricing): add endpoint for token metadata
- feat(cronjob): optimize schedule to 5 minutes

**Fixes:**
- fix(kafka): update broker hostname

**Changes:**
- refactor(domain): improve TokenPrice value object

**Tests:**
- All unit and e2e tests passing"
```

**CI проверки на PR → main:**
- Lint
- Unit тесты
- E2E тесты
- **Образ НЕ публикуется** (публикация только по тегу)

**После апрува:**
```bash
# Merge через GitHub UI (Create a merge commit)
gh pr merge <PR_NUMBER> --merge
```

---

### 4. Релиз (Создание тега)

**После мержа PR в main:**
```bash
# Переключиться на main
git checkout main
git pull origin main

# Создать тег (Semantic Versioning)
git tag v1.0.8 -m "Release v1.0.8: metadata endpoint and cronjob optimization"

# Push тега (запускает CI/CD)
git push origin v1.0.8
```

**Versioning:**
- `v1.0.0` → `v1.0.1` — patch (bug fixes)
- `v1.0.0` → `v1.1.0` — minor (new features, backward compatible)
- `v1.0.0` → `v2.0.0` — major (breaking changes)

---

### 5. CI/CD Pipeline (автоматически по тегу)

**GitHub Actions автоматически:**
1. Запускает тесты (Lint + Unit + E2E) и security scan
2. Собирает и публикует Docker образ в GHCR
3. Создает GitOps PR с обновлением версии образа
4. После мержа GitOps PR → ArgoCD деплоит в кластер

Детали: см. раздел **"CI/CD Pipeline"** выше.

---

### 6. Деплой в Production (GitOps)

**После мержа GitOps PR:**
1. **ArgoCD** автоматически обнаруживает изменения в `main`
2. Синхронизирует изменения с кластером Kubernetes
3. Запускает rolling update деплоя
4. Проверяет readiness/liveness probes

**Проверка деплоя:**
```bash
# Статус пода
kubectl -n token-price-service get pods

# Статус rolling update
kubectl -n token-price-service rollout status deploy/token-price-service

# Логи приложения
kubectl -n token-price-service logs deploy/token-price-service --tail=100 -f

# Проверка через API
curl https://dsavin.tech/pricing/status
```

**ArgoCD UI (если доступен):**
```bash
# Port-forward для доступа к ArgoCD
kubectl port-forward -n argocd svc/argocd-server 8080:443

# Открыть в браузере: https://localhost:8080
```

---

### 7. Откат версии

Если нужно откатить версию:
- **Revert GitOps PR** - откат через Git
- **Ручной откат через kubectl** - быстрый откат
- **Новый релиз с фиксом** - forward fix

Детали: см. раздел **"Откат версии"** выше.

---

### 8. Hotfix (срочное исправление в production)

**Для критических багов:**
```bash
# Создать hotfix-ветку от main
git checkout main
git pull origin main
git checkout -b hotfix/critical-security-fix

# Исправить проблему
# ... code ...
git commit -m "fix(security): patch CVE-2024-XXXXX"

# Создать PR hotfix → main (минуя dev)
gh pr create --base main --head hotfix/critical-security-fix \
  --title "fix(security): patch CVE-2024-XXXXX" \
  --label "hotfix" --label "security"

# После мержа:
git tag v1.0.9
git push origin v1.0.9

# Синхронизировать dev с main
git checkout dev
git merge main
git push origin dev
```

---

### Полная диаграмма процесса

```
┌─────────────────────────────────────────────────────────────────┐
│ РАЗРАБОТЧИК                                                     │
├─────────────────────────────────────────────────────────────────┤
│ 1. Создать feature-ветку от dev                                │
│    git checkout -b feature/my-feature                           │
│                                                                 │
│ 2. Разработка + тесты локально                                 │
│    npm test && npm run test:e2e                                 │
│                                                                 │
│ 3. Push и создание PR → dev                                    │
│    gh pr create --base dev                                      │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│ CI: Pull Request Checks (на feature → dev)                      │
├─────────────────────────────────────────────────────────────────┤
│ ✓ Lint                                                          │
│ ✓ Unit Tests                                                    │
│ ✓ E2E Tests                                                     │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         ▼ (после апрува)
┌─────────────────────────────────────────────────────────────────┐
│ Merge feature → dev                                             │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         │ (когда готов релиз)
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│ PR: dev → main                                                  │
├─────────────────────────────────────────────────────────────────┤
│ CI: Lint + Tests (без публикации образа)                        │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         ▼ (после апрува)
┌─────────────────────────────────────────────────────────────────┐
│ Merge dev → main                                                │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│ РЕЛИЗ                                                           │
├─────────────────────────────────────────────────────────────────┤
│ git tag v1.0.X                                                  │
│ git push origin v1.0.X  ◄── ЗАПУСК CI/CD                        │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│ CI/CD: GitHub Actions (на тег)                                  │
├─────────────────────────────────────────────────────────────────┤
│ 1. Test: Lint + Unit + E2E + Security Scan                     │
│ 2. Build: Docker образ → GHCR                                   │
│ 3. GitOps PR: обновить deployment-patch.yaml                    │
│ 4. Auto-merge GitOps PR → main                                  │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│ PRODUCTION: ArgoCD (GitOps)                                     │
├─────────────────────────────────────────────────────────────────┤
│ 1. Обнаруживает изменения в main                                │
│ 2. Применяет новый образ в кластер                              │
│ 3. Rolling update деплоя                                        │
│ 4. Health checks (readiness/liveness)                           │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         ▼
                  PRODUCTION READY
```

---

### Чек-лист для разработчика

**Перед созданием PR:**
- [ ] Код соответствует стилю проекта (lint pass)
- [ ] Добавлены unit-тесты для новой функциональности
- [ ] Добавлены e2e-тесты (если нужно)
- [ ] Все тесты проходят локально
- [ ] Conventional Commits соблюдены
- [ ] README/документация обновлена (если нужно)

**Перед релизом:**
- [ ] Все PR в `dev` смержены
- [ ] PR `dev → main` создан и апрувлен
- [ ] Версия тега соответствует Semantic Versioning
- [ ] Release notes подготовлены (описание изменений)

**После релиза:**
- [ ] CI/CD pipeline завершился успешно (зелёный)
- [ ] GitOps PR автоматически смержен
- [ ] ArgoCD синхронизировал изменения
- [ ] Приложение в production работает (проверить `/pricing/status`)
- [ ] CronJob обновления цен работает (проверить jobs)

---

## Планирование обновления цен

### Kubernetes CronJob (настроен и включен)

Сервис использует **Kubernetes CronJob** для автоматического обновления цен **каждые 5 минут**. Встроенного планировщика в приложении нет — запуск только извне.

**Конфигурация:**
- Файл: `gitops/base/cronjob.yaml`
- Расписание: `*/5 * * * *` (каждые 5 минут)
- Concurrency: `Forbid` (не запускать новый job если предыдущий выполняется)
- История: 3 успешных + 3 неудачных jobs
- Retry: 2 попытки при неудаче
- Ресурсы: 10m CPU / 16Mi RAM (requests), 50m CPU / 64Mi RAM (limits)

**Управление CronJob:**
```bash
# Проверить статус
kubectl -n token-price-service get cronjob price-updater

# Посмотреть последние jobs
kubectl -n token-price-service get jobs --sort-by=.metadata.creationTimestamp

# Посмотреть логи последнего job
kubectl -n token-price-service logs -l app=price-updater --tail=50

# Приостановить CronJob (если нужно)
kubectl -n token-price-service patch cronjob price-updater -p '{"spec":{"suspend":true}}'

# Возобновить CronJob
kubectl -n token-price-service patch cronjob price-updater -p '{"spec":{"suspend":false}}'

# Ручной запуск (создать job вне расписания)
kubectl -n token-price-service create job --from=cronjob/price-updater manual-update-$(date +%s)
```

### Ручной запуск через API

Если нужно запустить обновление вручную:
```bash
# Локально
curl -X POST http://localhost:3000/pricing/trigger-update

# В кластере (из другого пода; в проде требуется внутренний токен)
kubectl -n token-price-service exec -it deploy/token-price-service -- \
  curl -X POST -H "x-internal-job-token: $INTERNAL_JOB_TOKEN" http://localhost:3000/pricing/trigger-update
```

## API Endpoints

### Health Check
```
GET /pricing/health
```
Возвращает статус сервиса и текущий timestamp.

### Status
```
GET /pricing/status
```
Возвращает детальную информацию о состоянии сервиса: общее число токенов и `lastUpdate` (время последнего обновления цен).

### Trigger Update
```
POST /pricing/trigger-update
```
Запускает обновление цен для всех токенов. Используется внешними планировщиками.

## Тестирование

### Unit тесты
```bash
npm test
```

### E2E тесты
```bash
npm run test:e2e
```

### Покрытие кода
```bash
npm run test:cov
```

## Мониторинг

### Логи
Сервис использует структурированное JSON логирование с временными метками и контекстом.

### Метрики
Интеграция с OpenTelemetry для сбора метрик и трассировки.

### Health Checks
Встроенные health checks для Kubernetes liveness и readiness probes.


## Безопасность

- Все секреты хранятся в Kubernetes Secrets
- Конфигурация через ConfigMaps
- Health checks для мониторинга
- Graceful shutdown для корректного завершения

## Дополнительные ресурсы

### Полезные команды

```bash
# Проверка статуса всех ресурсов
kubectl get all -n token-price-service

# Проверка статуса конкретных компонентов
kubectl -n token-price-service get pods,svc,pvc,deploy

# Просмотр логов основного приложения
kubectl -n token-price-service logs -l app=token-price-service -f

# Просмотр логов Kafka
kubectl -n token-price-service logs -l app=kafka -f

# Просмотр логов Postgres
kubectl -n token-price-service logs -l app=postgres -f

# Port-forward для локального доступа
kubectl -n token-price-service port-forward svc/token-price-service 3000:3000

# Доступ к ArgoCD (если установлен)
kubectl -n argocd port-forward svc/argocd-server 8080:443
```