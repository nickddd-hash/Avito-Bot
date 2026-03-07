# Avito Demo Bot — Project State

## Статус: РАБОТАЕТ (2026-03-04)

## Архитектура
- **Платформа**: n8n self-hosted (https://n8n.flowsmart.ru)
- **ЛЛМ**: GPT-4o-mini (OpenAI)
- **Память диалога**: Postgres Chat Memory (Supabase, сессия по chat_id)
- **RAG**: Supabase Vector Store (таблица `avito_knowledge`, embeddings `text-embedding-3-small`)
- **Webhook**: зарегистрирован через `POST /messenger/v3/webhook`

## Воркфлоу (n8n-workflow-R2.json)

### Основная цепочка (авто-ответы)
```
Webhook → If → Получить Токен → AI Agent → Обрезать ответ → Ответить в Авито
```

### Вспомогательные цепочки
- `Зарегистрировать Webhook → Токен → Подписать Webhook Авито` — одноразовая регистрация
- `Начать → Наши компетенции → Supabase Vector Store (Запись)` — загрузка базы знаний

## Ключевые технические решения

### Webhook
- Авито требует ответ **200 OK за 2 секунды** — иначе retry → дубли
- Текущий воркфлоу: `responseMode: "lastNode"` — **TODO**: поменять на `onReceived` или добавить "Respond to Webhook" ноду
- Webhook зарегистрирован через API: `POST https://api.avito.ru/messenger/v3/webhook`
- Подписка на получение: `GET https://api.avito.ru/messenger/v1/subscriptions`
- Отписка: `POST https://api.avito.ru/messenger/v1/webhook/unsubscribe`

### Отправка сообщений
- Endpoint: `POST /messenger/v1/accounts/{user_id}/chats/{chat_id}/messages`
- Body: `{ "type": "text", "message": { "text": "..." } }`
- **user_id** берётся из webhook payload (`body.payload.value.user_id`) — НЕ хардкодить
- **Синтаксис n8n**: в URL и body полях использовать `={{ expression }}` (с `=`), НЕ `{{ }}`

### Фильтрация (If нода — 3 условия AND)
1. `author_id != user_id` — не отвечать на собственные сообщения
2. `type == "text"` — только текстовые сообщения
3. `content.text != ""` — не пустые

### Обрезка ответа (Code нода)
```javascript
const text = $input.item.json.output || '';
const clean = text.replace(/[#*_~`]/g, '').trim();
return [{ json: { output: clean.slice(0, 1000) } }];
```
- Убирает markdown символы
- Обрезает до 1000 символов (лимит Авито)

## Supabase — match_documents

Функция для RAG (нужно создать вручную при новой установке):

```sql
drop function if exists match_documents(vector, integer, jsonb);

create or replace function match_documents (
  query_embedding vector(1536),
  match_count int,
  filter jsonb default '{}'
) returns table (
  id uuid,
  content text,
  metadata jsonb,
  similarity float
)
language plpgsql
as $$
begin
  return query
  select
    ak.id,
    ak.content,
    ak.metadata,
    1 - (ak.embedding <=> query_embedding) as similarity
  from avito_knowledge ak
  where ak.metadata @> filter
  order by ak.embedding <=> query_embedding
  limit match_count;
end;
$$;
```

**Важно**: таблица `avito_knowledge` имеет `id` типа `uuid` (не bigint).
Если PostgREST перезапустился и функция "пропала" из кэша — пересоздать через SQL Editor.

## Webhook Payload (Авито v3)
```json
{
  "body": {
    "id": "uuid",
    "version": "v3.0.0",
    "payload": {
      "type": "message",
      "value": {
        "chat_id": "u2i-...",
        "user_id": 180088918,
        "author_id": 240375490,
        "type": "text",
        "content": { "text": "сообщение клиента" }
      }
    }
  }
}
```

## Для нового клиента (Вариант А — "под ключ")

Что менять при дублировании воркфлоу:
1. `client_id` + `client_secret` в нодах "Получить Токен Авито" и "Токен для Регистрации"
2. Системный промпт в "AI Agent" — под бизнес клиента
3. Содержимое ноды "Наши компетенции (Текст)" — услуги/цены клиента
4. URL вебхука в "Подписать Webhook Авито" (если другой домен)
5. Запустить "Зарегистрировать Webhook" один раз

## Human Handoff (n8n-workflow-R3.json)

Система паузы бота при подключении владельца к переписке.

### Как работает
1. Бот определяет горячего лида → уведомляет владельца в TG → **молча ставит паузу** (запись в `avito_paused_chats`)
2. Уведомление содержит команду `/resume <chat_id>` для возобновления
3. В начале каждого входящего сообщения: `SELECT EXISTS(...)` → если пауза → бот не отвечает
4. Владелец пишет `/resume <chat_id>` боту → запись удаляется → бот снова активен

### DB
```sql
-- migrations/001_avito_paused_chats.sql
CREATE TABLE avito_paused_chats (
  chat_id TEXT PRIMARY KEY,
  paused_at TIMESTAMP DEFAULT NOW()
);
```

### Изменения в воркфлоу (R2 → R3)
- `Respond to Webhook` → `Проверить паузу` (EXISTS query) → `IF на паузе` → при паузе END
- `Уведомить владельца` → `Поставить паузу` (INSERT ... ON CONFLICT DO NOTHING)
- `Telegram Trigger` → `/resume` команда → `Удалить паузу` → `Подтверждение`
- `Уведомить владельца`: в текст добавлена строка `▶️ /resume <chat_id>`

## TODO
- [ ] Протестировать уведомления о горячих лидах и команду /resume
- [ ] Пересоздать токен @my_avito_orders_bot через @BotFather (старый засветился)
- [ ] Расширить базу знаний: кейсы, FAQ, возражения
