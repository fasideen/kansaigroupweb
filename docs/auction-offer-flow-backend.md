# Instant offer flow: backend handoff

**For:** the agent or person with access to the Supabase project `ieqflqzcurwfyxobprro`.
**Front-end branch:** `feature/instant-offer-flow` (local only, not pushed).
**Draft SQL:** [`supabase/migrations/20261128000000_instant_offers.sql`](../supabase/migrations/20261128000000_instant_offers.sql)

## What changed for visitors

Before: register → WhatsApp → pay deposit → staff approve → bidder code → only then make an offer.

Now, on `auction-car.html`:

1. The visitor taps **Make an Offer** and enters the amount, their name and WhatsApp number in one form.
2. **Send offer** saves the offer with `submit_offer` (new) and opens WhatsApp to **+60 11-5117 7026** with the offer pre-filled. The visitor taps Send.
3. Staff verify the bidder and take the refundable deposit on WhatsApp, then click **Confirm deposit & approve** in `auction-admin.html`, the same button as today. Approving makes that bidder's offers public.

Approved bidders can still enter their **bidder code**. Offers made with the code use the existing `place_bid` and go live at once, as before.

## Rules the database must enforce

| Rule | Where |
|---|---|
| Offers sent by name + phone are saved with `bids.verified = false` | `submit_offer` |
| Unverified offers are never public | `public_bids` view adds `and b.verified` |
| Price, minimum and RM 500 step are measured against **verified** offers only | `validate_bid()` |
| Approving a bidder makes their earlier offers public | trigger `bidders_publish_offers` |
| Existing bids and `place_bid` inserts stay public | `verified default true` |
| Typed phone of an already-approved bidder still gives an unverified offer (no identity proof) | `submit_offer` |
| Blocked numbers cannot submit | `submit_offer` raises `P0001` |
| Spam guard: at most 10 offers per number per hour | `submit_offer` raises `P0001` |
| Closed or expired listings reject offers | `submit_offer` (and `validate_bid`) |

## RPC contract used by the page

```
rpc submit_offer(p_auction uuid, p_amount numeric, p_name text, p_phone text, p_terms text) → jsonb
```

- `p_phone` arrives as digits with country code, for example `60123456789`. The page has already normalised `012-345 6789`, `+60 …` and `0060 …`.
- `p_terms` is `2026-11-28-offer-1`, the new Auction Terms version. **The live `register_bidder` rejects anything except `2026-11-whatsapp-2`** (verified 28 Nov 2026: P0001 "Refresh the page and accept the current offer terms."). Make it, and `submit_offer`, accept `2026-11-28-offer-1`. Until then the page's fallback sends the old value to `register_bidder` (constant `LEGACY_TERMS_VERSION` in `auction-car.html`), and the WhatsApp message records the real version. Remove that constant once the new version is accepted.
- Success: `{ "ok": true, "bid_id": "…", "reference": "KG-000123", "bidder_status": "pending" | "approved", "existing": bool, "verified": false }`. The page shows `reference` to the visitor and puts it in the WhatsApp message.
- Errors meant for the visitor: `raise exception using errcode = 'P0001', message = '…'`. The page shows `message` as written, so keep it short, plain and polite.
- Any other error: the page shows a generic error and a "Send this offer on WhatsApp instead" link, so the offer is not lost.

**Fallback that is live now.** While `submit_offer` doesn't exist, PostgREST answers `PGRST202`. The page then calls the existing `register_bidder(p_name, p_phone, p_terms, p_auction)`, so the registration appears under Bidders → Pending, and sends the offer amount by WhatsApp only. Once `submit_offer` is deployed the page uses it automatically. No front-end change is needed.

## Admin page (`auction-admin.html`) expectations

The admin page already reads `select * from bids`. It treats `verified === false` as unverified, and anything else (including no column) as live. With the new column it shows:

- an **Unverified** badge, highlighted rows, and "Public price" vs "N unverified (highest RM …)" per listing;
- a **Make live** button that runs `update bids set verified = true where id = …`, using the staff UPDATE policy already used for soft deletes;
- for pending bidders, "Waiting to go live: RM … · car", matched by `bids.bidder_id`, or by phone digits when `bidder_id` is null;
- new-offer toasts saying "New unverified offer".

## Before running the SQL, check these against the live schema

Run `pg_get_functiondef` or `pg_get_viewdef` on each item:

1. **`public_bids` view.** Re-create it with the same columns and name masking, adding only `and b.verified`.
2. **`validate_bid()`.** Limit its "current highest" query to `verified and deleted_at is null`. Make sure the trigger is **BEFORE INSERT only**; if it also fires on UPDATE, publishing a lower, older offer would fail.
3. **`register_bidder()`.** Confirm its return keys (`registration_ref`, `existing`, `status`), how it stores the phone (digits only?), and whether it validates `p_terms`. `submit_offer` looks the bidder up by `phone = <digits>`.
4. **`bids` columns.** Check whether `bidder_id` already exists, maybe under another name, and whether other NOT NULL columns need values on insert.
5. **`remove_bidder_registration()`.** It should still soft-delete the bidder's offers, including unverified ones.
6. **Staff alerts.** If a Telegram or other trigger on `bids` notifies staff, include whether the offer is verified in the message.
7. **Stats views.** `auction_week.bids` and `auction_stats`: decide whether to count unverified offers. Probably yes, as "offers received".

## How to verify after deploying

1. Open a live listing, e.g. `auction-car.html?id=0bf1b8f7-e6b6-4b50-a222-e179ff45d535`, and make an offer with name `TEST Claude` and a test number.
2. Expected: a success screen with a `KG-…` reference, and WhatsApp opening with the offer. The public price does **not** change.
3. In the Auction Manager: the offer appears as **Unverified**, and the bidder is under Pending with "Waiting to go live".
4. Click **Confirm deposit & approve** on that bidder. The offer becomes **Live**, and the public page updates within 5 seconds.
5. Clean up: click **Remove registration** on the test bidder.
