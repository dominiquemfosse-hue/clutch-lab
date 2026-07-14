-- ═══════ 20260710_blocage_annule_verrou.sql ═══════
-- ============================================================================
-- P0 #5 — BLOQUER N'ANNULE PAS LE VERROU ACTIF — 10.07.2026
--
-- SYMPTÔME HUMAIN : Alice est au café avec Bob (Verrou actif). Il la met mal à l'aise, elle le bloque.
-- Mais le blocage ne faisait qu'un insert dans `blocks` (masquage des présences FUTURES) → le Verrou
-- reste « confirmé », le CHAT reste ouvert, Bob peut continuer à lui écrire. Bloquer quelqu'un pendant
-- qu'on est physiquement avec lui doit couper TOUT lien, pas juste le masquer des découvertes.
--
-- FIX : RPC gardée cancel_active_clutches_with(p_other) — passe tout clutch ACTIF entre les deux en
-- 'cancelled' (l'app ferme alors le chat, l'app gère déjà 'cancelled') et libère l'occupation.
-- SILENCIEUX (décision David) : aucune notif à la personne bloquée — on n'alerte pas un harceleur.
-- Appelée par handleBlock côté app (commit séparé).
-- ============================================================================

create or replace function public.cancel_active_clutches_with(p_other uuid)
returns int language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); n int := 0;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  with cancelled as (
    update public.clutches set status = 'cancelled'
     where status in ('pending','accepted','counter','confirmed','checked_in')
       and ((sender_id = me and receiver_id = p_other) or (sender_id = p_other and receiver_id = me))
     returning id
  ), freed as (
    delete from public.occupancies where source_id in (select id from cancelled) returning 1
  )
  select count(*) into n from cancelled;
  return n;
end; $$;

grant execute on function public.cancel_active_clutches_with(uuid) to authenticated;

-- ── ROLLBACK ────────────────────────────────────────────────────────────────
-- drop function if exists public.cancel_active_clutches_with(uuid);

-- ═══════ 20260710_cooldown_sur_ignore.sql ═══════
-- ============================================================================
-- P0 #2 — HARCÈLEMENT : le cooldown se contournait quand elle IGNORE — 10.07.2026
--
-- AVANT : le cooldown anti-re-propositions (clutch_pairs, migration 20260626) ne se posait QUE sur un
-- refus explicite (status → 'declined'). Si la cible IGNORE (le clutch expire, status → 'expired'),
-- aucun cooldown → l'émetteur peut re-proposer en boucle = harcèlement.
--
-- RÈGLE DAVID (le juste milieu, pas un mur) :
--   • Un IGNORE n'est PAS un refus : elle a peut-être juste découvert l'app / oublié de répondre.
--   • → On laisse UNE chance : le 1er ignore est pardonné (il peut re-proposer une fois).
--   • → À partir du 2e ignore (fenêtre glissante 90 j) : cooldown MODÉRÉ de 7 jours
--        (« entre les deux » — plus doux que l'escalade d'un refus 48h→7j→30j→180j).
--   • Si elle ACCEPTE un jour : le compteur d'ignores repart à 0 (elle est engagée, pas une ignoreuse).
--
-- Réutilise la table clutch_pairs + le cooldown_until déjà vérifié par create_clutch(). Requiert
-- 20260626 (clutch_pairs) appliqué — l'est, car create_clutch() en dépend.
-- ============================================================================

alter table public.clutch_pairs
  add column if not exists ignores_count  int not null default 0,
  add column if not exists last_ignore_at timestamptz;

create or replace function public.register_clutch_ignore()
returns trigger language plpgsql security definer set search_path = public as $$
declare fresh boolean; n int;
begin
  -- Elle a répondu positivement → on efface le signal d'ignore (elle n'ignore pas).
  if new.status in ('accepted','confirmed','checked_in') and old.status = 'pending' then
    update public.clutch_pairs set ignores_count = 0, updated_at = now()
      where actor_id = new.sender_id and target_id = new.receiver_id;
    return new;
  end if;

  -- Proposé jamais répondu qui expire = "ignoré" (signal doux, ≠ refus explicite).
  if new.status = 'expired' and old.status = 'pending' then
    select cp.last_ignore_at > now() - interval '90 days', cp.ignores_count
      into fresh, n
      from public.clutch_pairs cp
     where cp.actor_id = new.sender_id and cp.target_id = new.receiver_id;
    n := case when fresh then coalesce(n,0) + 1 else 1 end;

    insert into public.clutch_pairs (actor_id, target_id, ignores_count, last_ignore_at, updated_at, cooldown_until)
    values (new.sender_id, new.receiver_id, n, now(), now(), null)  -- 1er ignore : aucun cooldown (la chance)
    on conflict (actor_id, target_id) do update set
      ignores_count  = n,
      last_ignore_at = now(),
      updated_at     = now(),
      -- 2e ignore et + → cooldown 7 j ; on ne raccourcit jamais un cooldown de refus déjà plus long.
      cooldown_until = case when n >= 2
        then greatest(coalesce(clutch_pairs.cooldown_until, now()), now() + interval '7 days')
        else clutch_pairs.cooldown_until end;
  end if;
  return new;
end; $$;

drop trigger if exists trg_clutch_ignore on public.clutches;
create trigger trg_clutch_ignore after update on public.clutches
  for each row execute function public.register_clutch_ignore();

-- ── ROLLBACK ────────────────────────────────────────────────────────────────
-- drop trigger if exists trg_clutch_ignore on public.clutches;
-- drop function if exists public.register_clutch_ignore();
-- alter table public.clutch_pairs drop column if exists ignores_count, drop column if exists last_ignore_at;

-- ═══════ 20260710_feedback_applique_a_la_cible.sql ═══════
-- ============================================================================
-- P0 #3 — FEEDBACK À L'ENVERS : le lapin punissait le RAPPORTEUR — 10.07.2026
--
-- SYMPTÔME HUMAIN : Alice se fait poser un lapin, le signale honnêtement (🐰 -5)… et c'est ELLE
-- qui perd 5 points de fiabilité. Bob (le fautif) garde un score intact. Justice inversée sur LA
-- fonction centrale du produit (la fiabilité comportementale = « le tueur invisible »).
--
-- CAUSE : le client applique le delta d'outcome à SON PROPRE score (app2 onScore → user.id), et
-- AUCUN process serveur n'applique jamais pts au to_id. is_revealed n'est jamais passé à true → la
-- révélation cachée 3h ne se produit pas non plus.
--
-- FIX SERVEUR : apply_revealed_feedback() (cron 10 min) — à l'échéance revealed_at, applique les
-- points de l'outcome à la CIBLE (to_id), jamais au rapporteur, et marque is_revealed=true (idempotent,
-- atomique : le UPDATE...RETURNING ne réclame chaque feedback qu'une fois). Double-révélation cachée
-- préservée : le score bouge au moment de la révélation, pas à l'instant du signalement.
-- (Côté client : onScore ne modifie plus le score du rapporteur — commit app séparé.)
-- ============================================================================

create or replace function public.apply_revealed_feedback()
returns int language plpgsql security definer set search_path = public as $$
declare n int := 0;
begin
  with due as (
    -- réclame atomiquement les feedbacks échus non révélés (false→true = réclamé une seule fois)
    update public.rdv_feedbacks
       set is_revealed = true
     where is_revealed = false and revealed_at is not null and revealed_at <= now()
     returning to_id, outcome
  ), deltas as (
    select to_id,
           sum(case outcome when 'on_time' then 2 when 'showed' then 1 when 'absent' then -5 else 0 end) as d
      from due
     group by to_id
  )
  update public.profiles p
     set reliability_score = greatest(0, least(100, coalesce(p.reliability_score, 80) + deltas.d))
    from deltas
   where p.id = deltas.to_id;
  get diagnostics n = row_count;
  return n;
end; $$;

-- Cron toutes les 10 min (idempotent, silencieux si pg_cron absent → sinon planifier via dashboard Cron)
do $$ begin
  perform cron.schedule('apply-revealed-feedback', '*/10 * * * *', 'select public.apply_revealed_feedback()');
exception when others then null; end $$;

-- ── ROLLBACK ────────────────────────────────────────────────────────────────
-- select cron.unschedule('apply-revealed-feedback');
-- drop function if exists public.apply_revealed_feedback();

-- ═══════ 20260710_fix_double_event_occupancy_trigger.sql ═══════
-- ============================================================================
-- P0 #6 — LES ÉVÉNEMENTS SONT INJOIGNABLES (double trigger d'occupation) — 10.07.2026
--
-- SYMPTÔME HUMAIN : « Rejoindre » n'importe quel event à heure réelle → « tu as déjà un
-- rendez-vous à cette heure » ALORS QUE l'agenda est vide. Aucun event ne se remplit → events morts.
--
-- CAUSE RACINE (audit) : DEUX triggers coexistent sur event_participants —
--   • trg_event_occupancy         (20260627_event_model.sql, JAMAIS supprimé)
--   • trg_sync_event_occupancy    (20260709_event_occupancy.sql)
-- Les deux appellent sync_event_occupancy(). La version 20260709 fait un INSERT dans occupancies
-- SANS delete idempotent préalable → sur une seule insertion de participant, les 2 triggers insèrent
-- DEUX lignes occupancies IDENTIQUES → la 2ᵉ viole occ_no_overlap → tout l'INSERT du participant
-- échoue (23P01), attrapé côté app comme « déjà un RDV ».
--
-- FIX (les deux, ceinture + bretelles) :
--   1) rendre sync_event_occupancy() IDEMPOTENTE (delete avant chaque insert) ;
--   2) supprimer le trigger DOUBLON hérité (trg_event_occupancy) → un seul trigger reste.
-- Après ça : rejoindre un event à créneau LIBRE marche ; un vrai chevauchement est toujours refusé
-- (mais ça, c'est le bug côté app "publier-puis-disparaître" à traiter séparément : bloquer AVANT).
-- ============================================================================

create or replace function public.sync_event_occupancy()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if TG_OP = 'INSERT' then
    if coalesce(NEW.state,'accepted') = 'accepted' then
      -- idempotent : on efface une éventuelle occupation existante pour ce (user, event) avant d'insérer
      delete from public.occupancies
       where source_type = 'event' and source_id = NEW.event_id and user_id = NEW.user_id;
      insert into public.occupancies (user_id, start_at, end_at, source_type, source_id)
      select NEW.user_id, e.starts_at, e.starts_at + interval '120 minutes', 'event', NEW.event_id
        from public.events e
       where e.id = NEW.event_id and e.starts_at is not null and coalesce(e.active,true);
    end if;
    return NEW;
  elsif TG_OP = 'UPDATE' then
    if coalesce(OLD.state,'accepted') <> 'accepted' and coalesce(NEW.state,'accepted') = 'accepted' then
      delete from public.occupancies
       where source_type = 'event' and source_id = NEW.event_id and user_id = NEW.user_id;
      insert into public.occupancies (user_id, start_at, end_at, source_type, source_id)
      select NEW.user_id, e.starts_at, e.starts_at + interval '120 minutes', 'event', NEW.event_id
        from public.events e
       where e.id = NEW.event_id and e.starts_at is not null and coalesce(e.active,true);
    elsif coalesce(OLD.state,'accepted') = 'accepted' and coalesce(NEW.state,'accepted') <> 'accepted' then
      delete from public.occupancies
       where source_type = 'event' and source_id = NEW.event_id and user_id = NEW.user_id;
    end if;
    return NEW;
  else
    delete from public.occupancies
     where source_type = 'event' and source_id = OLD.event_id and user_id = OLD.user_id;
    return OLD;
  end if;
end; $$;

-- 2) retirer le trigger DOUBLON (cause de l'auto-collision). On garde le seul trg_sync_event_occupancy.
drop trigger if exists trg_event_occupancy on public.event_participants;

-- Vérif manuelle : select tgname from pg_trigger where tgrelid='public.event_participants'::regclass and not tgisinternal;
--   → doit ne lister que trg_sync_event_occupancy (+ éventuels triggers non-occupation).

-- ═══════ 20260710_invariant_reports.sql ═══════
-- ============================================================================
-- 🧪 RAPPORTS D'INVARIANTS AUTOMATIQUES (David 08.07 : « on envoie quand c'est orange
-- et tu répares ? ou on peut faire automatique ? » → AUTOMATIQUE.)
-- Chaque violation détectée par le moteur d'invariants (sur N'IMPORTE quel téléphone —
-- David, Mel, Dom) est envoyée ici. Plus besoin de captures d'écran : le Test Lab a un
-- panneau « Rapports » qui lit cette table, et Claude la dépouille en session.
-- Volume attendu : minuscule (dédupliqué côté client 60 s). Rétention : purge > 14 jours.
-- ⚠️ À APPLIQUER AVEC DAVID (SQL Editor).
-- ============================================================================

create table if not exists public.invariant_reports (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.profiles(id) on delete cascade,
  inv_id text not null,           -- ex. DISPO_COHERENTE, FENETRE_SANS_GEO
  detail text,                    -- le message exact affiché dans la bannière
  build text,                     -- ex. « 0x240 · 317 » (repère la version fautive)
  platform text,                  -- 'ios' | 'android' | 'web' (best-effort)
  created_at timestamptz not null default now()
);

alter table public.invariant_reports enable row level security;

-- Chacun peut ÉCRIRE ses propres rapports (c'est de la télémetrie de cohérence, pas des données sensibles,
-- mais on borne quand même : user_id = soi).
drop policy if exists inv_reports_insert_self on public.invariant_reports;
create policy inv_reports_insert_self on public.invariant_reports
  for insert to authenticated with check (auth.uid() = user_id);

-- Seuls les ADMINS lisent (le panneau du Lab).
drop policy if exists inv_reports_select_admin on public.invariant_reports;
create policy inv_reports_select_admin on public.invariant_reports
  for select to authenticated using (public.qa_is_admin());

-- Purge automatique > 14 jours (accrochée au cron existant si pg_cron est là).
create or replace function public.purge_invariant_reports() returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  delete from public.invariant_reports where created_at < now() - interval '14 days';
  get diagnostics n = row_count;
  return n;
end; $$;
do $$ begin
  begin perform cron.unschedule('purge-invariant-reports'); exception when others then null; end;
  begin perform cron.schedule('purge-invariant-reports', '17 4 * * *', 'select public.purge_invariant_reports()'); exception when others then null; end;
end $$;

-- ═══════ 20260711_algo_couche2.sql ═══════
-- ═══════════════════════════════════════════════════════════════════════════
-- ALGO COUCHE 2 (LLM conversationnel opt-in) — structure de données
-- Brief : docs/algo/document-2-brief-technique-couches-1-2.md (C.4)
--
-- Architecture : 1 LLM stateless partagé + 1 petit vecteur JSON par user.
-- Le vecteur = LE seul état par utilisateur (préférences apprises, patterns,
-- mood éphémère, résumé). Quelques Ko. Exportable (RGPD), destructible en 1 bouton.
--
-- ⚠️ Le PROMPT SYSTÈME (le vrai actif) ne vit PAS dans le repo (repo public) :
--    il vit dans la table algo_prompts, service-role only, insérée à la main
--    via supabase/private/prompt-affinage-v1.sql (fichier GITIGNORÉ).
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. Le vecteur utilisateur ────────────────────────────────────────────────
create table if not exists public.user_vectors (
  user_id    uuid primary key references public.profiles(id) on delete cascade,
  vector     jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.user_vectors enable row level security;

-- RGPD / LPD : l'utilisateur peut LIRE son vecteur (transparence + export)
-- et le DÉTRUIRE en un bouton. Il ne l'écrit JAMAIS lui-même :
-- seule l'Edge Function (service role, bypass RLS) le met à jour —
-- sinon un client malveillant s'injecterait des boosts arbitraires.
drop policy if exists user_vectors_select_own on public.user_vectors;
create policy user_vectors_select_own on public.user_vectors
  for select using (auth.uid() = user_id);

drop policy if exists user_vectors_delete_own on public.user_vectors;
create policy user_vectors_delete_own on public.user_vectors
  for delete using (auth.uid() = user_id);

-- (pas de policy insert/update → refus par défaut pour anon/authenticated)

-- ── 2. Les prompts système (l'actif — jamais dans le client, jamais dans le repo) ──
create table if not exists public.algo_prompts (
  name       text primary key,          -- ex. 'affinage-v1'
  content    text not null,
  active     boolean not null default false,
  updated_at timestamptz not null default now()
);

alter table public.algo_prompts enable row level security;
-- AUCUNE policy → invisible pour anon/authenticated. Service role uniquement.
-- Itération A/B : insérer 'affinage-v2', basculer les flags active, zéro redeploy.

-- ── 3. Garde-fou : un seul prompt actif à la fois ───────────────────────────
create or replace function public.algo_prompt_single_active()
returns trigger language plpgsql as $$
begin
  if new.active then
    update public.algo_prompts set active = false where name <> new.name and active;
  end if;
  return new;
end $$;

drop trigger if exists trg_algo_prompt_single_active on public.algo_prompts;
create trigger trg_algo_prompt_single_active
  before insert or update on public.algo_prompts
  for each row execute function public.algo_prompt_single_active();

-- ═══════ 20260711_favorites_rls.sql ═══════
-- 🐛 David 11.07 (« favori : Pas enregistré — réessaie », récidive builds 348-349)
-- CAUSE RACINE : RLS activée sur favorites (20260624_hardening) mais AUCUNE policy → tout est refusé.
-- ⚠️ La vraie colonne = favorited_id (découverte 11.07 : le code écrivait profile_id, INEXISTANTE → 42703 depuis toujours).
-- + RLS : la table était lisible par les ANONYMES (fuite) → policies strictes.
-- + contrainte UNIQUE (permet l'upsert propre et empêche les doublons).
ALTER TABLE favorites ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS favorites_select ON favorites;
CREATE POLICY favorites_select ON favorites FOR SELECT TO authenticated USING (user_id = auth.uid());
DROP POLICY IF EXISTS favorites_insert ON favorites;
CREATE POLICY favorites_insert ON favorites FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid());
DROP POLICY IF EXISTS favorites_delete ON favorites;
CREATE POLICY favorites_delete ON favorites FOR DELETE TO authenticated USING (user_id = auth.uid());
CREATE UNIQUE INDEX IF NOT EXISTS favorites_user_profile_uniq ON favorites (user_id, favorited_id);

-- ═══════ 20260712_simulateur_personas.sql ═══════
-- ============================================================================
-- 🎭 SIMULATEUR PERSONAS v1 (12.07.2026) — « on le fait nous-mêmes » (David)
-- La ville vivante AUTONOME : tourne côté serveur (pg_cron, 1 tick/minute), même
-- quand personne n'a l'app ouverte, jusqu'à l'arrêt. Modèle v2 simplifié :
-- traits stables × état × contexte (chronotype, heure, scène). Les bots agissent
-- par les MÊMES RPC gardées que les humains (admin_*) — incassable par construction.
-- Cockpit : SEUL David (email) peut écrire la consigne (sim_control). Kill switch inclus.
-- Dom pourra reprendre/améliorer ce moteur ensuite (le cerveau est dans sim_bots.traits).
-- ============================================================================

-- ── 0) qa_is_admin : le cron (pg_cron s'exécute en 'postgres') doit passer les gardes.
--    Les clients passent TOUJOURS par PostgREST (current_user = authenticator/authenticated,
--    auth.uid() non nul) → ce chemin est inatteignable depuis l'extérieur.
create or replace function public.qa_is_admin() returns boolean language sql stable as $$
  select current_user = 'postgres' or auth.uid() = any(array[
    'bad38f3e-87df-40e0-a2d2-75c03b58d72b',
    '409e83dc-dda8-42c3-bb98-3ea900857d35',
    '9626a0ba-037f-49dd-9957-ebd37e58a864',
    'bfb0eabf-8982-4e36-a65e-81b51ec4eef6'   -- Dom (Dominique)
  ]::uuid[]);
$$;

-- ── 1) LA CONSIGNE (sim_control, 1 ligne) — lisible par les connectés, ÉCRITE PAR DAVID SEUL.
create table if not exists public.sim_control (
  id int primary key default 1 check (id = 1),
  running boolean not null default false,
  scene text not null default 'B' check (scene in ('A','B','C')),
  density numeric not null default 1.0 check (density between 0.1 and 3.0),
  updated_at timestamptz not null default now(),
  note text
);
insert into public.sim_control (id) values (1) on conflict do nothing;
alter table public.sim_control enable row level security;
drop policy if exists sim_control_read on public.sim_control;
create policy sim_control_read on public.sim_control for select to authenticated using (true);
drop policy if exists sim_control_write on public.sim_control;
create policy sim_control_write on public.sim_control for update to authenticated
  using ((auth.jwt() ->> 'email') = 'david.saugy@gmail.com')
  with check ((auth.jwt() ->> 'email') = 'david.saugy@gmail.com');

-- ── 2) LE CERVEAU (sim_bots) — un tirage de traits par bot + son état + son réveil.
create table if not exists public.sim_bots (
  bot_id uuid primary key references public.profiles(id) on delete cascade,
  traits jsonb not null default '{}'::jsonb,   -- {chrono, temper, fiab, civil, comp, organise, accept_p, latence_min…}
  state text not null default 'actif',          -- nouveau·actif·hyper_engage·hyper_arroseur·occupe·pause·refroidi·churne
  state_since timestamptz not null default now(),
  home_lat double precision, home_lng double precision, town text,
  next_action_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
alter table public.sim_bots enable row level security;
drop policy if exists sim_bots_read on public.sim_bots;
create policy sim_bots_read on public.sim_bots for select to authenticated using (public.qa_is_admin());
create index if not exists sim_bots_due on public.sim_bots (next_action_at);

-- ── 3) SEMER (sim_seed) — assigne traits + domicile réaliste aux bots existants (is_bot).
--    Communes pondérées (population approx) — TOUTES sur terre ; jitter ±0.008 ≈ 900 m, reste au sec.
create or replace function public.sim_seed(p_n int default 300) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  towns constant jsonb := '[
    ["Lausanne",46.5197,6.6323,28],["Genève",46.2044,6.1432,26],["Fribourg",46.8065,7.1619,8],
    ["Neuchâtel",46.9920,6.9310,7],["Sion",46.2331,7.3606,6],["Yverdon",46.7785,6.6411,5],
    ["Montreux",46.4312,6.9107,4],["Vevey",46.4628,6.8419,4],["Renens",46.5399,6.5882,4],
    ["Nyon",46.3832,6.2396,4],["Morges",46.5093,6.4983,3],["Bulle",46.6194,7.0567,3],
    ["Martigny",46.1027,7.0724,3],["La Chaux-de-Fonds",47.0999,6.8259,3],["Payerne",46.8220,6.9380,2],
    ["Aigle",46.3167,6.9667,2],["Gland",46.4212,6.2704,2],["Echallens",46.6410,6.6350,1],
    ["Moudon",46.6670,6.7980,1],["Romont",46.6960,6.9190,1]
  ]'::jsonb;
  totw numeric := 0; t jsonb; r numeric; b record; n_done int := 0;
  chrono text; temper text; fiab text; st text; tlat double precision; tlng double precision; tname text;
begin
  if not public.qa_is_admin() then return jsonb_build_object('ok',false,'code','RLS_FORBIDDEN'); end if;
  select coalesce(sum((e->>3)::numeric),0) into totw from jsonb_array_elements(towns) e;
  for b in select id from public.profiles where is_bot = true
           and id not in (select bot_id from public.sim_bots) limit p_n loop
    -- tirage commune pondérée
    r := random() * totw;
    for t in select e from jsonb_array_elements(towns) e loop
      r := r - (t->>3)::numeric;
      if r <= 0 then exit; end if;
    end loop;
    tname := t->>0; tlat := (t->>1)::float8 + (random()-0.5)*0.016; tlng := (t->>2)::float8 + (random()-0.5)*0.02;
    -- traits (distributions v2 — priors non sourcés, config à affiner)
    chrono := (array['matin','std','std','std','soir','soir'])[1+floor(random()*6)::int];
    temper := case when random()<0.25 then 'extraverti' when random()<0.75 then 'neutre' else 'timide' end;
    fiab   := case when random()<0.15 then 'roc' when random()<0.60 then 'ponctuel'
                   when random()<0.80 then 'retard' when random()<0.92 then 'annuleur' else 'noshow' end;
    st     := case when random()<0.05 then 'hyper_engage' when random()<0.08 then 'hyper_arroseur'
                   when random()<0.55 then 'actif' when random()<0.75 then 'occupe' else 'pause' end;
    insert into public.sim_bots (bot_id, traits, state, home_lat, home_lng, town, next_action_at)
    values (b.id, jsonb_build_object(
      'chrono',chrono,'temper',temper,'fiab',fiab,
      'organise',(random()<0.10),'accept_p',0.25+random()*0.5,
      'latence_min',(3+floor(random()*40))::int),
      st, tlat, tlng, tname, now() + (random()*interval '20 minutes'))
    on conflict (bot_id) do nothing;
    n_done := n_done + 1;
  end loop;
  return jsonb_build_object('ok',true,'seeded',n_done);
end; $$;
grant execute on function public.sim_seed(int) to authenticated;

-- ── 4) LE TICK (sim_tick) — 1×/minute via pg_cron. Budget de bots traités par tick, tout est
--    best-effort (une erreur sur un bot n'arrête jamais la ville).
create or replace function public.sim_tick() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  ctl record; b record; tr jsonb; h int; dow int; awake numeric; target int; online int;
  acted int := 0; published int := 0; answered int := 0; events int := 0;
  cl record; lat8 double precision; lng8 double precision; sm timestamptz; su timestamptz;
  pool jsonb; pick jsonb;
begin
  if not public.qa_is_admin() then return jsonb_build_object('ok',false,'code','RLS_FORBIDDEN'); end if;
  select * into ctl from public.sim_control where id = 1;
  if ctl is null or not ctl.running then return jsonb_build_object('ok',true,'skipped','off'); end if;
  h := extract(hour from now() at time zone 'Europe/Zurich')::int;
  dow := extract(isodow from now() at time zone 'Europe/Zurich')::int;   -- 1=lundi
  -- cible de bots EN LIGNE selon scène × densité × heure (pic 17-22, jeu-sam ×1.5)
  target := round((case ctl.scene when 'A' then 25 when 'B' then 180 else 700 end) * ctl.density
            * (case when h between 17 and 22 then 1.0 when h between 12 and 16 then 0.6
                    when h between 7 and 11 then 0.4 else 0.25 end)
            * (case when dow in (4,5,6) then 1.5 else 1.0 end));
  select count(*) into online from public.profiles p join public.sim_bots s on s.bot_id=p.id
    where p.is_available = true and p.available_until > now();

  for b in select * from public.sim_bots where next_action_at <= now()
           and state not in ('churne') order by next_action_at limit 40 loop
    begin
      acted := acted + 1; tr := b.traits;
      -- réveil suivant (par chronotype : les bons créneaux du bot reviennent plus vite)
      awake := case when (tr->>'chrono')='matin' and h between 7 and 11 then 1
                    when (tr->>'chrono')='soir'  and (h >= 18 or h < 2) then 1
                    when (tr->>'chrono')='std'   and h between 11 and 22 then 1 else 0.3 end;
      update public.sim_bots set next_action_at = now() + ((8 + random()*35) / awake) * interval '1 minute'
        where bot_id = b.bot_id;

      -- transitions d'état LÉGÈRES à chaque passage (matrice hebdo ~ diluée)
      if random() < 0.02 then
        update public.sim_bots set state = case b.state
            when 'pause' then (case when random()<0.5 then 'actif' else 'pause' end)
            when 'occupe' then (case when random()<0.5 then 'actif' else 'occupe' end)
            when 'refroidi' then 'actif'
            when 'actif' then (case when random()<0.12 then 'occupe' when random()<0.2 then 'hyper_engage' else 'actif' end)
            else b.state end,
          state_since = now() where bot_id = b.bot_id;
      end if;

      if b.state in ('pause','occupe') and random() < 0.85 then continue; end if;   -- eux, ils vivent leur vie

      -- ① PUBLIER un créneau (si pas déjà en ligne, sous la cible, et humeur du moment)
      if online < target and random() < (case b.state when 'hyper_engage' then 0.75 when 'hyper_arroseur' then 0.7 else 0.45 end) * awake
         and not exists (select 1 from public.profiles where id=b.bot_id and is_available and available_until>now()) then
        sm := date_trunc('hour', now()) + (floor(random()*4)*interval '15 minutes');
        if sm < now() then sm := now(); end if;
        su := sm + (interval '1 hour' * (1.5 + random()*3.5));
        if su > now() + interval '17 hours' then su := now() + interval '17 hours'; end if;
        lat8 := b.home_lat + (random()-0.5)*0.01; lng8 := b.home_lng + (random()-0.5)*0.014;
        perform public.admin_set_availability(b.bot_id, sm, su, lat8, lng8, (array[3,5,8,10,15])[1+floor(random()*5)::int]);
        online := online + 1; published := published + 1;
      end if;

      -- ② RÉPONDRE aux clutchs en attente reçus (latence par traits, accept par fiabilité/état)
      for cl in select c.id, c.sender_id from public.clutches c
                where c.receiver_id = b.bot_id and c.status = 'pending'
                  and c.created_at < now() - ((tr->>'latence_min')::int * interval '1 minute') limit 2 loop
        if random() < coalesce((tr->>'accept_p')::numeric, 0.4)
           and (tr->>'fiab') not in ('noshow') then
          perform public.admin_accept_clutch(b.bot_id, cl.sender_id);
        else
          perform public.admin_refuse_clutch(b.bot_id, cl.sender_id);
        end if;
        answered := answered + 1;
      end loop;

      -- ③ ORGANISER un event (les organisateurs, rarement, à une heure crédible)
      if (tr->>'organise')::boolean and random() < 0.05 and h between 8 and 22 then
        pool := case when h < 11 then '[["☕","Café-croissants"],["🥾","Balade matinale"]]'::jsonb
                     when h < 14 then '[["🥗","Lunch ensemble"],["♟️","Échecs au parc"]]'::jsonb
                     when h < 17 then '[["🎨","Atelier croquis"],["🚴","Sortie vélo"]]'::jsonb
                     else '[["🍹","Apéro spontané"],["🎲","Soirée jeux"],["🏐","Beach-volley"]]'::jsonb end;
        pick := pool->floor(random()*jsonb_array_length(pool))::int;
        perform public.admin_create_event(b.bot_id,
          (pick->>0)||' '||(pick->>1)||' — '||coalesce(b.town,'Lausanne'),
          now() + (interval '1 hour' * (1 + random()*3)),
          b.home_lat + (random()-0.5)*0.008, b.home_lng + (random()-0.5)*0.012,
          4 + floor(random()*8)::int);
        events := events + 1;
      end if;
    exception when others then null;   -- un bot qui rate ≠ la ville qui s'arrête
    end;
  end loop;
  return jsonb_build_object('ok',true,'acted',acted,'published',published,'answered',answered,'events',events,'online',online,'target',target);
end; $$;
grant execute on function public.sim_tick() to authenticated;   -- le cockpit peut forcer un tick à la main

-- ── 5) KILL SWITCH — coupe la consigne (les créneaux expirent naturellement ; brutal = purge dispos bots).
create or replace function public.sim_kill(p_hard boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not public.qa_is_admin() then return jsonb_build_object('ok',false,'code','RLS_FORBIDDEN'); end if;
  update public.sim_control set running = false, updated_at = now() where id = 1;
  if p_hard then
    update public.profiles set is_available = false
      where id in (select bot_id from public.sim_bots) and is_available = true;
  end if;
  return jsonb_build_object('ok',true,'hard',p_hard);
end; $$;
grant execute on function public.sim_kill(boolean) to authenticated;

-- ── 6) LE CŒUR QUI BAT — pg_cron toutes les minutes (idempotent, silencieux si absent).
do $$ begin
  begin perform cron.unschedule('sim-tick'); exception when others then null; end;
  begin perform cron.schedule('sim-tick', '* * * * *', 'select public.sim_tick()'); exception when others then null; end;
