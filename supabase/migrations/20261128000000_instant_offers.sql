-- Instant offers: anyone can send an offer with name + WhatsApp number. It is saved as
-- UNVERIFIED (staff only) and goes public when staff approve the bidder with a confirmed
-- deposit, or click "Make live" in the Auction Manager.
--
-- Written against the live definitions read on 28 Nov 2026 (project ieqflqzcurwfyxobprro).
-- Additive and re-runnable. Existing bids, place_bid and remove_bidder_registration keep
-- working; old bids stay public (verified defaults to true).

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. bids.verified
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.bids add column if not exists verified boolean not null default true;

create index if not exists bids_auction_verified_idx
  on public.bids (auction_id, amount desc) where deleted_at is null and verified;
create index if not exists bids_bidder_created_idx
  on public.bids (bidder_id, created_at desc);
create index if not exists bids_unverified_created_idx
  on public.bids (created_at) where not verified;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. public_bids: verified offers only (same columns, same order)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace view public.public_bids as
  select id, auction_id, amount, bidder_label, created_at
    from public.bids
   where deleted_at is null
     and verified;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. validate_bid(): the minimum follows the highest VERIFIED offer
--    (an unverified offer must not raise the public minimum). Otherwise unchanged.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.validate_bid()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare a record; top numeric; minimum numeric;
begin
  select * into a from auctions where id=new.auction_id for update;
  if not found then raise exception 'Listing not found.'; end if;
  if a.status='closed' or (a.deadline is not null and a.deadline<=clock_timestamp()) then
    raise exception 'This listing is closed to new offers.';
  end if;
  if new.amount is null or new.amount::text in ('NaN','Infinity','-Infinity')
     or new.amount<=0 or new.amount>100000000 then
    raise exception 'Enter a valid offer up to RM 100,000,000.';
  end if;
  select greatest(coalesce(max(amount),0),coalesce(a.starting_price,0)) into top
    from bids where auction_id=new.auction_id and deleted_at is null and verified;
  minimum:=ceil((top+500)/500)*500;
  if new.amount<minimum or mod(new.amount,500)<>0 then
    raise exception 'Offer at least RM %, using whole RM 500 steps.',minimum;
  end if;
  return new;
end;
$function$;
-- Trigger bids_validate stays BEFORE INSERT only, so publishing an older offer never re-validates it.


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. register_bidder(): also accept the new terms version. Otherwise unchanged.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.register_bidder(p_name text, p_phone text, p_terms text, p_auction uuid default null::uuid)
 returns json
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  n text:=btrim(coalesce(p_name,''));
  d text:=regexp_replace(coalesce(p_phone,''),'\D','','g');
  b record;
begin
  if n='' or length(n)>80 then raise exception 'Please enter your name (up to 80 characters).'; end if;
  if left(d,1)='0' then d:='60'||substr(d,2); end if;
  if length(d)<10 or length(d)>14 then raise exception 'Please enter a valid WhatsApp number.'; end if;
  if p_auction is not null and not exists(select 1 from auctions where id=p_auction) then
    raise exception 'Listing not found. Please refresh and try again.';
  end if;
  if p_terms is null or p_terms not in ('2026-11-28-offer-1','2026-11-offers-1','2026-11-whatsapp-2') then
    raise exception 'Refresh the page and accept the current offer terms.';
  end if;
  perform pg_advisory_xact_lock(7419202601);
  select * into b from bidders where phone=d;
  if found then
    -- A reference identifies a registration; it is never a bidder credential.
    return json_build_object('ok',true,'status',b.status,'existing',true,
      'registration_ref','KG-'||lpad(b.registration_number::text,greatest(6,length(b.registration_number::text)),'0'));
  end if;
  if (select count(*) from bidders where created_at>clock_timestamp()-interval '10 minutes')>=30 then
    raise exception 'We are receiving many registrations. Please WhatsApp us or try again shortly.';
  end if;
  for attempt in 1..5 loop
    begin
      insert into bidders(name,phone,terms_version,registration_auction_id)
        values(n,d,p_terms,p_auction) returning * into b;
      exit;
    exception when unique_violation then
      if attempt=5 then raise exception 'Could not allocate your bidder code. Please try again.'; end if;
    end;
  end loop;
  return json_build_object('ok',true,'status','pending','existing',false,
    'registration_ref','KG-'||lpad(b.registration_number::text,greatest(6,length(b.registration_number::text)),'0'));
