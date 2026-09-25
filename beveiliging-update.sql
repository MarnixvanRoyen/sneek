-- Sneek op z'n Haags: beveiliging highscorelèst (update 25 sept 2026)
-- Doel: 1 regel per speler (alleen de beste score telt) + een rem tegen spam.
-- Voer DEEL A en DEEL B los van elkaar uit (zie uitleg in de chat).

-- =====================================================================
-- DEEL A  (eerst uitvoeren, daarna het spel online zetten met git push)
-- =====================================================================

-- A1. Dubbele namen opruimen: per Insta-naam blijft alleen de beste score staan
--     (bij gelijke score blijft de oudste staan).
delete from public.scores a
using public.scores b
where a.insta = b.insta
  and (a.score < b.score or (a.score = b.score and a.id > b.id));

-- A2. Vanaf nu mag elke Insta-naam maar 1 keer in de tabel staan.
alter table public.scores
  add constraint scores_insta_uniek unique (insta);

-- A3. De "poortwachter": het spel stuurt scores voortaan hierheen.
create or replace function public.bewaar_score(p_insta text, p_score integer)
returns void
language plpgsql
security definer          -- de functie mag zelf in de tabel schrijven, de bezoeker niet
set search_path = ''      -- veiligheid: alleen expliciet genoemde tabellen gebruiken
as $$
begin
  -- Naam en score controleren (zelfde regels als de tabel)
  if p_insta is null or p_insta !~ '^[a-z0-9._]{1,30}$' then
    raise exception 'ongeldige naam';
  end if;
  if p_score is null or p_score < 1 or p_score > 1000 then
    raise exception 'ongeldige score';
  end if;

  -- Rem voor iedereen samen: max 30 nieuwe/verbeterde scores per minuut
  if (select count(*) from public.scores
      where created_at > now() - interval '1 minute') >= 30 then
    raise exception 'te druk';
  end if;

  -- Rem per speler: dezelfde naam max 1 keer per 30 seconden
  if exists (select 1 from public.scores
             where insta = p_insta
               and created_at > now() - interval '30 seconds') then
    raise exception 'effe wachten';
  end if;

  -- Nieuwe speler: toevoegen. Bestaande speler: alleen bijwerken als de score hoger is.
  insert into public.scores (insta, score)
  values (p_insta, p_score)
  on conflict (insta) do update
    set score = excluded.score, created_at = now()
    where public.scores.score < excluded.score;
end;
$$;

-- A4. Bezoekers (anon) mogen de poortwachter gebruiken.
revoke all on function public.bewaar_score(text, integer) from public;
grant execute on function public.bewaar_score(text, integer) to anon;


-- =====================================================================
-- DEEL B  (pas uitvoeren NA de git push, als het nieuwe spel online staat)
-- =====================================================================

-- B1. Rechtstreeks toevoegen in de tabel mag niet meer: alleen via de poortwachter.
drop policy if exists "iedereen mag een score toevoegen" on public.scores;
revoke insert, update, delete on public.scores from anon;
