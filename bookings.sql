-- Green Valley CRM – Advance / booking details
-- Run this ONCE in Supabase: Project "Greenvally" → SQL Editor → New query → paste → Run.
-- Safe to run again (it skips what already exists).

-- 1. Helper: is the logged-in user an active admin?
create or replace function public.gv_is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin' and coalesce(p.blocked, false) = false);
$$;

-- 2. One booking row per customer (advance, registration, balance)
create table if not exists public.bookings (
  customer_id       uuid primary key references public.customers(id) on delete cascade,
  status            text not null default 'booked',
  plot_no           text default '',
  total_price       numeric check (total_price is null or total_price > 0),
  booking_amount    numeric not null default 0,
  booking_date      date,
  advance_amount    numeric not null default 0,
  advance_date      date,
  agreement_date    date,
  balance_paid      numeric not null default 0 check (balance_paid >= 0),
  balance_due_date  date,
  registration_date date,
  payment_note      text default '',
  created_by        uuid default auth.uid(),
  created_at        timestamptz not null default now(),
  updated_by        uuid default auth.uid(),
  updated_at        timestamptz not null default now(),
  edit_count        int not null default 0
);

-- 2b. Columns / rules (also upgrades a table made by an earlier version of this file)
alter table public.bookings add column if not exists booking_amount numeric not null default 0;
alter table public.bookings add column if not exists booking_date   date;
alter table public.bookings add column if not exists agreement_date date;
alter table public.bookings alter column advance_amount set default 0;
update public.bookings set advance_amount = 0 where advance_amount is null;
alter table public.bookings alter column advance_amount set not null;
alter table public.bookings alter column advance_date drop not null;
alter table public.bookings alter column status set default 'booked';
alter table public.bookings drop constraint if exists bookings_status_check;
alter table public.bookings drop constraint if exists bookings_advance_amount_check;
alter table public.bookings drop constraint if exists bk_status_ok;
alter table public.bookings drop constraint if exists bk_amounts_ok;
alter table public.bookings drop constraint if exists bk_not_over;
alter table public.bookings drop constraint if exists bk_reg_after;
alter table public.bookings add constraint bk_status_ok check (status in ('booked','advance','agreement','registered','cancelled'));
alter table public.bookings add constraint bk_amounts_ok check (booking_amount >= 0 and advance_amount >= 0 and balance_paid >= 0 and (booking_amount > 0 or advance_amount > 0));
alter table public.bookings add constraint bk_not_over check (total_price is null or booking_amount + advance_amount + balance_paid <= total_price);
alter table public.bookings add constraint bk_reg_after check (registration_date is null or registration_date >= least(coalesce(booking_date, advance_date), coalesce(advance_date, booking_date)));

-- 3. Every save is kept as a version (admin sees the change history)
create table if not exists public.booking_versions (
  id          bigserial primary key,
  customer_id uuid not null references public.customers(id) on delete cascade,
  version     int not null,
  saved_at    timestamptz not null default now(),
  saved_by    uuid,
  data        jsonb not null
);

create or replace function public.gv_booking_stamp()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := auth.uid(); new.created_at := now(); new.edit_count := 0;
  else
    new.created_by := old.created_by; new.created_at := old.created_at; new.edit_count := old.edit_count + 1;
  end if;
  new.updated_by := auth.uid(); new.updated_at := now();
  return new;
end $$;

create or replace function public.gv_booking_version()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.booking_versions (customer_id, version, saved_at, saved_by, data)
  values (new.customer_id, new.edit_count + 1, new.updated_at, new.updated_by, to_jsonb(new));
  return new;
end $$;

drop trigger if exists bk_stamp on public.bookings;
create trigger bk_stamp before insert or update on public.bookings for each row execute function public.gv_booking_stamp();
drop trigger if exists bk_version on public.bookings;
create trigger bk_version after insert or update on public.bookings for each row execute function public.gv_booking_version();

-- 4. Security: employee sees/edits only bookings of customers they added; admin sees all.
alter table public.bookings enable row level security;
alter table public.booking_versions enable row level security;

drop policy if exists bk_select on public.bookings;
drop policy if exists bk_insert on public.bookings;
drop policy if exists bk_update on public.bookings;
create policy bk_select on public.bookings for select to authenticated
  using (public.gv_is_admin() or exists (select 1 from public.customers c where c.id = customer_id and c.created_by = auth.uid()));
create policy bk_insert on public.bookings for insert to authenticated
  with check (public.gv_is_admin() or exists (select 1 from public.customers c where c.id = customer_id and c.created_by = auth.uid()));
create policy bk_update on public.bookings for update to authenticated
  using (public.gv_is_admin() or exists (select 1 from public.customers c where c.id = customer_id and c.created_by = auth.uid()))
  with check (public.gv_is_admin() or exists (select 1 from public.customers c where c.id = customer_id and c.created_by = auth.uid()));
-- (no delete policy: booking rows cannot be deleted from the app; use status = 'cancelled')

drop policy if exists bkv_select on public.booking_versions;
create policy bkv_select on public.booking_versions for select to authenticated using (public.gv_is_admin());

grant select, insert, update on public.bookings to authenticated;
grant select on public.booking_versions to authenticated;

-- 5. Admin can change an employee's WhatsApp phone number from the Users page
alter table public.profiles add column if not exists phone text;
drop policy if exists profiles_admin_update on public.profiles;
create policy profiles_admin_update on public.profiles for update to authenticated
  using (public.gv_is_admin()) with check (public.gv_is_admin());

-- Tell the API about the new tables right away
notify pgrst, 'reload schema';
