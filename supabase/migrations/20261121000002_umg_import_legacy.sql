-- =====================================================================
-- MODUL UMG — 002 FUNGSI PEMINDAHAN DATA DARI TABEL LAMA (umg_)
-- Membuat fungsi saja; pemindahan baru terjadi saat Anda menjalankan:
--
--   select public.umg2_import_legacy(
--     '<ORG_ID organisasi tujuan>',
--     'email-anda@contoh.com'      -- akun Platform Inti untuk user admin lama
--   );
--
-- Sifat:
--  • Tabel lama umg_ hanya DIBACA, tidak diubah/dihapus.
--  • Aman dijalankan ulang: data yang sudah pindah tidak digandakan.
--    p_refresh => true menimpa data baru dengan isi tabel lama
--    (pakai hanya selama aplikasi GAS lama masih dipakai paralel).
--  • Hanya bisa dijalankan dari SQL Editor (pemilik database).
-- =====================================================================

-- ---------- fungsi bantu konversi (aman: nilai rusak → null) ----------
create or replace function public.umg2_ts(t text)
returns timestamptz language plpgsql immutable as $$
begin
  if t is null or btrim(t) = '' then return null; end if;
  return btrim(t)::timestamptz;
exception when others then return null;
end $$;

create or replace function public.umg2_json(t text, fallback jsonb default null)
returns jsonb language plpgsql immutable as $$
begin
  if t is null or btrim(t) = '' then return fallback; end if;
  return btrim(t)::jsonb;
exception when others then return fallback;
end $$;

create or replace function public.umg2_bool(t text)
returns boolean language sql immutable as $$
  select coalesce(lower(btrim(t)) in ('1', 'true', 'ya', 'yes'), false);
$$;

