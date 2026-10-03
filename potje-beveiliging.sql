-- Sneek op z'n Haags: beveiliging laag 1 tegen gescripte scores (chat 12, 02-10-2026)
-- Supabase-project "Haagse Content" (ref bbmsggyqbhbcrziyblhr). Archief: de SQL staat ook in de chat.
--
-- Wat het doet:
--   1. Potje-kaartje: bij "Beginne" vraagt het spel een eenmalig kaartje aan (start_potje). De server noteert de starttijd.
--   2. Scores gaan voortaan via bewaar_score_potje: alleen met een geldig, ongebruikt kaartje,
--      en alleen als de score in de verstreken tijd mogelijk is (ruime marge, zie sneek_min_ms).
--   3. Limiet per IP (naast de bestaande per naam en voor iedereen samen). Het IP wordt niet bewaard, alleen een
--      onherkenbare hash, en kaartjes worden na 2 dagen weggegooid.
--   4. Geweigerde pogingen komen in score_poging (voor de opruim-query), 30 dagen bewaard.
--
-- Volgorde: DEEL A draaien -> daarna pushen -> ± 1 uur later DEEL B (oude deur dicht).

-- =====================================================================
-- DEEL A  (vóór het pushen)
-- =====================================================================

-- A1. Geheim zout voor de IP-hash (alleen de database zelf kan het lezen)
create table if not exists public.sneek_geheim (id int primary key default 1 check (id = 1), zout text not null,
  sinds timestamptz not null default now());   -- sinds = moment dat de kaartjes begonnen (voor de opruim-query)
insert into public.sneek_geheim (zout) values (md5(random()::text || clock_timestamp()::text)) on conflict (id) do nothing;

-- A2. Kaartjes: één per gestart potje
create table if not exists public.potjes (
  id        uuid primary key default gen_random_uuid(),
  gestart   timestamptz not null default now(),
  ip_hash   text not null,
  ingeleverd timestamptz,
  insta     text,
  score     integer,
  goed      boolean
);
create index if not exists potjes_gestart on public.potjes (gestart);
create index if not exists potjes_ip on public.potjes (ip_hash, gestart);

-- A3. Geweigerde pogingen (om te bekèke)
create table if not exists public.score_poging (
  id      bigint generated always as identity primary key,
  tijd    timestamptz not null default now(),
  insta   text,
  score   integer,
  reden   text not null,
  ip_hash text,
  potje   uuid,
  speeltijd_s numeric
);
create index if not exists score_poging_ip on public.score_poging (ip_hash, tijd);

-- A4. Niemand van buitenaf mag in deze tabellen kijken of schrijven (Supabase geeft standaard rechten aan anon/authenticated)
alter table public.sneek_geheim enable row level security;
alter table public.potjes       enable row level security;
alter table public.score_poging enable row level security;
revoke all on public.sneek_geheim, public.potjes, public.score_poging from anon, authenticated;
-- Extra slot op de scorelèst zelf: bezoekers en ingelogde gebruikers mogen alleen lezen (schrijven gaat via de functie).
-- (RLS hield dit al tegen; dit is een tweede slot, ook tegen TRUNCATE dat niet onder RLS valt.)
revoke insert, update, delete, truncate, references, trigger on public.scores from anon, authenticated;

-- A5. IP van de speler -> hash. Cloudflare zet cf-connecting-ip (niet na te maken door de speler);
--     anders het LAATSTE adres uit x-forwarded-for (het eerste kan de speler zelf meesturen).
create or replace function public.sneek_ip_hash()
returns text language plpgsql stable security definer set search_path = '' as $$
declare h json; ip text;
begin
  h := nullif(current_setting('request.headers', true), '')::json;
  ip := nullif(trim(h->>'cf-connecting-ip'), '');
  if ip is null then
    ip := nullif(trim(reverse(split_part(reverse(coalesce(h->>'x-forwarded-for', '')), ',', 1))), '');
  end if;
  return md5((select zout from public.sneek_geheim where id = 1) || coalesce(ip, 'onbekend'));
end; $$;

-- A6. Minimale speeltijd (ms) voor een score. Basis: 20.000 gesimuleerde potjes van een "perfecte" speler
--     (altijd de kortste weg, nooit dood, rekent het snelste tempo, koffiekick en dubbele punte mee).
--     Tabel = snelste tijd (s) per 50 punten. Eis = de helft daarvan min 3 s, minimaal 1 s.
--     Voorbeeld: 100 punte -> 4,5 s (echte spelers doen er gemiddeld ± 45 s over), 500 -> 48 s, 1000 -> 108 s.
create or replace function public.sneek_min_ms(p_score integer)
returns integer language sql immutable set search_path = '' as $$
  select greatest(1000, round(((array[0,5.6,14.9,23.8,32.9,43.2,50.9,67.1,75,87.3,102.4,109.8,116.9,131.1,146.9,158.2,174.7,183.4,201.7,209.3,222.2])
           [least(greatest(p_score, 0), 1000) / 50 + 1] * 0.5 - 3) * 1000))::integer;
