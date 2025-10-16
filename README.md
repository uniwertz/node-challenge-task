# Token Price Service (OLD)

Этот документ фиксирует выявленные антипаттерны, баги и архитектурные недостатки в проекте `token-price-service`, а также содержит предложения по улучшениям с обоснованием.

### Охваченные файлы
- `src/main.ts`
- `src/app.module.ts`
- `src/services/token-price-update.service.ts`
- `src/services/mock-price.service.ts`
- `src/kafka/kafka-producer.service.ts`
- `src/models/token.entity.ts`
- `src/models/token.schema.ts`
- `src/models/token-price-update-message.ts`
- `tsconfig.json`, `package.json`

---

## 1. Выявление проблем

### 1.1 Антипаттерны и потенциальные баги
- **Жёстко зашитая конфигурация (DB, Kafka, порт)**
  - В `src/app.module.ts` настройки TypeORM (host, port, user, password, database) заданы константами. В `src/kafka/kafka-producer.service.ts` брокеры Kafka и `clientId` также хардкодятся. В `src/main.ts` порт 3000 не конфигурируется.
  - Риск: несовместимость окружений, невозможность безопасного деплоя, утечки секретов.

- **Побочные эффекты в конструкторах и на старте модуля**
  - `KafkaProducerService`: вызов `this.connect()` в конструкторе (асинхронный побочный эффект без ожидания).
  - `AppModule.onModuleInit`: сидинг БД и запуск фонового сервиса обновления цен прямо из модуля.
  - Риск: гонки инициализации, неочевидный порядок старта, трудности тестирования.

- **Неполноценная обработка ошибок и завершение процесса**
  - `src/main.ts`: при ошибке старта просто логируется `error.message`, процесс не завершается с ненулевым кодом; не включены shutdown hooks.
  - `KafkaProducerService.sendPriceUpdateMessage`: нет `await` у `producer.send`, ошибки могут теряться, подтверждения отправки нет.
  - Риск: сервис в «полу-рабочем» состоянии, потеря сообщений, сложность инцидент-менеджмента.

- **Несоответствие типов для денежных значений (decimal vs number)**
  - `Token.price` хранится в PostgreSQL как `decimal(28,0)`, но в коде используется как `number`. TypeORM в Postgres, как правило, возвращает `string` для `decimal`, что приведёт к:
    - сравнение `oldPrice !== newPrice` всегда `true` из-за несоответствия типов (`string` vs `number`), что вызывает лишние отправки в Kafka и записи в БД;
    - потенциальные ошибки округления.

- **Дублирование и денормализация данных в сущности**
  - В `src/models/token.entity.ts` одновременно есть `chainId` и `chain_Id`, а также блоки `chain_*` и `logo_*` полей. Это явная денормализация и несогласованность нейминга (`camelCase`/`snake_Case`/смешение регистра).
  - Риск: расхождения данных, усложнение миграций и эволюции схемы, рост связности.

- **Несогласованность схем валидации (Zod) с сущностью**
  - `token.schema.ts` повторяет денормализованные поля и задаёт `price` как `number`, что расходится с БД (`decimal`).
  - `address: z.instanceof(Buffer)` ограничивает источники данных; часто адрес приходит как строка/hex в DTO.

- **Фоновый цикл через `setInterval` с async-колбэком**
  - `TokenPriceUpdateService`: `setInterval` с async функцией, где ошибки внутри ловятся, но очереди вызовов могут наслаиваться, если выполнение дольше интервала. Отсутствует ограничение конкуренции/«шторка» выполнения.
  - Нет конфигурируемости интервала из окружения; начальный запуск из `onModuleInit` скрещён с сидингом.

- **Логи и стиль**
  - Местами используется `console.error` вместо Nest `Logger`.
  - Нет глобальных `ValidationPipe`, `Config`-валидации и health-check.

- **Нестрогая компиляция TypeScript**
  - `tsconfig.json`: отключены многие строгие флаги (`strictNullChecks`, `noImplicitAny`, `forceConsistentCasingInFileNames`, и пр.). Риск пропуска классов ошибок на этапе компиляции.

### 1.2 Конкретные примеры багов
- **Потеря await при отправке в Kafka**
  - В `KafkaProducerService.sendPriceUpdateMessage` нет `await this.producer.send(...)`, из-за чего код продолжает выполнение, не дожидаясь подтверждения отправки.

