# Olympus Project Memory

## User Context
- Не программист — описывает проблемы на уровне продукта ("логи пустые", "неправильный layout")
- Я самостоятельно нахожу нужные файлы, диагностирую и правлю — не прошу уточнять файл/строку
- Объяснения даю простым языком, без технического жаргона там, где можно избежать

## Critical Conventions (enforce always)
- `getRestaurantId()` from restaurantContext — NEVER hardcode restaurant_id
- `utcToLocal()` / `getTimezoneOffset()` from restaurantContext — NEVER hardcode timezone
- `getDefaultDurationMs()` from bookingsStore — NEVER hardcode booking duration
- All Supabase queries MUST filter by `restaurant_id`
- State pattern: plain JS modules with subscribe/getSnapshot (NOT Redux/Zustand)
- Language: respond in **Russian**

## Critical Code Patterns

### "Deleted table" = no hall_layout_items row
- `tables` contains ALL ever-created tables. Active = has `hall_layout_items` row for current layout
- Filter with `!inner` join: `.select('*, hall_layout_items!inner(id)').eq('hall_id', hallId)`
- Or client-side: `.filter(t => layoutItemsByTableId.has(t.id))`

### Reactive restaurant_id in useEffect — NEVER use .then() on getRestaurantId()
- `getRestaurantId()` is SYNCHRONOUS (string | null), NOT a Promise
- Use `useCurrentRestaurant()` hook + add restaurantId to deps:
  ```typescript
  const { restaurantId } = useCurrentRestaurant();
  useEffect(() => { if (!restaurantId) return; ... }, [restaurantId]);
  ```

### isLoadingTables must start as `true` in Dashboard
- Prevents orphan bookings from flashing on initial render before tables load

### hall_layout_items has no restaurant_id — filter via nested join
- `.select('table_id, tables!inner(hall_id, halls!inner(restaurant_id))')`
- `.eq('tables.halls.restaurant_id', restaurantId)`

### Parallel queries with Promise.all
- Use `Promise.all([...])` for all independent Supabase calls — never await sequentially without reason

## Open Issues (as of 2026-02-25)
### P1
- Athena n8n: 6 hardcoded spots (restaurant_id in Calc_Times, timezone in FormatPrompt/Extract_Cancel/IdentifyClient)
- Athena scaling: Variant 3 (one workflow, many Telegram bots via webhook)
- FormatPrompt v71: файл готов в `n8n_fixes/FormatPrompt_v70_qwen.js`, нужно залить в n8n
- IF-нода перед Save_Booking: не добавлена (должна блокировать error-объект от Calc_Times)
- ~~Lasso не выделяет барные стулья~~: FIXED 2026-02-26.

## Silero TTS (добавлено 2026-02-24)
- GPU сервер: 193.247.73.96 (root), RTX A4000 16GB
- n8n сервер: 109.172.38.209
- Silero: Docker container `local-tts`, порт 8000, restart=unless-stopped
- API: POST http://193.247.73.96:8000/audio/speech — поля: model=tts-1, input=текст, voice=kseniya, response_format=opus
- Telegram sendVoice: POST https://api.telegram.org/bot{TOKEN}/sendVoice (multipart-form-data: chat_id + voice binary)
- Clean_Text Code нода: стрипает emoji, конвертирует HH:MM → "19 часов 00 минут", DD.MM → дату, числа → слова
- ElevenLabs: заблокирован с российского IP (Cloudflare 403), но работает через Voximplant (их IP не в России)
- Для телефонии: Voximplant + ElevenLabs = рабочая схема; для ФЗ-152 чистоты — стрипать PII из текста перед TTS

## Chair Distribution & Rotation (tableGeometry.ts) — Key Rules
- Threshold 1.2: ratio >= 1.2 → rectangular (2+2 on long sides); < 1.2 → square (1+1+1+1)
- Physical cap: MIN_PX_PER_CHAIR = 33 — floors chair count per side
- Rectangular tables: rotateTable() swaps w↔h → chairs recompute from new dimensions ✓
- Square tables (w=h): rotateTable() toggles `rotated` boolean on TableItem → distributeChairsPerSide applies 90° CW permutation: `{ top: base.left, right: base.top, bottom: base.right, left: base.bottom }`
- `hall_layout_items.rotated` BOOLEAN column (migration 20260219120000) — persists rotation to DB
- `restaurant_settings.table_types` JSONB — custom types persist across sessions

