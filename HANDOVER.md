# Handover: instant offer flow + leaderboard. Backend work needed

**For:** the agent with access to the Supabase project `ieqflqzcurwfyxobprro` (production).
**From:** the front-end session, 28 Nov 2026.
**Goal:** make the database match the new auction offer flow the front end already implements. Front-end changes after you deploy should be one constant (see §7).

---

## 0. Ground rules (from the project owner)

- Work on the **local** branch `feature/instant-offer-flow` in `/Users/rafaysyed/play_ground/kansai`. **It has not been pushed.** Do not push, open a PR or deploy without the owner's explicit go-ahead. If you work from another machine, ask the owner to approve a push first.
- Never commit on `main`.
- The Supabase project is **production**, with one live auction that has real visitors. Prefer additive, re-runnable migrations in one transaction. Read the live definitions before you change anything (§3).
- Commit the final SQL you actually ran to `supabase/migrations/`, replacing the draft, so the repo records the backend for the first time.

---

## 1. What the product does now

**Before:** register → WhatsApp → deposit → staff approval → bidder code → only then could someone make an offer.

**Now (front end done):**

1. The visitor taps **Make an Offer** (`auction-car.html`) and enters amount, name and WhatsApp number in one form.
2. **Send offer** calls the new RPC `submit_offer` → the offer is saved as **unverified** → WhatsApp opens to **+60 11-5117 7026** with the offer pre-filled, and the visitor taps Send.
3. Staff verify the person and take the refundable deposit on WhatsApp, then click **Confirm deposit & approve** in `auction-admin.html`. **This is the same approval flow as today and must keep working as is.** Approval makes that bidder's offers public.
4. Public pages (leaderboard, price, auctions list) show **verified offers only**.
5. Approved bidders can still use their **bidder code** → existing `place_bid` → live immediately.

**The auction page now has a gamified leaderboard** built on `public_bids`: ranks, leader, "You", new-offer and outbid alerts. It polls every 5 s, so no Realtime is needed.

**What is live today without your work:** `submit_offer` doesn't exist (`PGRST202`), so the page falls back to the existing `register_bidder` and sends the offer amount **only via WhatsApp**. Staff see the pending bidder, but the offer isn't in the database and never reaches the leaderboard. **Your work closes that gap.**

---

## 2. Code on the branch

| Commit | What |
|---|---|
| `b548b81` | Instant offer flow, admin "Unverified" labels + **Make live**, Terms `2026-11-28-offer-1`, Privacy Notice, copy, draft SQL |
| `f14d838` | Leaderboard, momentum chips, outbid/leader alerts, urgency timer |
| (latest) | This handover, tie-break ranking |

Files: `auction-car.html` (all public offer logic), `auction-admin.html` (staff), `auctions.html`, `live-auctions.js`, `auction-terms.html`, `auction-privacy.html`, `supabase/migrations/20261128000000_instant_offers.sql` (**draft**).

**Run it locally:** `python3 -m http.server 5173` in the repo, then open `http://localhost:5173/auction-car.html?id=0bf1b8f7-e6b6-4b50-a222-e179ff45d535`. It talks to the production database.

---

## 3. Step 1: read the live schema first

The draft SQL was written blind; the anon key can't read definitions. Run this read-only query in the SQL editor and keep the output:

```sql
select kind, name, def from (
  select 'table' kind, c.relname name,
         string_agg(a.attname||' '||format_type(a.atttypid,a.atttypmod)
           ||case when a.attnotnull then ' not null' else '' end
           ||coalesce(' default '||pg_get_expr(d.adbin,d.adrelid),''), E'\n' order by a.attnum) def
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  join pg_attribute a on a.attrelid=c.oid and a.attnum>0 and not a.attisdropped
  left join pg_attrdef d on d.adrelid=c.oid and d.adnum=a.attnum
  where n.nspname='public' and c.relkind='r' group by c.relname
  union all select 'view', viewname, definition from pg_views where schemaname='public'
  union all
  select 'function', p.proname, pg_get_functiondef(p.oid)
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.prokind='f'
    and not exists (select 1 from pg_depend dp where dp.objid=p.oid and dp.deptype='e')
  union all
  select 'policy', tablename||'.'||policyname,
         cmd||' to '||array_to_string(roles,',')||E'\nusing: '||coalesce(qual,'')||E'\ncheck: '||coalesce(with_check,'')
  from pg_policies where schemaname='public'
  union all
  select 'trigger', tgrelid::regclass::text||'.'||tgname, pg_get_triggerdef(oid)
  from pg_trigger where not tgisinternal and tgrelid in (select oid from pg_class where relnamespace='public'::regnamespace)
  union all
  select 'grant', table_name, string_agg(grantee||':'||privilege_type, ', ')
  from information_schema.role_table_grants
  where table_schema='public' and grantee in ('anon','authenticated') group by table_name
) s order by kind, name;
```

