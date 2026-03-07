-- Migration: create avito_paused_chats table
-- Purpose: track chats where the bot is paused (human handoff)

CREATE TABLE avito_paused_chats (
  chat_id TEXT PRIMARY KEY,
  paused_at TIMESTAMP DEFAULT NOW()
);
