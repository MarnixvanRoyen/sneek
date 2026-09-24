-- Sneek op z'n Haags: tabel voor de highscorelèst
-- Plak dit in Supabase > SQL Editor en klik op "Run".

create table if not exists public.scores (
  id         bigint generated always as identity primary key,
  insta      text        not null check (insta ~ '^[a-z0-9._]{1,30}$'),
  score      integer     not null check (score between 1 and 1000),
  created_at timestamptz not null default now()
);

create index if not exists scores_score_idx on public.scores (score desc);

-- Beveiliging: iedereen mag de lijst lezen en een score toevoegen,
-- maar niemand mag scores wijzigen of verwijderen (behalve jij in het dashboard).
alter table public.scores enable row level security;

create policy "iedereen mag lezen"
  on public.scores for select
  to anon
  using (true);

create policy "iedereen mag een score toevoegen"
  on public.scores for insert
  to anon
  with check (true);

grant select, insert on public.scores to anon;
