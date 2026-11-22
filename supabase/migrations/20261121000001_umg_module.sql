-- =====================================================================
-- MODUL UMG (Universal Mobile Mapping GIS) di Platform Inti — TAHAP 1
-- Tabel baru berawalan umg2_ (tabel lama umg_ TIDAK disentuh).
--   umg2_members   role khusus UMG per anggota (opsional)
--   umg2_settings  judul, warna, logo, peta dasar per organisasi
--   umg2_projects  proyek
--   umg2_layers    layer + skema formulir + gaya simbol
--   umg2_features  data lapangan (PostGIS) + atribut, foto, GPS, review
--   umg2_conflicts catatan bentrok sinkron offline
--   umg2_sync_ops  kwitansi operasi sinkron (anti data ganda)
-- Aman dijalankan ulang.
-- =====================================================================

insert into public.apps (code, name, description, category, status, icon, default_trial_days, sort)
values ('umg', 'Universal Mobile Mapping GIS', 'Pemetaan lapangan offline-first: proyek, layer, formulir, review, cetak peta', 'GIS', 'dev', '🧭', 30, 15)
on conflict (code) do update set name = excluded.name, description = excluded.description, icon = excluded.icon;

-- ---------------------------------------------------------------------
-- ROLE UMG: admin · supervisor · surveyor · viewer
-- Bila tidak diatur di umg2_members, diturunkan dari role Platform Inti:
--   owner/admin → admin, editor → surveyor, viewer → viewer
-- ---------------------------------------------------------------------
create table if not exists public.umg2_members (
  org_id      uuid not null,
  user_id     uuid not null,
  role        text not null check (role in ('admin', 'supervisor', 'surveyor', 'viewer')),
  updated_at  timestamptz not null default now(),
  primary key (org_id, user_id),
  foreign key (org_id, user_id) references public.memberships(org_id, user_id) on delete cascade
);

