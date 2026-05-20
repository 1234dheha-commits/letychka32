-- Letychka online messenger - schema v1
-- Tables: profiles, devices, chats, chat_members, messages
-- Row-Level Security ON for every table; policies tie reads/writes to auth.uid().

-- ---------- enums ----------
do $$ begin
    create type public.chat_kind as enum ('direct', 'group');
exception when duplicate_object then null; end $$;

do $$ begin
    create type public.member_role as enum ('owner', 'admin', 'member');
exception when duplicate_object then null; end $$;

-- ---------- profiles ----------
create table if not exists public.profiles (
    id uuid primary key references auth.users(id) on delete cascade,
    username text unique not null,
    display_name text,
    avatar_url text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);
create index if not exists profiles_username_lower_idx
    on public.profiles (lower(username));

-- ---------- devices (APNs tokens) ----------
create table if not exists public.devices (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references public.profiles(id) on delete cascade,
    apns_token text unique not null,
    created_at timestamptz not null default now(),
    last_seen timestamptz not null default now()
);
create index if not exists devices_user_idx on public.devices(user_id);

-- ---------- chats ----------
create table if not exists public.chats (
    id uuid primary key default gen_random_uuid(),
    kind public.chat_kind not null,
    name text,
    created_by uuid references public.profiles(id) on delete set null,
    created_at timestamptz not null default now()
);

-- ---------- chat_members ----------
create table if not exists public.chat_members (
    chat_id uuid not null references public.chats(id) on delete cascade,
    user_id uuid not null references public.profiles(id) on delete cascade,
    role public.member_role not null default 'member',
    joined_at timestamptz not null default now(),
    primary key (chat_id, user_id)
);
create index if not exists chat_members_user_idx on public.chat_members(user_id);

-- ---------- messages ----------
create table if not exists public.messages (
    id uuid primary key default gen_random_uuid(),
    chat_id uuid not null references public.chats(id) on delete cascade,
    sender_id uuid not null references public.profiles(id) on delete cascade,
    body text,
    media_url text,
    created_at timestamptz not null default now()
);
create index if not exists messages_chat_recent_idx
    on public.messages(chat_id, created_at desc);

-- ---------- RLS ----------
alter table public.profiles      enable row level security;
alter table public.devices       enable row level security;
alter table public.chats         enable row level security;
alter table public.chat_members  enable row level security;
alter table public.messages      enable row level security;

-- profiles
drop policy if exists "profiles read all"   on public.profiles;
drop policy if exists "profiles insert own" on public.profiles;
drop policy if exists "profiles update own" on public.profiles;
create policy "profiles read all"
    on public.profiles for select to authenticated using (true);
create policy "profiles insert own"
    on public.profiles for insert to authenticated
    with check (auth.uid() = id);
create policy "profiles update own"
    on public.profiles for update to authenticated
    using (auth.uid() = id);

-- devices
drop policy if exists "devices read own"   on public.devices;
drop policy if exists "devices insert own" on public.devices;
drop policy if exists "devices update own" on public.devices;
drop policy if exists "devices delete own" on public.devices;
create policy "devices read own"
    on public.devices for select to authenticated
    using (user_id = auth.uid());
create policy "devices insert own"
    on public.devices for insert to authenticated
    with check (user_id = auth.uid());
create policy "devices update own"
    on public.devices for update to authenticated
    using (user_id = auth.uid());
create policy "devices delete own"
    on public.devices for delete to authenticated
    using (user_id = auth.uid());

-- chats
drop policy if exists "chats read for members"   on public.chats;
drop policy if exists "chats insert by creator"  on public.chats;
drop policy if exists "chats update by admins"   on public.chats;
create policy "chats read for members"
    on public.chats for select to authenticated using (
        exists (
            select 1 from public.chat_members m
            where m.chat_id = chats.id and m.user_id = auth.uid()
        )
    );
create policy "chats insert by creator"
    on public.chats for insert to authenticated
    with check (created_by = auth.uid());
create policy "chats update by admins"
    on public.chats for update to authenticated using (
        exists (
            select 1 from public.chat_members m
            where m.chat_id = chats.id
              and m.user_id = auth.uid()
              and m.role in ('owner','admin')
        )
    );

-- chat_members
drop policy if exists "chat_members read for members" on public.chat_members;
drop policy if exists "chat_members insert"           on public.chat_members;
drop policy if exists "chat_members delete"           on public.chat_members;
create policy "chat_members read for members"
    on public.chat_members for select to authenticated using (
        exists (
            select 1 from public.chat_members me
            where me.chat_id = chat_members.chat_id
              and me.user_id = auth.uid()
        )
    );
create policy "chat_members insert"
    on public.chat_members for insert to authenticated with check (
        -- creator joining as owner during chat creation
        (user_id = auth.uid() and role = 'owner')
        or exists (
            select 1 from public.chat_members me
            where me.chat_id = chat_members.chat_id
              and me.user_id = auth.uid()
              and me.role in ('owner','admin')
        )
    );
create policy "chat_members delete"
    on public.chat_members for delete to authenticated using (
        user_id = auth.uid()
        or exists (
            select 1 from public.chat_members me
            where me.chat_id = chat_members.chat_id
              and me.user_id = auth.uid()
              and me.role in ('owner','admin')
        )
    );

-- messages
drop policy if exists "messages read for members" on public.messages;
drop policy if exists "messages insert by members" on public.messages;
drop policy if exists "messages delete own"        on public.messages;
create policy "messages read for members"
    on public.messages for select to authenticated using (
        exists (
            select 1 from public.chat_members m
            where m.chat_id = messages.chat_id
              and m.user_id = auth.uid()
        )
    );
create policy "messages insert by members"
    on public.messages for insert to authenticated with check (
        sender_id = auth.uid()
        and exists (
            select 1 from public.chat_members m
            where m.chat_id = messages.chat_id
              and m.user_id = auth.uid()
        )
    );
create policy "messages delete own"
    on public.messages for delete to authenticated
    using (sender_id = auth.uid());
