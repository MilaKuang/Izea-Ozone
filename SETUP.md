# Repack Ledger setup (about 15 minutes, one time)

1. Create a free project at supabase.com. Pick a strong database password and save it.
2. Open setup.sql in a text editor. Change the three example emails in the members list to the real emails of Izea, Mila and Alex (lowercase). Only these emails can see or change data.
3. In Supabase go to SQL Editor, New query, paste the whole edited setup.sql, press Run. It should finish with "Success".
   Already ran an earlier setup.sql? Do not run it again. Run upgrade.sql instead (adds trades and photos to your existing database).
4. In Supabase go to Authentication, Users, Add user, Create new user. Make one user per person with the same email as in the members list, and tick Auto Confirm User. Give each a password (they can change it in the app).
5. Authentication, Sign In / Providers: turn OFF "Allow new users to sign up". Authentication, URL Configuration: set Site URL to the address where you host the app (needed for the Forgot password link).
6. Project Settings, API: copy the Project URL and the anon public key into config.js.
7. Upload the whole folder to Vercel (or any static host that uses https). Open the link on each phone, sign in, then Add to Home Screen (Share menu on iPhone, browser menu on Android).

Notes
- Everyone sees the same live data. Edits appear on other phones within a second or two.
- "Added by" and "Last edited by" are set by the database from the signed-in email, so they cannot be faked. The Activity tab is read-only for everyone.
- Weeks close for everyone at once. Closed weeks stay in History.
- Back up now and then: Settings, Export backup. Supabase also keeps daily backups on paid plans.

Trades, photos and sale percentages
- Photos: on any card, buy (spend) or payout tap Take photo or Choose photo. They are stored privately and only signed-in members can see them. Photos are shrunk on the phone before upload.
- Trades: open the card, set Status to "Traded to a customer", enter the trade value and any cash received, then tap Add received card for each card you got. Only the cash is split between partners. Received cards show a Trade-in badge and are linked to the slab you gave up.
- Selling at a different percentage: set Status to "Sold for cash" and tap 88, 90, 92 or 94 (or type any percent, or the sale price). The partner split can change on every sale. The consignor rate is set per card.
- Selling many at once: on the Cards tab tap Select / sell many, tick the cards (or All shown), tap Sell at %. Pick a percent or type one total price for the lot (it is spread across the cards by market value). One payout per partner is recorded, and cards owned by one partner pay that partner in full.
- The Summary tab shows your average sold % of market value, so you can see how close you stay to 90-94%.