end $$;

-- ═══════ 20260712b_sim_clutch_humains.sql ═══════
-- ============================================================================
-- 🎯 SIM v1.1 (12.07) — les bots CLUTCHENT AUSSI les humains, à dose CRÉDIBLE.
-- Demande David : « de temps en temps il me clutche, de temps en temps pas — pas
-- toutes les deux minutes, insupportable ». Triple garde-fou :
--   ① throttle GLOBAL : max 1 clutch entrant / 25 min / humain (tous bots confondus)
--   ② jamais deux fois le même bot vers le même humain en 24 h
--   ③ le plafond de réception existant (boîte pleine à 5) s'applique via admin_create_clutch.
-- Résultat : un filet crédible (~2-3/h au pic quand tu es dispo), jamais la mitraille.
-- Remplace sim_tick (v1 → v1.1). À COLLER après 20260712_simulateur_personas.sql.
-- ============================================================================
create or replace function public.sim_tick() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  ctl record; b record; tr jsonb; h int; dow int; awake numeric; target int; online int;
  acted int := 0; published int := 0; answered int := 0; events int := 0; clutched int := 0;
  cl record; hum record; lat8 double precision; lng8 double precision; sm timestamptz; su timestamptz;
  pool jsonb; pick jsonb;
begin
  if not public.qa_is_admin() then return jsonb_build_object('ok',false,'code','RLS_FORBIDDEN'); end if;
  select * into ctl from public.sim_control where id = 1;
  if ctl is null or not ctl.running then return jsonb_build_object('ok',true,'skipped','off'); end if;
  h := extract(hour from now() at time zone 'Europe/Zurich')::int;
  dow := extract(isodow from now() at time zone 'Europe/Zurich')::int;
  target := round((case ctl.scene when 'A' then 25 when 'B' then 180 else 700 end) * ctl.density
            * (case when h between 17 and 22 then 1.0 when h between 12 and 16 then 0.6
                    when h between 7 and 11 then 0.4 else 0.25 end)
            * (case when dow in (4,5,6) then 1.5 else 1.0 end));
  select count(*) into online from public.profiles p join public.sim_bots s on s.bot_id=p.id
    where p.is_available = true and p.available_until > now();

  for b in select * from public.sim_bots where next_action_at <= now()
           and state not in ('churne') order by next_action_at limit 40 loop
    begin
      acted := acted + 1; tr := b.traits;
      awake := case when (tr->>'chrono')='matin' and h between 7 and 11 then 1
                    when (tr->>'chrono')='soir'  and (h >= 18 or h < 2) then 1
                    when (tr->>'chrono')='std'   and h between 11 and 22 then 1 else 0.3 end;
      update public.sim_bots set next_action_at = now() + ((8 + random()*35) / awake) * interval '1 minute'
        where bot_id = b.bot_id;

      if random() < 0.02 then
        update public.sim_bots set state = case b.state
            when 'pause' then (case when random()<0.5 then 'actif' else 'pause' end)
            when 'occupe' then (case when random()<0.5 then 'actif' else 'occupe' end)
            when 'refroidi' then 'actif'
            when 'actif' then (case when random()<0.12 then 'occupe' when random()<0.2 then 'hyper_engage' else 'actif' end)
            else b.state end,
          state_since = now() where bot_id = b.bot_id;
      end if;

      if b.state in ('pause','occupe') and random() < 0.85 then continue; end if;

      -- ① PUBLIER un créneau
      if online < target and random() < (case b.state when 'hyper_engage' then 0.75 when 'hyper_arroseur' then 0.7 else 0.45 end) * awake
         and not exists (select 1 from public.profiles where id=b.bot_id and is_available and available_until>now()) then
        sm := date_trunc('hour', now()) + (floor(random()*4)*interval '15 minutes');
        if sm < now() then sm := now(); end if;
        su := sm + (interval '1 hour' * (1.5 + random()*3.5));
        if su > now() + interval '17 hours' then su := now() + interval '17 hours'; end if;
        lat8 := b.home_lat + (random()-0.5)*0.01; lng8 := b.home_lng + (random()-0.5)*0.014;
        perform public.admin_set_availability(b.bot_id, sm, su, lat8, lng8, (array[3,5,8,10,15])[1+floor(random()*5)::int]);
        online := online + 1; published := published + 1;
      end if;

      -- ② RÉPONDRE aux clutchs reçus (latence + caractère)
      for cl in select c.id, c.sender_id from public.clutches c
                where c.receiver_id = b.bot_id and c.status = 'pending'
                  and c.created_at < now() - ((tr->>'latence_min')::int * interval '1 minute') limit 2 loop
        if random() < coalesce((tr->>'accept_p')::numeric, 0.4)
           and (tr->>'fiab') not in ('noshow') then
          perform public.admin_accept_clutch(b.bot_id, cl.sender_id);
        else
          perform public.admin_refuse_clutch(b.bot_id, cl.sender_id);
        end if;
        answered := answered + 1;
      end loop;

      -- ②bis 🎯 CLUTCHER UN HUMAIN dispo, à dose crédible (v1.1)
      if b.state in ('actif','hyper_engage','hyper_arroseur') and random() < 0.03 then
        select p.id into hum
          from public.profiles p
          where coalesce(p.is_bot,false) = false and p.is_available = true and p.available_until > now()
            and p.center_lat is not null
            and abs(p.center_lat - b.home_lat) < 0.15 and abs(p.center_lng - b.home_lng) < 0.2
            and not exists (select 1 from public.clutches c2 where c2.receiver_id = p.id
                            and c2.created_at > now() - interval '25 minutes')          -- ① anti-mitraille global
            and not exists (select 1 from public.clutches c3 where c3.sender_id = b.bot_id
                            and c3.receiver_id = p.id and c3.created_at > now() - interval '24 hours')  -- ② pas 2× le même jour
          order by random() limit 1;
        if hum.id is not null then
          perform public.admin_create_clutch(b.bot_id, hum.id,
            (array['Un café ?','Une balade au bord du lac ?','Un verre en terrasse ?','Un ping-pong ?','Une glace ?'])[1+floor(random()*5)::int],
            now() + (interval '1 hour' * (0.75 + random()*2)),
            (array['On tente ? 🙂','Dispo si tu l''es','Ça te dit ?','Simple et sans pression'])[1+floor(random()*4)::int],
            60, b.home_lat, b.home_lng);
          clutched := clutched + 1;
        end if;
      end if;

      -- ③ ORGANISER un event
      if (tr->>'organise')::boolean and random() < 0.05 and h between 8 and 22 then
        pool := case when h < 11 then '[["☕","Café-croissants"],["🥾","Balade matinale"]]'::jsonb
                     when h < 14 then '[["🥗","Lunch ensemble"],["♟️","Échecs au parc"]]'::jsonb
                     when h < 17 then '[["🎨","Atelier croquis"],["🚴","Sortie vélo"]]'::jsonb
                     else '[["🍹","Apéro spontané"],["🎲","Soirée jeux"],["🏐","Beach-volley"]]'::jsonb end;
        pick := pool->floor(random()*jsonb_array_length(pool))::int;
        perform public.admin_create_event(b.bot_id,
          (pick->>0)||' '||(pick->>1)||' — '||coalesce(b.town,'Lausanne'),
          now() + (interval '1 hour' * (1 + random()*3)),
          b.home_lat + (random()-0.5)*0.008, b.home_lng + (random()-0.5)*0.012,
          4 + floor(random()*8)::int);
        events := events + 1;
      end if;
    exception when others then null;
    end;
  end loop;
  return jsonb_build_object('ok',true,'acted',acted,'published',published,'answered',answered,'clutched',clutched,'events',events,'online',online,'target',target);
end; $$;

-- ═══════ 20260712c_sim_personas_v2.sql ═══════
-- ============================================================================
-- 🎭 SIM v2 — LES PERSONNAGES (12.07, David : « on fait ce que Dom ferait, go à fond »)
-- Chaque bot reçoit un ARCHÉTYPE de l'étude v2 et se comporte comme lui :
--   🌞 piliere · ⚡ comete_engage · 💨 comete_arroseur · 🎪 organisatrice · 🧭 power
--   🫣 timide (retire son créneau quand on la clutche) · 🌦️ occasionnelle · 🛋️ dormeur
--   🤪 perdu (créneaux à 4h, rayons absurdes) · 🐌 indecise (répond à la dernière minute)
--   🍂 noshow (accepte tout, ne viendra pas) · 😤 vexe (re-clutche après un refus → teste le cooldown)
--   🚆 pendulaire (ne vit qu'aux heures de train, 2 villes) · ✈️ expat (rayon énorme, court terme)
-- + transitions d'état quotidiennes (matrice 90 jours diluée). À COLLER après 20260712b.
-- ============================================================================

-- ── 1) SEMER v2 : archétype + traits dérivés. Ré-exécutable : force la re-dotation de TOUS les bots.
create or replace function public.sim_seed(p_n int default 1000) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  towns constant jsonb := '[
    ["Lausanne",46.5197,6.6323,28],["Genève",46.2044,6.1432,26],["Fribourg",46.8065,7.1619,8],
    ["Neuchâtel",46.9920,6.9310,7],["Sion",46.2331,7.3606,6],["Yverdon",46.7785,6.6411,5],
    ["Montreux",46.4312,6.9107,4],["Vevey",46.4628,6.8419,4],["Renens",46.5399,6.5882,4],
    ["Nyon",46.3832,6.2396,4],["Morges",46.5093,6.4983,3],["Bulle",46.6194,7.0567,3],
    ["Martigny",46.1027,7.0724,3],["La Chaux-de-Fonds",47.0999,6.8259,3],["Payerne",46.8220,6.9380,2],
    ["Aigle",46.3167,6.9667,2],["Gland",46.4212,6.2704,2],["Echallens",46.6410,6.6350,1],
    ["Moudon",46.6670,6.7980,1],["Romont",46.6960,6.9190,1]
  ]'::jsonb;
  archs constant jsonb := '[
    ["piliere",5],["comete_engage",3],["comete_arroseur",2],["organisatrice",4],["power",5],
    ["timide",8],["occasionnelle",18],["dormeur",20],["perdu",8],["indecise",7],
    ["noshow",5],["vexe",2],["pendulaire",7],["expat",4],["couple",2]
  ]'::jsonb;
  totw numeric; tota numeric; t jsonb; a jsonb; r numeric; b record; n_done int := 0;
  arch text; chrono text; st text; tlat float8; tlng float8; tname text;
  acceptp numeric; latmin int; organise boolean;
begin
  if not public.qa_is_admin() then return jsonb_build_object('ok',false,'code','RLS_FORBIDDEN'); end if;
  select sum((e->>3)::numeric) into totw from jsonb_array_elements(towns) e;
  select sum((e->>1)::numeric) into tota from jsonb_array_elements(archs) e;
  for b in select id from public.profiles where is_bot = true limit p_n loop
    r := random() * totw;
    for t in select e from jsonb_array_elements(towns) e loop
      r := r - (t->>3)::numeric; if r <= 0 then exit; end if;
    end loop;
    tname := t->>0; tlat := (t->>1)::float8 + (random()-0.5)*0.016; tlng := (t->>2)::float8 + (random()-0.5)*0.02;
    r := random() * tota;
    for a in select e from jsonb_array_elements(archs) e loop
      r := r - (a->>1)::numeric; if r <= 0 then exit; end if;
    end loop;
    arch := a->>0;
    -- traits dérivés de l'archétype (l'étude v2, en chiffres)
    chrono  := case arch when 'pendulaire' then 'pendulaire'
                         when 'piliere' then 'std'
                         else (array['matin','std','std','soir','soir'])[1+floor(random()*5)::int] end;
    acceptp := case arch when 'piliere' then 0.6 when 'comete_engage' then 0.65 when 'comete_arroseur' then 0.7
                         when 'power' then 0.3 when 'timide' then 0.3 when 'dormeur' then 0.15
                         when 'noshow' then 0.85 when 'indecise' then 0.5 when 'vexe' then 0.5
                         else 0.35 + random()*0.2 end;
    latmin  := case arch when 'comete_engage' then 4+floor(random()*8)::int
                         when 'comete_arroseur' then 3+floor(random()*5)::int
                         when 'piliere' then 15+floor(random()*40)::int
                         when 'indecise' then 150+floor(random()*90)::int      -- la dernière minute
                         when 'dormeur' then 120+floor(random()*300)::int
                         else 10+floor(random()*60)::int end;
    organise := arch = 'organisatrice' or (arch = 'piliere' and random() < 0.4);
    st := case arch when 'dormeur' then 'pause' when 'occasionnelle' then (case when random()<0.5 then 'occupe' else 'actif' end)
                    when 'comete_engage' then 'hyper_engage' when 'comete_arroseur' then 'hyper_arroseur'
                    else 'actif' end;
    insert into public.sim_bots (bot_id, traits, state, home_lat, home_lng, town, next_action_at)
    values (b.id, jsonb_build_object(
        'arch',arch,'chrono',chrono,
        'fiab',case arch when 'noshow' then 'noshow' when 'piliere' then 'roc' when 'indecise' then 'annuleur'
                         when 'perdu' then 'retard' else (array['roc','ponctuel','ponctuel','retard'])[1+floor(random()*4)::int] end,
        'organise',organise,'accept_p',acceptp,'latence_min',latmin,
        'work_lat',46.5197+(random()-0.5)*0.01,'work_lng',6.6323+(random()-0.5)*0.014),  -- pendulaires : boulot à Lausanne
      st, tlat, tlng, tname, now() + (random()*interval '20 minutes'))
    on conflict (bot_id) do update set traits = excluded.traits, state = excluded.state,
      home_lat = excluded.home_lat, home_lng = excluded.home_lng, town = excluded.town;
    n_done := n_done + 1;
  end loop;
  return jsonb_build_object('ok',true,'seeded',n_done);
end; $$;

-- ── 2) LE TICK v2 : chaque personnage joue SA partition.
create or replace function public.sim_tick() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  ctl record; b record; tr jsonb; arch text; h int; dow int; awake numeric; target int; online int;
  acted int := 0; published int := 0; answered int := 0; events int := 0; clutched int := 0; retired int := 0; revenge int := 0;
  cl record; hum record; vx record; lat8 float8; lng8 float8; sm timestamptz; su timestamptz; radp int;
  pool jsonb; pick jsonb; pubp numeric;
begin
  if not public.qa_is_admin() then return jsonb_build_object('ok',false,'code','RLS_FORBIDDEN'); end if;
  select * into ctl from public.sim_control where id = 1;
  if ctl is null or not ctl.running then return jsonb_build_object('ok',true,'skipped','off'); end if;
  h := extract(hour from now() at time zone 'Europe/Zurich')::int;
  dow := extract(isodow from now() at time zone 'Europe/Zurich')::int;
  target := round((case ctl.scene when 'A' then 25 when 'B' then 180 else 700 end) * ctl.density
            * (case when h between 17 and 22 then 1.0 when h between 12 and 16 then 0.6
                    when h between 7 and 11 then 0.4 else 0.25 end)
            * (case when dow in (4,5,6) then 1.5 else 1.0 end));
  select count(*) into online from public.profiles p join public.sim_bots s on s.bot_id=p.id
    where p.is_available = true and p.available_until > now();

  for b in select * from public.sim_bots where next_action_at <= now()
           and state not in ('churne') order by next_action_at limit 40 loop
    begin
      acted := acted + 1; tr := b.traits; arch := coalesce(tr->>'arch','occasionnelle');
      awake := case when (tr->>'chrono')='pendulaire' and (h between 7 and 9 or h between 17 and 19) then 1
                    when (tr->>'chrono')='pendulaire' then 0.15
                    when (tr->>'chrono')='matin' and h between 7 and 11 then 1
                    when (tr->>'chrono')='soir'  and (h >= 18 or h < 2) then 1
                    when (tr->>'chrono')='std'   and h between 11 and 22 then 1 else 0.3 end;
      update public.sim_bots set next_action_at = now() + ((8 + random()*35) / greatest(awake,0.1)) * interval '1 minute'
        where bot_id = b.bot_id;
      if b.state in ('pause','occupe') and random() < 0.85 then continue; end if;

      -- ① PUBLIER — cadence, rayon et fenêtre PAR PERSONNAGE
      pubp := case arch when 'piliere' then 0.7 when 'comete_engage' then 0.8 when 'comete_arroseur' then 0.75
                        when 'power' then 0.6 when 'organisatrice' then 0.5 when 'timide' then 0.35
                        when 'occasionnelle' then (case when dow in (5,6,7) then 0.5 else 0.15 end)
                        when 'dormeur' then 0.08 when 'perdu' then 0.4 when 'pendulaire' then 0.6
                        when 'expat' then 0.55 when 'vexe' then 0.45 else 0.4 end;
      if online < target and random() < pubp * awake
         and not exists (select 1 from public.profiles where id=b.bot_id and is_available and available_until>now()) then
        sm := date_trunc('hour', now()) + (floor(random()*4)*interval '15 minutes');
        if sm < now() then sm := now(); end if;
        su := sm + (interval '1 hour' * (case arch when 'pendulaire' then 1 + random()
                                                    when 'expat' then 1 + random()*2
                                                    when 'perdu' then 0.5 + random()*8   -- n'importe quoi
                                                    else 1.5 + random()*3.5 end));
        if su > now() + interval '17 hours' then su := now() + interval '17 hours'; end if;
        -- le pendulaire publie sur son lieu du MOMENT (boulot en journée, maison le soir)
        if arch = 'pendulaire' and h between 9 and 17 then
          lat8 := (tr->>'work_lat')::float8 + (random()-0.5)*0.008; lng8 := (tr->>'work_lng')::float8 + (random()-0.5)*0.012;
        else
          lat8 := b.home_lat + (random()-0.5)*0.01; lng8 := b.home_lng + (random()-0.5)*0.014;
        end if;
        radp := case arch when 'expat' then (array[15,20,25])[1+floor(random()*3)::int]
                          when 'perdu' then (array[1,2,40])[1+floor(random()*3)::int]
                          when 'pendulaire' then (array[3,5,8])[1+floor(random()*3)::int]
                          else (array[3,5,8,10,15])[1+floor(random()*5)::int] end;
        perform public.admin_set_availability(b.bot_id, sm, su, lat8, lng8, radp);
        online := online + 1; published := published + 1;
      end if;

      -- ①bis 🫣 LA TIMIDE : quelqu'un l'a clutchée → panique, retire son créneau (le clutch expirera)
      if arch = 'timide' and random() < 0.4
         and exists (select 1 from public.clutches c where c.receiver_id=b.bot_id and c.status='pending') then
        update public.profiles set is_available = false where id = b.bot_id and is_available = true;
        retired := retired + 1;
      end if;

      -- ② RÉPONDRE (latence + caractère ; l'indécise répond à la toute dernière minute via sa latence géante)
      for cl in select c.id, c.sender_id from public.clutches c
                where c.receiver_id = b.bot_id and c.status = 'pending'
                  and c.created_at < now() - ((tr->>'latence_min')::int * interval '1 minute') limit 2 loop
        if random() < coalesce((tr->>'accept_p')::numeric, 0.4) then
          perform public.admin_accept_clutch(b.bot_id, cl.sender_id);   -- le noshow ACCEPTE (et ne viendra pas)
        else
          perform public.admin_refuse_clutch(b.bot_id, cl.sender_id);
        end if;
        answered := answered + 1;
      end loop;

      -- ②bis 🎯 CLUTCHER UN HUMAIN (dose crédible — throttle global 25 min/humain, jamais 2× le même en 24 h)
      if b.state in ('actif','hyper_engage','hyper_arroseur')
         and random() < (case arch when 'comete_arroseur' then 0.08 when 'comete_engage' then 0.05
                                    when 'piliere' then 0.04 when 'timide' then 0.005 else 0.02 end) then
        select p.id into hum from public.profiles p
          where coalesce(p.is_bot,false) = false and p.is_available = true and p.available_until > now()
            and p.center_lat is not null
            and abs(p.center_lat - b.home_lat) < 0.15 and abs(p.center_lng - b.home_lng) < 0.2
            and not exists (select 1 from public.clutches c2 where c2.receiver_id = p.id and c2.created_at > now() - interval '25 minutes')
            and not exists (select 1 from public.clutches c3 where c3.sender_id = b.bot_id and c3.receiver_id = p.id and c3.created_at > now() - interval '24 hours')
          order by random() limit 1;
        if hum.id is not null then
          perform public.admin_create_clutch(b.bot_id, hum.id,
            (array['Un café ?','Une balade au bord du lac ?','Un verre en terrasse ?','Un ping-pong ?','Une glace ?'])[1+floor(random()*5)::int],
            now() + (interval '1 hour' * (0.75 + random()*2)),
            (array['On tente ? 🙂','Dispo si tu l''es','Ça te dit ?','Simple et sans pression'])[1+floor(random()*4)::int],
            60, b.home_lat, b.home_lng);
          clutched := clutched + 1;
        end if;
      end if;

      -- ②ter 😤 LE VEXÉ : son clutch a été refusé → il RETENTE (le cooldown serveur doit l'arrêter — c'est le test)
      if arch = 'vexe' and random() < 0.5 then
        select c.receiver_id into vx from public.clutches c
          where c.sender_id = b.bot_id and c.status in ('refused','declined','expired')
            and c.created_at > now() - interval '6 hours'
          order by c.created_at desc limit 1;
        if vx.receiver_id is not null then
          perform public.admin_create_clutch(b.bot_id, vx.receiver_id, 'Allez, un café quand même ?', now() + interval '90 minutes',
            'Je suis sûr qu''on s''entendrait bien', 60, b.home_lat, b.home_lng);
          revenge := revenge + 1;   -- la plupart seront refusés par COOLDOWN_ACTIVE : exactement ce qu'on vérifie
        end if;
      end if;

      -- ③ ORGANISER un event (organisatrices + pilières)
      if (tr->>'organise')::boolean and random() < 0.06 and h between 8 and 22 then
        pool := case when h < 11 then '[["☕","Café-croissants"],["🥾","Balade matinale"]]'::jsonb
                     when h < 14 then '[["🥗","Lunch ensemble"],["♟️","Échecs au parc"]]'::jsonb
                     when h < 17 then '[["🎨","Atelier croquis"],["🚴","Sortie vélo"]]'::jsonb
                     else '[["🍹","Apéro spontané"],["🎲","Soirée jeux"],["🏐","Beach-volley"]]'::jsonb end;
        pick := pool->floor(random()*jsonb_array_length(pool))::int;
        perform public.admin_create_event(b.bot_id,
          (pick->>0)||' '||(pick->>1)||' — '||coalesce(b.town,'Lausanne'),
          now() + (interval '1 hour' * (1 + random()*3)),
          b.home_lat + (random()-0.5)*0.008, b.home_lng + (random()-0.5)*0.012,
          4 + floor(random()*8)::int);
        events := events + 1;
      end if;
    exception when others then null;
    end;
  end loop;
  return jsonb_build_object('ok',true,'acted',acted,'published',published,'answered',answered,
    'clutched',clutched,'revenge',revenge,'retired',retired,'events',events,'online',online,'target',target);
end; $$;

-- ── 3) TRANSITIONS QUOTIDIENNES (matrice 90 jours de l'étude, version journalière)
create or replace function public.sim_transitions() returns jsonb
language plpgsql security definer set search_path = public as $$
declare moved int := 0;
begin
  if not public.qa_is_admin() then return jsonb_build_object('ok',false,'code','RLS_FORBIDDEN'); end if;
  update public.sim_bots set state = sub.next_state, state_since = now()
  from (
    select bot_id, case state
      when 'actif' then (case when random()<0.70 then 'actif' when random()<0.6 then 'occupe'
                              when random()<0.5 then 'hyper_engage' else 'pause' end)
      when 'hyper_engage' then (case when random()<0.75 then 'hyper_engage' when random()<0.6 then 'actif' else 'pause' end)
      when 'hyper_arroseur' then (case when random()<0.60 then 'hyper_arroseur' when random()<0.6 then 'churne' else 'actif' end)
      when 'occupe' then (case when random()<0.50 then 'actif' when random()<0.6 then 'pause' else 'churne' end)
      when 'pause' then (case when random()<0.40 then 'churne' when random()<0.6 then 'actif' else 'pause' end)
      when 'refroidi' then (case when random()<0.40 then 'actif' when random()<0.6 then 'pause' else 'churne' end)
      else state end as next_state
    from public.sim_bots where state <> 'churne' and state_since < now() - interval '5 days'
  ) sub where sim_bots.bot_id = sub.bot_id and sub.next_state <> sim_bots.state;
  get diagnostics moved = row_count;
  -- les churnés reviennent parfois (réactivation, ~8 %/passe)
  update public.sim_bots set state = 'actif', state_since = now()
    where state = 'churne' and random() < 0.08;
  return jsonb_build_object('ok',true,'moved',moved);
end; $$;
do $$ begin
  begin perform cron.unschedule('sim-transitions'); exception when others then null; end;
  begin perform cron.schedule('sim-transitions', '15 4 * * *', 'select public.sim_transitions()'); exception when others then null; end;
end $$;

-- ═══════ 20260712d_sim_pilot_fix.sql ═══════
-- 🔑 Fix serrure cockpit (12.07 soir) : auth.jwt()->>'email' peut être vide selon le jeton → on vérifie
-- l'email directement dans auth.users (source de vérité). Toujours DAVID SEUL.
create or replace function public.sim_is_pilot() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from auth.users where id = auth.uid() and lower(email) = 'david.saugy@gmail.com');
$$;
drop policy if exists sim_control_write on public.sim_control;
create policy sim_control_write on public.sim_control for update to authenticated
  using (public.sim_is_pilot()) with check (public.sim_is_pilot());

-- ═══════ 20260712e_sim_pilot_tous_comptes_david.sql ═══════
-- 🔑 (12.07 soir) David a PLUSIEURS comptes (david.saugy@gmail.com + comptes de test « afit… ») :
-- la serrure accepte ses 3 UIDs admin + l'email. Dom (bfb0eabf) reste hors pilotage (décision : David seul → ses comptes).
create or replace function public.sim_is_pilot() returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() = any(array[
    'bad38f3e-87df-40e0-a2d2-75c03b58d72b',
    '409e83dc-dda8-42c3-bb98-3ea900857d35',
    '9626a0ba-037f-49dd-9957-ebd37e58a864'
  ]::uuid[])
  or exists(select 1 from auth.users where id = auth.uid() and lower(email) = 'david.saugy@gmail.com');
$$;

-- ═══════ 20260713_fix_bots_is_bot.sql ═══════
-- 🐛 CAUSE RACINE « ville vide / 10 personnages » (David 12.07 nuit) :
-- create_test_bots insère dans auth.users → le trigger handle_new_user crée DÉJÀ un profil (sans is_bot)
-- → l'INSERT ... ON CONFLICT DO NOTHING ne marque jamais le bot. Résultat : ~1200 profils fantômes.
-- FIX ① la fonction force is_bot via DO UPDATE. FIX ② rattrapage des bots déjà créés (meta bot:true).

-- ── ① create_test_bots : DO UPDATE (marque toujours is_bot, même si le trigger a devancé) ──
create or replace function public.create_test_bots(p_n int default 8)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare
  caller uuid := auth.uid();
  admins uuid[] := array['bad38f3e-87df-40e0-a2d2-75c03b58d72b','409e83dc-dda8-42c3-bb98-3ea900857d35','9626a0ba-037f-49dd-9957-ebd37e58a864']::uuid[];
  prenoms_f text[] := array['Chloé','Léa','Manon','Sarah','Emma','Julie','Camille','Inès','Laura','Nina','Alice','Zoé'];
  prenoms_m text[] := array['Lucas','Hugo','Théo','Noah','Maxime','Adrien','Nathan','Yanis','Marco','Ethan','Robin','Ivan'];
  n int := greatest(1, least(coalesce(p_n,8), 100));   -- cap 60→100/appel
  i int; bid uuid; g text; nm text; a int; created int := 0;