What we already know from the outside:
- **Tables and views:** `auctions` and `public_bids` are readable by anon; `bids` and `bidders` are not (`42501`).
- **RPCs:** `register_bidder`, `verify_bidder`, `place_bid`, `remove_bidder_registration`, `is_staff`. `validate_bid()` enforces min increment 500.
- **Terms check:** `register_bidder` **rejects any `p_terms` other than `2026-11-whatsapp-2`**: P0001 "Refresh the page and accept the current offer terms."
- **Phone storage:** the admin builds `wa.me/<bidders.phone>` links, so phones are probably stored as digits only.
- **Staff alerts:** the Privacy Notice mentions optional **Telegram staff alerts** on registrations and offers, which means a trigger or webhook probably exists.
- **Data:** one auction (`0bf1b8f7-…`, status `live`, deadline 2026-12-05 10:30 UTC, start RM 215,000), zero public bids. Six registrations exist (latest `KG-000006`, a test).

---

## 4. Backend tasks

The draft for each lives in `supabase/migrations/20261128000000_instant_offers.sql`. Reconcile every `ASSUMPTION` line against §3 before running.

| # | Task | Done when |
|---|---|---|
| B1 | `bids.verified boolean not null default true` (+ `bidder_id uuid` if there's no link yet). The default keeps old bids and `place_bid` public. | Existing bids still public; `place_bid` unchanged |
| B2 | `public_bids` adds `and b.verified`. **Keep its columns and name masking exactly**: the front end reads `id, auction_id, amount, bidder_label, created_at`. | Unverified rows are invisible to anon |
| B3 | `validate_bid()`: "current highest" counts only `verified and deleted_at is null`. Trigger must be **BEFORE INSERT only**. | A fake unverified high offer doesn't raise the public minimum; publishing an older, lower offer doesn't fail |
| B4 | Accept terms `2026-11-28-offer-1` in `register_bidder` (and `submit_offer`). Keep accepting the old value until the front-end constant is removed. | Calling `register_bidder` with the new version succeeds |
| B5 | New RPC `submit_offer` (contract in §5), `security definer`, `grant execute to anon, authenticated`. It reuses `register_bidder` and inserts the bid with `verified=false`. | §8 steps 1–3 pass |
| B6 | Trigger on `bidders` status → `approved`: set `verified=true` on that bidder's live offers (by `bidder_id`, or phone when `bidder_id` is null). | Approving in the admin page makes the offers appear on the leaderboard within 5 s |
| B7 | Staff **Make live** button: `update bids set verified=true where id=…` via the staff session. Make sure the staff UPDATE policy on `bids` allows the `verified` column. | The button works with no error toast |
| B8 | `remove_bidder_registration` still soft-deletes **all** of the bidder's offers, unverified included. | Removing a pending test bidder clears their offers |
| B9 | Staff alerts (Telegram or other) on new bids: include verified / unverified, and fire for `submit_offer` inserts. | Staff are told about unverified offers |
| B10 | Stats views (`auction_week`, `auction_stats`): decide whether `bids` counts include unverified. Suggest yes, labelled "offers received". | Owner agrees |
| B11 | Spam guard in `submit_offer`: the draft allows 10 offers per number per hour. Tune as needed. Consider a per-auction cap too. | |

**Security rule (do not relax):** an offer submitted by name and phone is **always** unverified, even when that phone belongs to an approved bidder. A typed number proves nothing. Only `place_bid` with a valid code, staff approval, or staff **Make live** makes an offer public.

---

## 5. Contracts the front end relies on

### `submit_offer` (new)

```
rpc submit_offer(p_auction uuid, p_amount numeric, p_name text, p_phone text, p_terms text) → jsonb
```

**Input:**
- `p_phone` is digits with country code, e.g. `60123456789`; the front end has already normalised local and `+` formats.
- `p_amount` is a whole number, a multiple of 500, ≥ the next minimum.
- `p_terms` is `2026-11-28-offer-1`.

**Output on success:**
```json
{ "ok": true, "bid_id": "…", "reference": "KG-000123", "bidder_status": "pending|approved",
  "existing": false, "verified": false }
```
- `reference` is shown to the visitor and put in the WhatsApp message, so use the registration reference format `KG-` + 6 digits.

**Errors the visitor should see:** `raise exception using errcode='P0001', message='…'`. The page shows `message` as written, so keep it short and plain: closed listing, below minimum, wrong step, blocked number, too many offers.
- A blocked number may raise P0001, or return `bidder_status:'blocked'`; the page handles both.

**Any other error:** the page shows a generic failure plus "Send this offer on WhatsApp instead", so nothing is lost.

### Existing RPCs the front end still calls (keep their behaviour)

| RPC | Arguments | Used for |
|---|---|---|
| `verify_bidder` | `p_code` | Returns `{ok, can_bid, name, status}` |
| `place_bid` | `p_auction, p_amount, p_code` | Returns `{ok:true}`. Code path; must stay **verified** |
| `register_bidder` | `p_name, p_phone, p_terms, p_auction` | Returns `{registration_ref, existing, status}`. Fallback only, and called inside `submit_offer` |
| `is_staff` | | Admin gate |
| `remove_bidder_registration` | `p_bidder` | Returns `{ok:true}` |

### Tables and columns read

| Source | Who reads it | Columns used |
|---|---|---|
| `auctions` | anon | `id, car_name, year, specs, photos[{url}], starting_price, extra_lines[{label,amount}], deadline, status, description, created_at` |
| `public_bids` | anon: leaderboard, price, auctions list, homepage count | `id, auction_id, amount, bidder_label, created_at` |
| `bids` | staff | adds `bidder_name, bidder_phone, deleted_at, deleted_by, delete_reason, verified, bidder_id`. The admin treats `verified === false` as unverified; a missing column counts as live |
| `bidders` | staff | `id, name, phone, status, deposit_confirmed, code, approved_at, registration_number, registration_auction_id, created_at` |
| `auction_events` | anon insert | Event names are unchanged: `view, list_view, bid_open, bid_submit, register_submit, whatsapp, share`. `bid_submit` now also fires for saved unverified offers |

### Ranking rule on the leaderboard

The leaderboard sorts by amount (highest first), then `created_at` (earliest wins ties). Ties can happen when two people's unverified offers of the same amount are both approved later.

The visitor's own row ("You") is matched by amount, stored on their device. If you'd rather prevent equal amounts going public, raise it with the owner. It's an option, not required.

---

## 6. Already done in the front end (no backend work)

- Offer form, validation, phone normalisation, success / error / blocked screens, WhatsApp hand-off (`auction-car.html`).
- Bidder code path kept (`place_bid`), including the `?enter_code=1` deep link sent in the approval WhatsApp message.
- Leaderboard, chips, toasts, outbid banner, "Beat the leader" pre-fill, timer urgency, closed state.
- Admin: Unverified / Live badges, public price vs unverified highest, **Make live**, "Waiting to go live" per pending bidder, approve-confirm text, updated approval WhatsApp text.
- Terms `2026-11-28-offer-1` and Privacy Notice. The owner should still review the legal wording.

---

## 7. Front-end follow-up after B4 / B5

In `auction-car.html`, delete `LEGACY_TERMS_VERSION` and use `TERMS_VERSION` in the `register_bidder` fallback (search `LEGACY_TERMS_VERSION`, two places). Nothing else changes: the page uses `submit_offer` automatically once it exists.

---

## 8. Verification after deploying

Use a clearly marked test name such as `TEST – <agent>`. If possible, use a phone number the team controls.

1. **Offer saved:** on the live listing, make an offer.
   - Expect a success screen titled "Offer received" with a `KG-…` reference, and WhatsApp opening with the details.
   - The leaderboard and price do **not** change.
2. **SQL checks:**
   - `select id, amount, verified, bidder_id from bids order by created_at desc limit 1;` returns `verified=false`.
   - `select count(*) from public_bids where amount = <amount>;` returns `0`.
3. **Admin:** the offer shows **Unverified**, the listing shows "1 unverified (highest RM …)", and the bidder is under **Pending** with "Waiting to go live".
4. **Approval:** click **Confirm deposit & approve** on the bidder.
   - The offer becomes **Live**.
   - Within 5 s the leaderboard shows it as leader, a new-leader toast appears for open pages, and the price updates.
5. **Make live:** make a second unverified offer with an approved bidder's number. It stays unverified (security rule). Click **Make live** and it publishes.
6. **Minimum check:** submit an unverified offer far above the price (say +RM 50,000). Then confirm a normal offer at the public minimum is **still accepted** (B3).
7. **Code path:** with that bidder's code, an offer goes live immediately.
8. **Fallback gone:** in browser devtools, confirm the page no longer calls `register_bidder` directly.
9. **Clean up:** remove every test registration with **Remove registration**, and confirm their offers are soft-deleted.

---

## 9. Cleanup owed from the front-end session

- **Test registration KG-000006** ("TEST Claude (delete me)", +60 11-0000 0000) was created in production while testing the fallback. Remove it in the Auction Manager.
- A few `auction_events` rows (view / bid_open / register_submit) came from local testing on `localhost:5173`. Delete them if you want clean stats: `path` = `/auction-car.html`, recent timestamps, and the referrer may be `localhost`.

---

## 10. Open decisions for the owner

- **Deposit amount and refund terms:** stays a WhatsApp conversation, with no field in the database. OK?
- **Stats (B10):** count unverified offers in staff stats?
- **Unverified at close:** should an offer that is still unverified when the auction closes be auto-declined, or kept for staff? The Terms currently say it "may be declined".
- **Anti-sniping:** extend the deadline when a verified offer lands in the last minutes? Not built. Would be a `validate_bid` / trigger change plus small front-end copy.