$$;

-- A7. Kaartje aanvragen bij de start van een potje
create or replace function public.start_potje()
returns uuid language plpgsql volatile security definer set search_path = '' as $$
declare ip text := public.sneek_ip_hash(); nieuw uuid;
begin
  -- Rem per IP: max 150 potjes per 10 minuten (ook gedeelde wifi, bv. een café, blijft zo werken)
  if (select count(*) from public.potjes where ip_hash = ip and gestart > now() - interval '10 minutes') >= 150 then
    raise exception 'effe wachten';
  end if;
  -- Rem voor iedereen samen: max 3000 potjes per uur
  if (select count(*) from public.potjes where gestart > now() - interval '1 hour') >= 3000 then
    raise exception 'te druk';
  end if;
  insert into public.potjes (ip_hash) values (ip) returning id into nieuw;
  -- Af en toe opruimen: kaartjes ouder dan 2 dagen, pogingen ouder dan 30 dagen
  if random() < 0.02 then
    delete from public.potjes where gestart < now() - interval '2 days';
    delete from public.score_poging where tijd < now() - interval '30 days';
  end if;
  return nieuw;
end; $$;

-- A8. Nieuwe poortwachter: score opslaan mét kaartje
create or replace function public.bewaar_score_potje(p_potje uuid, p_insta text, p_score integer)
returns void language plpgsql volatile security definer set search_path = '' as $$
declare ip text := public.sneek_ip_hash(); k public.potjes%rowtype; ms numeric;
begin
  -- Zelfde basisregels als altijd
  if p_insta is null or p_insta !~ '^[a-z0-9._]{1,30}$' then raise exception 'niet gelukt'; end if;
  if p_score is null or p_score < 1 or p_score > 1000 then raise exception 'niet gelukt'; end if;

  -- Rem per IP: max 10 per minuut en 60 per uur (pogingen die geweigerd zijn tellen ook mee)
  if (select count(*) from public.potjes where ip_hash = ip and ingeleverd > now() - interval '1 minute')
   + (select count(*) from public.score_poging where ip_hash = ip and tijd > now() - interval '1 minute') >= 10
  or (select count(*) from public.potjes where ip_hash = ip and ingeleverd > now() - interval '1 hour')
   + (select count(*) from public.score_poging where ip_hash = ip and tijd > now() - interval '1 hour') >= 60 then
    raise exception 'effe wachten';
  end if;
  -- Bestaande remmen: iedereen samen max 30 per minuut, zelfde naam max 1 keer per 30 seconden
  if (select count(*) from public.scores where created_at > now() - interval '1 minute') >= 30 then
    raise exception 'te druk';
  end if;
  if exists (select 1 from public.scores where insta = p_insta and created_at > now() - interval '30 seconds') then
    raise exception 'effe wachten';
  end if;

  -- Kaartje controleren (en vastzetten, zodat het maar 1 keer kan)
  select * into k from public.potjes where id = p_potje for update;
  if not found or k.ingeleverd is not null or k.gestart < now() - interval '12 hours' then
    insert into public.score_poging (insta, score, reden, ip_hash, potje)
    values (p_insta, p_score, case when not found then 'geen kaartje' when k.ingeleverd is not null then 'kaartje al gebruikt' else 'kaartje verlopen' end, ip, p_potje);
    return;   -- stil weigeren: geen foutmelding die de regels verraadt (de speler komt gewoon niet op de lèst)
  end if;

  -- Tijdcheck: kon deze score in deze tijd?
  ms := extract(epoch from (now() - k.gestart)) * 1000;
  if ms < public.sneek_min_ms(p_score) then
    insert into public.score_poging (insta, score, reden, ip_hash, potje, speeltijd_s)
    values (p_insta, p_score, 'te snel', ip, p_potje, round(ms / 1000, 1));
    update public.potjes set ingeleverd = now(), insta = p_insta, score = p_score, goed = false where id = p_potje;
    return;   -- stil weigeren
  end if;

  update public.potjes set ingeleverd = now(), insta = p_insta, score = p_score, goed = true where id = p_potje;
  insert into public.scores (insta, score)
  values (p_insta, p_score)
  on conflict (insta) do update
    set score = excluded.score, created_at = now()
    where public.scores.score < excluded.score;
end; $$;