begin
  if not (current_user = 'postgres' or caller = any(admins)) then
    return jsonb_build_object('ok', false, 'message', 'réservé admin');
  end if;
  for i in 1..n loop
    bid := gen_random_uuid();
    g := case when random() < 0.5 then 'woman' else 'man' end;
    a := 25 + floor(random() * 21)::int;
    nm := case when g = 'woman' then prenoms_f[1 + floor(random()*array_length(prenoms_f,1))::int]
               else prenoms_m[1 + floor(random()*array_length(prenoms_m,1))::int] end || ' 🤖';
    begin
      insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                              email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
      values (bid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
              'bot_' || replace(bid::text,'-','') || '@clutch.test', '', now(), now(), now(),
              '{"provider":"email","providers":["email"]}'::jsonb, '{"bot":true}'::jsonb);
    exception when others then null; end;
    -- 🔑 DO UPDATE : que le profil vienne d'être créé par le trigger ou non, il devient un VRAI bot.
    insert into public.profiles (id, name, age, gender, is_bot, center_lat, center_lng, available_radius_km, is_available)
    values (bid, nm, a, g, true, 46.5197 + (random()-0.5)*0.04, 6.6323 + (random()-0.5)*0.06, 8, false)
    on conflict (id) do update set is_bot = true, name = excluded.name, age = excluded.age,
      gender = excluded.gender, center_lat = excluded.center_lat, center_lng = excluded.center_lng,
      available_radius_km = 8;
    created := created + 1;
  end loop;
  return jsonb_build_object('ok', true, 'created', created);
end; $$;

-- ── ② RATTRAPAGE : tous les comptes bot déjà créés (meta bot:true) deviennent de vrais bots ──
update public.profiles p set is_bot = true
from auth.users u
where p.id = u.id and coalesce(u.raw_user_meta_data->>'bot','') = 'true' and coalesce(p.is_bot,false) = false;

select 'bots is_bot=true après rattrapage : ' || count(*) from public.profiles where is_bot = true;

-- ═══════ 20260713b_bots_noms_ages_quarts.sql ═══════
-- 🎭 SIM v2.1 (13.07) — David : « les bots ont des noms imbuvables, des âges à décimales, des créneaux
-- à 22h31 ». Cause : les 12 000 bots rattrapés ont été nommés par le trigger (email), pas par nous.
-- ① sim_seed réécrit nom + PRÉNOM réel + âge ENTIER dans profiles ② sim_tick arrondit l'heure de FIN
-- au quart d'heure ③ rattrapage immédiat : tous les bots reçoivent un vrai prénom + âge, sans re-semer.

-- ── ① sim_seed : dote AUSSI le prénom + l'âge (profiles) ──
create or replace function public.sim_seed(p_n int default 15000) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  towns constant jsonb := '[
    ["Lausanne",46.5197,6.6323,28],["Genève",46.2044,6.1432,26],["Fribourg",46.8065,7.1619,8],
    ["Neuchâtel",46.9920,6.9310,7],["Sion",46.2331,7.3606,6],["Yverdon",46.7785,6.6411,5],
    ["Montreux",46.4312,6.9107,4],["Vevey",46.4628,6.8419,4],["Renens",46.5399,6.5882,4],
    ["Nyon",46.3832,6.2396,4],["Morges",46.5093,6.4983,3],["Bulle",46.6194,7.0567,3],
    ["Martigny",46.1027,7.0724,3],["La Chaux-de-Fonds",47.0999,6.8259,3],["Payerne",46.8220,6.9380,2],
    ["Aigle",46.3167,6.9667,2],["Gland",46.4212,6.2704,2],["Echallens",46.6410,6.6350,1],
    ["Moudon",46.6670,6.7980,1],["Romont",46.6960,6.9190,1]
  ]'::jsonb;
  archs constant jsonb := '[["piliere",5],["comete_engage",3],["comete_arroseur",2],["organisatrice",4],
    ["power",5],["timide",8],["occasionnelle",18],["dormeur",20],["perdu",8],["indecise",7],
    ["noshow",5],["vexe",2],["pendulaire",7],["expat",4],["couple",2]]'::jsonb;
  pf constant text[] := array['Chloé','Léa','Manon','Sarah','Emma','Julie','Camille','Inès','Laura','Nina','Alice','Zoé','Sophie','Anaïs','Elodie','Marie','Clara','Jade','Lucie','Océane','Noémie','Aurélie','Fanny','Célia'];
  pm constant text[] := array['Lucas','Hugo','Théo','Noah','Maxime','Adrien','Nathan','Yanis','Marco','Ethan','Robin','Ivan','Julien','Quentin','Loïc','Bastien','Kevin','Damien','Nicolas','Antoine','Romain','Gaël','Sébastien','Florian'];
  nf constant text[] := array['Rochat','Favre','Blanc','Girard','Dubois','Perret','Baumann','Meier','Rey','Python','Chappuis','Roulin','Nicod','Gauthier','Progin','Aebischer','Décosterd','Bays','Marchand','Curdy'];
  totw numeric; tota numeric; t jsonb; a jsonb; r numeric; b record; n_done int := 0;
  arch text; chrono text; st text; tlat float8; tlng float8; tname text; acceptp numeric; latmin int; organise boolean;
  g text; nom text; age2 int;
begin
  if not public.qa_is_admin() then return jsonb_build_object('ok',false,'code','RLS_FORBIDDEN'); end if;
  select sum((e->>3)::numeric) into totw from jsonb_array_elements(towns) e;
  select sum((e->>1)::numeric) into tota from jsonb_array_elements(archs) e;
  for b in select id, gender from public.profiles where is_bot = true limit p_n loop
    r := random()*totw; for t in select e from jsonb_array_elements(towns) e loop r := r-(t->>3)::numeric; if r<=0 then exit; end if; end loop;
    tname := t->>0; tlat := (t->>1)::float8 + (random()-0.5)*0.016; tlng := (t->>2)::float8 + (random()-0.5)*0.02;
    r := random()*tota; for a in select e from jsonb_array_elements(archs) e loop r := r-(a->>1)::numeric; if r<=0 then exit; end if; end loop;
    arch := a->>0;
    chrono := case arch when 'pendulaire' then 'pendulaire' when 'piliere' then 'std' else (array['matin','std','std','soir','soir'])[1+floor(random()*5)::int] end;
    acceptp := case arch when 'piliere' then 0.6 when 'comete_engage' then 0.65 when 'comete_arroseur' then 0.7 when 'power' then 0.3 when 'timide' then 0.3 when 'dormeur' then 0.15 when 'noshow' then 0.85 when 'indecise' then 0.5 when 'vexe' then 0.5 else 0.35+random()*0.2 end;
    latmin := case arch when 'comete_engage' then 4+floor(random()*8)::int when 'comete_arroseur' then 3+floor(random()*5)::int when 'piliere' then 15+floor(random()*40)::int when 'indecise' then 150+floor(random()*90)::int when 'dormeur' then 120+floor(random()*300)::int else 10+floor(random()*60)::int end;
    organise := arch='organisatrice' or (arch='piliere' and random()<0.4);
    st := case arch when 'dormeur' then 'pause' when 'occasionnelle' then (case when random()<0.5 then 'occupe' else 'actif' end) when 'comete_engage' then 'hyper_engage' when 'comete_arroseur' then 'hyper_arroseur' else 'actif' end;
    insert into public.sim_bots (bot_id, traits, state, home_lat, home_lng, town, next_action_at)
    values (b.id, jsonb_build_object('arch',arch,'chrono',chrono,
        'fiab',case arch when 'noshow' then 'noshow' when 'piliere' then 'roc' when 'indecise' then 'annuleur' when 'perdu' then 'retard' else (array['roc','ponctuel','ponctuel','retard'])[1+floor(random()*4)::int] end,
        'organise',organise,'accept_p',acceptp,'latence_min',latmin,'work_lat',46.5197+(random()-0.5)*0.01,'work_lng',6.6323+(random()-0.5)*0.014),
      st, tlat, tlng, tname, now()+(random()*interval '20 minutes'))
    on conflict (bot_id) do update set traits=excluded.traits, home_lat=excluded.home_lat, home_lng=excluded.home_lng, town=excluded.town;
    -- 👤 vrai prénom + nom + âge ENTIER (David : « fais-moi au moins des noms »)
    g := coalesce(b.gender,'man');
    nom := case when g in ('woman','F','f') then pf[1+floor(random()*array_length(pf,1))::int] else pm[1+floor(random()*array_length(pm,1))::int] end
           || ' ' || nf[1+floor(random()*array_length(nf,1))::int];
    age2 := 22 + floor(random()*24)::int;
    update public.profiles set name = nom, age = age2, center_lat = tlat, center_lng = tlng where id = b.id;
    n_done := n_done + 1;
  end loop;
  return jsonb_build_object('ok',true,'seeded',n_done);
end; $$;

-- ── ② RATTRAPAGE IMMÉDIAT : prénom + âge entier pour TOUS les bots (sans attendre un re-semis) ──
with pf as (select array['Chloé','Léa','Manon','Sarah','Emma','Julie','Camille','Inès','Laura','Nina','Alice','Zoé','Sophie','Anaïs','Elodie','Marie','Clara','Jade','Lucie','Océane'] a),
     pm as (select array['Lucas','Hugo','Théo','Noah','Maxime','Adrien','Nathan','Yanis','Marco','Ethan','Robin','Ivan','Julien','Quentin','Loïc','Bastien','Kevin','Damien','Nicolas','Antoine'] a),
     nf as (select array['Rochat','Favre','Blanc','Girard','Dubois','Perret','Baumann','Meier','Rey','Python','Chappuis','Roulin','Nicod','Gauthier','Progin','Aebischer','Bays','Marchand','Curdy','Bays'] a)
update public.profiles p set
  name = (case when p.gender in ('woman','F','f') then (select a from pf) else (select a from pm) end)[1+floor(random()*20)::int]
         || ' ' || (select a from nf)[1+floor(random()*20)::int],
  age = 22 + floor(random()*24)::int
where p.is_bot = true and (p.name is null or p.name like '%🤖%' or p.name like 'bot_%' or p.age is null or p.age <> floor(p.age));

select 'bots renommés' as info, count(*) from public.profiles where is_bot = true;

-- ── ③ sim_tick : l'heure de FIN au quart d'heure (David : « je vois 22h31, non ! ») ──
-- Patch chirurgical : on ré-arrondit su juste avant admin_set_availability. On recrée sim_tick
-- (copie v2 + su arrondi). Voir 20260712c pour la version d'origine.

create or replace function public.sim_tick() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  ctl record; b record; tr jsonb; arch text; h int; dow int; awake numeric; target int; online int;
  acted int := 0; published int := 0; answered int := 0; events int := 0; clutched int := 0; retired int := 0; revenge int := 0;
  cl record; hum record; vx record; lat8 float8; lng8 float8; sm timestamptz; su timestamptz; radp int;
  pool jsonb; pick jsonb; pubp numeric;
