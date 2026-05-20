-- Letychka schema v1.1 - fix infinite recursion in RLS policies
--
-- The original chat_members SELECT policy did:
--   USING (exists (select 1 from chat_members me where ...))
-- but the inner select also runs through RLS, which re-triggers the same
-- policy, which Postgres correctly refuses with
--   "infinite recursion detected in policy for relation chat_members".
-- The recursion silently broke every INSERT into chat_members (the new
-- row's WITH CHECK referenced chat_members again), so users could create
-- chats but never join them, and openDirectChat / createGroup looked dead
-- on the client. Same recursion lurked in chats + messages SELECT.
--
-- Fix: wrap the membership checks in SECURITY DEFINER helper functions.
-- Inside a SECURITY DEFINER function RLS does NOT apply to the body's
-- queries, so the inner select runs against the raw table and there's no
-- cycle. The function still uses auth.uid() so it stays scoped to the
-- caller, just without the recursive policy evaluation.

-- ---------- helper functions ----------
create or replace function public.is_chat_member(p_chat uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.chat_members
    where chat_id = p_chat
      and user_id = auth.uid()
  );
$$;

create or replace function public.is_chat_admin(p_chat uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.chat_members
    where chat_id = p_chat
      and user_id = auth.uid()
      and role in ('owner', 'admin')
  );
$$;

-- These helpers must be callable from the API layer.
grant execute on function public.is_chat_member(uuid) to authenticated;
grant execute on function public.is_chat_admin(uuid)  to authenticated;

-- ---------- chat_members ----------
drop policy if exists "chat_members read for members" on public.chat_members;
drop policy if exists "chat_members insert"           on public.chat_members;
drop policy if exists "chat_members delete"           on public.chat_members;

create policy "chat_members read for members"
  on public.chat_members for select to authenticated
  using (public.is_chat_member(chat_id));

create policy "chat_members insert"
  on public.chat_members for insert to authenticated
  with check (
    -- creator joining as owner the moment the chat is born
    (user_id = auth.uid() and role = 'owner')
    -- or I am already an owner/admin adding someone
    or public.is_chat_admin(chat_id)
  );

create policy "chat_members delete"
  on public.chat_members for delete to authenticated
  using (
    user_id = auth.uid()
    or public.is_chat_admin(chat_id)
  );

-- ---------- chats ----------
drop policy if exists "chats read for members"  on public.chats;
drop policy if exists "chats update by admins"  on public.chats;

create policy "chats read for members"
  on public.chats for select to authenticated
  using (public.is_chat_member(id));

create policy "chats update by admins"
  on public.chats for update to authenticated
  using (public.is_chat_admin(id));

-- ---------- messages ----------
drop policy if exists "messages read for members"  on public.messages;
drop policy if exists "messages insert by members" on public.messages;

create policy "messages read for members"
  on public.messages for select to authenticated
  using (public.is_chat_member(chat_id));

create policy "messages insert by members"
  on public.messages for insert to authenticated
  with check (
    sender_id = auth.uid()
    and public.is_chat_member(chat_id)
  );

-- ---------- clean up orphans from the bug period ----------
-- Chats that were created during the recursion bug but never got their
-- chat_members row would otherwise pile up forever. Delete any chat
-- that has zero members; CASCADE on messages handles those too.
delete from public.chats c
where not exists (
  select 1 from public.chat_members m where m.chat_id = c.id
);
