-- Letychka schema v1.2 - per-member last-read timestamp for read receipts
--
-- Adds chat_members.last_read_at. The client UPDATEs it to now() each
-- time the user opens that chat. For an outgoing message, the sender
-- can compute "read" by checking: any other member with last_read_at
-- >= the message's created_at. Cheap, no extra rows, no fan-out.

alter table public.chat_members
  add column if not exists last_read_at timestamptz not null default now();

create index if not exists chat_members_last_read_idx
  on public.chat_members(chat_id, last_read_at);