- **Гонки соединения с Kafka**
  - `connect()` вызывается в конструкторе и не awaited перед первой отправкой. Возможна попытка отправить сообщения до установления соединения.

- **Неверное сравнение цен (типовая несовместимость)**
  - `oldPrice !== newPrice` при `oldPrice` как `string` и `newPrice` как `number` приведёт к ложным обновлениям.

- **Жёстко зашитые учётные данные БД**
  - Риск утечек и несовместимости с деплой-процессами.

---

## 2. Предложенные изменения и обоснование

### 2.1 Управление конфигурацией
- **Что сделано**: параметры БД, Kafka, интервал обновления и порт сервера вынесены в `@nestjs/config`; добавлена схема валидации конфигурации (`zod`).
- **Зачем**: единообразное управление окружениями, безопасность секретов, предотвращение конфигурационных ошибок при старте.

### 2.2 Жизненный цикл приложения
- **Что сделано**:
  - Асинхронное подключение Kafka перенесено из конструктора в `onModuleInit` с явным `await`.
  - В `main.ts` включены `app.enableShutdownHooks()` и корректное завершение при ошибках (`process.exit(1)`); добавлены глобальные `ValidationPipe`.
  - Сидинг данных отделён от запуска фонового процесса: сидинг запускается отдельной командой либо управляется через флаг окружения.
- **Зачем**: предсказуемая инициализация, корректное завершение, управляемость прод-циклов.

### 2.3 Kafka-производитель
- **Что сделано**:
  - Добавлено `await producer.send(...)` и обработка ошибок с ретраями/backoff.
  - `topic`, `clientId`, `brokers` параметризованы через конфиг.
  - Добавлены подтверждения доставки/метрики; рассмотрены механизмы DLQ/повторных попыток на уровне потребителей.
- **Зачем**: избежать потери сообщений и гонок соединения, повысить наблюдаемость.

### 2.4 Модель данных `Token`
- **Что сделано**:
  - Устранено дублирование `chainId`/`chain_Id`; унифицирован нейминг (camelCase в коде, snake_case в БД через `name`); `chain_*` и `logo_*` вынесены в связанные таблицы (нормализация) либо денормализация формализована инвариантами.
  - Для `price` внедрён fixed‑point формат: `TokenPrice` хранит значение как `BigInt amount` при фиксированном масштабе `scale=8`; в БД используется `DECIMAL`, во внешнем API — строки. Арифметика и сравнения выполняются без float.
- **Зачем**: целостность данных, корректность денежных расчётов, отсутствие ошибок округления, совместимость с ончейн‑подходом (fixed‑point).

### 2.5 Схемы валидации (Zod)
- **Что сделано**:
  - `token.schema.ts` приведён в соответствие с сущностью после нормализации.
  - Разрешён ввод адреса в человеко-ориентированном формате (строка/hex) с преобразованием в `Buffer` в слое маппинга.
  - Для денежных полей реализована валидация строкового представления либо применены branded types.
- **Зачем**: единая контрактная модель, надёжная валидация входных данных.

### 2.6 Обновление цен
- **Что сделано**:
  - Отказались от `@nestjs/schedule`; обновление цен выполняется внешним планировщиком (Kubernetes CronJob). В приложении оставлен idempotent use‑case и триггер‑эндпоинт.
  - Обработка выполнена батчами, сэкономлены round‑trips к БД (batch save), ограничена параллельность.
- **Зачем**: надёжный и управляемый прод‑процесс (CRON на уровне кластера), предсказуемая нагрузка, простота эксплуатации.

### 2.7 main.ts и кросс-срезовые аспекты
- **Что сделано**: добавлены глобальные пайпы/фильтры, health-check (например, эндпойнт `/health`), структурированные логи.
- **Зачем**: операбельность, наблюдаемость, защита от невалидных входных данных.

### 2.8 TypeScript строгий режим
- **Что сделано**: включены `strict` и связанные флаги (`noImplicitAny`, `strictNullChecks`, `forceConsistentCasingInFileNames` и др.).
- **Зачем**: ловить классы ошибок на этапе сборки, повысить качество кода.

---

## 3. Краткая карта: Проблема → Изменение → Обоснование

