-- 어반사이드 팝업 POS v2 업그레이드 (한 번만 실행)
-- 1) 직원별 PIN·역할  2) 매장별 데이터 분리  3) 고객 영수증 조회
-- 기존 아난티 데이터는 매장 'ananti' 아래로 옮겨요. 상품 목록·초기 재고는 그대로예요.

create table if not exists pos_staff (
  pin text primary key,
  name text not null,
  role text not null check (role in ('store', 'hq')),
  store text not null default '',
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table pos_staff enable row level security;

-- PIN 확인: 직원 PIN 또는 기존 마스터 비밀번호(본사 권한)
create or replace function pos_who(p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s pos_staff; m pos_meta;
begin
  select * into s from pos_staff where pin = p_pin and active;
  if found then return jsonb_build_object('name', s.name, 'role', s.role, 'store', s.store); end if;
  select * into m from pos_meta where id = 1;
  if m.pin = p_pin then return jsonb_build_object('name', '본사', 'role', 'hq', 'store', ''); end if;
  raise exception 'PIN';
end $$;

create or replace function pos_login(p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  return pos_who(p_pin);
end $$;

-- 읽기: 매장 직원은 자기 매장 + 공용(상품·설정)만, 본사는 전부
create or replace function pos_load(p_pin text, p_ver bigint default 0) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w jsonb; m pos_meta;
begin
  w := pos_who(p_pin);
  select * into m from pos_meta where id = 1;
  if p_ver > 0 and p_ver = m.ver then return null; end if;
  return jsonb_build_object('ver', m.ver, 'me', w,
    'docs', coalesce((select jsonb_agg(jsonb_build_array(path, data)) from pos_docs
      where w->>'role' = 'hq' or path not like 's/%' or path like 's/' || (w->>'store') || '/%'), '[]'::jsonb));
end $$;

-- 쓰기: 매장 직원은 자기 매장 데이터만, 상품·설정은 본사만
create or replace function pos_put(p_pin text, p_path text, p_data jsonb, p_merge boolean default false) returns bigint
language plpgsql security definer set search_path = public as $$
declare w jsonb; v bigint;
begin
  w := pos_who(p_pin);
  if w->>'role' <> 'hq' and p_path not like 's/' || (w->>'store') || '/%' then raise exception 'FORBIDDEN'; end if;
  perform 1 from pos_meta where id = 1 for update;
  if p_merge then
    update pos_docs set data = data || p_data, updated_at = now() where path = p_path;
    if not found then raise exception 'not found: %', p_path; end if;
  else
    insert into pos_docs (path, data) values (p_path, p_data)
    on conflict (path) do update set data = excluded.data, updated_at = now();
  end if;
  update pos_meta set ver = ver + 1 where id = 1 returning ver into v;
  return v;
end $$;

-- 직원 관리 (본사만)
create or replace function pos_staff_list(p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w jsonb;
begin
  w := pos_who(p_pin);
  if w->>'role' <> 'hq' then raise exception 'FORBIDDEN'; end if;
  return coalesce((select jsonb_agg(to_jsonb(s) - 'created_at' order by s.created_at) from pos_staff s), '[]'::jsonb);
end $$;

create or replace function pos_staff_set(p_pin text, p_staff_pin text, p_name text, p_role text, p_store text, p_active boolean) returns void
language plpgsql security definer set search_path = public as $$
declare w jsonb;
begin
  w := pos_who(p_pin);
  if w->>'role' <> 'hq' then raise exception 'FORBIDDEN'; end if;
  insert into pos_staff (pin, name, role, store, active) values (p_staff_pin, p_name, p_role, coalesce(p_store, ''), p_active)
  on conflict (pin) do update set name = excluded.name, role = excluded.role, store = excluded.store, active = excluded.active;
end $$;

-- 고객 영수증: 영수증 토큰으로 그 주문 하나만, 연락처·주소·메모 등은 빼고 돌려줌 (비밀번호 불필요)
create or replace function pos_receipt(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d jsonb; pth text;
begin
  if p_token is null or length(p_token) < 16 then return null; end if;
  select data, path into d, pth from pos_docs where path like 's/%/sales/%' and data->>'rt' = p_token limit 1;
  if not found then return null; end if;
  return jsonb_build_object(
    'sale', d - 'custPhone' - 'ship' - 'memo' - 'by' - 'paid' - 'cancels' - 'consent',
    'store', split_part(pth, '/', 2),
    'config', (select data from pos_docs where path = 'config/main'));
end $$;

-- 기존 아난티 데이터 → 매장 'ananti'로 이동
update pos_docs set path = 's/ananti/' || path
where path like 'sales/%' or path like 'receipts/%' or path like 'requests/%';

insert into pos_docs (path, data) values ('config/main', jsonb_build_object(
  'stores', jsonb_build_array(
    jsonb_build_object('id', 'ananti', 'name', '아난티 팝업', 'code', 'A', 'promo', jsonb_build_object('on', false)),
    jsonb_build_object('id', 'chungcheong', 'name', '더현대 충청', 'code', 'C',
      'promo', jsonb_build_object('on', true, 'threshold', 500000, 'rate', 0.05, 'basis', 'sale', 'mode', 'sum', 'includeExcluded', true))),
  'notes', '{}'::jsonb,
  'notice', ''))
on conflict (path) do nothing;
update pos_meta set ver = ver + 1 where id = 1;

revoke all on function pos_who(text) from public, anon;
revoke all on function pos_login(text) from public;
revoke all on function pos_staff_list(text) from public;
revoke all on function pos_staff_set(text, text, text, text, text, boolean) from public;
revoke all on function pos_receipt(text) from public;
grant execute on function pos_login(text) to anon;
grant execute on function pos_staff_list(text) to anon;
grant execute on function pos_staff_set(text, text, text, text, text, boolean) to anon;
grant execute on function pos_receipt(text) to anon;
