-- Client follows (portal → My team → Following / Followers). Applied as migration client_follows.
create table if not exists public.client_follows (
  follower uuid not null references public.profiles (id) on delete cascade,
  followee uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower, followee),
  check (follower <> followee));
create index if not exists client_follows_followee on public.client_follows (followee);
alter table public.client_follows enable row level security;
create policy "see follows that involve you" on public.client_follows for select to authenticated
  using (follower = (select auth.uid()) or followee = (select auth.uid()));
create policy "stop following" on public.client_follows for delete to authenticated using (follower = (select auth.uid()));
-- follow_set(person, on_): follow or unfollow a client who is visible in Messages and not blocked.
-- follow_lists(): { following, followers, suggested, counts } with hidden and blocked people left out.
-- Full function bodies: see the applied migration in Supabase (client_follows).
