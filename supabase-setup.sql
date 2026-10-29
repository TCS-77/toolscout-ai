-- ToolScout AI community database setup
-- Run this entire script in Supabase: SQL Editor -> New query -> Run.
-- This creates user profiles and a moderated community tool-submission table.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.community_tools (
  id uuid primary key default gen_random_uuid(),
  created_by uuid not null references auth.users(id) on delete cascade,
  name text not null check (char_length(name) between 2 and 80),
  website_url text not null check (website_url ~* '^https?://'),
  description text not null check (char_length(description) between 15 and 700),
  category text not null check (char_length(category) between 2 and 50),
  pricing text not null check (pricing in ('Free','Free plan available','Paid','Unknown')),
  creator_name text check (creator_name is null or char_length(creator_name) <= 50),
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now()
);

create index if not exists community_tools_status_created_at_idx
  on public.community_tools(status, created_at desc);
create index if not exists community_tools_created_by_idx
  on public.community_tools(created_by);

alter table public.profiles enable row level security;
alter table public.community_tools enable row level security;

-- A helper keeps admin checks consistent. Users cannot grant themselves admin
-- because profile updates below do not allow changing is_admin.
create or replace function public.is_toolscout_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and is_admin = true
  );
$$;

grant execute on function public.is_toolscout_admin() to authenticated;

drop policy if exists "Profiles are viewable by owner" on public.profiles;
create policy "Profiles are viewable by owner"
  on public.profiles for select
  to authenticated
  using (id = auth.uid() or public.is_toolscout_admin());

drop policy if exists "Users can update their own display name" on public.profiles;
create policy "Users can update their own display name"
  on public.profiles for update
  to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

drop policy if exists "Anyone can view approved community tools" on public.community_tools;
create policy "Anyone can view approved community tools"
  on public.community_tools for select
  to anon, authenticated
  using (status = 'approved' or created_by = auth.uid() or public.is_toolscout_admin());

drop policy if exists "Signed-in users can submit pending tools" on public.community_tools;
create policy "Signed-in users can submit pending tools"
  on public.community_tools for insert
  to authenticated
  with check (created_by = auth.uid() and status = 'pending');

drop policy if exists "Admins can update community submissions" on public.community_tools;
create policy "Admins can update community submissions"
  on public.community_tools for update
  to authenticated
  using (public.is_toolscout_admin())
  with check (public.is_toolscout_admin());

drop policy if exists "Admins can delete community submissions" on public.community_tools;
create policy "Admins can delete community submissions"
  on public.community_tools for delete
  to authenticated
  using (public.is_toolscout_admin());

-- Automatically create a profile whenever someone signs up.
create or replace function public.handle_new_toolscout_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'display_name', split_part(new.email, '@', 1)));
  return new;
end;
$$;

drop trigger if exists on_toolscout_auth_user_created on auth.users;
create trigger on_toolscout_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_toolscout_user();

-- IMPORTANT: After creating your own account, make it the first admin by
-- running this separately in the SQL Editor, replacing the email:
-- update public.profiles
-- set is_admin = true
-- where id = (select id from auth.users where email = 'YOUR-EMAIL-HERE');
--
-- Keep the Supabase service_role key private. Only the project URL and anon /
-- publishable key belong in the public website. Never disable RLS.