## FloorEditor Save Patterns
- `saveCurrentLayout()`: upserts tables → saves layout items (incl. rotated) → updates local state
- `handleSaveAs()`: upserts ALL tables first (assigns dbId to new ones) → find/create layout → save items. If name exists → overwrite, don't block
- `loadLayoutItems()`: restores `rotated: layoutItem.rotated || false` for each table
- Keyboard handler: check `activeElement instanceof HTMLInputElement/HTMLTextAreaElement` before processing Delete/Backspace

## DB Quick Ref
- Restaurant: id = `8509e2ad-ad9c-4f81-b9b8-7bdd706d1567`
- booking_status enum: pending/confirmed/seated/completed/cancelled/no_show
- booking_source enum: admin/tg/phone/widget/telegram
- notify_channel enum: sms/telegram/none
- RPC: `cancel_booking_secure`, `get_or_create_client`
- Supabase host: supabase.flowsmart.ru
- `bookings.table_id` is NULLABLE (ALTER applied 2026-02-18) — orphan bookings have table_id=NULL

## Dashboard Merge/Unlink UX (обновлено 2026-02-27)
- **"Объединить"** кнопка → `isMergeMode=true`; клики в `pendingMergeIds` (первый = primary); "Готово" → `confirmMerge()` → новый `RuntimeMerge` с `originalPositions` (для undo)
- **"Отменить объединение"**: клик на любой стол ad-hoc группы → попап → `undoAdHocMerge(groupId)` → позиции восстанавливаются; state: `contextAdHocTableId`
- **"Разъединить"** кнопка → `isUnlinkMode=true`; только schema-merged столы (`table.mergeGroupId`) интерактивны; клик → `unlinkRuntimeTableWithSuffix()`
- **Авто-разъединение** (ad-hoc): `clearRuntimeMergesForTable` — удаляет только группы где `group.id !== table.mergeGroupId`
- **Авто-восстановление** (schema-unlinked): `restoreSchemaGroup` — убирает suffix, возвращает в schema-группу через `runtimeMerges`
- Оба вызываются при completed/cancelled и в 30-сек таймере (useEffect с `allBookingsForDate` dep)
- Refs: `runtimeSuffixesRef`, `tablesRef`, `runtimeMergesRef` — sync в теле компонента, для timer callback
- Удалены: `mergeMode`, `mergeModeSourceId`, `contextTableId`, `unlinkRuntimeTable`, `mergeRuntimeTables`
- **TODO NEXT**: "Разъединить" для schema-merged столов на Dashboard — доработать UX (сейчас режим работает, но требует тестирования и возможно доработки поведения)

## Table Merge Groups (обновлено 2026-02-26)
- `merge_group_id UUID` + `merge_group_primary BOOLEAN` + `number_suffix VARCHAR(5)` — все на `tables` (migrations 20260225100000, 20260225110000)
- **Group drag**: `dragState.groupStartPositions` хранит стартовые позиции других членов; одним `setTables` двигаются все
- **Group rotate**: вокруг центроида, формула 90° CW screen-space: `newRelX = -relY, newRelY = relX`
- **suppressSides** в JSX: tolerance 3px, передаётся в TableRenderer → стулья на внутренних сторонах подавляются
- Primary: показывает номер; Secondary: `number=undefined` → не рендерится; `zIndex: 2` на primary div
- Unlink в FloorEditor: все члены группы получают `numberSuffix: undefined`; `checkTableCollision` пропускает столы одной группы
- **Adjacency guard** (FloorEditor): `areTablesConnected(tables, threshold=10)` — BFS, блокирует объединение несмежных столов
- **mergeWidth/Height/chairOffsetX/Y** в TableRenderer: combined bbox → правильное распределение стульев по длинным сторонам

### Dashboard Runtime Merges
- DB merge groups загружаются в `runtimeMerges` автоматически при loadHallTables/handleLayoutChange
- Маппинг таблиц включает `mergeGroupId`, `mergeGroupPrimary`, `numberSuffix` из БД
- **Отсоединить стол**: клик на merged table → попап → `unlinkRuntimeTableWithSuffix(tableId)`
  - Суффикс = номер primary + буква (А, Б, В…): `runtimeSuffixes[tableId] = "3А"`
  - Счётчик per-group: `runtimeSuffixCounters[merge.id]` — не сбивается при повторных unlink
  - Сброс: `setRuntimeSuffixes({})`, `setRuntimeSuffixCounters({})` при смене зала/схемы

