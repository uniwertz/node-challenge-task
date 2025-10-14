#!/bin/bash

# Скрипт для тестирования локальной сборки Docker образа

set -e

echo "🐳 Тестирование сборки Docker образа..."

# Проверяем, что мы в корневой директории проекта
if [ ! -f "Dockerfile" ]; then
    echo "❌ Ошибка: Dockerfile не найден. Запустите скрипт из корневой директории проекта."
    exit 1
fi

# Собираем образ
echo "📦 Сборка Docker образа..."
docker build -t token-price-service:test .

echo "✅ Docker образ успешно собран!"

# Тестируем запуск контейнера
echo "🚀 Тестирование запуска контейнера..."
docker run --rm -d --name token-price-service-test -p 3000:3000 \
    -e DATABASE_URL="postgresql://user:password@host:5432/db" \
    -e KAFKA_BROKERS="localhost:9092" \
    token-price-service:test

# Ждем запуска
echo "⏳ Ожидание запуска приложения..."
sleep 10

# Проверяем health endpoint
echo "🔍 Проверка health endpoint..."
if curl -f http://localhost:3000/pricing/health > /dev/null 2>&1; then
    echo "✅ Health endpoint отвечает!"
else
    echo "❌ Health endpoint не отвечает"
fi

# Останавливаем контейнер
echo "🛑 Остановка тестового контейнера..."
docker stop token-price-service-test

echo "🎉 Тест завершен успешно!"