-- A9. Rechten: alleen bezoekers (anon) mogen de twee deuren gebruiken; de hulpfuncties niemand van buitenaf.
--     Let op: Supabase geeft nieuwe functies standaard óók aan authenticated, dus dat expliciet weghalen.
revoke all on function public.start_potje()                              from public, anon, authenticated;
revoke all on function public.bewaar_score_potje(uuid, text, integer)   from public, anon, authenticated;
revoke all on function public.sneek_ip_hash()                            from public, anon, authenticated;
revoke all on function public.sneek_min_ms(integer)                      from public, anon, authenticated;
grant execute on function public.start_potje()                            to anon;
grant execute on function public.bewaar_score_potje(uuid, text, integer) to anon;


-- =====================================================================
-- DEEL B  (± 1 uur NA het pushen: oude deur dicht)
-- De oude pagina (in iemands cache) gebruikte bewaar_score zonder kaartje. GitHub Pages bewaart een pagina
-- 10 minuten in de cache; na een uur heeft vrijwel niemand de oude versie nog. Wie toch nog de oude pagina open had,
-- ziet "Opslaan lukte niet"; opnieuw laden lost het op.
-- =====================================================================
-- drop function if exists public.bewaar_score(text, integer);


-- =====================================================================
-- CONTROLE: wie mag wat? (na DEEL A en na DEEL B)
-- =====================================================================
-- select 'tabel' soort, table_name naam, grantee, string_agg(privilege_type, ', ' order by privilege_type) rechten
--   from information_schema.role_table_grants
--  where table_schema = 'public' and table_name in ('scores','potjes','score_poging','sneek_geheim') and grantee in ('anon','authenticated')
--  group by table_name, grantee
-- union all
-- select 'functie', routine_name, grantee, string_agg(privilege_type, ', ')
--   from information_schema.routine_privileges
--  where routine_schema = 'public' and routine_name in ('bewaar_score','bewaar_score_potje','start_potje','sneek_ip_hash','sneek_min_ms') and grantee in ('anon','authenticated','PUBLIC')
--  group by routine_name, grantee
-- union all
-- select 'regel (policy)', tablename, array_to_string(roles, ','), cmd from pg_policies where schemaname = 'public' and tablename = 'scores'
-- order by 1, 2, 3;


-- =====================================================================
-- OPRUIM-QUERY (af en toe draaien): welke scores op de lèst zijn verdacht?
-- Kolom "waarom" legt het uit. Lege "waarom" = niks aan de hand. Verwijderen: zie onderaan.
-- =====================================================================
-- with s as (
--   select s.insta, s.score, s.created_at, p.ip_hash,
--          round(extract(epoch from p.ingeleverd - p.gestart)) speeltijd_s,
--          public.sneek_min_ms(s.score) / 1000.0 min_s
--     from public.scores s
--     left join lateral (select * from public.potjes p where p.insta = s.insta and p.score = s.score and p.goed
--                         order by p.ingeleverd desc limit 1) p on true
-- )
-- select rank() over (order by score desc) plek, insta, score,
--        to_char(created_at at time zone 'Europe/Amsterdam', 'DD-MM HH24:MI:SS') tijd, speeltijd_s,
--        concat_ws(' · ',
--          case when ip_hash is null and created_at > (select sinds from public.sneek_geheim) + interval '2 days' then 'zonder kaartje opgeslagen' end,
--          case when ip_hash is null and created_at <= (select sinds from public.sneek_geheim) then 'van vóór de kaartjes (niet te controleren)' end,
--          case when ip_hash is null and created_at > (select sinds from public.sneek_geheim) and created_at <= (select sinds from public.sneek_geheim) + interval '2 days' then 'via de oude deur (overgang)' end,
--          case when speeltijd_s < 2 * min_s then 'krap aan de snelste mogelijke tijd' end,
--          case when ip_hash is not null and (select count(distinct q.insta) from public.potjes q where q.ip_hash = s.ip_hash and q.goed) >= 5
--               then 'zelfde apparaat/wifi met 5+ namen' end,
--          case when score >= 300 then 'heel hoog (huidige top ligt rond de 110)' end) waarom
--   from s
--  order by (case when ip_hash is null and created_at <= (select sinds from public.sneek_geheim) then 1 else 0 end), score desc;

-- Geweigerde pogingen per soort (wie probeert het?):
-- select reden, count(*) pogingen, count(distinct ip_hash) apparaten, max(score) hoogste,
--        to_char(max(tijd) at time zone 'Europe/Amsterdam', 'DD-MM HH24:MI') laatste
--   from public.score_poging group by reden order by pogingen desc;

-- Verwijderen (namen invullen, zonder @):
-- delete from public.scores where insta in ('naam1', 'naam2');