create or replace function public.umg2_role(p_org uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce(
    (select role from umg2_members where org_id = p_org and user_id = auth.uid()),
    (select case m.role when 'owner' then 'admin' when 'admin' then 'admin'
                        when 'editor' then 'surveyor' else 'viewer' end
       from memberships m where m.org_id = p_org and m.user_id = auth.uid()));
$$;

-- Izin persis seperti PERMS di versi GAS (00_Config.gs)
create or replace function public.umg2_can(p_org uuid, p_perm text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.has_license(p_org, 'umg') and case public.umg2_role(p_org)
    when 'admin' then true
    when 'supervisor' then p_perm = any (array['project.write','layer.write','feature.read','feature.write.any',
                                               'feature.review','audit.read','export'])
    when 'surveyor' then p_perm = any (array['feature.read','feature.write.own','export'])
    when 'viewer' then p_perm = any (array['feature.read','export'])
    else false end, false);
$$;

-- ---------------------------------------------------------------------
-- PENGATURAN per organisasi (pengganti sheet Config)
-- ---------------------------------------------------------------------
create table if not exists public.umg2_settings (
  org_id      uuid primary key references public.organizations(id) on delete cascade,
  settings    jsonb not null default '{}'::jsonb,
  updated_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- PROYEK / LAYER / FITUR
-- id tetap TEKS seperti versi lama, karena id dipakai di dalam skema
-- formulir (relasi antar-layer, hitung otomatis). Tidak boleh diubah.
-- ---------------------------------------------------------------------
create table if not exists public.umg2_projects (
  id           text primary key check (id ~ '^[A-Za-z0-9_-]{1,64}$'),
  org_id       uuid not null references public.organizations(id) on delete cascade,
  name         text not null,
  description  text not null default '',
  work_area    jsonb,                                   -- GeoJSON batas area kerja
  status       text not null default 'active',
  created_by   uuid,
  legacy_created_by text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  deleted      boolean not null default false
);
create index if not exists umg2_projects_org on public.umg2_projects(org_id);

create table if not exists public.umg2_layers (
  id           text primary key check (id ~ '^[A-Za-z0-9_-]{1,64}$'),
  org_id       uuid not null references public.organizations(id) on delete cascade,
  project_id   text not null references public.umg2_projects(id) on delete cascade,
  name         text not null,
  geom_type    text not null check (geom_type in ('Point', 'LineString', 'Polygon', 'None')),
  srid         text not null default '4326',
  schema       jsonb not null default '[]'::jsonb,      -- daftar atribut formulir
  style        jsonb not null default '{}'::jsonb,      -- warna, simbol, label, klasifikasi
  version      int  not null default 1,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  deleted      boolean not null default false
);
create index if not exists umg2_layers_org on public.umg2_layers(org_id);
create index if not exists umg2_layers_project on public.umg2_layers(project_id);

create table if not exists public.umg2_features (
  id           text primary key check (id ~ '^[A-Za-z0-9_-]{1,64}$'),
  org_id       uuid not null references public.organizations(id) on delete cascade,
  project_id   text not null references public.umg2_projects(id) on delete cascade,
  layer_id     text not null references public.umg2_layers(id) on delete cascade,
  geom_type    text not null,
  -- 2D atau 3D (ketinggian RTK dipertahankan); null untuk layer tabel (None)
  geom         extensions.geometry check (geom is null or extensions.ST_SRID(geom) = 4326),
  bbox         jsonb,
  attrs        jsonb not null default '{}'::jsonb,
  photos       jsonb not null default '[]'::jsonb,      -- ref foto (drive:… lama / storage:… baru)
  gps          jsonb,
  metrics      jsonb not null default '{}'::jsonb,
  status       text not null default 'draft'
               check (status in ('draft', 'submitted', 'approved', 'revision', 'rejected')),
  version      int  not null default 1,
  created_by   uuid,
  updated_by   uuid,
  review_by    uuid,
  legacy_created_by text,
  legacy_updated_by text,
  legacy_review_by  text,
  review_note  text not null default '',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  deleted      boolean not null default false
);
create index if not exists umg2_features_geom  on public.umg2_features using gist (geom);
create index if not exists umg2_features_layer on public.umg2_features(layer_id) where not deleted;
create index if not exists umg2_features_org   on public.umg2_features(org_id);
create index if not exists umg2_features_attrs on public.umg2_features using gin (attrs);

create table if not exists public.umg2_conflicts (
  id              text primary key,
  org_id          uuid not null references public.organizations(id) on delete cascade,
  feature_id      text not null,
  user_id         uuid,
  legacy_user_id  text,
  base_version    int not null default 0,
  server_version  int not null default 0,
  status          text not null default 'open',
  created_at      timestamptz not null default now()
);
create index if not exists umg2_conflicts_org on public.umg2_conflicts(org_id, status);

create table if not exists public.umg2_sync_ops (
  op_id       text primary key,
  org_id      uuid not null references public.organizations(id) on delete cascade,
  user_id     uuid,
  legacy_user_id text,
  entity_id   text,
  result      jsonb,
  created_at  timestamptz not null default now()
);
create index if not exists umg2_sync_ops_org on public.umg2_sync_ops(org_id, created_at);

-- Org fitur = org layer, proyek = proyek layer (cegah data salah organisasi)
create or replace function public.umg2_features_before()
returns trigger language plpgsql set search_path = public, extensions as $$
declare v_org uuid; v_project text;
begin
  select org_id, project_id into v_org, v_project from umg2_layers where id = new.layer_id;
  if v_org is null then raise exception 'Layer tidak ditemukan'; end if;
  new.org_id := v_org;
  new.project_id := v_project;
  if new.geom is not null and not ST_IsValid(new.geom) then new.geom := ST_MakeValid(new.geom); end if;
  return new;
end $$;
drop trigger if exists umg2_features_before on public.umg2_features;
create trigger umg2_features_before before insert or update on public.umg2_features
  for each row execute function public.umg2_features_before();

create or replace function public.umg2_layers_before()
returns trigger language plpgsql set search_path = public as $$
declare v_org uuid;
begin
  select org_id into v_org from umg2_projects where id = new.project_id;
  if v_org is null then raise exception 'Proyek tidak ditemukan'; end if;
  new.org_id := v_org;
  return new;
end $$;
drop trigger if exists umg2_layers_before on public.umg2_layers;
create trigger umg2_layers_before before insert or update on public.umg2_layers
  for each row execute function public.umg2_layers_before();

-- Audit otomatis ke audit_log Platform Inti
drop trigger if exists umg2_projects_audit on public.umg2_projects;
create trigger umg2_projects_audit after insert or update or delete on public.umg2_projects
  for each row execute function public.audit_trigger();
drop trigger if exists umg2_layers_audit on public.umg2_layers;
create trigger umg2_layers_audit after insert or update or delete on public.umg2_layers
  for each row execute function public.audit_trigger();
drop trigger if exists umg2_features_audit on public.umg2_features;
create trigger umg2_features_audit after insert or update or delete on public.umg2_features
  for each row execute function public.audit_trigger();

-- =====================================================================
-- KEAMANAN (RLS) — meniru aturan izin versi GAS
-- =====================================================================
alter table public.umg2_members   enable row level security;
alter table public.umg2_settings  enable row level security;
alter table public.umg2_projects  enable row level security;
alter table public.umg2_layers    enable row level security;
alter table public.umg2_features  enable row level security;
alter table public.umg2_conflicts enable row level security;
alter table public.umg2_sync_ops  enable row level security;

-- anggota & pengaturan
drop policy if exists umg2_members_select on public.umg2_members;
create policy umg2_members_select on public.umg2_members for select to authenticated using (public.is_member(org_id));
drop policy if exists umg2_members_write on public.umg2_members;
create policy umg2_members_write on public.umg2_members for all to authenticated
  using (public.umg2_role(org_id) = 'admin') with check (public.umg2_role(org_id) = 'admin');

drop policy if exists umg2_settings_select on public.umg2_settings;
create policy umg2_settings_select on public.umg2_settings for select to authenticated using (public.is_member(org_id));
drop policy if exists umg2_settings_write on public.umg2_settings;
create policy umg2_settings_write on public.umg2_settings for all to authenticated
  using (public.umg2_role(org_id) = 'admin') with check (public.umg2_role(org_id) = 'admin');

-- proyek & layer: baca = feature.read, tulis = project.write / layer.write
drop policy if exists umg2_projects_select on public.umg2_projects;
create policy umg2_projects_select on public.umg2_projects for select to authenticated
  using (public.umg2_can(org_id, 'feature.read'));
drop policy if exists umg2_projects_write on public.umg2_projects;
create policy umg2_projects_write on public.umg2_projects for all to authenticated
  using (public.umg2_can(org_id, 'project.write')) with check (public.umg2_can(org_id, 'project.write'));

drop policy if exists umg2_layers_select on public.umg2_layers;
create policy umg2_layers_select on public.umg2_layers for select to authenticated
  using (public.umg2_can(org_id, 'feature.read'));
drop policy if exists umg2_layers_write on public.umg2_layers;
create policy umg2_layers_write on public.umg2_layers for all to authenticated
  using (public.umg2_can(org_id, 'layer.write')) with check (public.umg2_can(org_id, 'layer.write'));

-- fitur: surveyor hanya data miliknya yang belum disetujui
drop policy if exists umg2_features_select on public.umg2_features;
create policy umg2_features_select on public.umg2_features for select to authenticated
  using (public.umg2_can(org_id, 'feature.read'));
drop policy if exists umg2_features_insert on public.umg2_features;
create policy umg2_features_insert on public.umg2_features for insert to authenticated
  with check (public.umg2_can(org_id, 'feature.write.any')
              or (public.umg2_can(org_id, 'feature.write.own') and created_by = auth.uid()
                  and status in ('draft', 'submitted')));
drop policy if exists umg2_features_update on public.umg2_features;
create policy umg2_features_update on public.umg2_features for update to authenticated
  using (public.umg2_can(org_id, 'feature.write.any')
         or (public.umg2_can(org_id, 'feature.write.own') and created_by = auth.uid()
             and status in ('draft', 'revision', 'submitted')))
  with check (public.umg2_can(org_id, 'feature.write.any')
              or (public.umg2_can(org_id, 'feature.write.own') and created_by = auth.uid()
                  and status in ('draft', 'submitted')));
-- hapus = soft delete (deleted=true) lewat UPDATE; hapus permanen hanya admin
drop policy if exists umg2_features_delete on public.umg2_features;
create policy umg2_features_delete on public.umg2_features for delete to authenticated
  using (public.umg2_role(org_id) = 'admin');

drop policy if exists umg2_conflicts_select on public.umg2_conflicts;
create policy umg2_conflicts_select on public.umg2_conflicts for select to authenticated
  using (public.umg2_can(org_id, 'feature.read'));
drop policy if exists umg2_sync_ops_select on public.umg2_sync_ops;
create policy umg2_sync_ops_select on public.umg2_sync_ops for select to authenticated
  using (user_id = auth.uid() or public.umg2_can(org_id, 'audit.read'));
-- conflicts & sync_ops ditulis oleh fungsi server (Tahap 2), bukan langsung oleh aplikasi

-- =====================================================================
-- BENTUK DATA UNTUK TAMPILAN (sama persis dengan pubFeature/pubLayer GAS)
-- =====================================================================
create or replace function public.umg2_pub_feature(f public.umg2_features)
returns jsonb language sql stable set search_path = public, extensions as $$
  select jsonb_build_object(
    'id', f.id, 'project_id', f.project_id, 'layer_id', f.layer_id, 'geom_type', f.geom_type,
    'geometry', case when f.geom is null then null else ST_AsGeoJSON(f.geom, 9)::jsonb end,
    'bbox', f.bbox, 'attrs', f.attrs, 'photos', f.photos, 'gps', f.gps, 'metrics', f.metrics,
    'status', f.status, 'version', f.version,
    'created_by', coalesce(f.created_by::text, f.legacy_created_by, ''),
    'updated_by', coalesce(f.updated_by::text, f.legacy_updated_by, ''),
    'created_at', f.created_at, 'updated_at', f.updated_at,
    'review_by', coalesce(f.review_by::text, f.legacy_review_by, ''), 'review_note', f.review_note,
    'deleted', f.deleted);
$$;

create or replace function public.umg2_pub_layer(l public.umg2_layers)
returns jsonb language sql stable as $$
  select jsonb_build_object('id', l.id, 'project_id', l.project_id, 'name', l.name, 'geom_type', l.geom_type,
    'srid', l.srid, 'schema', l.schema, 'style', l.style, 'version', l.version, 'updated_at', l.updated_at);
$$;

create or replace function public.umg2_pub_project(p public.umg2_projects)
returns jsonb language sql stable as $$
  select jsonb_build_object('id', p.id, 'name', p.name, 'description', p.description, 'status', p.status,
    'work_area', p.work_area, 'updated_at', p.updated_at);
$$;

grant execute on function public.umg2_role(uuid) to authenticated;
grant execute on function public.umg2_can(uuid, text) to authenticated;
