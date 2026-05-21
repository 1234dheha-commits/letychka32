-- Letychka schema v1.3 - media messages + presence
--
-- Adds:
--   * messages.kind            ('text' | 'image' | 'audio')
--   * messages.duration_ms     audio length in ms (null for text/image)
--   * messages.width, .height  image dimensions in px (null for text/audio)
--   * profiles.last_seen_at    presence timestamp (null = never seen)
--   * profiles.online_visible  user-controlled "hide online" toggle
--   * storage bucket 'chat-media' for photos/voices with per-user RLS
--
-- All new columns are nullable / have defaults, so existing rows keep working
-- and the iOS client can run against either an unmigrated or migrated DB.

-- ---------- message kind enum ----------
do $$ begin
    create type public.msg_kind as enum ('text', 'image', 'audio');
exception when duplicate_object then null; end $$;

-- ---------- messages additions ----------
alter table public.messages
    add column if not exists kind public.msg_kind not null default 'text';
alter table public.messages
    add column if not exists duration_ms integer;
alter table public.messages
    add column if not exists width  integer;
alter table public.messages
    add column if not exists height integer;

-- ---------- profiles additions ----------
alter table public.profiles
    add column if not exists last_seen_at timestamptz;
alter table public.profiles
    add column if not exists online_visible boolean not null default true;

-- ---------- presence helper RPC ----------
-- Cheap UPDATE that only touches the caller's own row and only when the user
-- has not explicitly hidden their online status. Returning void keeps the
-- caller code short on the client (.rpc("touch_presence")).
create or replace function public.touch_presence()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    update public.profiles
       set last_seen_at = now()
     where id = auth.uid()
       and online_visible = true;
end;
$$;
grant execute on function public.touch_presence() to authenticated;

-- ---------- storage bucket for chat media ----------
-- Public read so URLs work without signed-link bookkeeping. Writes restricted
-- to the owner's own folder via the per-user prefix `<auth.uid>/...`.
insert into storage.buckets (id, name, public)
values ('chat-media', 'chat-media', true)
on conflict (id) do nothing;

drop policy if exists "chat-media read any"      on storage.objects;
drop policy if exists "chat-media insert own"    on storage.objects;
drop policy if exists "chat-media delete own"    on storage.objects;

create policy "chat-media read any"
    on storage.objects for select
    using (bucket_id = 'chat-media');

create policy "chat-media insert own"
    on storage.objects for insert
    to authenticated
    with check (
        bucket_id = 'chat-media'
        and auth.uid()::text = (storage.foldername(name))[1]
    );

create policy "chat-media delete own"
    on storage.objects for delete
    to authenticated
    using (
        bucket_id = 'chat-media'
        and auth.uid()::text = (storage.foldername(name))[1]
    );