- **Хардкод конфигурации** → Вынести в `@nestjs/config` + схема валидации → Надёжность окружений, безопасность.
- **Побочные эффекты в конструкторах** → Перенос в `onModuleInit`/lifecycle и `await` → Предсказуемая инициализация.
- **Kafka без await и ретраев** → `await send` + обработка ошибок/ретраи → Гарантированная отправка/видимость сбоев.
- **`decimal` как `number`** → Строка/BigNumber/трансформер → Корректные сравнения и отсутствие лишних апдейтов.
- **Денормализация и несогласованные имена** → Нормализация + единый стиль имён → Целостность и сопровождаемость.
- **Async в `setInterval` без шторки** → `@nestjs/schedule` + защита от конкурентного запуска → Стабильность фоновых задач.
- **Отсутствие глобальной валидации/health** → `ValidationPipe`, health-check → Операбельность, безопасность.
- **Нестрогий TS** → Включить strict-флаги → Раннее обнаружение ошибок.

---

## 4. Приоритеты внедрения
1) Безопасность и надёжность: конфигурация, корректная инициализация Kafka, строгий TS.
2) Корректность домена: приведение `price` к безопасному типу, устранение дублирования полей.
3) Операционные аспекты: health-check, валидация конфигурации, structured logging.
4) Производительность и масштабирование: шедулер, батчи/параллелизм с лимитами.

---

## 5. Потенциальные риски и миграции
- Нормализация сущности потребует миграций БД и возможной адаптации потребителей Kafka.
- Изменение представления `price` потребует адаптации мест, где ожидается `number`.
- Вынесение сидера из `onModuleInit` изменит стартовый сценарий — потребуется обновление README/скриптов.


# Token Price Service (NEW)

Сделал production-ready сервис, который обновляет цены на токены по внешнему расписанию (каждые 5 минут через Kubernetes CronJob).

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


#### Автоматическое развертывание через CI/CD

Проект использует **GitHub Actions** для автоматической сборки и развертывания:

1. **При создании Pull Request в main:**
   - Запускаются тесты (unit + e2e)
   - Проверяется линтинг

2. **При создании тега `v*.*.*` (например, v1.0.0):**
   - Запускаются тесты
   - Собирается Docker образ для `linux/amd64`
   - Образ публикуется в GitHub Container Registry (GHCR): `ghcr.io/uniwertz/token-price-service:v1.0.0`
   - Выполняется security scan через Trivy
   - **Автоматически создается Pull Request** с обновлением production манифеста
   - После мержа PR, ArgoCD автоматически деплоит новую версию в кластер

#### Процесс релиза

```bash
# 1. Создайте и запушьте тег версии
git tag v1.0.0
git push origin v1.0.0

# 2. GitHub Actions автоматически:
#    - Соберет и опубликует Docker образ
#    - Создаст PR с обновлением версии в gitops/overlays/production/deployment-patch.yaml

# 3. Проверьте и смержьте автоматически созданный PR

# 4. ArgoCD автоматически задеплоит новую версию (если настроен syncPolicy.automated)
```

#### Ручное развертывание (если нужно)

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


## Developer Flow (от dev до релиза)

1) Работа в ветке `dev`
- **Шаги разработчика**:
  - `git checkout -b feature/<short-desc>` от `dev`
  - Код + тесты (unit/e2e) локально: `npm test`, `npm run test:e2e`
  - Коммиты и push в вашу feature-ветку
  - Открываете PR → `dev`
  - CI на PR: линт, unit, e2e (без публикации образа)
  - После апрува — merge в `dev`

2) Подготовка релиза
- Синхронизируем `main`:
  - `git checkout main && git pull`
  - `git merge --no-ff dev -m "chore(release): merge dev into main"`

3) Тег релиза (запуск CI/CD)
- Создание тега:
```bash
git tag vX.Y.Z
git push origin main --tags
```
- CI по тегу делает:
  - `test`: линт, unit, e2e
  - `build`: сборка Docker образа, публикация в GHCR `ghcr.io/uniwertz/token-price-service:vX.Y.Z`
  - `security-scan`: Trivy
  - `gitops-update`: PR с изменением версии образа в `gitops/overlays/production/deployment-patch.yaml`

4) Деплой в кластер (GitOps)
- После мержа GitOps‑PR в `main`:
  - ArgoCD автоматически синхронизирует прод-окружение
  - Проверка статуса:
```bash
kubectl -n token-price-service get pods
kubectl -n token-price-service rollout status deploy/token-price-service
```

5) Откат
- Через revert GitOps‑PR или установку предыдущего тега (см. раздел «Откат версии» выше).


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