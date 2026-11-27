-- Instant offers: anyone can send an offer with name + WhatsApp number; it is saved as
-- UNVERIFIED and becomes public when staff approve the bidder (or click "Make live").
--
-- DRAFT. Written without access to the live schema. Every line marked ASSUMPTION must be
-- checked against the real definitions before running. See HANDOVER.md at the repo root.
-- Run in one transaction; it is safe to re-run.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. bids.verified (+ bidder link)
--    Default TRUE keeps every existing bid, and every place_bid() insert, public as today.
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.bids add column if not exists verified boolean not null default true;

-- ASSUMPTION: bids has no bidder_id column yet. If it already has one (possibly with another
-- name), drop this line and use the existing column below.
alter table public.bids add column if not exists bidder_id uuid references public.bidders(id) on delete set null;

create index if not exists bids_auction_live_idx
  on public.bids (auction_id, amount desc) where deleted_at is null and verified;
create index if not exists bids_phone_recent_idx
  on public.bids (bidder_phone, created_at desc);


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. public_bids: verified offers only
--    Keep the existing column list and name masking EXACTLY as they are now; only add the
--    "and b.verified" condition. Get the current definition with:
--      select pg_get_viewdef('public.public_bids'::regclass, true);
-- ─────────────────────────────────────────────────────────────────────────────
-- create or replace view public.public_bids as
--   <existing select list>
--   from public.bids b
--   where b.deleted_at is null
--     and b.verified;                               -- ← the only change


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. validate_bid(): the minimum is measured against VERIFIED offers only
--    Otherwise one fake unverified offer at RM 900,000 would block every real bidder while the
--    page still shows the lower public price. In the existing function, wherever it computes
--    the current highest amount, add:   and verified and deleted_at is null
--    Keep RM 500 as min_increment (auction-car.html has MIN_INCREMENT = 500).
--
--    The trigger must be BEFORE INSERT only. If it also fires on UPDATE, publishing an
--    older, lower offer (step 5 or "Make live") would be rejected. Check with:
--      select pg_get_triggerdef(oid) from pg_trigger where tgrelid = 'public.bids'::regclass;
-- ─────────────────────────────────────────────────────────────────────────────


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. submit_offer(): the public entry point used by auction-car.html
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.submit_offer(
  p_auction uuid,
  p_amount  numeric,
  p_name    text,
  p_phone   text,
  p_terms   text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name    text := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
  v_phone   text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');   -- the page sends "60123456789"
  v_auction public.auctions%rowtype;
  v_reg     jsonb;
  v_bidder  public.bidders%rowtype;
  v_bid_id  uuid;
  v_recent  int;
begin
  if length(v_name) < 2 or length(v_name) > 80 then
    raise exception using errcode = 'P0001', message = 'Please enter your full name.';
  end if;
  if length(v_phone) < 9 or length(v_phone) > 15 then
    raise exception using errcode = 'P0001', message = 'Please enter a valid WhatsApp number, including the country code.';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount > 100000000 or p_amount <> trunc(p_amount) then
    raise exception using errcode = 'P0001', message = 'Please enter a valid offer amount.';
  end if;

  select * into v_auction from public.auctions where id = p_auction;
  if not found then
    raise exception using errcode = 'P0001', message = 'This listing was not found.';
  end if;
  if v_auction.status = 'closed' or (v_auction.deadline is not null and v_auction.deadline <= now()) then
    raise exception using errcode = 'P0001', message = 'This listing is closed to new offers.';
  end if;

  -- Spam guard: offers per number per hour (tune as needed).
  select count(*) into v_recent
    from public.bids
   where bidder_phone = v_phone and created_at > now() - interval '1 hour';
  if v_recent >= 10 then
    raise exception using errcode = 'P0001',
      message = 'Too many offers from this number. Please try again later or message us on WhatsApp.';
  end if;

  -- Reuse the existing registration logic: creates a pending bidder, or returns the existing one.
  -- ASSUMPTION: register_bidder(p_name, p_phone, p_terms, p_auction) returns json(b) with
  -- registration_ref, existing, status (that is what auction-car.html has always read from it).
  v_reg := public.register_bidder(v_name, v_phone, p_terms, p_auction)::jsonb;

  -- ASSUMPTION: register_bidder stores the phone as digits only (the admin page builds
  -- wa.me/<phone> links from it). If it normalises differently, match its rule here.
  select * into v_bidder
    from public.bidders
   where phone = v_phone
   order by created_at desc
   limit 1;
  if not found then
    raise exception 'submit_offer: bidder row not found after register_bidder (phone format mismatch?)';
  end if;
  if v_bidder.status = 'blocked' then
    raise exception using errcode = 'P0001',
      message = 'This number cannot submit offers online. Please contact us on WhatsApp.';
  end if;

  -- Always unverified, even for approved bidders: a typed phone number is not proof of
  -- identity. Approved bidders use their bidder code (place_bid) to go live at once.
  -- validate_bid() still enforces the RM 500 step and the minimum on this insert.
  insert into public.bids (auction_id, amount, bidder_id, bidder_name, bidder_phone, verified)
  values (p_auction, p_amount, v_bidder.id, v_bidder.name, v_bidder.phone, false)
  returning id into v_bid_id;
  -- ASSUMPTION: no other NOT NULL columns on bids without defaults (e.g. a bidder code). Add them here.

  return jsonb_build_object(
    'ok',            true,
    'bid_id',        v_bid_id,
    'reference',     v_reg->>'registration_ref',
    'bidder_status', v_bidder.status,
    'existing',      coalesce((v_reg->>'existing')::boolean, false),
    'verified',      false
  );
end;
$$;

revoke all on function public.submit_offer(uuid, numeric, text, text, text) from public;
grant execute on function public.submit_offer(uuid, numeric, text, text, text) to anon, authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Approving a bidder publishes the offers they already sent
--    Staff keep using "Confirm deposit & approve" exactly as today.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.publish_offers_on_approval()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'approved' and old.status is distinct from 'approved' then
    update public.bids
       set verified = true
     where verified = false
       and deleted_at is null
       and (bidder_id = new.id or (bidder_id is null and bidder_phone = new.phone));
  end if;
  return new;
end;
$$;

drop trigger if exists bidders_publish_offers on public.bidders;
create trigger bidders_publish_offers
  after update of status on public.bidders
  for each row execute function public.publish_offers_on_approval();


-- ─────────────────────────────────────────────────────────────────────────────
-- 6. Staff "Make live" button (auction-admin.html → update bids set verified = true)
--    ASSUMPTION: staff already have an UPDATE policy on bids (used for soft deletes). If that
--    policy limits which columns may change, allow "verified" too. Nothing to do otherwise.
-- ─────────────────────────────────────────────────────────────────────────────

commit;

-- Smoke test (then remove the test rows with "Remove registration" in the Auction Manager):
--   select public.submit_offer('<live auction id>', <next valid amount>, 'TEST Claude', '60110000000', '2026-11-28-offer-1');
--   select id, amount, verified from public.bids order by created_at desc limit 1;      -- verified = false
--   select count(*) from public.public_bids where amount = <that amount>;               -- 0