end;
$function$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. place_bid(): "you already lead" compares against the highest VERIFIED offer.
--    Otherwise unchanged; its inserts stay verified (column default).
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.place_bid(p_auction uuid, p_amount numeric, p_code text)
 returns json
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  b record; topb record; a record; lbl text; car text;
begin
  select * into b from bidders where code = upper(btrim(coalesce(p_code, ''))) for update;
  if not found then
    perform pg_sleep(0.6);
    raise exception 'Bidder code not recognised. Please check it and try again.';
  end if;
  if b.status = 'blocked' then
    raise exception 'Your bidder account is not active. Please contact Kansai Group.';
  end if;
  if b.status <> 'approved' or not b.deposit_confirmed then
    raise exception 'Your account is awaiting approval and deposit confirmation. Our team will contact you on WhatsApp.';
  end if;
  select * into a from auctions where id=p_auction for update;
  if not found then raise exception 'Listing not found.'; end if;
  if a.status='closed' or (a.deadline is not null and a.deadline<=clock_timestamp()) then
    raise exception 'This listing is closed to new offers.';
  end if;
  if exists (select 1 from bids where bidder_id=b.id and created_at>clock_timestamp()-interval '3 seconds') then
    raise exception 'Please wait a few seconds before bidding again.';
  end if;

  select * into topb from bids where auction_id = p_auction and deleted_at is null and verified
    order by amount desc limit 1;
  if found and topb.bidder_id = b.id then
    raise exception 'You already have the highest bid.';
  end if;

  lbl := case when length(b.name) <= 3
              then upper(left(b.name, 1)) || substr(b.name, 2) || '***'
              else upper(left(b.name, 1)) || lower(substr(b.name, 2, 2)) || '***' end;

  insert into bids (auction_id, amount, bidder_id, bidder_name, bidder_phone, bidder_label, created_at)
    values (p_auction, p_amount, b.id, b.name, b.phone, lbl, clock_timestamp());

  select car_name into car from auctions where id = p_auction;
  perform public.notify_staff('New bid RM ' || p_amount || ' by ' || b.name || ' on ' || coalesce(car, 'an auction'));
  return json_build_object('ok', true);
end;
$function$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 6. submit_offer(): name + WhatsApp number + amount → unverified offer
--    Called by auction-car.html. Errors use the default SQLSTATE P0001 and are shown
--    to the visitor as written.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.submit_offer(p_auction uuid, p_amount numeric, p_name text, p_phone text, p_terms text)
 returns json
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  n text := regexp_replace(btrim(coalesce(p_name,'')), '\s+', ' ', 'g');
  d text := regexp_replace(coalesce(p_phone,''), '\D', '', 'g');
  reg json; b record; lbl text; car text; new_id uuid;
begin
  if p_auction is null then raise exception 'Listing not found. Please refresh and try again.'; end if;
  if left(d,1)='0' then d := '60'||substr(d,2); end if;   -- same rule as register_bidder

  -- Validates name, number, listing and terms; creates the bidder when new (pending);
  -- holds the registration lock until this transaction ends.
  reg := public.register_bidder(n, d, p_terms, p_auction);

  select * into b from bidders where phone = d for update;
  if not found then raise exception 'We could not save your offer. Please try again.'; end if;
  if b.status = 'blocked' then
    raise exception 'This number cannot make offers online. Please contact Kansai Group on WhatsApp.';
  end if;

  -- Spam guards
  if exists (select 1 from bids where bidder_id=b.id and created_at>clock_timestamp()-interval '3 seconds') then
    raise exception 'Please wait a few seconds before sending another offer.';
  end if;
  if (select count(*) from bids where bidder_id=b.id and created_at>clock_timestamp()-interval '1 hour') >= 10 then
    raise exception 'Too many offers from this number. Please try again later or message us on WhatsApp.';
  end if;
  if (select count(*) from bids where not verified and created_at>clock_timestamp()-interval '10 minutes') >= 60 then
    raise exception 'We are receiving many offers. Please WhatsApp us or try again shortly.';
  end if;

  lbl := case when length(b.name) <= 3
              then upper(left(b.name, 1)) || substr(b.name, 2) || '***'
              else upper(left(b.name, 1)) || lower(substr(b.name, 2, 2)) || '***' end;

  -- Always unverified, even for an approved bidder's number: a typed number proves nothing.
  -- Approved bidders use their code (place_bid) to go live at once.
  -- validate_bid() checks the listing is open and the RM 500 minimum / steps.
  insert into bids (auction_id, amount, bidder_id, bidder_name, bidder_phone, bidder_label, verified, created_at)
    values (p_auction, p_amount, b.id, b.name, b.phone, lbl, false, clock_timestamp())
    returning id into new_id;

  select car_name into car from auctions where id = p_auction;
  perform public.notify_staff(
    'New UNVERIFIED offer RM ' || to_char(p_amount, 'FM999,999,999') || ' by ' || b.name || ' (+' || b.phone || ')'
    || case when lower(n) <> lower(b.name) then ' [typed name: ' || n || ']' else '' end
    || ' on ' || coalesce(car, 'an auction')
    || '. Verify on WhatsApp, then approve in the Auction Manager.');

  return json_build_object(
    'ok', true,
    'bid_id', new_id,
    'reference', reg->>'registration_ref',
    'bidder_status', b.status,
    'existing', coalesce((reg->>'existing')::boolean, false),
    'verified', false);
end;
$function$;

revoke all on function public.submit_offer(uuid, numeric, text, text, text) from public;
grant execute on function public.submit_offer(uuid, numeric, text, text, text) to anon, authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 7. Approval publishes the bidder's offers
--    Same rule as place_bid: approved AND deposit confirmed. Staff keep using
--    "Confirm deposit & approve" (sets both) or "Mark deposit received".
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.publish_offers_on_approval()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  if new.status = 'approved' and new.deposit_confirmed
     and not (old.status = 'approved' and old.deposit_confirmed) then
    update bids set verified = true
     where bidder_id = new.id and not verified and deleted_at is null;
  end if;
  return new;
end;
$function$;

revoke all on function public.publish_offers_on_approval() from public, anon, authenticated;

drop trigger if exists bidders_publish_offers on public.bidders;
create trigger bidders_publish_offers
  after update of status, deposit_confirmed on public.bidders
  for each row execute function public.publish_offers_on_approval();

-- "Make live" in the Auction Manager is a plain staff UPDATE on bids, already allowed by
-- the existing policy "staff manage bids" (ALL to authenticated using is_staff()).

commit;