-- ---------- fungsi utama ----------
create or replace function public.umg2_import_legacy(
  p_org      uuid,
  p_admin_email text default null,
  p_tenant   uuid default null,
  p_refresh  boolean default false
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_tenant uuid := p_tenant;
  v_admin  uuid;
  v_report jsonb := '{}'::jsonb;
  v_n int;
  v_bad int;
begin
  if not exists (select 1 from organizations where id = p_org) then
    raise exception 'Organisasi % tidak ditemukan. Cek: select id, name from organizations;', p_org;
  end if;
  if to_regclass('public.umg_features') is null then
    raise exception 'Tabel lama umg_ tidak ada di proyek ini.';
  end if;

  -- tenant lama: bila tidak disebut, harus tepat satu
  if v_tenant is null then
    select count(distinct tenant_id) into v_n from umg_projects;
    if v_n > 1 then
      raise exception 'Ada % tenant di tabel lama. Sebutkan p_tenant. Daftar: select distinct tenant_id from umg_projects;', v_n;
    end if;
    select tenant_id into v_tenant from umg_projects limit 1;
    if v_tenant is null then select tenant_id into v_tenant from umg_users limit 1; end if;
  end if;

  -- akun Platform Inti untuk admin lama
  if p_admin_email is not null then
    select id into v_admin from profiles where lower(email) = lower(btrim(p_admin_email));
    if v_admin is null then raise exception 'Email % belum terdaftar di Platform Inti.', p_admin_email; end if;
    if not exists (select 1 from memberships where org_id = p_org and user_id = v_admin) then
      raise exception 'Akun % bukan anggota organisasi tujuan.', p_admin_email;
    end if;
    insert into umg2_members (org_id, user_id, role) values (p_org, v_admin, 'admin')
    on conflict (org_id, user_id) do update set role = 'admin', updated_at = now();
  end if;

  -- lisensi UMG untuk organisasi tujuan (paket pro, tanpa batas waktu)
  insert into licenses (org_id, app_code, plan, valid_until, notes)
  values (p_org, 'umg', 'pro', null, 'Migrasi dari UMG versi GAS')
  on conflict (org_id, app_code) do nothing;

  -- pemetaan user lama → akun baru (admin lama → p_admin_email)
  create temp table if not exists _umg_usermap (legacy text primary key, uid uuid) on commit drop;
  truncate _umg_usermap;
  insert into _umg_usermap
  select u.id, case when u.role = 'admin' then v_admin end
  from umg_users u where u.tenant_id = v_tenant
  on conflict do nothing;

  -- teks besar yang dipecah (@blob:) disatukan kembali
  create temp table if not exists _umg_blob (blob_id text primary key, data text) on commit drop;
  truncate _umg_blob;
  insert into _umg_blob
  select blob_id, string_agg(data, '' order by seq) from umg_blobs
  where tenant_id = v_tenant and blob_id <> 'free' group by blob_id;

  -- ---------------- PENGATURAN ----------------
  insert into umg2_settings (org_id, settings)
  select p_org, coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
  from umg_config where tenant_id = v_tenant and key !~* '^(license|lic_|secret)'
  on conflict (org_id) do update
    set settings = umg2_settings.settings || excluded.settings, updated_at = now()
    where p_refresh;

  -- ---------------- PROYEK ----------------
  insert into umg2_projects (id, org_id, name, description, work_area, status, created_by, legacy_created_by,
                             created_at, updated_at, deleted)
  select p.id, p_org, coalesce(nullif(p.name, ''), 'Tanpa nama'), coalesce(p.description, ''),
         umg2_json(p.work_area), coalesce(nullif(p.status, ''), 'active'),
         m.uid, p.created_by,
         coalesce(umg2_ts(p.created_at), now()), coalesce(umg2_ts(p.updated_at), umg2_ts(p.created_at), now()),
         umg2_bool(p.deleted)
  from umg_projects p left join _umg_usermap m on m.legacy = p.created_by
  where p.tenant_id = v_tenant and p.id ~ '^[A-Za-z0-9_-]{1,64}$'
  on conflict (id) do update set
    name = excluded.name, description = excluded.description, work_area = excluded.work_area,
    status = excluded.status, updated_at = excluded.updated_at, deleted = excluded.deleted
    where p_refresh;

  -- ---------------- LAYER ----------------
  insert into umg2_layers (id, org_id, project_id, name, geom_type, srid, schema, style, version,
                           created_at, updated_at, deleted)
  select l.id, p_org, l.project_id, coalesce(nullif(l.name, ''), 'Layer'),
         case when l.geom_type in ('Point', 'LineString', 'Polygon', 'None') then l.geom_type else 'Point' end,
         coalesce(nullif(l.srid, ''), '4326'),
         umg2_json(case when l.schema_json like '@blob:%' then (select data from _umg_blob where blob_id = substr(l.schema_json, 7)) else l.schema_json end, '[]'::jsonb),
         umg2_json(l.style_json, '{}'::jsonb),
         greatest(coalesce(l.version, 1), 1),
         coalesce(umg2_ts(l.created_at), now()), coalesce(umg2_ts(l.updated_at), umg2_ts(l.created_at), now()),
         umg2_bool(l.deleted)
  from umg_layers l
  where l.tenant_id = v_tenant and l.id ~ '^[A-Za-z0-9_-]{1,64}$'
    and exists (select 1 from umg2_projects p where p.id = l.project_id and p.org_id = p_org)
  on conflict (id) do update set
    name = excluded.name, geom_type = excluded.geom_type, srid = excluded.srid, schema = excluded.schema,
    style = excluded.style, version = excluded.version, updated_at = excluded.updated_at, deleted = excluded.deleted
    where p_refresh;

  -- ---------------- FITUR ----------------
  insert into umg2_features (id, org_id, project_id, layer_id, geom_type, geom, bbox, attrs, photos, gps, metrics,
                             status, version, created_by, updated_by, review_by,
                             legacy_created_by, legacy_updated_by, legacy_review_by, review_note,
                             created_at, updated_at, deleted)
  select f.id, p_org, f.project_id, f.layer_id, l.geom_type,
         case when l.geom_type = 'None' then null
              else coalesce(
                case when f.geom is not null then ST_SetSRID(f.geom::extensions.geometry, 4326) end,
                (select ST_SetSRID(ST_GeomFromGeoJSON(g.txt), 4326)
                   from (select case when f.geometry like '@blob:%'
                                     then (select data from _umg_blob where blob_id = substr(f.geometry, 7))
                                     else f.geometry end as txt) g
                  where umg2_json(g.txt) is not null and jsonb_typeof(umg2_json(g.txt)) = 'object'))
         end,
         umg2_json(f.bbox),
         umg2_json(case when f.attrs like '@blob:%' then (select data from _umg_blob where blob_id = substr(f.attrs, 7)) else f.attrs end, '{}'::jsonb),
         umg2_json(f.photos, '[]'::jsonb),
         umg2_json(f.gps),
         umg2_json(f.metrics, '{}'::jsonb),
         case when f.status in ('draft', 'submitted', 'approved', 'revision', 'rejected') then f.status else 'draft' end,
         greatest(coalesce(f.version, 1), 1),
         mc.uid, mu.uid, mr.uid,
         nullif(f.created_by, ''), nullif(f.updated_by, ''), nullif(f.review_by, ''),
         coalesce(f.review_note, ''),
         coalesce(umg2_ts(f.created_at), now()), coalesce(umg2_ts(f.updated_at), umg2_ts(f.created_at), now()),
         umg2_bool(f.deleted)
  from umg_features f
  join umg2_layers l on l.id = f.layer_id and l.org_id = p_org
  left join _umg_usermap mc on mc.legacy = f.created_by
  left join _umg_usermap mu on mu.legacy = f.updated_by
  left join _umg_usermap mr on mr.legacy = f.review_by
  where f.tenant_id = v_tenant and f.id ~ '^[A-Za-z0-9_-]{1,64}$'
  on conflict (id) do update set
    geom = excluded.geom, bbox = excluded.bbox, attrs = excluded.attrs, photos = excluded.photos,
    gps = excluded.gps, metrics = excluded.metrics, status = excluded.status, version = excluded.version,
    review_note = excluded.review_note, updated_at = excluded.updated_at, deleted = excluded.deleted
    where p_refresh;

  -- ---------------- KONFLIK & KWITANSI SINKRON ----------------
  insert into umg2_conflicts (id, org_id, feature_id, user_id, legacy_user_id, base_version, server_version, status, created_at)
  select c.id, p_org, c.feature_id, m.uid, c.user_id, coalesce(c.base_version, 0), coalesce(c.server_version, 0),
         coalesce(nullif(c.status, ''), 'open'), coalesce(umg2_ts(c.created_at), now())
  from umg_conflicts c left join _umg_usermap m on m.legacy = c.user_id
  where c.tenant_id = v_tenant and coalesce(c.id, '') <> ''
  on conflict (id) do nothing;

  insert into umg2_sync_ops (op_id, org_id, user_id, legacy_user_id, entity_id, result, created_at)
  select s.op_id, p_org, m.uid, s.user_id, s.entity_id, umg2_json(s.result), coalesce(umg2_ts(s.created_at), now())
  from umg_sync_ops s left join _umg_usermap m on m.legacy = s.user_id
  where s.tenant_id = v_tenant and coalesce(s.op_id, '') <> ''
  on conflict (op_id) do nothing;

  -- ---------------- RIWAYAT (AUDIT) LAMA → audit_log ----------------
  if not exists (select 1 from audit_log where org_id = p_org and table_name = 'umg_legacy') then
    insert into audit_log (org_id, user_id, table_name, action, record_id, new_data, created_at)
    select p_org, m.uid, 'umg_legacy', coalesce(nullif(a.action, ''), 'unknown'), a.entity_id,
           jsonb_build_object('entity', a.entity, 'detail', coalesce(umg2_json(a.detail), to_jsonb(a.detail)),
                              'legacy_user', a.user_id),
           coalesce(umg2_ts(a.ts), now())
    from umg_audit a left join _umg_usermap m on m.legacy = a.user_id
    where a.tenant_id = v_tenant;
  end if;

  -- ---------------- LAPORAN VERIFIKASI ----------------
  select count(*) filter (where l.geom_type <> 'None' and f.geom is null) into v_bad
  from umg2_features f join umg2_layers l on l.id = f.layer_id where f.org_id = p_org;

  v_report := jsonb_build_object(
    'tenant_lama', v_tenant,
    'akun_admin', p_admin_email,
    'proyek',  jsonb_build_object('lama', (select count(*) from umg_projects where tenant_id = v_tenant),
                                  'baru', (select count(*) from umg2_projects where org_id = p_org)),
    'layer',   jsonb_build_object('lama', (select count(*) from umg_layers where tenant_id = v_tenant),
                                  'baru', (select count(*) from umg2_layers where org_id = p_org)),
    'fitur',   jsonb_build_object('lama', (select count(*) from umg_features where tenant_id = v_tenant),
                                  'baru', (select count(*) from umg2_features where org_id = p_org),
                                  'aktif_baru', (select count(*) from umg2_features where org_id = p_org and not deleted),
                                  'geometri_gagal', v_bad),
    'riwayat', jsonb_build_object('lama', (select count(*) from umg_audit where tenant_id = v_tenant),
                                  'baru', (select count(*) from audit_log where org_id = p_org and table_name = 'umg_legacy')),
    'layer_dilewati_tanpa_proyek', (select coalesce(jsonb_agg(l.id), '[]'::jsonb) from umg_layers l
                                    where l.tenant_id = v_tenant and not exists (select 1 from umg2_layers n where n.id = l.id)),
    'fitur_dilewati', (select coalesce(jsonb_agg(f.id), '[]'::jsonb) from umg_features f
                       where f.tenant_id = v_tenant and not exists (select 1 from umg2_features n where n.id = f.id)),
    'fitur_geometri_gagal_dibaca', (select coalesce(jsonb_agg(f.id), '[]'::jsonb) from umg2_features f
                                    join umg2_layers l on l.id = f.layer_id
                                    where f.org_id = p_org and l.geom_type <> 'None' and f.geom is null),
    'user_lama_belum_dipetakan', (select coalesce(jsonb_agg(u.username || ' (' || u.role || ')'), '[]'::jsonb)
                                  from umg_users u join _umg_usermap m on m.legacy = u.id
                                  where u.tenant_id = v_tenant and m.uid is null),
    'foto_masih_di_drive', (select count(*) from umg2_features f, jsonb_array_elements_text(f.photos) ph
                            where f.org_id = p_org and ph like 'drive:%')
  );
  return v_report;
end $$;

-- hanya pemilik database (SQL Editor) yang boleh menjalankan
revoke execute on function public.umg2_import_legacy(uuid, text, uuid, boolean) from public, anon, authenticated;