## Multi-Selection (FloorEditor, desktop only) — добавлено 2026-02-25
- State: `multiSelectedIds: string[]`, `copiedGroup: TableItem[]`, `lassoState: { active, startLayoutX, startLayoutY, currentLayoutX, currentLayoutY } | null`
- Refs: `tablesRef` (always-current tables), `lassoRef` (always-current lasso state), `tableMouseDownRef` (flag: table drag just started → don't start lasso)
- **tableMouseDownRef**: заменяет `e.stopPropagation()` в `handleMouseDown`. В `handleCanvasMouseDown` проверяется флаг → если true, возвращаемся без старта лассо. Позволяет лассо стартовать с позиции барного стула.
- **lassoRef sync update**: в `handlePointerMove` ref обновляется СИНХРОННО (не через useEffect) — иначе `handlePointerUp` читает устаревшие координаты из-за React 18 batching
- Keyboard: Shift+click add/remove, Escape → clear, Delete → delete group, Ctrl+C → copyGroup, Ctrl+V → pasteGroup
- **Lasso bug FIXED 2026-02-26**: root cause — после `pointerup` браузер стреляет `click`, который вызывал handleTableClick/handleCanvasClick → `setMultiSelectedIds([])`. Фикс: в лассо handlePointerUp ставим `justFinishedInteractionRef.current = true` + RAF сброс; в handleTableClick добавили guard `&& !justFinishedInteractionRef.current`.

## FloorEditor Nav Guard (добавлено 2026-02-26)
- `useBlocker(hasUnsavedChanges)` из react-router-dom — блокирует SPA-навигацию
- `window.addEventListener('beforeunload', ...)` — блокирует закрытие вкладки/F5
- **Требует data router**: App.tsx мигрирован с `BrowserRouter` на `createBrowserRouter` + `RouterProvider`
- `RootLayout` (Outlet + BookingNotificationLayer) — сохраняет нотификации в контексте роутера

## Key File Patterns
- New store → subscribe/getSnapshot module in `src/stores/`, wrap with useSyncExternalStore hook in `src/hooks/`
- New service → `src/services/`, always add `restaurant_id` filter
- New page → add route in `src/App.tsx`
- restaurantContext must be init'd before any store that needs restaurant_id

## Avito Demo Bot (добавлено 2026-03-04)
- Repo: https://github.com/nickddd-hash/Avito-Bot | Local: `C:/Users/DIT/Documents/GitHub/avito-demo-bot/`
- n8n: https://n8n.flowsmart.ru | Workflow: "Avito Demo Bot - Webhook & Reply R2"
- Авито API ключи (актуальные): client_id=`8MrpTnFOg9YRkLfrRLWf`, client_secret=`fnBVRfey0QUM5Cdo9em8lBArUwgjfTgzytGyfuHI`
- Регистрация webhook: `POST /messenger/v3/webhook` с `{"url": "..."}`
- Подписки: `GET/POST /messenger/v1/subscriptions`, отписка: `POST /messenger/v1/webhook/unsubscribe`
- Отправка: `POST /messenger/v1/accounts/{user_id}/chats/{chat_id}/messages` — body `={{ JSON.stringify({...}) }}`
- **Критично**: в n8n URL/body полях ТОЛЬКО `={{ }}` синтаксис (с `=`), `{{ }}` без `=` не работает в продакшне
- **Дубли**: Авито делает retry если нет ответа за 2с — нужен "Respond to Webhook" или `responseMode: onReceived`
- **Supabase RAG**: таблица `avito_knowledge`, id=uuid; функция `match_documents` может слетать при рестарте PostgREST — пересоздавать через SQL Editor
- **Лимит Авито**: сообщения > ~1500 символов или с markdown → 400. Обрезать Code нодой до 1000 символов

## Windows / Dev Environment
- PowerShell блокирует npm: использовать `cmd /c "npm run dev"` или Git Bash в VSCode
- Dev server: http://localhost:8080/ (порт переопределён в vite.config, не 5173)
- Live Server extension — НЕ использовать для Олимпа, вызывает перезагрузки
- Открывать Олимп только через localhost:8080 в обычном браузере