begin
  if not public.qa_is_admin() then return jsonb_build_object('ok',false,'code','RLS_FORBIDDEN'); end if;
  select * into ctl from public.sim_control where id = 1;
  if ctl is null or not ctl.running then return jsonb_build_object('ok',true,'skipped','off'); end if;
  h := extract(hour from now() at time zone 'Europe/Zurich')::int;
  dow := extract(isodow from now() at time zone 'Europe/Zurich')::int;
  target := round((case ctl.scene when 'A' then 25 when 'B' then 180 else 700 end) * ctl.density
            * (case when h between 17 and 22 then 1.0 when h between 12 and 16 then 0.6
                    when h between 7 and 11 then 0.4 else 0.25 end)
            * (case when dow in (4,5,6) then 1.5 else 1.0 end));
  select count(*) into online from public.profiles p join public.sim_bots s on s.bot_id=p.id
    where p.is_available = true and p.available_until > now();

  for b in select * from public.sim_bots where next_action_at <= now()
           and state not in ('churne') order by next_action_at limit 40 loop
    begin
      acted := acted + 1; tr := b.traits; arch := coalesce(tr->>'arch','occasionnelle');
      awake := case when (tr->>'chrono')='pendulaire' and (h between 7 and 9 or h between 17 and 19) then 1
                    when (tr->>'chrono')='pendulaire' then 0.15
                    when (tr->>'chrono')='matin' and h between 7 and 11 then 1
                    when (tr->>'chrono')='soir'  and (h >= 18 or h < 2) then 1
                    when (tr->>'chrono')='std'   and h between 11 and 22 then 1 else 0.3 end;
      update public.sim_bots set next_action_at = now() + ((8 + random()*35) / greatest(awake,0.1)) * interval '1 minute'
        where bot_id = b.bot_id;
      if b.state in ('pause','occupe') and random() < 0.85 then continue; end if;

      -- ① PUBLIER — cadence, rayon et fenêtre PAR PERSONNAGE
      pubp := case arch when 'piliere' then 0.7 when 'comete_engage' then 0.8 when 'comete_arroseur' then 0.75
                        when 'power' then 0.6 when 'organisatrice' then 0.5 when 'timide' then 0.35
                        when 'occasionnelle' then (case when dow in (5,6,7) then 0.5 else 0.15 end)
                        when 'dormeur' then 0.08 when 'perdu' then 0.4 when 'pendulaire' then 0.6
                        when 'expat' then 0.55 when 'vexe' then 0.45 else 0.4 end;
      if online < target and random() < pubp * awake
         and not exists (select 1 from public.profiles where id=b.bot_id and is_available and available_until>now()) then
        sm := date_trunc('hour', now()) + (floor(random()*4)*interval '15 minutes');
        if sm < now() then sm := now(); end if;
        su := sm + (interval '1 hour' * (case arch when 'pendulaire' then 1 + random()
                                                    when 'expat' then 1 + random()*2
                                                    when 'perdu' then 0.5 + random()*8   -- n'importe quoi
                                                    else 1.5 + random()*3.5 end));
        if su > now() + interval '17 hours' then su := now() + interval '17 hours'; end if;
        su := to_timestamp(round(extract(epoch from su)/900)*900);  -- 🕐 fin au quart d'heure (David)
        -- le pendulaire publie sur son lieu du MOMENT (boulot en journée, maison le soir)
        if arch = 'pendulaire' and h between 9 and 17 then
          lat8 := (tr->>'work_lat')::float8 + (random()-0.5)*0.008; lng8 := (tr->>'work_lng')::float8 + (random()-0.5)*0.012;
        else
          lat8 := b.home_lat + (random()-0.5)*0.01; lng8 := b.home_lng + (random()-0.5)*0.014;
        end if;
        radp := case arch when 'expat' then (array[15,20,25])[1+floor(random()*3)::int]
                          when 'perdu' then (array[1,2,40])[1+floor(random()*3)::int]
                          when 'pendulaire' then (array[3,5,8])[1+floor(random()*3)::int]
                          else (array[3,5,8,10,15])[1+floor(random()*5)::int] end;
        perform public.admin_set_availability(b.bot_id, sm, su, lat8, lng8, radp);
        online := online + 1; published := published + 1;
      end if;

      -- ①bis 🫣 LA TIMIDE : quelqu'un l'a clutchée → panique, retire son créneau (le clutch expirera)
      if arch = 'timide' and random() < 0.4
         and exists (select 1 from public.clutches c where c.receiver_id=b.bot_id and c.status='pending') then
        update public.profiles set is_available = false where id = b.bot_id and is_available = true;
        retired := retired + 1;
      end if;

      -- ② RÉPONDRE (latence + caractère ; l'indécise répond à la toute dernière minute via sa latence géante)
      for cl in select c.id, c.sender_id from public.clutches c
                where c.receiver_id = b.bot_id and c.status = 'pending'
                  and c.created_at < now() - ((tr->>'latence_min')::int * interval '1 minute') limit 2 loop
        if random() < coalesce((tr->>'accept_p')::numeric, 0.4) then
          perform public.admin_accept_clutch(b.bot_id, cl.sender_id);   -- le noshow ACCEPTE (et ne viendra pas)
        else
          perform public.admin_refuse_clutch(b.bot_id, cl.sender_id);
        end if;
        answered := answered + 1;
      end loop;

      -- ②bis 🎯 CLUTCHER UN HUMAIN (dose crédible — throttle global 25 min/humain, jamais 2× le même en 24 h)
      if b.state in ('actif','hyper_engage','hyper_arroseur')
         and random() < (case arch when 'comete_arroseur' then 0.08 when 'comete_engage' then 0.05
                                    when 'piliere' then 0.04 when 'timide' then 0.005 else 0.02 end) then
        select p.id into hum from public.profiles p
          where coalesce(p.is_bot,false) = false and p.is_available = true and p.available_until > now()
            and p.center_lat is not null
            and abs(p.center_lat - b.home_lat) < 0.15 and abs(p.center_lng - b.home_lng) < 0.2
            and not exists (select 1 from public.clutches c2 where c2.receiver_id = p.id and c2.created_at > now() - interval '25 minutes')
            and not exists (select 1 from public.clutches c3 where c3.sender_id = b.bot_id and c3.receiver_id = p.id and c3.created_at > now() - interval '24 hours')
          order by random() limit 1;
        if hum.id is not null then
          perform public.admin_create_clutch(b.bot_id, hum.id,
            (array['Un café ?','Une balade au bord du lac ?','Un verre en terrasse ?','Un ping-pong ?','Une glace ?'])[1+floor(random()*5)::int],
            now() + (interval '1 hour' * (0.75 + random()*2)),
            (array['On tente ? 🙂','Dispo si tu l''es','Ça te dit ?','Simple et sans pression'])[1+floor(random()*4)::int],
            60, b.home_lat, b.home_lng);
          clutched := clutched + 1;
        end if;
      end if;

      -- ②ter 😤 LE VEXÉ : son clutch a été refusé → il RETENTE (le cooldown serveur doit l'arrêter — c'est le test)
      if arch = 'vexe' and random() < 0.5 then
        select c.receiver_id into vx from public.clutches c
          where c.sender_id = b.bot_id and c.status in ('refused','declined','expired')
            and c.created_at > now() - interval '6 hours'
          order by c.created_at desc limit 1;
        if vx.receiver_id is not null then
          perform public.admin_create_clutch(b.bot_id, vx.receiver_id, 'Allez, un café quand même ?', now() + interval '90 minutes',
            'Je suis sûr qu''on s''entendrait bien', 60, b.home_lat, b.home_lng);
          revenge := revenge + 1;   -- la plupart seront refusés par COOLDOWN_ACTIVE : exactement ce qu'on vérifie
        end if;
      end if;

      -- ③ ORGANISER un event (organisatrices + pilières)
      if (tr->>'organise')::boolean and random() < 0.06 and h between 8 and 22 then
        pool := case when h < 11 then '[["☕","Café-croissants"],["🥾","Balade matinale"]]'::jsonb
                     when h < 14 then '[["🥗","Lunch ensemble"],["♟️","Échecs au parc"]]'::jsonb
                     when h < 17 then '[["🎨","Atelier croquis"],["🚴","Sortie vélo"]]'::jsonb
                     else '[["🍹","Apéro spontané"],["🎲","Soirée jeux"],["🏐","Beach-volley"]]'::jsonb end;
        pick := pool->floor(random()*jsonb_array_length(pool))::int;
        perform public.admin_create_event(b.bot_id,
          (pick->>0)||' '||(pick->>1)||' — '||coalesce(b.town,'Lausanne'),
          now() + (interval '1 hour' * (1 + random()*3)),
          b.home_lat + (random()-0.5)*0.008, b.home_lng + (random()-0.5)*0.012,
          4 + floor(random()*8)::int);
        events := events + 1;
      end if;
    exception when others then null;
    end;
  end loop;
  return jsonb_build_object('ok',true,'acted',acted,'published',published,'answered',answered,
    'clutched',clutched,'revenge',revenge,'retired',retired,'events',events,'online',online,'target',target);
end; $$;

-- ═══════ 20260713c_sim_vivante_v3.sql ═══════
-- 🏙️💓 SIM v3 — LA VILLE QUI VIT D'ELLE-MÊME (David 13.07 : « rends-le dynamique, il ne se passe rien »)
-- Audit → docs/audit-simulation-13jul.md. Ajouts vs v2 : ① bots se clutchent ENTRE EUX (Verrous naissent)
-- ② rejoignent les events proches (les events se remplissent) ③ acceptent les demandes à leurs events
-- ④ organisent plus, titre = SA ville ⑤ budget 40→90/tick. À COLLER après 20260713b.

create or replace function public.sim_tick() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  ctl record; b record; tr jsonb; arch text; h int; dow int; awake numeric; target int; online int;
  acted int := 0; published int := 0; answered int := 0; events int := 0; clutched int := 0; retired int := 0; revenge int := 0; joined int := 0; botclutch int := 0; accepted int := 0;
  ev record; other record; req record;
  cl record; hum record; vx record; lat8 float8; lng8 float8; sm timestamptz; su timestamptz; radp int;
  pool jsonb; pick jsonb; pubp numeric;
begin
  if not public.qa_is_admin() then return jsonb_build_object('ok',false,'code','RLS_FORBIDDEN'); end if;
  select * into ctl from public.sim_control where id = 1;
  if ctl is null or not ctl.running then return jsonb_build_object('ok',true,'skipped','off'); end if;
  h := extract(hour from now() at time zone 'Europe/Zurich')::int;
  dow := extract(isodow from now() at time zone 'Europe/Zurich')::int;
  target := round((case ctl.scene when 'A' then 25 when 'B' then 180 else 700 end) * ctl.density
            * (case when h between 17 and 22 then 1.0 when h between 12 and 16 then 0.6
                    when h between 7 and 11 then 0.4 else 0.25 end)
            * (case when dow in (4,5,6) then 1.5 else 1.0 end));
  select count(*) into online from public.profiles p join public.sim_bots s on s.bot_id=p.id
    where p.is_available = true and p.available_until > now();

  for b in select * from public.sim_bots where next_action_at <= now()
           and state not in ('churne') order by next_action_at limit 90 loop
    begin
      acted := acted + 1; tr := b.traits; arch := coalesce(tr->>'arch','occasionnelle');
      awake := case when (tr->>'chrono')='pendulaire' and (h between 7 and 9 or h between 17 and 19) then 1
                    when (tr->>'chrono')='pendulaire' then 0.15
                    when (tr->>'chrono')='matin' and h between 7 and 11 then 1
                    when (tr->>'chrono')='soir'  and (h >= 18 or h < 2) then 1
                    when (tr->>'chrono')='std'   and h between 11 and 22 then 1 else 0.3 end;
      update public.sim_bots set next_action_at = now() + ((8 + random()*35) / greatest(awake,0.1)) * interval '1 minute'
        where bot_id = b.bot_id;
      if b.state in ('pause','occupe') and random() < 0.85 then continue; end if;

      -- ① PUBLIER — cadence, rayon et fenêtre PAR PERSONNAGE
      pubp := case arch when 'piliere' then 0.7 when 'comete_engage' then 0.8 when 'comete_arroseur' then 0.75
                        when 'power' then 0.6 when 'organisatrice' then 0.5 when 'timide' then 0.35
                        when 'occasionnelle' then (case when dow in (5,6,7) then 0.5 else 0.15 end)
                        when 'dormeur' then 0.08 when 'perdu' then 0.4 when 'pendulaire' then 0.6
                        when 'expat' then 0.55 when 'vexe' then 0.45 else 0.4 end;
      if online < target and random() < pubp * awake
         and not exists (select 1 from public.profiles where id=b.bot_id and is_available and available_until>now()) then
        sm := date_trunc('hour', now()) + (floor(random()*4)*interval '15 minutes');
        if sm < now() then sm := now(); end if;
        su := sm + (interval '1 hour' * (case arch when 'pendulaire' then 1 + random()
                                                    when 'expat' then 1 + random()*2
                                                    when 'perdu' then 0.5 + random()*8   -- n'importe quoi
                                                    else 1.5 + random()*3.5 end));
        if su > now() + interval '17 hours' then su := now() + interval '17 hours'; end if;
        su := to_timestamp(round(extract(epoch from su)/900)*900);  -- 🕐 fin au quart d'heure (David)
        -- le pendulaire publie sur son lieu du MOMENT (boulot en journée, maison le soir)
        if arch = 'pendulaire' and h between 9 and 17 then
          lat8 := (tr->>'work_lat')::float8 + (random()-0.5)*0.008; lng8 := (tr->>'work_lng')::float8 + (random()-0.5)*0.012;
        else
          lat8 := b.home_lat + (random()-0.5)*0.01; lng8 := b.home_lng + (random()-0.5)*0.014;
        end if;
        radp := case arch when 'expat' then (array[15,20,25])[1+floor(random()*3)::int]
                          when 'perdu' then (array[1,2,40])[1+floor(random()*3)::int]
                          when 'pendulaire' then (array[3,5,8])[1+floor(random()*3)::int]
                          else (array[3,5,8,10,15])[1+floor(random()*5)::int] end;
        perform public.admin_set_availability(b.bot_id, sm, su, lat8, lng8, radp);
        online := online + 1; published := published + 1;
      end if;

      -- ①bis 🫣 LA TIMIDE : quelqu'un l'a clutchée → panique, retire son créneau (le clutch expirera)
      if arch = 'timide' and random() < 0.4
         and exists (select 1 from public.clutches c where c.receiver_id=b.bot_id and c.status='pending') then
        update public.profiles set is_available = false where id = b.bot_id and is_available = true;
        retired := retired + 1;
      end if;

      -- ② RÉPONDRE (latence + caractère ; l'indécise répond à la toute dernière minute via sa latence géante)
      for cl in select c.id, c.sender_id from public.clutches c
                where c.receiver_id = b.bot_id and c.status = 'pending'
                  and c.created_at < now() - ((tr->>'latence_min')::int * interval '1 minute') limit 2 loop
        if random() < coalesce((tr->>'accept_p')::numeric, 0.4) then
          perform public.admin_accept_clutch(b.bot_id, cl.sender_id);   -- le noshow ACCEPTE (et ne viendra pas)
        else
          perform public.admin_refuse_clutch(b.bot_id, cl.sender_id);
        end if;
        answered := answered + 1;
      end loop;

      -- ②bis 🎯 CLUTCHER UN HUMAIN (dose crédible — throttle global 25 min/humain, jamais 2× le même en 24 h)
      if b.state in ('actif','hyper_engage','hyper_arroseur')
         and random() < (case arch when 'comete_arroseur' then 0.08 when 'comete_engage' then 0.05
                                    when 'piliere' then 0.04 when 'timide' then 0.005 else 0.02 end) then
        select p.id into hum from public.profiles p
          where coalesce(p.is_bot,false) = false and p.is_available = true and p.available_until > now()
            and p.center_lat is not null
            and abs(p.center_lat - b.home_lat) < 0.15 and abs(p.center_lng - b.home_lng) < 0.2
            and not exists (select 1 from public.clutches c2 where c2.receiver_id = p.id and c2.created_at > now() - interval '25 minutes')
            and not exists (select 1 from public.clutches c3 where c3.sender_id = b.bot_id and c3.receiver_id = p.id and c3.created_at > now() - interval '24 hours')
          order by random() limit 1;
        if hum.id is not null then
          perform public.admin_create_clutch(b.bot_id, hum.id,
            (array['Un café ?','Une balade au bord du lac ?','Un verre en terrasse ?','Un ping-pong ?','Une glace ?'])[1+floor(random()*5)::int],
            now() + (interval '1 hour' * (0.75 + random()*2)),
            (array['On tente ? 🙂','Dispo si tu l''es','Ça te dit ?','Simple et sans pression'])[1+floor(random()*4)::int],
            60, b.home_lat, b.home_lng);
          clutched := clutched + 1;
        end if;
      end if;

      -- ②quater 🤝 CLUTCHER UN AUTRE BOT (la ville s'anime d'elle-même — David 13.07 « il ne se passe rien »)
      if b.state in ('actif','hyper_engage','hyper_arroseur','occasionnelle')
         and random() < (case arch when 'comete_arroseur' then 0.16 when 'comete_engage' then 0.12
                                    when 'piliere' then 0.10 when 'timide' then 0.02 else 0.06 end) * awake then
        select p.id into other from public.profiles p join public.sim_bots s2 on s2.bot_id = p.id
          where p.is_bot = true and p.id <> b.bot_id and p.is_available = true and p.available_until > now()
            and abs(p.center_lat - b.home_lat) < 0.12 and abs(p.center_lng - b.home_lng) < 0.16
            and not exists (select 1 from public.clutches c2 where c2.receiver_id = p.id and c2.sender_id = b.bot_id and c2.created_at > now() - interval '24 hours')
            and not exists (select 1 from public.clutches c3 where c3.sender_id = b.bot_id and c3.status = 'pending')  -- 1 clutch en vol à la fois
          order by random() limit 1;
        if other.id is not null then
          perform public.admin_create_clutch(b.bot_id, other.id,
            (array['Un café ?','Une balade ?','Un verre ?','Un ping-pong ?','On se voit ?'])[1+floor(random()*5)::int],
            now() + (interval '1 hour' * (0.75 + random()*2)), 'Dispo maintenant 🙂', 60, b.home_lat, b.home_lng);
          botclutch := botclutch + 1;
        end if;
      end if;

      -- ⑤ 🎟️ REJOINDRE un EVENT proche pas plein (les events se remplissent → crédibles)
      if b.state in ('actif','hyper_engage','occasionnelle','dormeur') and random() < 0.10 * awake then
        select e.id into ev from public.events e
          where e.active = true and e.status in ('pending','open') and e.starts_at > now()
            and coalesce(e.taken,0) < e.spots and e.created_by <> b.bot_id
            and e.venue_lat is not null and abs(e.venue_lat - b.home_lat) < 0.2 and abs(e.venue_lng - b.home_lng) < 0.25
            and not exists (select 1 from public.event_participants ep where ep.event_id = e.id and ep.user_id = b.bot_id)
          order by random() limit 1;
        if ev.id is not null then perform public.join_event(ev.id, b.bot_id); joined := joined + 1; end if;
      end if;

      -- ⑥ ✅ ACCEPTER les demandes à MES events (organisateur curated) — les demandes ne pourrissent plus
      if (tr->>'organise')::boolean then
        for req in select ep.event_id, ep.user_id from public.event_participants ep
                   join public.events e on e.id = ep.event_id
                   where e.created_by = b.bot_id and ep.state = 'requested' limit 3 loop
          begin update public.event_participants set state = 'accepted' where event_id = req.event_id and user_id = req.user_id;
                accepted := accepted + 1; exception when others then null; end;
        end loop;
      end if;

      -- ②ter 😤 LE VEXÉ : son clutch a été refusé → il RETENTE (le cooldown serveur doit l'arrêter — c'est le test)
      if arch = 'vexe' and random() < 0.5 then
        select c.receiver_id into vx from public.clutches c
          where c.sender_id = b.bot_id and c.status in ('refused','declined','expired')
            and c.created_at > now() - interval '6 hours'
          order by c.created_at desc limit 1;
        if vx.receiver_id is not null then
          perform public.admin_create_clutch(b.bot_id, vx.receiver_id, 'Allez, un café quand même ?', now() + interval '90 minutes',
            'Je suis sûr qu''on s''entendrait bien', 60, b.home_lat, b.home_lng);
          revenge := revenge + 1;   -- la plupart seront refusés par COOLDOWN_ACTIVE : exactement ce qu'on vérifie
        end if;
      end if;

      -- ③ ORGANISER un event (organisatrices + pilières)
      if (tr->>'organise')::boolean and random() < 0.10 and h between 8 and 22 then
        pool := case when h < 11 then '[["☕","Café-croissants"],["🥾","Balade matinale"]]'::jsonb
                     when h < 14 then '[["🥗","Lunch ensemble"],["♟️","Échecs au parc"]]'::jsonb
                     when h < 17 then '[["🎨","Atelier croquis"],["🚴","Sortie vélo"]]'::jsonb
                     else '[["🍹","Apéro spontané"],["🎲","Soirée jeux"],["🏐","Beach-volley"]]'::jsonb end;
        pick := pool->floor(random()*jsonb_array_length(pool))::int;
        perform public.admin_create_event(b.bot_id,
          (pick->>0)||' '||(pick->>1)||' — '||coalesce(b.town,'Lausanne'),
          now() + (interval '1 hour' * (1 + random()*3)),
          b.home_lat + (random()-0.5)*0.008, b.home_lng + (random()-0.5)*0.012,
          4 + floor(random()*8)::int);
        events := events + 1;
      end if;
    exception when others then null;
    end;
  end loop;
  return jsonb_build_object('ok',true,'acted',acted,'published',published,'answered',answered,
    'clutched',clutched,'botclutch',botclutch,'joined',joined,'accepted',accepted,'revenge',revenge,'retired',retired,'events',events,'online',online,'target',target);
end; $$;

-- ═══════ 20260713d_sim_mobilite_oubli.sql ═══════
-- 🚶🤫 SIM v3.2 — MOUVEMENT & OUBLI (David 13.07 : « les gens bougent, eux aussi ; ils refusent, ils oublient »)
-- ① MOBILITÉ : chaque bot a un point COURANT ≠ domicile selon un indice de mobilité par archétype (casaniers
--   restent chez eux ~0.4 km, nomades/expats sortent jusqu'à ~6 km) → ils publient/clutchent LÀ OÙ ILS SONT.
-- ② OUBLI : dormeur/timide/perdu ignorent souvent un clutch reçu (silence → il expire), pas seulement oui/non.
-- À COLLER après 20260713c.

create or replace function public.sim_tick() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  ctl record; b record; tr jsonb; arch text; h int; dow int; awake numeric; target int; online int;
  acted int := 0; published int := 0; answered int := 0; events int := 0; clutched int := 0; retired int := 0; revenge int := 0; joined int := 0; botclutch int := 0; accepted int := 0;
  ev record; other record; req record; curlat float8; curlng float8; mob numeric;
  cl record; hum record; vx record; lat8 float8; lng8 float8; sm timestamptz; su timestamptz; radp int;
  pool jsonb; pick jsonb; pubp numeric;
begin
  if not public.qa_is_admin() then return jsonb_build_object('ok',false,'code','RLS_FORBIDDEN'); end if;
  select * into ctl from public.sim_control where id = 1;
  if ctl is null or not ctl.running then return jsonb_build_object('ok',true,'skipped','off'); end if;
  h := extract(hour from now() at time zone 'Europe/Zurich')::int;
  dow := extract(isodow from now() at time zone 'Europe/Zurich')::int;
  target := round((case ctl.scene when 'A' then 25 when 'B' then 180 else 700 end) * ctl.density
            * (case when h between 17 and 22 then 1.0 when h between 12 and 16 then 0.6
                    when h between 7 and 11 then 0.4 else 0.25 end)
            * (case when dow in (4,5,6) then 1.5 else 1.0 end));
  select count(*) into online from public.profiles p join public.sim_bots s on s.bot_id=p.id
    where p.is_available = true and p.available_until > now();

  for b in select * from public.sim_bots where next_action_at <= now()
           and state not in ('churne') order by next_action_at limit 90 loop
    begin
      acted := acted + 1; tr := b.traits; arch := coalesce(tr->>'arch','occasionnelle');
      awake := case when (tr->>'chrono')='pendulaire' and (h between 7 and 9 or h between 17 and 19) then 1
                    when (tr->>'chrono')='pendulaire' then 0.15
                    when (tr->>'chrono')='matin' and h between 7 and 11 then 1
                    when (tr->>'chrono')='soir'  and (h >= 18 or h < 2) then 1
                    when (tr->>'chrono')='std'   and h between 11 and 22 then 1 else 0.3 end;
      update public.sim_bots set next_action_at = now() + ((8 + random()*35) / greatest(awake,0.1)) * interval '1 minute'
        where bot_id = b.bot_id;
      -- 🚶 MOBILITÉ (David 13.07 « les gens bougent, eux aussi doivent bouger ») : point COURANT = domicile
      --   + un déplacement selon un indice de mobilité STABLE par bot (hash de l'id). Casaniers restent chez
      --   eux (±0.4 km) ; nomades/expats/comètes sortent en ville (jusqu'à ~6 km, un bar, un ami, un quartier).
      mob := case coalesce(tr->>'arch','x') when 'expat' then 0.9 when 'comete_arroseur' then 0.8
                  when 'comete_engage' then 0.7 when 'organisatrice' then 0.6 when 'power' then 0.55
                  when 'pendulaire' then 0.5 when 'dormeur' then 0.15 when 'timide' then 0.2
                  when 'piliere' then 0.35 else 0.4 end;
      if (tr->>'chrono') = 'pendulaire' and h between 9 and 17 then
        curlat := (tr->>'work_lat')::float8 + (random()-0.5)*0.008; curlng := (tr->>'work_lng')::float8 + (random()-0.5)*0.012;
      elsif random() < mob then
        -- sorti : déplacement gaussien, d'autant plus large que le bot est mobile (max ~6 km)
        curlat := b.home_lat + (random()+random()-1) * mob * 0.045;
        curlng := b.home_lng + (random()+random()-1) * mob * 0.06;
      else
        curlat := b.home_lat + (random()-0.5)*0.006; curlng := b.home_lng + (random()-0.5)*0.008;  -- casanier, autour de chez lui
      end if;
      if b.state in ('pause','occupe') and random() < 0.85 then continue; end if;

      -- ① PUBLIER — cadence, rayon et fenêtre PAR PERSONNAGE
      pubp := case arch when 'piliere' then 0.7 when 'comete_engage' then 0.8 when 'comete_arroseur' then 0.75
                        when 'power' then 0.6 when 'organisatrice' then 0.5 when 'timide' then 0.35
                        when 'occasionnelle' then (case when dow in (5,6,7) then 0.5 else 0.15 end)
                        when 'dormeur' then 0.08 when 'perdu' then 0.4 when 'pendulaire' then 0.6
                        when 'expat' then 0.55 when 'vexe' then 0.45 else 0.4 end;
      if online < target and random() < pubp * awake
         and not exists (select 1 from public.profiles where id=b.bot_id and is_available and available_until>now()) then
        sm := date_trunc('hour', now()) + (floor(random()*4)*interval '15 minutes');
        if sm < now() then sm := now(); end if;
        su := sm + (interval '1 hour' * (case arch when 'pendulaire' then 1 + random()
                                                    when 'expat' then 1 + random()*2
                                                    when 'perdu' then 0.5 + random()*8   -- n'importe quoi
                                                    else 1.5 + random()*3.5 end));
        if su > now() + interval '17 hours' then su := now() + interval '17 hours'; end if;
        su := to_timestamp(round(extract(epoch from su)/900)*900);  -- 🕐 fin au quart d'heure (David)
        -- le pendulaire publie sur son lieu du MOMENT (boulot en journée, maison le soir)
        lat8 := curlat; lng8 := curlng;   -- 🚶 publie là où il EST maintenant (mobilité)
        radp := case arch when 'expat' then (array[15,20,25])[1+floor(random()*3)::int]
                          when 'perdu' then (array[1,2,40])[1+floor(random()*3)::int]
                          when 'pendulaire' then (array[3,5,8])[1+floor(random()*3)::int]
                          else (array[3,5,8,10,15])[1+floor(random()*5)::int] end;
        perform public.admin_set_availability(b.bot_id, sm, su, lat8, lng8, radp);
        online := online + 1; published := published + 1;
      end if;

      -- ①bis 🫣 LA TIMIDE : quelqu'un l'a clutchée → panique, retire son créneau (le clutch expirera)
      if arch = 'timide' and random() < 0.4
         and exists (select 1 from public.clutches c where c.receiver_id=b.bot_id and c.status='pending') then
        update public.profiles set is_available = false where id = b.bot_id and is_available = true;
        retired := retired + 1;
      end if;

      -- ② RÉPONDRE (latence + caractère ; l'indécise répond à la toute dernière minute via sa latence géante)
      -- 🤫 David 13.07 : certains n'ONT PAS RÉPONDU (ils oublient / ignorent) → silence, le clutch expirera.
      --   dormeur/timide/perdu/occasionnelle oublient souvent ; les fiables répondent presque toujours.
      if not (random() < (case arch when 'dormeur' then 0.35 when 'timide' then 0.45 when 'perdu' then 0.4
                                    when 'occasionnelle' then 0.3 when 'indecise' then 0.25 else 0.06 end)) then
      for cl in select c.id, c.sender_id from public.clutches c
                where c.receiver_id = b.bot_id and c.status = 'pending'
                  and c.created_at < now() - ((tr->>'latence_min')::int * interval '1 minute') limit 2 loop
        if random() < coalesce((tr->>'accept_p')::numeric, 0.4) then
          perform public.admin_accept_clutch(b.bot_id, cl.sender_id);   -- le noshow ACCEPTE (et ne viendra pas)
        else
          perform public.admin_refuse_clutch(b.bot_id, cl.sender_id);
        end if;
        answered := answered + 1;
      end loop;
      end if;   -- fin du filtre « ignorer » (silence = expiration)

      -- ②bis 🎯 CLUTCHER UN HUMAIN (dose crédible — throttle global 25 min/humain, jamais 2× le même en 24 h)
      if b.state in ('actif','hyper_engage','hyper_arroseur')
         and random() < (case arch when 'comete_arroseur' then 0.08 when 'comete_engage' then 0.05
                                    when 'piliere' then 0.04 when 'timide' then 0.005 else 0.02 end) then
        select p.id into hum from public.profiles p
          where coalesce(p.is_bot,false) = false and p.is_available = true and p.available_until > now()
            and p.center_lat is not null
            and abs(p.center_lat - curlat) < 0.15 and abs(p.center_lng - curlng) < 0.2
            and not exists (select 1 from public.clutches c2 where c2.receiver_id = p.id and c2.created_at > now() - interval '25 minutes')
            and not exists (select 1 from public.clutches c3 where c3.sender_id = b.bot_id and c3.receiver_id = p.id and c3.created_at > now() - interval '24 hours')
          order by random() limit 1;
        if hum.id is not null then
          perform public.admin_create_clutch(b.bot_id, hum.id,
            (array['Un café ?','Une balade au bord du lac ?','Un verre en terrasse ?','Un ping-pong ?','Une glace ?'])[1+floor(random()*5)::int],
            now() + (interval '1 hour' * (0.75 + random()*2)),
            (array['On tente ? 🙂','Dispo si tu l''es','Ça te dit ?','Simple et sans pression'])[1+floor(random()*4)::int],
            60, b.home_lat, b.home_lng);
          clutched := clutched + 1;
        end if;
      end if;

      -- ②quater 🤝 CLUTCHER UN AUTRE BOT (la ville s'anime d'elle-même — David 13.07 « il ne se passe rien »)
      if b.state in ('actif','hyper_engage','hyper_arroseur','occasionnelle')
         and random() < (case arch when 'comete_arroseur' then 0.16 when 'comete_engage' then 0.12
                                    when 'piliere' then 0.10 when 'timide' then 0.02 else 0.06 end) * awake then
        select p.id into other from public.profiles p join public.sim_bots s2 on s2.bot_id = p.id
          where p.is_bot = true and p.id <> b.bot_id and p.is_available = true and p.available_until > now()
            and abs(p.center_lat - curlat) < 0.12 and abs(p.center_lng - curlng) < 0.16
            and not exists (select 1 from public.clutches c2 where c2.receiver_id = p.id and c2.sender_id = b.bot_id and c2.created_at > now() - interval '24 hours')
            and not exists (select 1 from public.clutches c3 where c3.sender_id = b.bot_id and c3.status = 'pending')  -- 1 clutch en vol à la fois
          order by random() limit 1;
        if other.id is not null then
          perform public.admin_create_clutch(b.bot_id, other.id,
            (array['Un café ?','Une balade ?','Un verre ?','Un ping-pong ?','On se voit ?'])[1+floor(random()*5)::int],
            now() + (interval '1 hour' * (0.75 + random()*2)), 'Dispo maintenant 🙂', 60, b.home_lat, b.home_lng);
          botclutch := botclutch + 1;
        end if;
      end if;

      -- ⑤ 🎟️ REJOINDRE un EVENT proche pas plein (les events se remplissent → crédibles)
      if b.state in ('actif','hyper_engage','occasionnelle','dormeur') and random() < 0.10 * awake then
        select e.id into ev from public.events e
          where e.active = true and e.status in ('pending','open') and e.starts_at > now()
            and coalesce(e.taken,0) < e.spots and e.created_by <> b.bot_id
            and e.venue_lat is not null and abs(e.venue_lat - curlat) < 0.2 and abs(e.venue_lng - curlng) < 0.25
            and not exists (select 1 from public.event_participants ep where ep.event_id = e.id and ep.user_id = b.bot_id)
          order by random() limit 1;
        if ev.id is not null then perform public.join_event(ev.id, b.bot_id); joined := joined + 1; end if;
      end if;

      -- ⑥ ✅ ACCEPTER les demandes à MES events (organisateur curated) — les demandes ne pourrissent plus
      if (tr->>'organise')::boolean then
        for req in select ep.event_id, ep.user_id from public.event_participants ep
                   join public.events e on e.id = ep.event_id
                   where e.created_by = b.bot_id and ep.state = 'requested' limit 3 loop
          begin update public.event_participants set state = 'accepted' where event_id = req.event_id and user_id = req.user_id;
                accepted := accepted + 1; exception when others then null; end;
        end loop;
      end if;

      -- ②ter 😤 LE VEXÉ : son clutch a été refusé → il RETENTE (le cooldown serveur doit l'arrêter — c'est le test)
      if arch = 'vexe' and random() < 0.5 then
        select c.receiver_id into vx from public.clutches c
          where c.sender_id = b.bot_id and c.status in ('refused','declined','expired')
            and c.created_at > now() - interval '6 hours'
          order by c.created_at desc limit 1;
        if vx.receiver_id is not null then
          perform public.admin_create_clutch(b.bot_id, vx.receiver_id, 'Allez, un café quand même ?', now() + interval '90 minutes',
            'Je suis sûr qu''on s''entendrait bien', 60, b.home_lat, b.home_lng);
          revenge := revenge + 1;   -- la plupart seront refusés par COOLDOWN_ACTIVE : exactement ce qu'on vérifie
        end if;
      end if;

      -- ③ ORGANISER un event (organisatrices + pilières)
      if (tr->>'organise')::boolean and random() < 0.10 and h between 8 and 22 then
        pool := case when h < 11 then '[["☕","Café-croissants"],["🥾","Balade matinale"]]'::jsonb
                     when h < 14 then '[["🥗","Lunch ensemble"],["♟️","Échecs au parc"]]'::jsonb
                     when h < 17 then '[["🎨","Atelier croquis"],["🚴","Sortie vélo"]]'::jsonb
                     else '[["🍹","Apéro spontané"],["🎲","Soirée jeux"],["🏐","Beach-volley"]]'::jsonb end;
        pick := pool->floor(random()*jsonb_array_length(pool))::int;
        perform public.admin_create_event(b.bot_id,
          (pick->>0)||' '||(pick->>1)||' — '||coalesce(b.town,'Lausanne'),
          now() + (interval '1 hour' * (1 + random()*3)),
          b.home_lat + (random()-0.5)*0.008, b.home_lng + (random()-0.5)*0.012,
          4 + floor(random()*8)::int);
        events := events + 1;
      end if;
    exception when others then null;
    end;
  end loop;
  return jsonb_build_object('ok',true,'acted',acted,'published',published,'answered',answered,
    'clutched',clutched,'botclutch',botclutch,'joined',joined,'accepted',accepted,'revenge',revenge,'retired',retired,'events',events,'online',online,'target',target);
end; $$;

-- ═══════ 20260713e_sim_modes_fiabilite.sql ═══════
-- 🎭⭐ SIM v4 — MODES / GENRE / MOOD + FIABILITÉ VARIÉE (audit complet 13.07 : les 3 trous VISIBLES)
-- ① les présences bots n'avaient AUCUN mode/genre → filtres cassés, fiches vides → sim_set_intent les pose
--   à chaque publication (stable par bot). ② fiabilité toutes pareilles → variée selon l'archétype.
-- ③ rattrapage immédiat sur les bots déjà en ligne. À COLLER après 20260713d.

-- ── Helper : pose modes + genre recherché + mood d'un bot (stable par hash de l'id) ──
create or replace function public.sim_set_intent(p_bot uuid) returns void
language plpgsql security definer set search_path = public as $$
declare hh int; g text; v_modes text[]; lf text; md text;
begin
  hh := ('x'||substr(md5(p_bot::text),1,7))::bit(28)::int;
  select gender into g from public.profiles where id = p_bot;
  -- modes : romance/amical dominants, parfois pro/activité/parent (multi possible)
  v_modes := case (hh % 10)
    when 0 then array['romance'] when 1 then array['romance'] when 2 then array['romance','amical']
    when 3 then array['amical'] when 4 then array['amical'] when 5 then array['amical','activite']
    when 6 then array['activite'] when 7 then array['pro'] when 8 then array['parent'] else array['romance','amical'] end;
  -- genre recherché : majorité hétéro, un peu de ALL, rare même genre
  lf := case when (hh/10) % 10 < 6 then (case when g in ('woman','F','f') then 'M' else 'F' end)
             when (hh/10) % 10 < 9 then 'ALL' else (case when g in ('woman','F','f') then 'F' else 'M' end) end;
  md := (array['cafe','balade','apero','diner','sport','culture'])[1 + (hh/100) % 6];
  update public.profiles set available_modes = v_modes, looking_for = lf where id = p_bot;
  -- le mood/modes DU CRÉNEAU (la vérité active) sur la dispo la plus récente du bot
  update public.availabilities set modes = v_modes, mood = md
    where user_id = p_bot and active = true and end_at > now();
end; $$;
grant execute on function public.sim_set_intent(uuid) to authenticated;

create or replace function public.sim_tick() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  ctl record; b record; tr jsonb; arch text; h int; dow int; awake numeric; target int; online int;
  acted int := 0; published int := 0; answered int := 0; events int := 0; clutched int := 0; retired int := 0; revenge int := 0; joined int := 0; botclutch int := 0; accepted int := 0;
  ev record; other record; req record; curlat float8; curlng float8; mob numeric;
  cl record; hum record; vx record; lat8 float8; lng8 float8; sm timestamptz; su timestamptz; radp int;
  pool jsonb; pick jsonb; pubp numeric;
begin
  if not public.qa_is_admin() then return jsonb_build_object('ok',false,'code','RLS_FORBIDDEN'); end if;
  select * into ctl from public.sim_control where id = 1;
  if ctl is null or not ctl.running then return jsonb_build_object('ok',true,'skipped','off'); end if;
  h := extract(hour from now() at time zone 'Europe/Zurich')::int;
  dow := extract(isodow from now() at time zone 'Europe/Zurich')::int;
  target := round((case ctl.scene when 'A' then 25 when 'B' then 180 else 700 end) * ctl.density
            * (case when h between 17 and 22 then 1.0 when h between 12 and 16 then 0.6
                    when h between 7 and 11 then 0.4 else 0.25 end)
            * (case when dow in (4,5,6) then 1.5 else 1.0 end));
  select count(*) into online from public.profiles p join public.sim_bots s on s.bot_id=p.id
    where p.is_available = true and p.available_until > now();

  for b in select * from public.sim_bots where next_action_at <= now()
           and state not in ('churne') order by next_action_at limit 90 loop
    begin
      acted := acted + 1; tr := b.traits; arch := coalesce(tr->>'arch','occasionnelle');
      awake := case when (tr->>'chrono')='pendulaire' and (h between 7 and 9 or h between 17 and 19) then 1
                    when (tr->>'chrono')='pendulaire' then 0.15
                    when (tr->>'chrono')='matin' and h between 7 and 11 then 1
                    when (tr->>'chrono')='soir'  and (h >= 18 or h < 2) then 1
                    when (tr->>'chrono')='std'   and h between 11 and 22 then 1 else 0.3 end;
      update public.sim_bots set next_action_at = now() + ((8 + random()*35) / greatest(awake,0.1)) * interval '1 minute'
        where bot_id = b.bot_id;
      -- 🚶 MOBILITÉ (David 13.07 « les gens bougent, eux aussi doivent bouger ») : point COURANT = domicile
      --   + un déplacement selon un indice de mobilité STABLE par bot (hash de l'id). Casaniers restent chez
      --   eux (±0.4 km) ; nomades/expats/comètes sortent en ville (jusqu'à ~6 km, un bar, un ami, un quartier).
      mob := case coalesce(tr->>'arch','x') when 'expat' then 0.9 when 'comete_arroseur' then 0.8
                  when 'comete_engage' then 0.7 when 'organisatrice' then 0.6 when 'power' then 0.55
                  when 'pendulaire' then 0.5 when 'dormeur' then 0.15 when 'timide' then 0.2
                  when 'piliere' then 0.35 else 0.4 end;
      if (tr->>'chrono') = 'pendulaire' and h between 9 and 17 then
        curlat := (tr->>'work_lat')::float8 + (random()-0.5)*0.008; curlng := (tr->>'work_lng')::float8 + (random()-0.5)*0.012;
      elsif random() < mob then
        -- sorti : déplacement gaussien, d'autant plus large que le bot est mobile (max ~6 km)
        curlat := b.home_lat + (random()+random()-1) * mob * 0.045;
        curlng := b.home_lng + (random()+random()-1) * mob * 0.06;
      else
        curlat := b.home_lat + (random()-0.5)*0.006; curlng := b.home_lng + (random()-0.5)*0.008;  -- casanier, autour de chez lui
      end if;
      if b.state in ('pause','occupe') and random() < 0.85 then continue; end if;

      -- ① PUBLIER — cadence, rayon et fenêtre PAR PERSONNAGE
      pubp := case arch when 'piliere' then 0.7 when 'comete_engage' then 0.8 when 'comete_arroseur' then 0.75
                        when 'power' then 0.6 when 'organisatrice' then 0.5 when 'timide' then 0.35
                        when 'occasionnelle' then (case when dow in (5,6,7) then 0.5 else 0.15 end)
                        when 'dormeur' then 0.08 when 'perdu' then 0.4 when 'pendulaire' then 0.6
                        when 'expat' then 0.55 when 'vexe' then 0.45 else 0.4 end;
      if online < target and random() < pubp * awake
         and not exists (select 1 from public.profiles where id=b.bot_id and is_available and available_until>now()) then
        sm := date_trunc('hour', now()) + (floor(random()*4)*interval '15 minutes');
        if sm < now() then sm := now(); end if;
        su := sm + (interval '1 hour' * (case arch when 'pendulaire' then 1 + random()
                                                    when 'expat' then 1 + random()*2
                                                    when 'perdu' then 0.5 + random()*8   -- n'importe quoi
                                                    else 1.5 + random()*3.5 end));
        if su > now() + interval '17 hours' then su := now() + interval '17 hours'; end if;
        su := to_timestamp(round(extract(epoch from su)/900)*900);  -- 🕐 fin au quart d'heure (David)
        -- le pendulaire publie sur son lieu du MOMENT (boulot en journée, maison le soir)
        lat8 := curlat; lng8 := curlng;   -- 🚶 publie là où il EST maintenant (mobilité)
        radp := case arch when 'expat' then (array[15,20,25])[1+floor(random()*3)::int]
                          when 'perdu' then (array[1,2,40])[1+floor(random()*3)::int]
                          when 'pendulaire' then (array[3,5,8])[1+floor(random()*3)::int]
                          else (array[3,5,8,10,15])[1+floor(random()*5)::int] end;
        perform public.admin_set_availability(b.bot_id, sm, su, lat8, lng8, radp);
        -- 🎭 MODES + GENRE RECHERCHÉ + MOOD (David 13.07 : les présences n'avaient AUCUN mode → filtres cassés).
        --   Stables par bot (hash de l'id) → un même bot cherche toujours la même chose. Dérivés de son profil.
        perform public.sim_set_intent(b.bot_id);
        online := online + 1; published := published + 1;
      end if;

      -- ①bis 🫣 LA TIMIDE : quelqu'un l'a clutchée → panique, retire son créneau (le clutch expirera)
      if arch = 'timide' and random() < 0.4
         and exists (select 1 from public.clutches c where c.receiver_id=b.bot_id and c.status='pending') then
        update public.profiles set is_available = false where id = b.bot_id and is_available = true;
        retired := retired + 1;
      end if;

      -- ② RÉPONDRE (latence + caractère ; l'indécise répond à la toute dernière minute via sa latence géante)
      -- 🤫 David 13.07 : certains n'ONT PAS RÉPONDU (ils oublient / ignorent) → silence, le clutch expirera.
      --   dormeur/timide/perdu/occasionnelle oublient souvent ; les fiables répondent presque toujours.
      if not (random() < (case arch when 'dormeur' then 0.35 when 'timide' then 0.45 when 'perdu' then 0.4
                                    when 'occasionnelle' then 0.3 when 'indecise' then 0.25 else 0.06 end)) then
      for cl in select c.id, c.sender_id from public.clutches c
                where c.receiver_id = b.bot_id and c.status = 'pending'
                  and c.created_at < now() - ((tr->>'latence_min')::int * interval '1 minute') limit 2 loop
        if random() < coalesce((tr->>'accept_p')::numeric, 0.4) then
          perform public.admin_accept_clutch(b.bot_id, cl.sender_id);   -- le noshow ACCEPTE (et ne viendra pas)
        else
          perform public.admin_refuse_clutch(b.bot_id, cl.sender_id);
        end if;
        answered := answered + 1;
      end loop;
      end if;   -- fin du filtre « ignorer » (silence = expiration)

      -- ②bis 🎯 CLUTCHER UN HUMAIN (dose crédible — throttle global 25 min/humain, jamais 2× le même en 24 h)
      if b.state in ('actif','hyper_engage','hyper_arroseur')
         and random() < (case arch when 'comete_arroseur' then 0.08 when 'comete_engage' then 0.05
                                    when 'piliere' then 0.04 when 'timide' then 0.005 else 0.02 end) then
        select p.id into hum from public.profiles p
          where coalesce(p.is_bot,false) = false and p.is_available = true and p.available_until > now()
            and p.center_lat is not null
            and abs(p.center_lat - curlat) < 0.15 and abs(p.center_lng - curlng) < 0.2
            and not exists (select 1 from public.clutches c2 where c2.receiver_id = p.id and c2.created_at > now() - interval '25 minutes')
            and not exists (select 1 from public.clutches c3 where c3.sender_id = b.bot_id and c3.receiver_id = p.id and c3.created_at > now() - interval '24 hours')
          order by random() limit 1;
        if hum.id is not null then
          perform public.admin_create_clutch(b.bot_id, hum.id,
            (array['Un café ?','Une balade au bord du lac ?','Un verre en terrasse ?','Un ping-pong ?','Une glace ?'])[1+floor(random()*5)::int],
            now() + (interval '1 hour' * (0.75 + random()*2)),
            (array['On tente ? 🙂','Dispo si tu l''es','Ça te dit ?','Simple et sans pression'])[1+floor(random()*4)::int],
            60, b.home_lat, b.home_lng);
          clutched := clutched + 1;
        end if;
      end if;

      -- ②quater 🤝 CLUTCHER UN AUTRE BOT (la ville s'anime d'elle-même — David 13.07 « il ne se passe rien »)
      if b.state in ('actif','hyper_engage','hyper_arroseur','occasionnelle')
         and random() < (case arch when 'comete_arroseur' then 0.16 when 'comete_engage' then 0.12
                                    when 'piliere' then 0.10 when 'timide' then 0.02 else 0.06 end) * awake then
        select p.id into other from public.profiles p join public.sim_bots s2 on s2.bot_id = p.id
          where p.is_bot = true and p.id <> b.bot_id and p.is_available = true and p.available_until > now()
            and abs(p.center_lat - curlat) < 0.12 and abs(p.center_lng - curlng) < 0.16
            and not exists (select 1 from public.clutches c2 where c2.receiver_id = p.id and c2.sender_id = b.bot_id and c2.created_at > now() - interval '24 hours')
            and not exists (select 1 from public.clutches c3 where c3.sender_id = b.bot_id and c3.status = 'pending')  -- 1 clutch en vol à la fois
          order by random() limit 1;
        if other.id is not null then
          perform public.admin_create_clutch(b.bot_id, other.id,
            (array['Un café ?','Une balade ?','Un verre ?','Un ping-pong ?','On se voit ?'])[1+floor(random()*5)::int],
            now() + (interval '1 hour' * (0.75 + random()*2)), 'Dispo maintenant 🙂', 60, b.home_lat, b.home_lng);
          botclutch := botclutch + 1;
        end if;
      end if;

      -- ⑤ 🎟️ REJOINDRE un EVENT proche pas plein (les events se remplissent → crédibles)
      if b.state in ('actif','hyper_engage','occasionnelle','dormeur') and random() < 0.10 * awake then
        select e.id into ev from public.events e
          where e.active = true and e.status in ('pending','open') and e.starts_at > now()
            and coalesce(e.taken,0) < e.spots and e.created_by <> b.bot_id
            and e.venue_lat is not null and abs(e.venue_lat - curlat) < 0.2 and abs(e.venue_lng - curlng) < 0.25
            and not exists (select 1 from public.event_participants ep where ep.event_id = e.id and ep.user_id = b.bot_id)
          order by random() limit 1;
        if ev.id is not null then perform public.join_event(ev.id, b.bot_id); joined := joined + 1; end if;
      end if;

      -- ⑥ ✅ ACCEPTER les demandes à MES events (organisateur curated) — les demandes ne pourrissent plus
      if (tr->>'organise')::boolean then
        for req in select ep.event_id, ep.user_id from public.event_participants ep
                   join public.events e on e.id = ep.event_id
                   where e.created_by = b.bot_id and ep.state = 'requested' limit 3 loop
          begin update public.event_participants set state = 'accepted' where event_id = req.event_id and user_id = req.user_id;
                accepted := accepted + 1; exception when others then null; end;
        end loop;
      end if;

      -- ②ter 😤 LE VEXÉ : son clutch a été refusé → il RETENTE (le cooldown serveur doit l'arrêter — c'est le test)
      if arch = 'vexe' and random() < 0.5 then
        select c.receiver_id into vx from public.clutches c
          where c.sender_id = b.bot_id and c.status in ('refused','declined','expired')
            and c.created_at > now() - interval '6 hours'
          order by c.created_at desc limit 1;
        if vx.receiver_id is not null then
          perform public.admin_create_clutch(b.bot_id, vx.receiver_id, 'Allez, un café quand même ?', now() + interval '90 minutes',
            'Je suis sûr qu''on s''entendrait bien', 60, b.home_lat, b.home_lng);
          revenge := revenge + 1;   -- la plupart seront refusés par COOLDOWN_ACTIVE : exactement ce qu'on vérifie
        end if;
      end if;

      -- ③ ORGANISER un event (organisatrices + pilières)
      if (tr->>'organise')::boolean and random() < 0.10 and h between 8 and 22 then
        pool := case when h < 11 then '[["☕","Café-croissants"],["🥾","Balade matinale"]]'::jsonb
                     when h < 14 then '[["🥗","Lunch ensemble"],["♟️","Échecs au parc"]]'::jsonb
                     when h < 17 then '[["🎨","Atelier croquis"],["🚴","Sortie vélo"]]'::jsonb
                     else '[["🍹","Apéro spontané"],["🎲","Soirée jeux"],["🏐","Beach-volley"]]'::jsonb end;
        pick := pool->floor(random()*jsonb_array_length(pool))::int;
        perform public.admin_create_event(b.bot_id,
          (pick->>0)||' '||(pick->>1)||' — '||coalesce(b.town,'Lausanne'),
          now() + (interval '1 hour' * (1 + random()*3)),
          b.home_lat + (random()-0.5)*0.008, b.home_lng + (random()-0.5)*0.012,
          4 + floor(random()*8)::int);
        events := events + 1;
      end if;
    exception when others then null;
    end;
  end loop;
  return jsonb_build_object('ok',true,'acted',acted,'published',published,'answered',answered,
    'clutched',clutched,'botclutch',botclutch,'joined',joined,'accepted',accepted,'revenge',revenge,'retired',retired,'events',events,'online',online,'target',target);
end; $$;

-- ── ① FIABILITÉ VARIÉE (David : « toutes les étoiles pareilles ») — selon l'archétype du bot ──
update public.profiles p set reliability_score = sub.rel
from (
  select s.bot_id, (case coalesce(s.traits->>'fiab','ponctuel')
    when 'roc' then 90 + floor(random()*10) when 'ponctuel' then 74 + floor(random()*18)
    when 'retard' then 58 + floor(random()*16) when 'annuleur' then 44 + floor(random()*15)
    when 'noshow' then 30 + floor(random()*18) else 65 + floor(random()*20) end)::int rel
  from public.sim_bots s
) sub where p.id = sub.bot_id;
-- bots sans entrée sim_bots encore : score varié par défaut
update public.profiles set reliability_score = 55 + floor(random()*40)::int
  where is_bot = true and reliability_score is null;

-- ── ② MODES + GENRE pour les bots DÉJÀ en ligne (effet visible tout de suite) ──
do $$ declare r record; begin
  for r in select id from public.profiles where is_bot = true and is_available = true and available_until > now() loop
    perform public.sim_set_intent(r.id);
  end loop;
end $$;

select 'fiabilité + modes rattrapés' as info;

-- ═══════ 20260713f_sim_phase2_verrou.sql ═══════
-- 🤝⭐ SIM v5 — PHASE 2 : LA VIE DU VERROU (David : « balance la phase 2, on fait ce que Dom aurait fait »)
-- ① LES RDV SE CLÔTURENT : à l'heure passée, chaque bot HONORE ou pose un LAPIN selon sa fiabilité →
--   son score de fiabilité ÉVOLUE tout seul (no-show chute vers ★★, roc monte vers ★★★★★). Le cœur du produit
--   (« le tueur invisible ») vit sans humain. ② liste d'attente DYNAMIQUE : les orgas valident les demandes
--   après un délai humain (5-45 min), plus dans la seconde. À COLLER après 20260713e.

create or replace function public.sim_tick() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  ctl record; b record; tr jsonb; arch text; h int; dow int; awake numeric; target int; online int;
  acted int := 0; published int := 0; answered int := 0; events int := 0; clutched int := 0; retired int := 0; revenge int := 0; joined int := 0; botclutch int := 0; accepted int := 0;
  ev record; other record; req record; curlat float8; curlng float8; mob numeric; rd record; closed int := 0;
  cl record; hum record; vx record; lat8 float8; lng8 float8; sm timestamptz; su timestamptz; radp int;
  pool jsonb; pick jsonb; pubp numeric;
begin
  if not public.qa_is_admin() then return jsonb_build_object('ok',false,'code','RLS_FORBIDDEN'); end if;
  select * into ctl from public.sim_control where id = 1;
  if ctl is null or not ctl.running then return jsonb_build_object('ok',true,'skipped','off'); end if;
  h := extract(hour from now() at time zone 'Europe/Zurich')::int;
  dow := extract(isodow from now() at time zone 'Europe/Zurich')::int;
  target := round((case ctl.scene when 'A' then 25 when 'B' then 180 else 700 end) * ctl.density
            * (case when h between 17 and 22 then 1.0 when h between 12 and 16 then 0.6
                    when h between 7 and 11 then 0.4 else 0.25 end)
            * (case when dow in (4,5,6) then 1.5 else 1.0 end));
  select count(*) into online from public.profiles p join public.sim_bots s on s.bot_id=p.id
    where p.is_available = true and p.available_until > now();

  -- 🤝🎯 PHASE 2 — LA VIE DU VERROU : les RDV passés se CLÔTURENT. Chaque bot participant a HONORÉ ou posé
  --   un LAPIN selon sa fiabilité → son score de fiabilité BOUGE tout seul (le no-show chute, le roc monte).
  --   C'est ce qui fait vivre « le tueur invisible » (la fiabilité comportementale) sans intervention humaine.
  for rd in select c.id, c.sender_id, c.receiver_id,
                   coalesce(c.counter_time, c.proposed_time) as t, coalesce(c.duration_minutes,60) as dm
            from public.clutches c
            where c.status in ('accepted','confirmed','checked_in')
              and coalesce(c.counter_time, c.proposed_time) is not null
              and coalesce(c.counter_time, c.proposed_time) + (coalesce(c.duration_minutes,60) * interval '1 minute') < now()
              and (exists(select 1 from public.sim_bots s where s.bot_id = c.sender_id)
                or  exists(select 1 from public.sim_bots s where s.bot_id = c.receiver_id))
            limit 120 loop
    begin
      -- chaque PARTICIPANT BOT : honore (selon sa fiab) ou pose un lapin → son propre score bouge
      update public.profiles p set reliability_score = greatest(0, least(100,
          coalesce(p.reliability_score,80) + (case when random() < (case coalesce(s.traits->>'fiab','ponctuel')
              when 'roc' then 0.98 when 'ponctuel' then 0.9 when 'retard' then 0.82 when 'annuleur' then 0.6 when 'noshow' then 0.15 else 0.85 end)
            then 1 else -5 end)))
        from public.sim_bots s
        where p.id = s.bot_id and p.id in (rd.sender_id, rd.receiver_id);
      update public.clutches set status = 'completed' where id = rd.id;
      closed := closed + 1;
    exception when others then null; end;
  end loop;


  for b in select * from public.sim_bots where next_action_at <= now()
           and state not in ('churne') order by next_action_at limit 90 loop
    begin
      acted := acted + 1; tr := b.traits; arch := coalesce(tr->>'arch','occasionnelle');
      awake := case when (tr->>'chrono')='pendulaire' and (h between 7 and 9 or h between 17 and 19) then 1
                    when (tr->>'chrono')='pendulaire' then 0.15
                    when (tr->>'chrono')='matin' and h between 7 and 11 then 1
                    when (tr->>'chrono')='soir'  and (h >= 18 or h < 2) then 1
                    when (tr->>'chrono')='std'   and h between 11 and 22 then 1 else 0.3 end;
      update public.sim_bots set next_action_at = now() + ((8 + random()*35) / greatest(awake,0.1)) * interval '1 minute'
        where bot_id = b.bot_id;
      -- 🚶 MOBILITÉ (David 13.07 « les gens bougent, eux aussi doivent bouger ») : point COURANT = domicile
      --   + un déplacement selon un indice de mobilité STABLE par bot (hash de l'id). Casaniers restent chez
      --   eux (±0.4 km) ; nomades/expats/comètes sortent en ville (jusqu'à ~6 km, un bar, un ami, un quartier).
      mob := case coalesce(tr->>'arch','x') when 'expat' then 0.9 when 'comete_arroseur' then 0.8
                  when 'comete_engage' then 0.7 when 'organisatrice' then 0.6 when 'power' then 0.55
                  when 'pendulaire' then 0.5 when 'dormeur' then 0.15 when 'timide' then 0.2
                  when 'piliere' then 0.35 else 0.4 end;
      if (tr->>'chrono') = 'pendulaire' and h between 9 and 17 then
        curlat := (tr->>'work_lat')::float8 + (random()-0.5)*0.008; curlng := (tr->>'work_lng')::float8 + (random()-0.5)*0.012;
      elsif random() < mob then
        -- sorti : déplacement gaussien, d'autant plus large que le bot est mobile (max ~6 km)
        curlat := b.home_lat + (random()+random()-1) * mob * 0.045;
        curlng := b.home_lng + (random()+random()-1) * mob * 0.06;
      else
        curlat := b.home_lat + (random()-0.5)*0.006; curlng := b.home_lng + (random()-0.5)*0.008;  -- casanier, autour de chez lui
      end if;
      if b.state in ('pause','occupe') and random() < 0.85 then continue; end if;

      -- ① PUBLIER — cadence, rayon et fenêtre PAR PERSONNAGE
      pubp := case arch when 'piliere' then 0.7 when 'comete_engage' then 0.8 when 'comete_arroseur' then 0.75
                        when 'power' then 0.6 when 'organisatrice' then 0.5 when 'timide' then 0.35
                        when 'occasionnelle' then (case when dow in (5,6,7) then 0.5 else 0.15 end)
                        when 'dormeur' then 0.08 when 'perdu' then 0.4 when 'pendulaire' then 0.6
                        when 'expat' then 0.55 when 'vexe' then 0.45 else 0.4 end;
      if online < target and random() < pubp * awake
         and not exists (select 1 from public.profiles where id=b.bot_id and is_available and available_until>now()) then
        sm := date_trunc('hour', now()) + (floor(random()*4)*interval '15 minutes');
        if sm < now() then sm := now(); end if;
        su := sm + (interval '1 hour' * (case arch when 'pendulaire' then 1 + random()
                                                    when 'expat' then 1 + random()*2
                                                    when 'perdu' then 0.5 + random()*8   -- n'importe quoi
                                                    else 1.5 + random()*3.5 end));
        if su > now() + interval '17 hours' then su := now() + interval '17 hours'; end if;
        su := to_timestamp(round(extract(epoch from su)/900)*900);  -- 🕐 fin au quart d'heure (David)
        -- le pendulaire publie sur son lieu du MOMENT (boulot en journée, maison le soir)
        lat8 := curlat; lng8 := curlng;   -- 🚶 publie là où il EST maintenant (mobilité)
        radp := case arch when 'expat' then (array[15,20,25])[1+floor(random()*3)::int]
                          when 'perdu' then (array[1,2,40])[1+floor(random()*3)::int]
                          when 'pendulaire' then (array[3,5,8])[1+floor(random()*3)::int]
                          else (array[3,5,8,10,15])[1+floor(random()*5)::int] end;
        perform public.admin_set_availability(b.bot_id, sm, su, lat8, lng8, radp);
        -- 🎭 MODES + GENRE RECHERCHÉ + MOOD (David 13.07 : les présences n'avaient AUCUN mode → filtres cassés).
        --   Stables par bot (hash de l'id) → un même bot cherche toujours la même chose. Dérivés de son profil.
        perform public.sim_set_intent(b.bot_id);
        online := online + 1; published := published + 1;
      end if;

      -- ①bis 🫣 LA TIMIDE : quelqu'un l'a clutchée → panique, retire son créneau (le clutch expirera)
      if arch = 'timide' and random() < 0.4
         and exists (select 1 from public.clutches c where c.receiver_id=b.bot_id and c.status='pending') then
        update public.profiles set is_available = false where id = b.bot_id and is_available = true;
        retired := retired + 1;
      end if;

      -- ② RÉPONDRE (latence + caractère ; l'indécise répond à la toute dernière minute via sa latence géante)
      -- 🤫 David 13.07 : certains n'ONT PAS RÉPONDU (ils oublient / ignorent) → silence, le clutch expirera.
      --   dormeur/timide/perdu/occasionnelle oublient souvent ; les fiables répondent presque toujours.
      if not (random() < (case arch when 'dormeur' then 0.35 when 'timide' then 0.45 when 'perdu' then 0.4
                                    when 'occasionnelle' then 0.3 when 'indecise' then 0.25 else 0.06 end)) then
      for cl in select c.id, c.sender_id from public.clutches c
                where c.receiver_id = b.bot_id and c.status = 'pending'
                  and c.created_at < now() - ((tr->>'latence_min')::int * interval '1 minute') limit 2 loop
        if random() < coalesce((tr->>'accept_p')::numeric, 0.4) then
          perform public.admin_accept_clutch(b.bot_id, cl.sender_id);   -- le noshow ACCEPTE (et ne viendra pas)
        else
          perform public.admin_refuse_clutch(b.bot_id, cl.sender_id);
        end if;
        answered := answered + 1;
      end loop;
      end if;   -- fin du filtre « ignorer » (silence = expiration)

      -- ②bis 🎯 CLUTCHER UN HUMAIN (dose crédible — throttle global 25 min/humain, jamais 2× le même en 24 h)
      if b.state in ('actif','hyper_engage','hyper_arroseur')
         and random() < (case arch when 'comete_arroseur' then 0.08 when 'comete_engage' then 0.05
                                    when 'piliere' then 0.04 when 'timide' then 0.005 else 0.02 end) then
        select p.id into hum from public.profiles p
          where coalesce(p.is_bot,false) = false and p.is_available = true and p.available_until > now()
            and p.center_lat is not null
            and abs(p.center_lat - curlat) < 0.15 and abs(p.center_lng - curlng) < 0.2
            and not exists (select 1 from public.clutches c2 where c2.receiver_id = p.id and c2.created_at > now() - interval '25 minutes')
            and not exists (select 1 from public.clutches c3 where c3.sender_id = b.bot_id and c3.receiver_id = p.id and c3.created_at > now() - interval '24 hours')
          order by random() limit 1;
        if hum.id is not null then
          perform public.admin_create_clutch(b.bot_id, hum.id,
            (array['Un café ?','Une balade au bord du lac ?','Un verre en terrasse ?','Un ping-pong ?','Une glace ?'])[1+floor(random()*5)::int],
            now() + (interval '1 hour' * (0.75 + random()*2)),
            (array['On tente ? 🙂','Dispo si tu l''es','Ça te dit ?','Simple et sans pression'])[1+floor(random()*4)::int],
            60, b.home_lat, b.home_lng);
          clutched := clutched + 1;
        end if;
      end if;

      -- ②quater 🤝 CLUTCHER UN AUTRE BOT (la ville s'anime d'elle-même — David 13.07 « il ne se passe rien »)
      if b.state in ('actif','hyper_engage','hyper_arroseur','occasionnelle')
         and random() < (case arch when 'comete_arroseur' then 0.16 when 'comete_engage' then 0.12
                                    when 'piliere' then 0.10 when 'timide' then 0.02 else 0.06 end) * awake then
        select p.id into other from public.profiles p join public.sim_bots s2 on s2.bot_id = p.id
          where p.is_bot = true and p.id <> b.bot_id and p.is_available = true and p.available_until > now()
            and abs(p.center_lat - curlat) < 0.12 and abs(p.center_lng - curlng) < 0.16
            and not exists (select 1 from public.clutches c2 where c2.receiver_id = p.id and c2.sender_id = b.bot_id and c2.created_at > now() - interval '24 hours')
            and not exists (select 1 from public.clutches c3 where c3.sender_id = b.bot_id and c3.status = 'pending')  -- 1 clutch en vol à la fois
          order by random() limit 1;
        if other.id is not null then
          perform public.admin_create_clutch(b.bot_id, other.id,
            (array['Un café ?','Une balade ?','Un verre ?','Un ping-pong ?','On se voit ?'])[1+floor(random()*5)::int],
            now() + (interval '1 hour' * (0.75 + random()*2)), 'Dispo maintenant 🙂', 60, b.home_lat, b.home_lng);
          botclutch := botclutch + 1;
        end if;
      end if;

      -- ⑤ 🎟️ REJOINDRE un EVENT proche pas plein (les events se remplissent → crédibles)
      if b.state in ('actif','hyper_engage','occasionnelle','dormeur') and random() < 0.10 * awake then
        select e.id into ev from public.events e
          where e.active = true and e.status in ('pending','open') and e.starts_at > now()
            and coalesce(e.taken,0) < e.spots and e.created_by <> b.bot_id
            and e.venue_lat is not null and abs(e.venue_lat - curlat) < 0.2 and abs(e.venue_lng - curlng) < 0.25
            and not exists (select 1 from public.event_participants ep where ep.event_id = e.id and ep.user_id = b.bot_id)
          order by random() limit 1;
        if ev.id is not null then perform public.join_event(ev.id, b.bot_id); joined := joined + 1; end if;
      end if;

      -- ⑥ ✅ ACCEPTER les demandes à MES events (organisateur curated) — les demandes ne pourrissent plus
      if (tr->>'organise')::boolean then
        for req in select ep.event_id, ep.user_id from public.event_participants ep
                   join public.events e on e.id = ep.event_id
                   where e.created_by = b.bot_id and ep.state = 'requested'
                     and ep.created_at < now() - (5 + floor(random()*40)) * interval '1 minute'  -- ⏳ délai humain (5-45 min)
                   limit 3 loop
          begin update public.event_participants set state = 'accepted' where event_id = req.event_id and user_id = req.user_id;
                accepted := accepted + 1; exception when others then null; end;
        end loop;
      end if;

      -- ②ter 😤 LE VEXÉ : son clutch a été refusé → il RETENTE (le cooldown serveur doit l'arrêter — c'est le test)
      if arch = 'vexe' and random() < 0.5 then
        select c.receiver_id into vx from public.clutches c
          where c.sender_id = b.bot_id and c.status in ('refused','declined','expired')
            and c.created_at > now() - interval '6 hours'
          order by c.created_at desc limit 1;
        if vx.receiver_id is not null then
          perform public.admin_create_clutch(b.bot_id, vx.receiver_id, 'Allez, un café quand même ?', now() + interval '90 minutes',
            'Je suis sûr qu''on s''entendrait bien', 60, b.home_lat, b.home_lng);
          revenge := revenge + 1;   -- la plupart seront refusés par COOLDOWN_ACTIVE : exactement ce qu'on vérifie
        end if;
      end if;

      -- ③ ORGANISER un event (organisatrices + pilières)
      if (tr->>'organise')::boolean and random() < 0.10 and h between 8 and 22 then
        pool := case when h < 11 then '[["☕","Café-croissants"],["🥾","Balade matinale"]]'::jsonb
                     when h < 14 then '[["🥗","Lunch ensemble"],["♟️","Échecs au parc"]]'::jsonb
                     when h < 17 then '[["🎨","Atelier croquis"],["🚴","Sortie vélo"]]'::jsonb
                     else '[["🍹","Apéro spontané"],["🎲","Soirée jeux"],["🏐","Beach-volley"]]'::jsonb end;
        pick := pool->floor(random()*jsonb_array_length(pool))::int;
        perform public.admin_create_event(b.bot_id,
          (pick->>0)||' '||(pick->>1)||' — '||coalesce(b.town,'Lausanne'),
          now() + (interval '1 hour' * (1 + random()*3)),
          b.home_lat + (random()-0.5)*0.008, b.home_lng + (random()-0.5)*0.012,
          4 + floor(random()*8)::int);
        events := events + 1;
      end if;
    exception when others then null;
    end;
  end loop;
  return jsonb_build_object('ok',true,'acted',acted,'published',published,'answered',answered,
    'clutched',clutched,'botclutch',botclutch,'joined',joined,'accepted',accepted,'rdv_clos',closed,'revenge',revenge,'retired',retired,'events',events,'online',online,'target',target);
end; $$;

-- ═══════ 20260713g_event_lieu_coherent.sql ═══════
-- 🕐 Cohérence titre/lieu des events (David 13.07 : « titre — Genève mais lieu Lausanne »).
-- admin_create_event mettait lieu='Lausanne' EN DUR. On dérive le lieu de la ville du titre
-- (« Activité — Ville » → Ville), fallback 'Lausanne' si le titre n'a pas de « — Ville ».
create or replace function public.admin_create_event(
  p_actor uuid, p_title text, p_starts_at timestamptz,
  p_lat double precision default 46.5197, p_lng double precision default 6.6323, p_spots int default 8
) returns jsonb language plpgsql security definer set search_path = public as $$
declare new_id uuid; nm text; ville text;
begin
  if not public.qa_is_admin() then return jsonb_build_object('ok',false,'code','RLS_FORBIDDEN','message','Admin uniquement'); end if;
  if p_starts_at is null or p_starts_at < now() - interval '5 min' then
    return jsonb_build_object('ok',false,'code','INVALID_TIME','message','Heure d''event dans le passé'); end if;
  select name into nm from public.profiles where id=p_actor;
  ville := nullif(trim(split_part(p_title, ' — ', 2)), '');   -- la ville EST dans le titre → le lieu la reflète
  insert into public.events (title, emoji, lieu, event_time, event_date, starts_at, duration_minutes, spots, taken,
                             description, tags, ev_gender, type, status, active, created_by, creator, venue_lat, venue_lng)
  values (p_title, '🎟️', coalesce(ville,'Lausanne'), to_char(p_starts_at,'HH24:MI'), to_char(p_starts_at,'TMDy DD/MM'),
          p_starts_at, 120, greatest(p_spots,2), 0, '(test lab)', array['test'], 'X', 'user', 'pending', true,
          p_actor, coalesce(nm,'Bot'), p_lat, p_lng)
  returning id into new_id;
  return jsonb_build_object('ok',true,'code','OK','event_id',new_id,'message','Event créé à '||to_char(p_starts_at,'HH24:MI'));
end; $$;

-- ═══════ 20260713h_sim_doctor.sql ═══════
-- 🩺 SIM DOCTOR + FIXES (13.07 ~03h30 — réponse à « notre système anti-bugs ne marche pas ») :
-- ① sim_doctor() = LA MACHINE SE VÉRIFIE ELLE-MÊME : un rapport lisible qui détecte les incohérences
--   (events dans l'eau, heures absurdes, ville qui n'a pas battu depuis X min, bots sans âme…) AVANT David.
-- ② sim_dry() : plus JAMAIS rien dans un lac (appliqué aux publications + events + rattrapage immédiat).
-- ③ sim_tick v6 : heures d'events crédibles (début entre 9h et 23h locale, sinon on ne crée pas).

-- ── sim_dry : sort un point de l'eau (rive nord) ──
create or replace function public.sim_dry(p_lat float8, p_lng float8)
returns float8[] language sql immutable as $$
  select case
    when p_lat > 46.20 and p_lat < 46.513 and p_lng > 6.15 and p_lng < 6.93 then array[46.516 + random()*0.006, p_lng]
    when p_lat > 46.78 and p_lat < 47.00 and p_lng > 6.63 and p_lng < 7.05 then array[47.003 + random()*0.006, p_lng]
    when p_lat > 46.90 and p_lat < 46.97 and p_lng > 7.05 and p_lng < 7.18 then array[46.973 + random()*0.004, p_lng]
    when p_lat > 47.05 and p_lat < 47.17 and p_lng > 7.10 and p_lng < 7.30 then array[47.173 + random()*0.004, p_lng]
    when p_lat > 46.60 and p_lat < 46.68 and p_lng > 6.25 and p_lng < 6.35 then array[46.683 + random()*0.004, p_lng]
    else array[p_lat, p_lng] end;
$$;

-- ── RATTRAPAGE IMMÉDIAT : tout ce qui est DANS un lac en sort (domiciles, présences, events futurs) ──
update public.sim_bots set home_lat = (public.sim_dry(home_lat, home_lng))[1]
  where (public.sim_dry(home_lat, home_lng))[1] <> home_lat;
update public.profiles p set center_lat = (public.sim_dry(center_lat, center_lng))[1]
  from public.sim_bots s where p.id = s.bot_id and p.center_lat is not null
  and (public.sim_dry(p.center_lat, p.center_lng))[1] <> p.center_lat;
update public.events set venue_lat = (public.sim_dry(venue_lat, venue_lng))[1]
  where active = true and venue_lat is not null
  and (public.sim_dry(venue_lat, venue_lng))[1] <> venue_lat;

-- ── 🩺 sim_doctor : le rapport d'auto-vérification (à lancer : select public.sim_doctor();) ──
create or replace function public.sim_doctor() returns text
language plpgsql security definer set search_path = public as $$
declare r text := ''; n1 int; n2 int; n3 int; n4 int; n5 int; ctl record; last_run timestamptz;
begin
  if not public.qa_is_admin() then return 'réservé admin'; end if;
  select * into ctl from public.sim_control where id = 1;
  r := '🩺 DOCTEUR — ' || to_char(now() at time zone 'Europe/Zurich','HH24:MI') || e'\n';
  r := r || '• consigne : ' || (case when ctl.running then '▶ EN MARCHE' else '⏸ arrêt' end) || ' · scène ' || ctl.scene || ' · densité ×' || ctl.density || e'\n';
  begin
    select max(end_time) into last_run from cron.job_run_details jrd join cron.job j on j.jobid = jrd.jobid where j.jobname = 'sim-tick' and jrd.status = 'succeeded';
    r := r || '• dernier battement réussi : ' || coalesce(to_char(last_run at time zone 'Europe/Zurich','HH24:MI:SS'),'JAMAIS ⚠️') || e'\n';
    select count(*) into n1 from cron.job_run_details jrd join cron.job j on j.jobid = jrd.jobid where j.jobname = 'sim-tick' and jrd.status = 'failed' and jrd.start_time > now() - interval '1 hour';
    if n1 > 0 then r := r || '  ⚠️ ' || n1 || ' battements EN ÉCHEC la dernière heure — le cœur tousse !' || e'\n'; end if;
  exception when others then r := r || '• (journal cron illisible)' || e'\n'; end;
  select count(*) into n1 from public.profiles where is_bot = true;
  select count(*) into n2 from public.sim_bots;
  select count(*) into n3 from public.profiles p join public.sim_bots s on s.bot_id = p.id where p.is_available and p.available_until > now();
  r := r || '• population : ' || n1 || ' bots · ' || n2 || ' âmes · ' || n3 || ' EN LIGNE maintenant' || e'\n';
  if n2 < n1/2 then r := r || '  ⚠️ moins de la moitié des bots ont une âme → 🌱 Semer !' || e'\n'; end if;
  if ctl.running and n3 = 0 then r := r || '  ⚠️ ville EN MARCHE mais 0 en ligne → cœur en panne ou nuit profonde' || e'\n'; end if;
  select count(*) into n4 from public.events where active and starts_at > now();
  select count(*) into n5 from public.events where active and starts_at > now()
    and extract(hour from starts_at at time zone 'Europe/Zurich') between 1 and 7;
  r := r || '• events à venir : ' || n4 || ' (dont ' || n5 || ' à heure ABSURDE 1-8h' || case when n5>0 then ' ⚠️' else ' ✓' end || ')' || e'\n';
  select count(*) into n1 from public.events where active and venue_lat is not null and (public.sim_dry(venue_lat, venue_lng))[1] <> venue_lat;
  r := r || '• events dans l''eau : ' || n1 || case when n1>0 then ' ⚠️ (relance cette migration)' else ' ✓' end || e'\n';
  select count(*) into n2 from public.clutches where created_at > now() - interval '1 hour';
  r := r || '• clutchs créés (1 h) : ' || n2 || e'\n';
  return r;
end; $$;
grant execute on function public.sim_doctor() to authenticated;

-- ── 🌙 Purge des events à heure absurde déjà créés (1h-8h locale) ──
update public.events set active = false
  where active and starts_at > now() and extract(hour from starts_at at time zone 'Europe/Zurich') between 1 and 7
  and created_by in (select bot_id from public.sim_bots);

-- ── sim_tick v6 : publications et events SÉCHÉS (sim_dry) + début d'event clampé 9h-23h locale ──
create or replace function public.sim_tick() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  ctl record; b record; tr jsonb; arch text; h int; dow int; awake numeric; target int; online int;
  acted int := 0; published int := 0; answered int := 0; events int := 0; clutched int := 0; retired int := 0; revenge int := 0; joined int := 0; botclutch int := 0; accepted int := 0;
  ev record; other record; req record; curlat float8; curlng float8; mob numeric; rd record; closed int := 0;
  cl record; hum record; vx record; lat8 float8; lng8 float8; sm timestamptz; su timestamptz; radp int;
  pool jsonb; pick jsonb; pubp numeric;
begin
  if not public.qa_is_admin() then return jsonb_build_object('ok',false,'code','RLS_FORBIDDEN'); end if;
  select * into ctl from public.sim_control where id = 1;
  if ctl is null or not ctl.running then return jsonb_build_object('ok',true,'skipped','off'); end if;
  h := extract(hour from now() at time zone 'Europe/Zurich')::int;
  dow := extract(isodow from now() at time zone 'Europe/Zurich')::int;
  target := round((case ctl.scene when 'A' then 25 when 'B' then 180 else 700 end) * ctl.density
            * (case when h between 17 and 22 then 1.0 when h between 12 and 16 then 0.6
                    when h between 7 and 11 then 0.4 else 0.25 end)
            * (case when dow in (4,5,6) then 1.5 else 1.0 end));
  select count(*) into online from public.profiles p join public.sim_bots s on s.bot_id=p.id
    where p.is_available = true and p.available_until > now();

  -- 🤝🎯 PHASE 2 — LA VIE DU VERROU : les RDV passés se CLÔTURENT. Chaque bot participant a HONORÉ ou posé
  --   un LAPIN selon sa fiabilité → son score de fiabilité BOUGE tout seul (le no-show chute, le roc monte).
  --   C'est ce qui fait vivre « le tueur invisible » (la fiabilité comportementale) sans intervention humaine.
  for rd in select c.id, c.sender_id, c.receiver_id,
                   coalesce(c.counter_time, c.proposed_time) as t, coalesce(c.duration_minutes,60) as dm
            from public.clutches c
            where c.status in ('accepted','confirmed','checked_in')
              and coalesce(c.counter_time, c.proposed_time) is not null
              and coalesce(c.counter_time, c.proposed_time) + (coalesce(c.duration_minutes,60) * interval '1 minute') < now()
              and (exists(select 1 from public.sim_bots s where s.bot_id = c.sender_id)
                or  exists(select 1 from public.sim_bots s where s.bot_id = c.receiver_id))
            limit 120 loop
    begin
      -- chaque PARTICIPANT BOT : honore (selon sa fiab) ou pose un lapin → son propre score bouge
      update public.profiles p set reliability_score = greatest(0, least(100,
          coalesce(p.reliability_score,80) + (case when random() < (case coalesce(s.traits->>'fiab','ponctuel')
              when 'roc' then 0.98 when 'ponctuel' then 0.9 when 'retard' then 0.82 when 'annuleur' then 0.6 when 'noshow' then 0.15 else 0.85 end)
            then 1 else -5 end)))
        from public.sim_bots s
        where p.id = s.bot_id and p.id in (rd.sender_id, rd.receiver_id);
      update public.clutches set status = 'completed' where id = rd.id;
      closed := closed + 1;
    exception when others then null; end;
  end loop;


  for b in select * from public.sim_bots where next_action_at <= now()
           and state not in ('churne') order by next_action_at limit 90 loop
    begin
      acted := acted + 1; tr := b.traits; arch := coalesce(tr->>'arch','occasionnelle');
      awake := case when (tr->>'chrono')='pendulaire' and (h between 7 and 9 or h between 17 and 19) then 1
                    when (tr->>'chrono')='pendulaire' then 0.15
                    when (tr->>'chrono')='matin' and h between 7 and 11 then 1
                    when (tr->>'chrono')='soir'  and (h >= 18 or h < 2) then 1
                    when (tr->>'chrono')='std'   and h between 11 and 22 then 1 else 0.3 end;
      update public.sim_bots set next_action_at = now() + ((8 + random()*35) / greatest(awake,0.1)) * interval '1 minute'
        where bot_id = b.bot_id;
      -- 🚶 MOBILITÉ (David 13.07 « les gens bougent, eux aussi doivent bouger ») : point COURANT = domicile
      --   + un déplacement selon un indice de mobilité STABLE par bot (hash de l'id). Casaniers restent chez
      --   eux (±0.4 km) ; nomades/expats/comètes sortent en ville (jusqu'à ~6 km, un bar, un ami, un quartier).
      mob := case coalesce(tr->>'arch','x') when 'expat' then 0.9 when 'comete_arroseur' then 0.8
                  when 'comete_engage' then 0.7 when 'organisatrice' then 0.6 when 'power' then 0.55
                  when 'pendulaire' then 0.5 when 'dormeur' then 0.15 when 'timide' then 0.2
                  when 'piliere' then 0.35 else 0.4 end;
      if (tr->>'chrono') = 'pendulaire' and h between 9 and 17 then
        curlat := (tr->>'work_lat')::float8 + (random()-0.5)*0.008; curlng := (tr->>'work_lng')::float8 + (random()-0.5)*0.012;
      elsif random() < mob then
        -- sorti : déplacement gaussien, d'autant plus large que le bot est mobile (max ~6 km)
        curlat := b.home_lat + (random()+random()-1) * mob * 0.045;
        curlng := b.home_lng + (random()+random()-1) * mob * 0.06;
      else
        curlat := b.home_lat + (random()-0.5)*0.006; curlng := b.home_lng + (random()-0.5)*0.008;  -- casanier, autour de chez lui
      end if;
      if b.state in ('pause','occupe') and random() < 0.85 then continue; end if;

      -- ① PUBLIER — cadence, rayon et fenêtre PAR PERSONNAGE
      pubp := case arch when 'piliere' then 0.7 when 'comete_engage' then 0.8 when 'comete_arroseur' then 0.75
                        when 'power' then 0.6 when 'organisatrice' then 0.5 when 'timide' then 0.35
                        when 'occasionnelle' then (case when dow in (5,6,7) then 0.5 else 0.15 end)
                        when 'dormeur' then 0.08 when 'perdu' then 0.4 when 'pendulaire' then 0.6
                        when 'expat' then 0.55 when 'vexe' then 0.45 else 0.4 end;
      if online < target and random() < pubp * awake
         and not exists (select 1 from public.profiles where id=b.bot_id and is_available and available_until>now()) then
        sm := date_trunc('hour', now()) + (floor(random()*4)*interval '15 minutes');
        if sm < now() then sm := now(); end if;
        su := sm + (interval '1 hour' * (case arch when 'pendulaire' then 1 + random()
                                                    when 'expat' then 1 + random()*2
                                                    when 'perdu' then 0.5 + random()*8   -- n'importe quoi
                                                    else 1.5 + random()*3.5 end));
        if su > now() + interval '17 hours' then su := now() + interval '17 hours'; end if;
        su := to_timestamp(round(extract(epoch from su)/900)*900);  -- 🕐 fin au quart d'heure (David)
        -- le pendulaire publie sur son lieu du MOMENT (boulot en journée, maison le soir)
        lat8 := (public.sim_dry(curlat, curlng))[1]; lng8 := curlng;   -- 🚶 là où il EST — jamais dans un lac (sim_dry)
        radp := case arch when 'expat' then (array[15,20,25])[1+floor(random()*3)::int]
                          when 'perdu' then (array[1,2,40])[1+floor(random()*3)::int]
                          when 'pendulaire' then (array[3,5,8])[1+floor(random()*3)::int]
                          else (array[3,5,8,10,15])[1+floor(random()*5)::int] end;
        perform public.admin_set_availability(b.bot_id, sm, su, lat8, lng8, radp);
        -- 🎭 MODES + GENRE RECHERCHÉ + MOOD (David 13.07 : les présences n'avaient AUCUN mode → filtres cassés).
        --   Stables par bot (hash de l'id) → un même bot cherche toujours la même chose. Dérivés de son profil.
        perform public.sim_set_intent(b.bot_id);
        online := online + 1; published := published + 1;
      end if;

      -- ①bis 🫣 LA TIMIDE : quelqu'un l'a clutchée → panique, retire son créneau (le clutch expirera)
      if arch = 'timide' and random() < 0.4
         and exists (select 1 from public.clutches c where c.receiver_id=b.bot_id and c.status='pending') then
        update public.profiles set is_available = false where id = b.bot_id and is_available = true;
        retired := retired + 1;
      end if;

      -- ② RÉPONDRE (latence + caractère ; l'indécise répond à la toute dernière minute via sa latence géante)
      -- 🤫 David 13.07 : certains n'ONT PAS RÉPONDU (ils oublient / ignorent) → silence, le clutch expirera.
      --   dormeur/timide/perdu/occasionnelle oublient souvent ; les fiables répondent presque toujours.
      if not (random() < (case arch when 'dormeur' then 0.35 when 'timide' then 0.45 when 'perdu' then 0.4
                                    when 'occasionnelle' then 0.3 when 'indecise' then 0.25 else 0.06 end)) then
      for cl in select c.id, c.sender_id from public.clutches c
                where c.receiver_id = b.bot_id and c.status = 'pending'
                  and c.created_at < now() - ((tr->>'latence_min')::int * interval '1 minute') limit 2 loop
        if random() < coalesce((tr->>'accept_p')::numeric, 0.4) then
          perform public.admin_accept_clutch(b.bot_id, cl.sender_id);   -- le noshow ACCEPTE (et ne viendra pas)
        else
          perform public.admin_refuse_clutch(b.bot_id, cl.sender_id);
        end if;
        answered := answered + 1;
      end loop;
      end if;   -- fin du filtre « ignorer » (silence = expiration)

      -- ②bis 🎯 CLUTCHER UN HUMAIN (dose crédible — throttle global 25 min/humain, jamais 2× le même en 24 h)
      if b.state in ('actif','hyper_engage','hyper_arroseur')
         and random() < (case arch when 'comete_arroseur' then 0.08 when 'comete_engage' then 0.05
                                    when 'piliere' then 0.04 when 'timide' then 0.005 else 0.02 end) then
        select p.id into hum from public.profiles p
          where coalesce(p.is_bot,false) = false and p.is_available = true and p.available_until > now()
            and p.center_lat is not null
            and abs(p.center_lat - curlat) < 0.15 and abs(p.center_lng - curlng) < 0.2
            and not exists (select 1 from public.clutches c2 where c2.receiver_id = p.id and c2.created_at > now() - interval '25 minutes')
            and not exists (select 1 from public.clutches c3 where c3.sender_id = b.bot_id and c3.receiver_id = p.id and c3.created_at > now() - interval '24 hours')
          order by random() limit 1;
        if hum.id is not null then
          perform public.admin_create_clutch(b.bot_id, hum.id,
            (array['Un café ?','Une balade au bord du lac ?','Un verre en terrasse ?','Un ping-pong ?','Une glace ?'])[1+floor(random()*5)::int],
            now() + (interval '1 hour' * (0.75 + random()*2)),
            (array['On tente ? 🙂','Dispo si tu l''es','Ça te dit ?','Simple et sans pression'])[1+floor(random()*4)::int],
            60, b.home_lat, b.home_lng);
          clutched := clutched + 1;
        end if;
      end if;

      -- ②quater 🤝 CLUTCHER UN AUTRE BOT (la ville s'anime d'elle-même — David 13.07 « il ne se passe rien »)
      if b.state in ('actif','hyper_engage','hyper_arroseur','occasionnelle')
         and random() < (case arch when 'comete_arroseur' then 0.16 when 'comete_engage' then 0.12
                                    when 'piliere' then 0.10 when 'timide' then 0.02 else 0.06 end) * awake then
        select p.id into other from public.profiles p join public.sim_bots s2 on s2.bot_id = p.id
          where p.is_bot = true and p.id <> b.bot_id and p.is_available = true and p.available_until > now()
            and abs(p.center_lat - curlat) < 0.12 and abs(p.center_lng - curlng) < 0.16
            and not exists (select 1 from public.clutches c2 where c2.receiver_id = p.id and c2.sender_id = b.bot_id and c2.created_at > now() - interval '24 hours')
            and not exists (select 1 from public.clutches c3 where c3.sender_id = b.bot_id and c3.status = 'pending')  -- 1 clutch en vol à la fois
          order by random() limit 1;
        if other.id is not null then
          perform public.admin_create_clutch(b.bot_id, other.id,
            (array['Un café ?','Une balade ?','Un verre ?','Un ping-pong ?','On se voit ?'])[1+floor(random()*5)::int],
            now() + (interval '1 hour' * (0.75 + random()*2)), 'Dispo maintenant 🙂', 60, b.home_lat, b.home_lng);
          botclutch := botclutch + 1;
        end if;
      end if;

      -- ⑤ 🎟️ REJOINDRE un EVENT proche pas plein (les events se remplissent → crédibles)
      if b.state in ('actif','hyper_engage','occasionnelle','dormeur') and random() < 0.10 * awake then
        select e.id into ev from public.events e
          where e.active = true and e.status in ('pending','open') and e.starts_at > now()
            and coalesce(e.taken,0) < e.spots and e.created_by <> b.bot_id
            and e.venue_lat is not null and abs(e.venue_lat - curlat) < 0.2 and abs(e.venue_lng - curlng) < 0.25
            and not exists (select 1 from public.event_participants ep where ep.event_id = e.id and ep.user_id = b.bot_id)
          order by random() limit 1;
        if ev.id is not null then perform public.join_event(ev.id, b.bot_id); joined := joined + 1; end if;
      end if;

      -- ⑥ ✅ ACCEPTER les demandes à MES events (organisateur curated) — les demandes ne pourrissent plus
      if (tr->>'organise')::boolean then
        for req in select ep.event_id, ep.user_id from public.event_participants ep
                   join public.events e on e.id = ep.event_id
                   where e.created_by = b.bot_id and ep.state = 'requested'
                     and ep.created_at < now() - (5 + floor(random()*40)) * interval '1 minute'  -- ⏳ délai humain (5-45 min)
                   limit 3 loop
          begin update public.event_participants set state = 'accepted' where event_id = req.event_id and user_id = req.user_id;
                accepted := accepted + 1; exception when others then null; end;
        end loop;
      end if;

      -- ②ter 😤 LE VEXÉ : son clutch a été refusé → il RETENTE (le cooldown serveur doit l'arrêter — c'est le test)
      if arch = 'vexe' and random() < 0.5 then
        select c.receiver_id into vx from public.clutches c
          where c.sender_id = b.bot_id and c.status in ('refused','declined','expired')
            and c.created_at > now() - interval '6 hours'
          order by c.created_at desc limit 1;
        if vx.receiver_id is not null then
          perform public.admin_create_clutch(b.bot_id, vx.receiver_id, 'Allez, un café quand même ?', now() + interval '90 minutes',
            'Je suis sûr qu''on s''entendrait bien', 60, b.home_lat, b.home_lng);
          revenge := revenge + 1;   -- la plupart seront refusés par COOLDOWN_ACTIVE : exactement ce qu'on vérifie
        end if;
      end if;

      -- ③ ORGANISER un event (organisatrices + pilières)
      if (tr->>'organise')::boolean and random() < 0.10 and h between 8 and 22 then
        pool := case when h < 11 then '[["☕","Café-croissants"],["🥾","Balade matinale"]]'::jsonb
                     when h < 14 then '[["🥗","Lunch ensemble"],["♟️","Échecs au parc"]]'::jsonb
                     when h < 17 then '[["🎨","Atelier croquis"],["🚴","Sortie vélo"]]'::jsonb
                     else '[["🍹","Apéro spontané"],["🎲","Soirée jeux"],["🏐","Beach-volley"]]'::jsonb end;
        pick := pool->floor(random()*jsonb_array_length(pool))::int;
        sm := now() + (interval '1 hour' * (1 + random()*3));
        -- 🕐 crédibilité : un event ne COMMENCE jamais entre 23h et 9h locale (David : « heures improbables »)
        if extract(hour from sm at time zone 'Europe/Zurich') between 9 and 22 then
          lat8 := (public.sim_dry(b.home_lat + (random()-0.5)*0.008, b.home_lng))[1];
          perform public.admin_create_event(b.bot_id,
            (pick->>0)||' '||(pick->>1)||' — '||coalesce(b.town,'Lausanne'),
            sm, lat8, b.home_lng + (random()-0.5)*0.012,
            4 + floor(random()*8)::int);
          events := events + 1;
        end if;
      end if;
    exception when others then null;
    end;
  end loop;
  return jsonb_build_object('ok',true,'acted',acted,'published',published,'answered',answered,
    'clutched',clutched,'botclutch',botclutch,'joined',joined,'accepted',accepted,'rdv_clos',closed,'revenge',revenge,'retired',retired,'events',events,'online',online,'target',target);
end; $$;

-- ═══════ 20260713i_sim_set_intent_fix.sql ═══════
-- 🎯 LE COUPABLE DE LA NUIT (13.07 ~03h55) : sim_set_intent N'EXISTAIT PAS en base (la migration v4 a
-- sauté dans l'enchaînement des collages) → chaque publication de bot levait « function does not exist »,
-- le filet per-bot avalait l'erreur ET annulait la sous-transaction → acted=90, published=0, ville morte.
-- Trouvé par : sim_doctor (0 en ligne) → journal cron (ticks verts) → tick manuel (published=0) → bloc
-- débug sans filet (erreur brute). ✅ APPLIQUÉE À LA MAIN par David 03h55 — ce fichier = trace.
create or replace function public.sim_set_intent(p_bot uuid) returns void
language plpgsql security definer set search_path = public as $$
declare hh int; g text; v_modes text[]; lf text; md text;
begin
  hh := ('x'||substr(md5(p_bot::text),1,7))::bit(28)::int;
  select gender into g from public.profiles where id = p_bot;
  v_modes := case (hh % 10)
    when 0 then array['romance'] when 1 then array['romance'] when 2 then array['romance','amical']
    when 3 then array['amical'] when 4 then array['amical'] when 5 then array['amical','activite']
    when 6 then array['activite'] when 7 then array['pro'] when 8 then array['parent'] else array['romance','amical'] end;
  lf := case when (hh/10) % 10 < 6 then (case when g in ('woman','F','f') then 'M' else 'F' end)
             when (hh/10) % 10 < 9 then 'ALL' else (case when g in ('woman','F','f') then 'F' else 'M' end) end;
  md := (array['cafe','balade','apero','diner','sport','culture'])[1 + (hh/100) % 6];
  update public.profiles set available_modes = v_modes, looking_for = lf where id = p_bot;
  update public.availabilities set modes = v_modes, mood = md
    where user_id = p_bot and active = true and end_at > now();
end; $$;
grant execute on function public.sim_set_intent(uuid) to authenticated;

-- ═══════ 20260713j_bots_genre_backfill.sql ═══════
-- 🚺🚹 TROISIÈME VERROU DE LA NUIT (13.07 ~04h10) : les ~11 000 bots rattrapés n'avaient JAMAIS reçu de
-- genre (le trigger handle_new_user ne le pose pas ; les rattrapages avaient corrigé nom/âge mais pas genre)
-- → « 59 en ligne, 0 femme » → le filtre « des femmes » de David filtrait une ville SANS femmes.
-- ✅ APPLIQUÉE À LA MAIN par David 04h10 (vérifié : 69 en ligne · 12 femmes près de Lausanne).
update public.profiles set gender = case when random() < 0.5 then 'woman' else 'man' end
where is_bot and (gender is null or gender not in ('woman','man'));
-- + prénoms raccordés au genre + sim_set_intent re-exécuté pour les bots en ligne (voir historique session).

-- ═══════ 20260713k_sim_modes_vocab.sql ═══════
-- 🔤 QUATRIÈME VERROU DE LA NUIT (13.07 ~04h25) : DÉCALAGE DE VOCABULAIRE des modes.
-- L'app filtre sur ['romantic','friend','pro','parent'] ; sim_set_intent posait
-- ['romance','amical','activite','parent'] → intersection quasi impossible → « 73 × aucun mode en commun ».
-- ✅ APPLIQUÉE À LA MAIN par David 04h25 — sim_set_intent parle désormais la langue de l'app + re-pose
-- des intentions de tous les bots en ligne. (Trace du SQL exact : historique session / ce fichier.)
-- Leçon registre : quand DEUX systèmes partagent un champ, le VOCABULAIRE est un contrat — le vérifier
-- AVANT d'écrire (grep des valeurs réellement filtrées côté app).
select 1; -- (fonction déjà appliquée à la main — ce fichier est la trace)

-- ═══════ 20260713l_sim_events_off.sql ═══════
-- ⏸️ ÉVÉNEMENTS DE BOTS : OFF (demande David 13.07 ~04h35 — « il ne faut juste pas d'événements pour l'instant »)
-- ✅ APPLIQUÉE À LA MAIN 04h35. Le gène « organise » (seul déclencheur d'events dans sim_tick) est éteint
-- sur tous les sim_bots + events de bots pas encore commencés effacés (colonne = created_by, PAS creator_id).
-- update public.sim_bots set traits = jsonb_set(traits, '{organise}', 'false'::jsonb);
-- delete from public.events e using public.profiles p
--   where p.id = e.created_by and p.is_bot and e.starts_at > now();
-- 🔛 POUR RALLUMER un jour : re-poser organise=true sur ~8-12 % des bots :
-- update public.sim_bots set traits = jsonb_set(traits,'{organise}','true'::jsonb)
--   where ('x'||substr(md5(bot_id::text),1,7))::bit(28)::int % 10 = 0;
select 1;

-- ═══════ 20260713m_sim_humains_v7.sql ═══════
-- ═══════════════════════════════════════════════════════════════════════════════════════
-- 20260713m — FOURNÉE 18 (David 12:36) : des bots HUMAINS + une ville qui MONTRE ses erreurs
-- ① Prénoms SEULS (décision : pas de nom de famille sur les profils — bots = mêmes règles)
-- ② Enrichissement MASSIF : photos (portrait genré + 2 lifestyle), langues variées (bilingues !),
--    fiabilité variée, PHRASE D'ACCROCHE (bio), INTÉRÊTS (vocabulaire EXACT du catalogue app — contrat !)
-- ③ Boîtes à 10 (David : « dix, pas cinq — et j'étais à DEUX » → c'est pour ça que Mel ne le voyait pas)
-- ④ Events de bots RALLUMÉS ~1/10 (comme les humains), max 1 event futur par organisateur
-- ⑤ sim_tick v7 : chaque action a SON filet (fini le rollback invisible de tout le bot) + les ÉCHECS
--    remontent dans le Battement (err_*) — « montre-moi les erreurs, pas quand ça marche »
-- ═══════════════════════════════════════════════════════════════════════════════════════

-- ① PRÉNOMS SEULS
update public.profiles set name = split_part(name, ' ', 1)
where is_bot = true and position(' ' in coalesce(name,'')) > 0;

-- ③ BOÎTES À 10 — pour TOUT LE MONDE (le 2 de David venait d'un vieux test)
update public.profiles set max_received_clutchs = 10 where coalesce(max_received_clutchs, 0) <> 10;
alter table public.profiles alter column max_received_clutchs set default 10;

-- ④ ORGANISE rallumé sur ~10 % des bots (stable par hash — toujours les mêmes organisateurs)
update public.sim_bots set traits = jsonb_set(traits, '{organise}',
  to_jsonb((abs(hashtext(bot_id::text)) % 10) = 0));

-- ② ENRICHISSEMENT MASSIF (tous les bots, pas seulement 1200)
do $$
declare
  -- ⚠️ PIÈGE Postgres (vécu 13.07) : text[][] doit être RECTANGULAIRE (2202E) → les langues passent par un CASE.
  lifestyle text[] := array[
    'https://images.unsplash.com/photo-1506905925346-21bda4d32df4?w=600&q=80',
    'https://images.unsplash.com/photo-1514362453360-8f94243c9996?w=600&q=80',
    'https://images.unsplash.com/photo-1507035895480-2b3156c31fc8?w=600&q=80',
    'https://images.unsplash.com/photo-1508672019048-805c876b67e2?w=600&q=80',
    'https://images.unsplash.com/photo-1545205597-3d9d02c29597?w=600&q=80',
    'https://images.unsplash.com/photo-1555396273-367ea4eb4db5?w=600&q=80',
    'https://images.unsplash.com/photo-1522163182402-834f871fd851?w=600&q=80',
    'https://images.unsplash.com/photo-1576092768241-dec231879fc3?w=600&q=80' ];
  -- 🗣️ accroches humaines, bienveillantes, variées (pas de vulgarité — règle modération)
  bios text[] := array[
    'Toujours partant·e pour un café en terrasse ☕','Ici pour des vraies rencontres, pas des écrans',
    'Balade au bord du lac, ça te dit ?','Nouvelle·au dans le coin, je découvre la région',
    'Un ping-pong, un verre, un rire — simple','J''aime les plans spontanés et les gens vrais',
    'Plutôt rando le matin, apéro le soir','Musicien·ne à mes heures, curieux·se tout le temps',
    'On refait le monde autour d''un verre ?','Fan de marchés, de brocantes et de bonnes adresses',
    'Sportif·ve du dimanche, motivé·e toute la semaine','Je cuisine trop pour une seule personne — aide-moi',
    'Le tram m''a fait rater mille rencontres. Plus maintenant','Ciné du quartier ou grande salle, tant qu''il y a du popcorn',
    'Chercher des champignons compte comme un sport ?','Expat·e qui veut enfin parler français',
    'Un échiquier traîne toujours dans mon sac','Team lever tôt : le lac à 7 h, personne, magique' ];
  -- 🧩 CONTRAT DE VOCABULAIRE : les intérêts = EXACTEMENT le catalogue de l'app (comparés en texte)
  cats text[] := array['☕ Café','🍷 Vins','🥾 Randonnée','🧘 Yoga','🎬 Cinéma','🍳 Cuisine','🎵 Musique','✈️ Voyage',
    '🏃 Running','🎨 Art','💻 Tech','⛽ Sport','📚 Lecture','💃 Danse','🎉 Festivals','🍕 Restos','🎸 Concerts','🌿 Nature'];
  r record; hh int; dir text; main text; n int := 0;
begin
  for r in select id, gender, photo_url, photos, languages, reliability_score, bio, interests
           from public.profiles where is_bot = true loop
    hh := abs(hashtext(r.id::text));
    dir := case when r.gender = 'woman' then 'women' else 'men' end;
    main := case when r.photo_url like '%/portraits/'||dir||'/%' then r.photo_url
                 else 'https://randomuser.me/api/portraits/'||dir||'/'||(hh % 80)||'.jpg' end;
    update public.profiles set
      photo_url = main,
      photos = array[main, lifestyle[1 + hh % 8], lifestyle[1 + (hh/8) % 8]],
      languages = case hh % 9
        when 0 then array['Français'] when 1 then array['Français','Anglais']
        when 2 then array['Français','Anglais','Allemand'] when 3 then array['Anglais','Français']
        when 4 then array['Français','Italien'] when 5 then array['Allemand','Français']
        when 6 then array['Français','Espagnol'] when 7 then array['Anglais','Espagnol','Français']
        else array['Italien','Français'] end,
      reliability_score = case when reliability_score is null or reliability_score = 100
                               then 55 + (hh % 31) + ((hh/31) % 15) else reliability_score end,
      bio = case when coalesce(bio,'') = '' or bio = '(test lab)' then bios[1 + (hh/7) % array_length(bios,1)] else bio end,
      interests = case when interests is null or coalesce(array_length(interests,1),0) = 0
                       then array[ cats[1 + hh % 18], cats[1 + (hh/18) % 18], cats[1 + (hh/324) % 18] ]
                       else interests end
    where id = r.id;
    n := n + 1;
  end loop;
  raise notice 'bots enrichis : %', n;
end $$;

-- ⑤ sim_tick v7 — filets PAR ACTION + échecs visibles (err_*) + botclutch dans le Battement
create or replace function public.sim_tick() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  ctl record; b record; tr jsonb; arch text; h int; dow int; awake numeric; target int; online int;
  acted int := 0; published int := 0; answered int := 0; events int := 0; clutched int := 0; retired int := 0; revenge int := 0; joined int := 0; botclutch int := 0; accepted int := 0;
  ev record; other record; req record; curlat float8; curlng float8; mob numeric; rd record; closed int := 0;
  cl record; hum record; vx record; lat8 float8; lng8 float8; sm timestamptz; su timestamptz; radp int;
  pool jsonb; pick jsonb; pubp numeric;
  fails int := 0; err_pub text; err_answer text; err_clutch text; err_bot text; err_join text; err_event text;
begin
  if not public.qa_is_admin() then return jsonb_build_object('ok',false,'code','RLS_FORBIDDEN'); end if;
  select * into ctl from public.sim_control where id = 1;
  if ctl is null or not ctl.running then return jsonb_build_object('ok',true,'skipped','off'); end if;
  h := extract(hour from now() at time zone 'Europe/Zurich')::int;
  dow := extract(isodow from now() at time zone 'Europe/Zurich')::int;
  target := round((case ctl.scene when 'A' then 25 when 'B' then 180 else 700 end) * ctl.density
            * (case when h between 17 and 22 then 1.0 when h between 12 and 16 then 0.6
                    when h between 7 and 11 then 0.4 else 0.25 end)
            * (case when dow in (4,5,6) then 1.5 else 1.0 end));
  select count(*) into online from public.profiles p join public.sim_bots s on s.bot_id=p.id
    where p.is_available = true and p.available_until > now();

  -- 🤝 la vie du Verrou : RDV passés clôturés, la fiabilité de chaque bot participant bouge toute seule
  for rd in select c.id, c.sender_id, c.receiver_id from public.clutches c
            where c.status in ('accepted','confirmed','checked_in')
              and coalesce(c.counter_time, c.proposed_time) is not null
              and coalesce(c.counter_time, c.proposed_time) + (coalesce(c.duration_minutes,60) * interval '1 minute') < now()
              and (exists(select 1 from public.sim_bots s where s.bot_id = c.sender_id)
                or  exists(select 1 from public.sim_bots s where s.bot_id = c.receiver_id))
            limit 120 loop
    begin
      update public.profiles p set reliability_score = greatest(0, least(100,
          coalesce(p.reliability_score,80) + (case when random() < (case coalesce(s.traits->>'fiab','ponctuel')
              when 'roc' then 0.98 when 'ponctuel' then 0.9 when 'retard' then 0.82 when 'annuleur' then 0.6 when 'noshow' then 0.15 else 0.85 end)
            then 1 else -5 end)))
        from public.sim_bots s
        where p.id = s.bot_id and p.id in (rd.sender_id, rd.receiver_id);
      update public.clutches set status = 'completed' where id = rd.id;
      closed := closed + 1;
    exception when others then fails := fails + 1; end;
  end loop;

  for b in select * from public.sim_bots where next_action_at <= now()
           and state not in ('churne') order by next_action_at limit 90 loop
    acted := acted + 1; tr := b.traits; arch := coalesce(tr->>'arch','occasionnelle');
    awake := case when (tr->>'chrono')='pendulaire' and (h between 7 and 9 or h between 17 and 19) then 1
                  when (tr->>'chrono')='pendulaire' then 0.15
                  when (tr->>'chrono')='matin' and h between 7 and 11 then 1
                  when (tr->>'chrono')='soir'  and (h >= 18 or h < 2) then 1
                  when (tr->>'chrono')='std'   and h between 11 and 22 then 1 else 0.3 end;
    update public.sim_bots set next_action_at = now() + ((8 + random()*35) / greatest(awake,0.1)) * interval '1 minute'
      where bot_id = b.bot_id;
    mob := case coalesce(tr->>'arch','x') when 'expat' then 0.9 when 'comete_arroseur' then 0.8
                when 'comete_engage' then 0.7 when 'organisatrice' then 0.6 when 'power' then 0.55
                when 'pendulaire' then 0.5 when 'dormeur' then 0.15 when 'timide' then 0.2
                when 'piliere' then 0.35 else 0.4 end;
    if (tr->>'chrono') = 'pendulaire' and h between 9 and 17 then
      curlat := (tr->>'work_lat')::float8 + (random()-0.5)*0.008; curlng := (tr->>'work_lng')::float8 + (random()-0.5)*0.012;
    elsif random() < mob then
      curlat := b.home_lat + (random()+random()-1) * mob * 0.045;
      curlng := b.home_lng + (random()+random()-1) * mob * 0.06;
    else
      curlat := b.home_lat + (random()-0.5)*0.006; curlng := b.home_lng + (random()-0.5)*0.008;
    end if;
    if b.state in ('pause','occupe') and random() < 0.85 then continue; end if;

    -- ① PUBLIER (filet propre : un échec ici n'annule plus le reste du bot)
    begin
      pubp := case arch when 'piliere' then 0.7 when 'comete_engage' then 0.8 when 'comete_arroseur' then 0.75
                        when 'power' then 0.6 when 'organisatrice' then 0.5 when 'timide' then 0.35
                        when 'occasionnelle' then (case when dow in (5,6,7) then 0.5 else 0.15 end)
                        when 'dormeur' then 0.08 when 'perdu' then 0.4 when 'pendulaire' then 0.6
                        when 'expat' then 0.55 when 'vexe' then 0.45 else 0.4 end;
      if online < target and random() < pubp * awake
         and not exists (select 1 from public.profiles where id=b.bot_id and is_available and available_until>now()) then
        sm := date_trunc('hour', now()) + (floor(random()*4)*interval '15 minutes');
        -- 🕐 v7.1 (bug David « 14h06 ») : le clamp « pas dans le passé » cassait l'arrondi ¼h → PROCHAIN quart d'heure.
        if sm < now() then sm := to_timestamp(ceil(extract(epoch from now())/900)*900); end if;
        su := sm + (interval '1 hour' * (case arch when 'pendulaire' then 1 + random()
                                                    when 'expat' then 1 + random()*2
                                                    when 'perdu' then 1 + random()*8
                                                    else 1.5 + random()*3.5 end));
        if su > now() + interval '17 hours' then su := now() + interval '17 hours'; end if;
        su := to_timestamp(round(extract(epoch from su)/900)*900);
        lat8 := (public.sim_dry(curlat, curlng))[1]; lng8 := curlng;
        radp := case arch when 'expat' then (array[15,20,25])[1+floor(random()*3)::int]
                          when 'perdu' then (array[1,2,40])[1+floor(random()*3)::int]
                          when 'pendulaire' then (array[3,5,8])[1+floor(random()*3)::int]
                          else (array[3,5,8,10,15])[1+floor(random()*5)::int] end;
        perform public.admin_set_availability(b.bot_id, sm, su, lat8, lng8, radp);
        perform public.sim_set_intent(b.bot_id);
        online := online + 1; published := published + 1;
      end if;
    exception when others then fails := fails + 1; err_pub := coalesce(err_pub, SQLERRM); end;

    -- ①bis 🫣 la timide retire son créneau quand on la clutch
    begin
      if arch = 'timide' and random() < 0.4
         and exists (select 1 from public.clutches c where c.receiver_id=b.bot_id and c.status='pending') then
        update public.profiles set is_available = false where id = b.bot_id and is_available = true;
        retired := retired + 1;
      end if;
    exception when others then fails := fails + 1; end;

    -- ② RÉPONDRE (latence + caractère ; certains ignorent → le clutch expirera)
    begin
      if not (random() < (case arch when 'dormeur' then 0.35 when 'timide' then 0.45 when 'perdu' then 0.4
                                    when 'occasionnelle' then 0.3 when 'indecise' then 0.25 else 0.06 end)) then
        for cl in select c.id, c.sender_id from public.clutches c
                  where c.receiver_id = b.bot_id and c.status = 'pending'
                    and c.created_at < now() - ((tr->>'latence_min')::int * interval '1 minute') limit 2 loop
          if random() < coalesce((tr->>'accept_p')::numeric, 0.4) then
            perform public.admin_accept_clutch(b.bot_id, cl.sender_id);
          else
            perform public.admin_refuse_clutch(b.bot_id, cl.sender_id);
          end if;
          answered := answered + 1;
        end loop;
      end if;
    exception when others then fails := fails + 1; err_answer := coalesce(err_answer, SQLERRM); end;

    -- ②bis 🎯 CLUTCHER UN HUMAIN (dose crédible ×2 — David « personne ne me clutch » ; throttle 25 min/humain)
    begin
      if b.state in ('actif','hyper_engage','hyper_arroseur')
         and random() < (case arch when 'comete_arroseur' then 0.16 when 'comete_engage' then 0.10
                                    when 'piliere' then 0.08 when 'timide' then 0.01 else 0.04 end) then
        select p.id into hum from public.profiles p
          where coalesce(p.is_bot,false) = false and p.is_available = true and p.available_until > now()
            and p.center_lat is not null
            and abs(p.center_lat - curlat) < 0.15 and abs(p.center_lng - curlng) < 0.2
            and not exists (select 1 from public.clutches c2 where c2.receiver_id = p.id and c2.created_at > now() - interval '25 minutes')
            and not exists (select 1 from public.clutches c3 where c3.sender_id = b.bot_id and c3.receiver_id = p.id and c3.created_at > now() - interval '24 hours')
          order by random() limit 1;
        if hum.id is not null then
          perform public.admin_create_clutch(b.bot_id, hum.id,
            (array['Un café ?','Une balade au bord du lac ?','Un verre en terrasse ?','Un ping-pong ?','Une glace ?'])[1+floor(random()*5)::int],
            to_timestamp(round(extract(epoch from now() + (interval '1 hour' * (0.75 + random()*2)))/900)*900),
            (array['On tente ? 🙂','Dispo si tu l''es','Ça te dit ?','Simple et sans pression'])[1+floor(random()*4)::int],
            60, b.home_lat, b.home_lng);
          clutched := clutched + 1;
        end if;
      end if;
    exception when others then fails := fails + 1; err_clutch := coalesce(err_clutch, SQLERRM); end;

    -- ②quater 🤝 CLUTCHER UN AUTRE BOT (dose ×2 — la ville s'anime d'elle-même)
    begin
      if b.state in ('actif','hyper_engage','hyper_arroseur','occasionnelle')
         and random() < (case arch when 'comete_arroseur' then 0.30 when 'comete_engage' then 0.22
                                    when 'piliere' then 0.18 when 'timide' then 0.04 else 0.12 end) * awake then
        select p.id into other from public.profiles p join public.sim_bots s2 on s2.bot_id = p.id
          where p.is_bot = true and p.id <> b.bot_id and p.is_available = true and p.available_until > now()
            and abs(p.center_lat - curlat) < 0.12 and abs(p.center_lng - curlng) < 0.16
            and not exists (select 1 from public.clutches c2 where c2.receiver_id = p.id and c2.sender_id = b.bot_id and c2.created_at > now() - interval '24 hours')
            and not exists (select 1 from public.clutches c3 where c3.sender_id = b.bot_id and c3.status = 'pending')
          order by random() limit 1;
        if other.id is not null then
          perform public.admin_create_clutch(b.bot_id, other.id,
            (array['Un café ?','Une balade ?','Un verre ?','Un ping-pong ?','On se voit ?'])[1+floor(random()*5)::int],
            to_timestamp(round(extract(epoch from now() + (interval '1 hour' * (0.75 + random()*2)))/900)*900), 'Dispo maintenant 🙂', 60, b.home_lat, b.home_lng);
          botclutch := botclutch + 1;
        end if;
      end if;
    exception when others then fails := fails + 1; err_bot := coalesce(err_bot, SQLERRM); end;

    -- ⑤ 🎟️ REJOINDRE un event proche pas plein
    begin
      if b.state in ('actif','hyper_engage','occasionnelle','dormeur') and random() < 0.10 * awake then
        select e.id into ev from public.events e
          where e.active = true and e.status in ('pending','open') and e.starts_at > now()
            and coalesce(e.taken,0) < e.spots and e.created_by <> b.bot_id
            and e.venue_lat is not null and abs(e.venue_lat - curlat) < 0.2 and abs(e.venue_lng - curlng) < 0.25
            and not exists (select 1 from public.event_participants ep where ep.event_id = e.id and ep.user_id = b.bot_id)
          order by random() limit 1;
        if ev.id is not null then perform public.join_event(ev.id, b.bot_id); joined := joined + 1; end if;
      end if;
    exception when others then fails := fails + 1; err_join := coalesce(err_join, SQLERRM); end;

    -- ⑥ ✅ ACCEPTER les demandes à MES events (délai humain 5-45 min)
    begin
      if (tr->>'organise')::boolean then
        for req in select ep.event_id, ep.user_id from public.event_participants ep
                   join public.events e on e.id = ep.event_id
                   where e.created_by = b.bot_id and ep.state = 'requested'
                     and ep.created_at < now() - (5 + floor(random()*40)) * interval '1 minute'
                   limit 3 loop
          update public.event_participants set state = 'accepted' where event_id = req.event_id and user_id = req.user_id;
          accepted := accepted + 1;
        end loop;
      end if;
    exception when others then fails := fails + 1; end;

    -- ②ter 😤 le vexé retente (le cooldown serveur doit l'arrêter — c'est le test)
    begin
      if arch = 'vexe' and random() < 0.5 then
        select c.receiver_id into vx from public.clutches c
          where c.sender_id = b.bot_id and c.status in ('refused','declined','expired')
            and c.created_at > now() - interval '6 hours'
          order by c.created_at desc limit 1;
        if vx.receiver_id is not null then
          perform public.admin_create_clutch(b.bot_id, vx.receiver_id, 'Allez, un café quand même ?', to_timestamp(round(extract(epoch from now() + interval '90 minutes')/900)*900),
            'Je suis sûr qu''on s''entendrait bien', 60, b.home_lat, b.home_lng);
          revenge := revenge + 1;
        end if;
      end if;
    exception when others then fails := fails + 1; end;

    -- ③ 🎟️ ORGANISER un event (organise ~1/10 — RALLUMÉ 13.07 ; max 1 event FUTUR par organisateur)
    begin
      if (tr->>'organise')::boolean and random() < 0.06 and h between 8 and 22
         and not exists (select 1 from public.events e where e.created_by = b.bot_id and e.active and e.starts_at > now()) then
        pool := case when h < 11 then '[["☕","Café-croissants"],["🥾","Balade matinale"]]'::jsonb
                     when h < 14 then '[["🥗","Lunch ensemble"],["♟️","Échecs au parc"]]'::jsonb
                     when h < 17 then '[["🎨","Atelier croquis"],["🚴","Sortie vélo"]]'::jsonb
                     else '[["🍹","Apéro spontané"],["🎲","Soirée jeux"],["🏐","Beach-volley"]]'::jsonb end;
        pick := pool->floor(random()*jsonb_array_length(pool))::int;
        sm := now() + (interval '1 hour' * (1 + random()*3));
        if extract(hour from sm at time zone 'Europe/Zurich') between 9 and 22 then
          lat8 := (public.sim_dry(b.home_lat + (random()-0.5)*0.008, b.home_lng))[1];
          perform public.admin_create_event(b.bot_id,
            (pick->>0)||' '||(pick->>1)||' — '||coalesce(b.town,'Lausanne'),
            sm, lat8, b.home_lng + (random()-0.5)*0.012,
            4 + floor(random()*8)::int);
          events := events + 1;
        end if;
      end if;
    exception when others then fails := fails + 1; err_event := coalesce(err_event, SQLERRM); end;

  end loop;
  return jsonb_build_object('ok',true,'acted',acted,'published',published,'answered',answered,
    'clutched',clutched,'botclutch',botclutch,'joined',joined,'accepted',accepted,'rdv_clos',closed,'revenge',revenge,'retired',retired,'events',events,'online',online,'target',target,
    'fails',fails,'err_pub',err_pub,'err_answer',err_answer,'err_clutch',err_clutch,'err_bot',err_bot,'err_join',err_join,'err_event',err_event);
end; $$;

-- ═══════ 20260713n_forteresse_serveur.sql ═══════
-- ═══════════════════════════════════════════════════════════════════════════════════════
-- 20260713n — LA FORTERESSE NE DORT JAMAIS (David 14h09 : « app éteinte, il se passe quoi ?
-- On n'a pas le GPS, on ne peut pas gérer les créneaux — ça ne va pas du tout »)
-- ① Le téléphone dépose sa DERNIÈRE POSITION CONNUE (arrondie ~110 m, seulement pendant une dispo
--    active, max 1×/3 min — LPD : grain grossier, pas d'historique, une seule ligne écrasée).
-- ② guard_slots() — cron toutes les 5 min : pour chaque créneau HUMAIN qui commence dans ≤ 45 min,
--    si la dernière position est FRAÎCHE (< 15 min) et trop loin pour couvrir la zone
--    (trajet ×1.35 à 30 km/h + 30 min de marge « le temps de vivre ») :
--      → début DÉCALÉ au prochain ¼h tenable (guard_reason posé, l'app le DIT à la réouverture)
--      → ou ÉTEINT s'il resterait < 1 h (règle créneau minimum, David 13.07)
--    Position inconnue ou vieille → on ne touche à RIEN (jamais de faux positif).
-- ═══════════════════════════════════════════════════════════════════════════════════════

alter table public.profiles add column if not exists last_lat double precision;
alter table public.profiles add column if not exists last_lng double precision;
alter table public.profiles add column if not exists last_gps_at timestamptz;
alter table public.availabilities add column if not exists guard_reason text;

create or replace function public.guard_slots() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  a record; needed_min numeric; min_start timestamptz; shifted int := 0; killed int := 0; hhmm text;
begin
  for a in
    select av.id, av.start_at, av.end_at, av.lat, av.lng, coalesce(av.radius_km,3) as radius_km,
           av.place, av.user_id, p.last_lat, p.last_lng
    from public.availabilities av
    join public.profiles p on p.id = av.user_id
    where av.active = true
      and coalesce(p.is_bot, false) = false                      -- humains seulement
      and av.start_at > now() and av.start_at < now() + interval '45 minutes'
      and av.lat is not null and av.lng is not null
      and p.last_lat is not null and p.last_gps_at > now() - interval '15 minutes'
  loop
    begin
      -- temps pour couvrir la zone : distance au centre + rayon, route ×1.35 à 30 km/h, + 30 min de marge
      needed_min := (public.hav_km(a.last_lat, a.last_lng, a.lat, a.lng) + a.radius_km) * 1.35 / 30 * 60 + 30;
      if now() + (needed_min * interval '1 minute') > a.start_at then
        min_start := to_timestamp(ceil(extract(epoch from now() + needed_min * interval '1 minute')/900)*900);
        hhmm := to_char(min_start at time zone 'Europe/Zurich', 'HH24:MI');
        if min_start <= a.end_at - interval '60 minutes' then
          update public.availabilities set start_at = min_start,
            guard_reason = 'début décalé à '||hhmm||' pendant ton absence — le temps d''arriver'
            where id = a.id;
          -- une seule vérité : le résumé profil suit si ce créneau était le plus tôt
          update public.profiles set available_from = min_start
            where id = a.user_id and available_from is not null and available_from < min_start;
          shifted := shifted + 1;
        else
          update public.availabilities set active = false,
            guard_reason = 'éteint pendant ton absence — impossible d''y être à temps (il restait moins d''1 h)'
            where id = a.id;
          killed := killed + 1;
        end if;
      end if;
    exception when others then null; end;
  end loop;
  return jsonb_build_object('ok', true, 'decales', shifted, 'eteints', killed);
end; $$;

-- cron toutes les 5 minutes (idempotent : on remplace s'il existe)
do $$ begin
  perform cron.unschedule('guard-slots');
exception when others then null; end $$;
select cron.schedule('guard-slots', '*/5 * * * *', $$select public.guard_slots()$$);

-- ═══════ 20260713o_join_event_types.sql ═══════
-- ═══════════════════════════════════════════════════════════════════════════════════════
-- 20260713o — LE VERROU QUE LE BATTEMENT A AVOUÉ TOUT SEUL (14h18) :
-- « inscription: operator does not exist: text <= timestamp with time zone »
-- Cause : profiles.available_from/until sont des colonnes TEXTE (héritage) et join_event les
-- comparait à ev.starts_at (timestamptz) → TOUTE inscription passant par la fenêtre profil pétait.
-- Fix minimal (rayon d'impact zéro) : cast ::timestamptz DANS la fonction. La preuve que la
-- philosophie v7 « montre-moi les erreurs » paie : 12 échecs affichés = diagnostic servi sur un plateau.
-- ═══════════════════════════════════════════════════════════════════════════════════════

create or replace function public.join_event(p_event_id uuid, p_actor uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare actor uuid; ev record; has_avail boolean; taken int; cap int;
begin
  actor := case when p_actor is not null and public.qa_is_admin() then p_actor else auth.uid() end;
  if actor is null then return jsonb_build_object('ok',false,'code','RLS_FORBIDDEN','message','Non connecté'); end if;

  select id, starts_at, coalesce(spots,8) as spots, coalesce(active,true) as active, created_by
    into ev from public.events where id = p_event_id;
  if ev.id is null then return jsonb_build_object('ok',false,'code','NOT_FOUND','message','Événement introuvable'); end if;
  if not ev.active then return jsonb_build_object('ok',false,'code','NOT_EVENT_VISIBLE','message','Événement non actif'); end if;
  if ev.created_by = actor then return jsonb_build_object('ok',false,'code','OWN_EVENT','message','C''est ton événement'); end if;
  if exists (select 1 from public.event_participants where event_id=p_event_id and user_id=actor) then
    return jsonb_build_object('ok',true,'code','ALREADY','message','Déjà inscrit'); end if;

  -- 🔑 RÈGLE DISPO↔EVENT (⚠️ cast : available_from/until sont TEXTE en base — piège découvert par le Battement v7)
  select exists(
    select 1 from public.availabilities a
      where a.user_id=actor and a.active and a.start_at <= ev.starts_at and a.end_at >= ev.starts_at
    union all
    select 1 from public.profiles p
      where p.id=actor and p.is_available and p.available_from is not null and p.available_until is not null
        and (p.available_from)::timestamptz <= ev.starts_at and (p.available_until)::timestamptz >= ev.starts_at
  ) into has_avail;
  if ev.starts_at is not null and not has_avail then
    return jsonb_build_object('ok',false,'code','NO_COMPATIBLE_AVAILABILITY','message','Tu n''es pas disponible à ce créneau — ajoute une dispo qui couvre cette heure');
  end if;

  select count(*) into taken from public.event_participants where event_id=p_event_id;
  cap := ev.spots;
  if taken < cap then
    insert into public.event_participants(event_id, user_id) values (p_event_id, actor) on conflict do nothing;
    return jsonb_build_object('ok',true,'code','JOINED','message','Inscrit ('||(taken+1)||'/'||cap||')');
  else
    insert into public.event_waitlist(event_id, user_id) values (p_event_id, actor) on conflict do nothing;
    return jsonb_build_object('ok',true,'code','WAITLISTED','message','Complet → liste d''attente');
  end if;
end; $$;

-- ═══════ 20260714a_ville_regles_humaines.sql ═══════
-- ═══════════════════════════════════════════════════════════════════════════════════════
-- 20260714a — LA VILLE SUIT LES RÈGLES DES HUMAINS (fournée debug David 14.07, 01h20) :
-- ① sim_tick v7.2 : FILTRE GENRE CROISÉ sur les clutchs de bots (bot→humain ET bot→bot) —
--    « Gaël ♂ m'a clutché alors que je cherche des femmes ». Miroir EXACT du client
--    (passesPresenceFilters) : looking_for ∈ {M,F,X} = filtre dur, ALL/mode/null = passe.
-- ② sim_tick v7.2 : la ville organise aussi des EVENTS LA NUIT (23h→2h, pool nocturne) —
--    David teste à 1h du matin et la création d'events était bloquée 23h→8h (« les bots ne
--    font aucun événement »). Zone morte conservée : 3h→7h (la ville dort un peu quand même).
-- ③ sim_seed v2.2 : PRÉNOM SEUL (plus jamais « Prénom Nom » réécrit à chaque re-semis) et
--    ≤ 8 caractères (Sébastien→Mathieu, règle Mel) + rattrapage immédiat des bots existants.
-- NB : admin_create_clutch (RPC God-mode du Test Lab) reste SANS filtre — c'est le cerveau de
--    la ville (sim_tick) qui suit les règles humaines, pas l'outil de laboratoire.
-- ═══════════════════════════════════════════════════════════════════════════════════════

-- ── ③ RATTRAPAGE IMMÉDIAT : prénoms seuls + ≤ 8 caractères sur les bots existants ──
update public.profiles set name = split_part(name, ' ', 1)
  where is_bot = true and position(' ' in coalesce(name,'')) > 0;
update public.profiles set name = (array['Mathieu','Simon','Marc','Bruno'])[1 + (abs(hashtext(id::text)) % 4)]
  where is_bot = true and length(coalesce(name,'')) > 8;

-- ── ① + ② sim_tick v7.2 (copie exacte de v7 + filtre genre croisé + events nocturnes) ──
create or replace function public.sim_tick() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  ctl record; b record; tr jsonb; arch text; h int; dow int; awake numeric; target int; online int;
  acted int := 0; published int := 0; answered int := 0; events int := 0; clutched int := 0; retired int := 0; revenge int := 0; joined int := 0; botclutch int := 0; accepted int := 0;
  ev record; other record; req record; curlat float8; curlng float8; mob numeric; rd record; closed int := 0;
  cl record; hum record; vx record; lat8 float8; lng8 float8; sm timestamptz; su timestamptz; radp int;
  bgen text; blook text;
  pool jsonb; pick jsonb; pubp numeric;
  fails int := 0; err_pub text; err_answer text; err_clutch text; err_bot text; err_join text; err_event text;
begin
  if not public.qa_is_admin() then return jsonb_build_object('ok',false,'code','RLS_FORBIDDEN'); end if;
  select * into ctl from public.sim_control where id = 1;
  if ctl is null or not ctl.running then return jsonb_build_object('ok',true,'skipped','off'); end if;
  h := extract(hour from now() at time zone 'Europe/Zurich')::int;
  dow := extract(isodow from now() at time zone 'Europe/Zurich')::int;
  target := round((case ctl.scene when 'A' then 25 when 'B' then 180 else 700 end) * ctl.density
            * (case when h between 17 and 22 then 1.0 when h between 12 and 16 then 0.6
                    when h between 7 and 11 then 0.4 else 0.25 end)
            * (case when dow in (4,5,6) then 1.5 else 1.0 end));
  select count(*) into online from public.profiles p join public.sim_bots s on s.bot_id=p.id
    where p.is_available = true and p.available_until > now();

  -- 🤝 la vie du Verrou : RDV passés clôturés, la fiabilité de chaque bot participant bouge toute seule
  for rd in select c.id, c.sender_id, c.receiver_id from public.clutches c
            where c.status in ('accepted','confirmed','checked_in')
              and coalesce(c.counter_time, c.proposed_time) is not null
              and coalesce(c.counter_time, c.proposed_time) + (coalesce(c.duration_minutes,60) * interval '1 minute') < now()
              and (exists(select 1 from public.sim_bots s where s.bot_id = c.sender_id)
                or  exists(select 1 from public.sim_bots s where s.bot_id = c.receiver_id))
            limit 120 loop
    begin
      update public.profiles p set reliability_score = greatest(0, least(100,
          coalesce(p.reliability_score,80) + (case when random() < (case coalesce(s.traits->>'fiab','ponctuel')
              when 'roc' then 0.98 when 'ponctuel' then 0.9 when 'retard' then 0.82 when 'annuleur' then 0.6 when 'noshow' then 0.15 else 0.85 end)
            then 1 else -5 end)))
        from public.sim_bots s
        where p.id = s.bot_id and p.id in (rd.sender_id, rd.receiver_id);
      update public.clutches set status = 'completed' where id = rd.id;
      closed := closed + 1;
    exception when others then fails := fails + 1; end;
  end loop;

  for b in select * from public.sim_bots where next_action_at <= now()
           and state not in ('churne') order by next_action_at limit 90 loop
    acted := acted + 1; tr := b.traits; arch := coalesce(tr->>'arch','occasionnelle');
    -- 🚻 v7.2 : le bot connait SON genre et CE QU'IL cherche (filtre croise, miroir exact du client)
    select (case when gender in ('woman','F','f') then 'F' when gender in ('man','M','m') then 'M' else 'X' end), looking_for
      into bgen, blook from public.profiles where id = b.bot_id;
    awake := case when (tr->>'chrono')='pendulaire' and (h between 7 and 9 or h between 17 and 19) then 1
                  when (tr->>'chrono')='pendulaire' then 0.15
                  when (tr->>'chrono')='matin' and h between 7 and 11 then 1
                  when (tr->>'chrono')='soir'  and (h >= 18 or h < 2) then 1
                  when (tr->>'chrono')='std'   and h between 11 and 22 then 1 else 0.3 end;
    update public.sim_bots set next_action_at = now() + ((8 + random()*35) / greatest(awake,0.1)) * interval '1 minute'
      where bot_id = b.bot_id;
    mob := case coalesce(tr->>'arch','x') when 'expat' then 0.9 when 'comete_arroseur' then 0.8
                when 'comete_engage' then 0.7 when 'organisatrice' then 0.6 when 'power' then 0.55
                when 'pendulaire' then 0.5 when 'dormeur' then 0.15 when 'timide' then 0.2
                when 'piliere' then 0.35 else 0.4 end;
    if (tr->>'chrono') = 'pendulaire' and h between 9 and 17 then
      curlat := (tr->>'work_lat')::float8 + (random()-0.5)*0.008; curlng := (tr->>'work_lng')::float8 + (random()-0.5)*0.012;
    elsif random() < mob then
      curlat := b.home_lat + (random()+random()-1) * mob * 0.045;
      curlng := b.home_lng + (random()+random()-1) * mob * 0.06;
    else
      curlat := b.home_lat + (random()-0.5)*0.006; curlng := b.home_lng + (random()-0.5)*0.008;
    end if;
    if b.state in ('pause','occupe') and random() < 0.85 then continue; end if;

    -- ① PUBLIER (filet propre : un échec ici n'annule plus le reste du bot)
    begin
      pubp := case arch when 'piliere' then 0.7 when 'comete_engage' then 0.8 when 'comete_arroseur' then 0.75
                        when 'power' then 0.6 when 'organisatrice' then 0.5 when 'timide' then 0.35
                        when 'occasionnelle' then (case when dow in (5,6,7) then 0.5 else 0.15 end)
                        when 'dormeur' then 0.08 when 'perdu' then 0.4 when 'pendulaire' then 0.6
                        when 'expat' then 0.55 when 'vexe' then 0.45 else 0.4 end;
      if online < target and random() < pubp * awake
         and not exists (select 1 from public.profiles where id=b.bot_id and is_available and available_until>now()) then
        sm := date_trunc('hour', now()) + (floor(random()*4)*interval '15 minutes');
        -- 🕐 v7.1 (bug David « 14h06 ») : le clamp « pas dans le passé » cassait l'arrondi ¼h → PROCHAIN quart d'heure.
        if sm < now() then sm := to_timestamp(ceil(extract(epoch from now())/900)*900); end if;
        su := sm + (interval '1 hour' * (case arch when 'pendulaire' then 1 + random()
                                                    when 'expat' then 1 + random()*2
                                                    when 'perdu' then 1 + random()*8
                                                    else 1.5 + random()*3.5 end));
        if su > now() + interval '17 hours' then su := now() + interval '17 hours'; end if;
        su := to_timestamp(round(extract(epoch from su)/900)*900);
        lat8 := (public.sim_dry(curlat, curlng))[1]; lng8 := curlng;
        radp := case arch when 'expat' then (array[15,20,25])[1+floor(random()*3)::int]
                          when 'perdu' then (array[1,2,40])[1+floor(random()*3)::int]
                          when 'pendulaire' then (array[3,5,8])[1+floor(random()*3)::int]
                          else (array[3,5,8,10,15])[1+floor(random()*5)::int] end;
        perform public.admin_set_availability(b.bot_id, sm, su, lat8, lng8, radp);
        perform public.sim_set_intent(b.bot_id);
        online := online + 1; published := published + 1;
      end if;
    exception when others then fails := fails + 1; err_pub := coalesce(err_pub, SQLERRM); end;

    -- ①bis 🫣 la timide retire son créneau quand on la clutch
    begin
      if arch = 'timide' and random() < 0.4
         and exists (select 1 from public.clutches c where c.receiver_id=b.bot_id and c.status='pending') then
        update public.profiles set is_available = false where id = b.bot_id and is_available = true;
        retired := retired + 1;
      end if;
    exception when others then fails := fails + 1; end;

    -- ② RÉPONDRE (latence + caractère ; certains ignorent → le clutch expirera)
    begin
      if not (random() < (case arch when 'dormeur' then 0.35 when 'timide' then 0.45 when 'perdu' then 0.4
                                    when 'occasionnelle' then 0.3 when 'indecise' then 0.25 else 0.06 end)) then
        for cl in select c.id, c.sender_id from public.clutches c
                  where c.receiver_id = b.bot_id and c.status = 'pending'
                    and c.created_at < now() - ((tr->>'latence_min')::int * interval '1 minute') limit 2 loop
          if random() < coalesce((tr->>'accept_p')::numeric, 0.4) then
            perform public.admin_accept_clutch(b.bot_id, cl.sender_id);
          else
            perform public.admin_refuse_clutch(b.bot_id, cl.sender_id);
          end if;
          answered := answered + 1;
        end loop;
      end if;
    exception when others then fails := fails + 1; err_answer := coalesce(err_answer, SQLERRM); end;

    -- ②bis 🎯 CLUTCHER UN HUMAIN (dose crédible ×2 — David « personne ne me clutch » ; throttle 25 min/humain)
    begin
      if b.state in ('actif','hyper_engage','hyper_arroseur')
         and random() < (case arch when 'comete_arroseur' then 0.16 when 'comete_engage' then 0.10
                                    when 'piliere' then 0.08 when 'timide' then 0.01 else 0.04 end) then
        select p.id into hum from public.profiles p
          where coalesce(p.is_bot,false) = false and p.is_available = true and p.available_until > now()
            and p.center_lat is not null
            and abs(p.center_lat - curlat) < 0.15 and abs(p.center_lng - curlng) < 0.2
            and not exists (select 1 from public.clutches c2 where c2.receiver_id = p.id and c2.created_at > now() - interval '25 minutes')
            and not exists (select 1 from public.clutches c3 where c3.sender_id = b.bot_id and c3.receiver_id = p.id and c3.created_at > now() - interval '24 hours')
            -- 🚻 v7.2 (bug David 14.07 « Gaël ♂ m'a clutché alors que je cherche des femmes ») :
            --    mêmes règles que les humains — il cherche → elle correspond, elle cherche → il correspond.
            and (coalesce(blook,'') not in ('M','F','X') or (case when p.gender in ('woman','F','f') then 'F' when p.gender in ('man','M','m') then 'M' else 'X' end) = blook)
            and (coalesce(p.looking_for,'') not in ('M','F','X') or p.looking_for = bgen)
          order by random() limit 1;
        if hum.id is not null then
          perform public.admin_create_clutch(b.bot_id, hum.id,
            (array['Un café ?','Une balade au bord du lac ?','Un verre en terrasse ?','Un ping-pong ?','Une glace ?'])[1+floor(random()*5)::int],
            to_timestamp(round(extract(epoch from now() + (interval '1 hour' * (0.75 + random()*2)))/900)*900),
            (array['On tente ? 🙂','Dispo si tu l''es','Ça te dit ?','Simple et sans pression'])[1+floor(random()*4)::int],
            60, b.home_lat, b.home_lng);
          clutched := clutched + 1;
        end if;
      end if;
    exception when others then fails := fails + 1; err_clutch := coalesce(err_clutch, SQLERRM); end;

    -- ②quater 🤝 CLUTCHER UN AUTRE BOT (dose ×2 — la ville s'anime d'elle-même)
    begin
      if b.state in ('actif','hyper_engage','hyper_arroseur','occasionnelle')
         and random() < (case arch when 'comete_arroseur' then 0.30 when 'comete_engage' then 0.22
                                    when 'piliere' then 0.18 when 'timide' then 0.04 else 0.12 end) * awake then
        select p.id into other from public.profiles p join public.sim_bots s2 on s2.bot_id = p.id
          where p.is_bot = true and p.id <> b.bot_id and p.is_available = true and p.available_until > now()
            and abs(p.center_lat - curlat) < 0.12 and abs(p.center_lng - curlng) < 0.16
            and not exists (select 1 from public.clutches c2 where c2.receiver_id = p.id and c2.sender_id = b.bot_id and c2.created_at > now() - interval '24 hours')
            and not exists (select 1 from public.clutches c3 where c3.sender_id = b.bot_id and c3.status = 'pending')
            and (coalesce(blook,'') not in ('M','F','X') or (case when p.gender in ('woman','F','f') then 'F' when p.gender in ('man','M','m') then 'M' else 'X' end) = blook)
            and (coalesce(p.looking_for,'') not in ('M','F','X') or p.looking_for = bgen)
          order by random() limit 1;
        if other.id is not null then
          perform public.admin_create_clutch(b.bot_id, other.id,
            (array['Un café ?','Une balade ?','Un verre ?','Un ping-pong ?','On se voit ?'])[1+floor(random()*5)::int],
            to_timestamp(round(extract(epoch from now() + (interval '1 hour' * (0.75 + random()*2)))/900)*900), 'Dispo maintenant 🙂', 60, b.home_lat, b.home_lng);
          botclutch := botclutch + 1;
        end if;
      end if;
    exception when others then fails := fails + 1; err_bot := coalesce(err_bot, SQLERRM); end;

    -- ⑤ 🎟️ REJOINDRE un event proche pas plein
    begin
      if b.state in ('actif','hyper_engage','occasionnelle','dormeur') and random() < 0.10 * awake then
        select e.id into ev from public.events e
          where e.active = true and e.status in ('pending','open') and e.starts_at > now()
            and coalesce(e.taken,0) < e.spots and e.created_by <> b.bot_id
            and e.venue_lat is not null and abs(e.venue_lat - curlat) < 0.2 and abs(e.venue_lng - curlng) < 0.25
            and not exists (select 1 from public.event_participants ep where ep.event_id = e.id and ep.user_id = b.bot_id)
          order by random() limit 1;
        if ev.id is not null then perform public.join_event(ev.id, b.bot_id); joined := joined + 1; end if;
      end if;
    exception when others then fails := fails + 1; err_join := coalesce(err_join, SQLERRM); end;

    -- ⑥ ✅ ACCEPTER les demandes à MES events (délai humain 5-45 min)
    begin
      if (tr->>'organise')::boolean then
        for req in select ep.event_id, ep.user_id from public.event_participants ep
                   join public.events e on e.id = ep.event_id
                   where e.created_by = b.bot_id and ep.state = 'requested'
                     and ep.created_at < now() - (5 + floor(random()*40)) * interval '1 minute'
                   limit 3 loop
          update public.event_participants set state = 'accepted' where event_id = req.event_id and user_id = req.user_id;
          accepted := accepted + 1;
        end loop;
      end if;
    exception when others then fails := fails + 1; end;

    -- ②ter 😤 le vexé retente (le cooldown serveur doit l'arrêter — c'est le test)
    begin
      if arch = 'vexe' and random() < 0.5 then
        select c.receiver_id into vx from public.clutches c
          where c.sender_id = b.bot_id and c.status in ('refused','declined','expired')
            and c.created_at > now() - interval '6 hours'
          order by c.created_at desc limit 1;
        if vx.receiver_id is not null then
          perform public.admin_create_clutch(b.bot_id, vx.receiver_id, 'Allez, un café quand même ?', to_timestamp(round(extract(epoch from now() + interval '90 minutes')/900)*900),
            'Je suis sûr qu''on s''entendrait bien', 60, b.home_lat, b.home_lng);
          revenge := revenge + 1;
        end if;
      end if;
    exception when others then fails := fails + 1; end;

    -- ③ 🎟️ ORGANISER un event (organise ~1/10 — RALLUMÉ 13.07 ; max 1 event FUTUR par organisateur)
    begin
      if (tr->>'organise')::boolean and random() < 0.06 and not (h between 3 and 7)
         and not exists (select 1 from public.events e where e.created_by = b.bot_id and e.active and e.starts_at > now()) then
        pool := case when h >= 23 or h < 3 then '[["🌙","Verre de minuit"],["🎲","Soirée jeux tardive"],["🍕","Pizza de minuit"]]'::jsonb
                     when h < 11 then '[["☕","Café-croissants"],["🥾","Balade matinale"]]'::jsonb
                     when h < 14 then '[["🥗","Lunch ensemble"],["♟️","Échecs au parc"]]'::jsonb
                     when h < 17 then '[["🎨","Atelier croquis"],["🚴","Sortie vélo"]]'::jsonb
                     else '[["🍹","Apéro spontané"],["🎲","Soirée jeux"],["🏐","Beach-volley"]]'::jsonb end;
        pick := pool->floor(random()*jsonb_array_length(pool))::int;
        sm := now() + (interval '1 hour' * (1 + random()*3));
        if not (extract(hour from sm at time zone 'Europe/Zurich') between 3 and 8) then
          lat8 := (public.sim_dry(b.home_lat + (random()-0.5)*0.008, b.home_lng))[1];
          perform public.admin_create_event(b.bot_id,
            (pick->>0)||' '||(pick->>1)||' — '||coalesce(b.town,'Lausanne'),
            sm, lat8, b.home_lng + (random()-0.5)*0.012,
            4 + floor(random()*8)::int);
          events := events + 1;
        end if;
      end if;
    exception when others then fails := fails + 1; err_event := coalesce(err_event, SQLERRM); end;

  end loop;
  return jsonb_build_object('ok',true,'acted',acted,'published',published,'answered',answered,
    'clutched',clutched,'botclutch',botclutch,'joined',joined,'accepted',accepted,'rdv_clos',closed,'revenge',revenge,'retired',retired,'events',events,'online',online,'target',target,
    'fails',fails,'err_pub',err_pub,'err_answer',err_answer,'err_clutch',err_clutch,'err_bot',err_bot,'err_join',err_join,'err_event',err_event);
end; $$;

-- ── ③ sim_seed v2.2 (prénom seul ≤ 8, plus de nom de famille au re-semis) ──
create or replace function public.sim_seed(p_n int default 15000) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  towns constant jsonb := '[
    ["Lausanne",46.5197,6.6323,28],["Genève",46.2044,6.1432,26],["Fribourg",46.8065,7.1619,8],
    ["Neuchâtel",46.9920,6.9310,7],["Sion",46.2331,7.3606,6],["Yverdon",46.7785,6.6411,5],
    ["Montreux",46.4312,6.9107,4],["Vevey",46.4628,6.8419,4],["Renens",46.5399,6.5882,4],
    ["Nyon",46.3832,6.2396,4],["Morges",46.5093,6.4983,3],["Bulle",46.6194,7.0567,3],
    ["Martigny",46.1027,7.0724,3],["La Chaux-de-Fonds",47.0999,6.8259,3],["Payerne",46.8220,6.9380,2],
    ["Aigle",46.3167,6.9667,2],["Gland",46.4212,6.2704,2],["Echallens",46.6410,6.6350,1],
    ["Moudon",46.6670,6.7980,1],["Romont",46.6960,6.9190,1]
  ]'::jsonb;
  archs constant jsonb := '[["piliere",5],["comete_engage",3],["comete_arroseur",2],["organisatrice",4],
    ["power",5],["timide",8],["occasionnelle",18],["dormeur",20],["perdu",8],["indecise",7],
    ["noshow",5],["vexe",2],["pendulaire",7],["expat",4],["couple",2]]'::jsonb;
  pf constant text[] := array['Chloé','Léa','Manon','Sarah','Emma','Julie','Camille','Inès','Laura','Nina','Alice','Zoé','Sophie','Anaïs','Elodie','Marie','Clara','Jade','Lucie','Océane','Noémie','Aurélie','Fanny','Célia'];
  pm constant text[] := array['Lucas','Hugo','Théo','Noah','Maxime','Adrien','Nathan','Yanis','Marco','Ethan','Robin','Ivan','Julien','Quentin','Loïc','Bastien','Kevin','Damien','Nicolas','Antoine','Romain','Gaël','Mathieu','Florian'];
  totw numeric; tota numeric; t jsonb; a jsonb; r numeric; b record; n_done int := 0;
  arch text; chrono text; st text; tlat float8; tlng float8; tname text; acceptp numeric; latmin int; organise boolean;
  g text; nom text; age2 int;
begin
  if not public.qa_is_admin() then return jsonb_build_object('ok',false,'code','RLS_FORBIDDEN'); end if;
  select sum((e->>3)::numeric) into totw from jsonb_array_elements(towns) e;
  select sum((e->>1)::numeric) into tota from jsonb_array_elements(archs) e;
  for b in select id, gender from public.profiles where is_bot = true limit p_n loop
    r := random()*totw; for t in select e from jsonb_array_elements(towns) e loop r := r-(t->>3)::numeric; if r<=0 then exit; end if; end loop;
    tname := t->>0; tlat := (t->>1)::float8 + (random()-0.5)*0.016; tlng := (t->>2)::float8 + (random()-0.5)*0.02;
    r := random()*tota; for a in select e from jsonb_array_elements(archs) e loop r := r-(a->>1)::numeric; if r<=0 then exit; end if; end loop;
    arch := a->>0;
    chrono := case arch when 'pendulaire' then 'pendulaire' when 'piliere' then 'std' else (array['matin','std','std','soir','soir'])[1+floor(random()*5)::int] end;
    acceptp := case arch when 'piliere' then 0.6 when 'comete_engage' then 0.65 when 'comete_arroseur' then 0.7 when 'power' then 0.3 when 'timide' then 0.3 when 'dormeur' then 0.15 when 'noshow' then 0.85 when 'indecise' then 0.5 when 'vexe' then 0.5 else 0.35+random()*0.2 end;
    latmin := case arch when 'comete_engage' then 4+floor(random()*8)::int when 'comete_arroseur' then 3+floor(random()*5)::int when 'piliere' then 15+floor(random()*40)::int when 'indecise' then 150+floor(random()*90)::int when 'dormeur' then 120+floor(random()*300)::int else 10+floor(random()*60)::int end;
    organise := arch='organisatrice' or (arch='piliere' and random()<0.4);
    st := case arch when 'dormeur' then 'pause' when 'occasionnelle' then (case when random()<0.5 then 'occupe' else 'actif' end) when 'comete_engage' then 'hyper_engage' when 'comete_arroseur' then 'hyper_arroseur' else 'actif' end;
    insert into public.sim_bots (bot_id, traits, state, home_lat, home_lng, town, next_action_at)
    values (b.id, jsonb_build_object('arch',arch,'chrono',chrono,
        'fiab',case arch when 'noshow' then 'noshow' when 'piliere' then 'roc' when 'indecise' then 'annuleur' when 'perdu' then 'retard' else (array['roc','ponctuel','ponctuel','retard'])[1+floor(random()*4)::int] end,
        'organise',organise,'accept_p',acceptp,'latence_min',latmin,'work_lat',46.5197+(random()-0.5)*0.01,'work_lng',6.6323+(random()-0.5)*0.014),
      st, tlat, tlng, tname, now()+(random()*interval '20 minutes'))
    on conflict (bot_id) do update set traits=excluded.traits, home_lat=excluded.home_lat, home_lng=excluded.home_lng, town=excluded.town;
    -- 👤 vrai prénom + nom + âge ENTIER (David : « fais-moi au moins des noms »)
    g := coalesce(b.gender,'man');
    -- 👤 v2.2 (David 14.07) : PRENOM SEUL, ≤ 8 caractères (règle Mel) — bots = mêmes règles que les humains.
    nom := case when g in ('woman','F','f') then pf[1+floor(random()*array_length(pf,1))::int] else pm[1+floor(random()*array_length(pm,1))::int] end;
    age2 := 22 + floor(random()*24)::int;
    update public.profiles set name = nom, age = age2, center_lat = tlat, center_lng = tlng where id = b.id;
    n_done := n_done + 1;
  end loop;
  return jsonb_build_object('ok',true,'seeded',n_done);
end; $$;

-- ═══════ 20260714b_venue_stats.sql ═══════
-- ═══════════════════════════════════════════════════════════════════════════════════════
-- 20260714b — VENUE STATS (idée business David 14.07 02h10, dictée « argument de vente ») :
-- compter, PAR LIEU, combien de fois il a été PROPOSÉ (chip affichée) / CHOISI (chip tapée) /
-- ENVOYÉ (clutch parti avec ce lieu) / ACCEPTÉ (verrou posé sur ce lieu).
-- C'est la donnée qui vendra les emplacements « lieux partenaires » plus tard :
-- « ton café a été proposé 412×, choisi 87×, a généré 23 rendez-vous ce mois ».
-- LPD : agrégé PAR LIEU uniquement — AUCUN id utilisateur, aucune paire, aucune trace de QUI
-- s'est rencontré où. Lecture réservée aux admins (donnée business).
-- Champ is_partner posé dès maintenant (défaut false) : le jour des partenaires, on marque —
-- MAIS règle éthique gravée : un lieu partenaire mis en avant sera TOUJOURS étiqueté dans l'UI
-- (anti-dark-pattern), et ne contourne JAMAIS la zone/inZone (l'équité du lieu prime sur l'ad).
-- ═══════════════════════════════════════════════════════════════════════════════════════

create table if not exists public.venue_stats (
  id         text primary key,                 -- lower(nom) @ lat/lng arrondis 3 déc. (~110 m)
  name       text not null,
  lat        double precision,
  lng        double precision,
  proposed   int not null default 0,
  picked     int not null default 0,
  sent       int not null default 0,
  accepted   int not null default 0,
  is_partner boolean not null default false,
  updated_at timestamptz not null default now()
);

alter table public.venue_stats enable row level security;

-- Lecture : admins uniquement (donnée business). Aucune policy d'écriture : tout passe par la RPC.
drop policy if exists venue_stats_admin_read on public.venue_stats;
create policy venue_stats_admin_read on public.venue_stats
  for select using (public.qa_is_admin());

-- RPC d'incrément — SECURITY DEFINER, champ whitelisté, clé normalisée. Comptage best-effort :
-- jamais d'erreur remontée au client (un compteur ne doit jamais casser un envoi de Clutch).
create or replace function public.venue_stat_bump(
  p_name text, p_lat double precision default null, p_lng double precision default null, p_field text default 'proposed'
) returns void language plpgsql security definer set search_path = public as $$
declare k text;
begin
  if auth.uid() is null then return; end if;                                  -- humains connectés seulement
  if p_field not in ('proposed','picked','sent','accepted') then return; end if;
  if p_name is null or length(trim(p_name)) < 2 or length(trim(p_name)) > 120 then return; end if;
  k := lower(trim(p_name)) || '@' || coalesce(round(p_lat::numeric,3)::text,'?') || ',' || coalesce(round(p_lng::numeric,3)::text,'?');
  insert into public.venue_stats (id, name, lat, lng) values (k, trim(p_name), p_lat, p_lng)
    on conflict (id) do nothing;
  execute format('update public.venue_stats set %I = %I + 1, updated_at = now() where id = $1', p_field, p_field) using k;
exception when others then return;   -- best-effort assumé
end; $$;

grant execute on function public.venue_stat_bump(text,double precision,double precision,text) to authenticated;

-- ═══════ 20260714c_moderation_log.sql ═══════
-- 🛡️ 20260714c — Journal de modération IA (spec docs/spec-moderation-ia-14jul.md §3.3)
-- Décision David 14.07 : tolérance zéro + « montre-moi les erreurs, pas quand ça marche ».
-- Chaque appel à l'edge fn moderate-photo écrit une ligne (verdict + catégories, JAMAIS l'image).
-- Sert à : ① mesurer le taux de refus / faux positifs ② rate-limiter (200 appels/24h/user)
-- ③ futur dashboard d'erreurs (V1.1). Best-effort : la modération marche même sans cette table.

create table if not exists public.moderation_log (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  surface text not null default 'unknown',          -- 'profile_photos' | 'avatar' | 'onboarding' | 'extra_photo' | 'event_photo'
  verdict text not null check (verdict in ('ok','refuse')),
  categories text[] not null default '{}',          -- ex. {sexual_nudity} — la trace exacte, jamais de refus silencieux (mineurs = obligation légale)
  model text,
  created_at timestamptz not null default now()
);

create index if not exists moderation_log_user_day on public.moderation_log (user_id, created_at desc);

-- RLS : personne ne lit/écrit côté client — seule l'edge fn (service role) y touche.
alter table public.moderation_log enable row level security;

-- Vérification ✅/❌
do $$ begin
  if exists (select 1 from information_schema.tables where table_schema='public' and table_name='moderation_log') then
    raise notice '✅ moderation_log créée';
  else
    raise notice '❌ moderation_log ABSENTE';
  end if;
end $$;

-- ═══════ 20260714d_clutch_vs_occupancy.sql ═══════
-- 🏰 FORTERESSE À L'ENVOI (David 14.07, vague 4 : « inscrit et validé à un event 10h-13h, il est 10h30,
--    et je peux encore proposer un Clutch à 11h — ça ne joue pas »).
-- Le trou : les occupancies (Verrou confirmé, event accepté — triggers 20260626/20260709/20260710) ne
-- sont vérifiées qu'à l'ACCEPT (contrainte d'exclusion) — create_clutch laissait partir un pending
-- condamné d'avance (l'accept aurait explosé en OVERLAP_OCCUPANCY chez l'AUTRE, au pire moment).
-- Fix : create_clutch refuse si MOI (l'envoyeur) ai déjà un engagement qui chevauche [heure, heure+durée].
-- ⚠️ VOLONTAIREMENT PAS de vérification côté RECEVEUR : répondre « occupé·e à 11h mais pas à 14h » à des
--    envois répétés = un ORACLE de son agenda (leçon SEND_ORACLE 03.07). Son conflit éventuel se règle à
--    l'accept (contrainte) / au pending « en pause » côté client — rien ne fuite.
-- Le message embarque l'heure de fin (« sender_busy until 13:00 ») → le client guide : « libre dès 13:00 ».
create or replace function public.create_clutch(
  p_receiver uuid, p_venue text, p_proposed_time timestamptz, p_message text,
  p_duration_minutes int default null, p_is_quick boolean default false,
  p_venue_lat double precision default null, p_venue_lng double precision default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); pair record; new_id uuid; rcap int; rcount int; tgt record;
        zone_cnt int; tlat double precision; tlng double precision; trad double precision;
        my_busy_until timestamptz;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  if me = p_receiver then raise exception 'self_clutch'; end if;
  if exists (select 1 from public.blocks where (blocker_id=me and blocked_id=p_receiver) or (blocker_id=p_receiver and blocked_id=me)) then
    raise exception 'blocked';
  end if;
  -- Heure déjà passée (> 15 min) : un RDV dans le passé n'existe pas.
  if p_proposed_time is not null and p_proposed_time < now() - interval '15 minutes' then
    raise exception 'invalid_time';
  end if;
  -- 🏰 NOUVEAU : MON agenda d'abord — un engagement confirmé (Verrou, event accepté) occupe la fenêtre.
  if p_proposed_time is not null then
    select max(o.end_at) into my_busy_until
      from public.occupancies o
     where o.user_id = me
       and o.start_at < p_proposed_time + make_interval(mins => coalesce(p_duration_minutes, 120))
       and p_proposed_time < o.end_at;
    if my_busy_until is not null then
      raise exception 'sender_busy until %', to_char(my_busy_until at time zone 'Europe/Zurich', 'HH24:MI');
    end if;
  end if;
  -- La cible doit avoir une fenêtre OUVERTE (vérité serveur).
  select is_available, available_until into tgt from public.profiles where id = p_receiver;
  if tgt is null or not coalesce(tgt.is_available,false) or tgt.available_until is null or tgt.available_until <= now() then
    raise exception 'target_unavailable';
  end if;
  -- GARDE ZONE (bug David 04.07) : le lieu proposé doit tomber dans une fenêtre active du receveur.
  if p_venue_lat is not null and p_venue_lng is not null then
    select count(*) into zone_cnt from public.availabilities a
     where a.user_id = p_receiver and a.active = true and a.end_at > now() and a.lat is not null and a.lng is not null;
    if zone_cnt > 0 then
      if not exists (
        select 1 from public.availabilities a
         where a.user_id = p_receiver and a.active = true and a.end_at > now() and a.lat is not null and a.lng is not null
           and public.hav_km(round(a.lat/0.01)*0.01, round(a.lng/0.01)*0.01, p_venue_lat, p_venue_lng)
               <= coalesce(a.radius_km, 3) * 1.25 + 1.5
      ) then
        raise exception 'target_out_of_zone';
      end if;
    else
      select center_lat, center_lng, available_radius_km into tlat, tlng, trad from public.profiles where id = p_receiver;
      if tlat is not null and tlng is not null and trad is not null
         and public.hav_km(round(tlat/0.01)*0.01, round(tlng/0.01)*0.01, p_venue_lat, p_venue_lng) > trad * 1.25 + 1.5 then
        raise exception 'target_out_of_zone';
      end if;
    end if;
  end if;
  -- Cooldown de refus (table pairwise)
  select * into pair from public.clutch_pairs where actor_id = me and target_id = p_receiver;
  if pair.cooldown_until is not null and pair.cooldown_until > now() then raise exception 'cooldown'; end if;
  -- Anti-doublon par paire
  if exists (select 1 from public.clutches where status in ('pending','accepted','confirmed','checked_in')
             and ((sender_id=me and receiver_id=p_receiver) or (sender_id=p_receiver and receiver_id=me))) then
    raise exception 'pair_busy';
  end if;
  -- Plafond de réception
  select coalesce(max_received_clutchs, 5) into rcap from public.profiles where id = p_receiver;
  select count(*) into rcount from public.clutches where receiver_id = p_receiver and status = 'pending';
  if rcount >= coalesce(rcap, 5) then raise exception 'inbox_full'; end if;
  insert into public.clutches (sender_id, receiver_id, venue, venue_lat, venue_lng, proposed_time, message, duration_minutes, is_quick_date, status)
  values (me, p_receiver, p_venue, p_venue_lat, p_venue_lng, p_proposed_time, p_message, p_duration_minutes, p_is_quick, 'pending')
  returning id into new_id;
  return new_id;
end; $$;

-- ✅ vérification : la fonction existe et contient la garde
do $$ begin
  if position('sender_busy' in pg_get_functiondef('public.create_clutch(uuid,text,timestamptz,text,int,boolean,double precision,double precision)'::regprocedure)) = 0 then
    raise exception '❌ garde sender_busy absente';
  end if;
  raise notice '✅ create_clutch + forteresse à l''envoi (sender_busy) en place';
end $$;

-- ═══════ 20260714e_dedup_interets_bots.sql ═══════
-- 🧩 20260714e — DÉDUP des intérêts des bots (bug David 14.07 11h06 : fiche Sarah, « Musique » × 2).
-- Cause : l'enrichissement v7 (20260713m) piochait les intérêts au hasard SANS dédoublonner.
-- L'affichage est déjà dédoublonné côté client (pansement) ; ceci guérit LA DONNÉE (cause racine).
update public.profiles p
set interests = (select array_agg(distinct i) from unnest(p.interests) i)
where p.is_bot = true
  and p.interests is not null
  and array_length(p.interests, 1) > (select count(distinct i) from unnest(p.interests) i);

