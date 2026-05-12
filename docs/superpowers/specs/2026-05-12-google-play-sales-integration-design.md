# Google Play Sales Integration — Design

**Date:** 2026-05-12
**Status:** Approved (design phase)
**Target:** AppSales (Objective-C, iOS, Core Data v7 → v8)

## Goal

Extend AppSales — currently App Store Connect only — to also pull sales and
payments from Google Play, and present linked iOS/Android apps as a single
entity in the existing dashboards. Reviews and promo codes are out of scope
for v1.

## Decisions (locked in during brainstorming)

| # | Decision | Choice |
|---|---|---|
| 1 | How "first-class" is Google? | **B — Full peer**: auto-download, native account type. |
| 2 | Sales granularity (Google only publishes monthly CSVs) | **B — Synthesize daily** from the per-transaction date column in the monthly sales CSV. |
| 3 | Google auth | **A — Service account JSON**. User pastes a service-account key file, AppSales builds JWTs and exchanges them for access tokens. No OAuth client registration, no refresh-token UX. |
| 4 | App matching strategy | **B — Manual mapping only.** A new "Linked Apps" screen lets the user pair iOS apps to Android apps explicitly. No fuzzy matching. |
| 5 | Data types in scope | **B — Sales + payments**. (Reviews, promo codes deferred.) |
| 6 | App count | **A — Under 5 per store**. UI doesn't need filtering or search. |

## Architecture

### Core Data — additive v8 migration

`ASAccount` stays Apple-only. We do **not** reshape it. New entities:

- **`GoogleAccount`** — same relationship shape as `ASAccount` (one-to-many
  `Product`, `DailyReport`, `Payment`). Additional fields:
  - `displayName` (NSString)
  - `bucketName` (NSString) — e.g. `pubsite_prod_rev_1234567890`
  - `serviceAccountClientEmail` (NSString) — for the UI to display "logged in as"
  - `lastImportedMonth` (NSString, `"YYYYMM"`) — watermark
  - Service-account JSON itself lives in Keychain (not Core Data) via the
    project's existing `SAMKeychain` wrapper, keyed by the account's `objectID`
    URI — same pattern `ASAccount.password` already uses.
- **`AppLink`** — join entity linking one iOS `Product` and one Android `Product`:
  - `iOSProduct` (→ `Product`, to-one, optional)
  - `androidProduct` (→ `Product`, to-one, optional)
  - `displayName` (NSString) — overrides the per-store name when both products
    share a row in the UI
  - `color` (transformable UIColor) — unified colour for the linked app

`Product` is reused for both stores. We can tell stores apart by which
`account` (`ASAccount` vs `GoogleAccount`) the product belongs to.

Migration is purely additive — Core Data handles it as a lightweight migration.

### `<DownloadableAccount>` protocol

The only refactor of existing code. Sites that currently say
`ASAccount *account` and read generic fields (`displayName`,
`isDownloadingReports`, `downloadStatus`, `downloadProgress`, `sortIndex`) are
retargeted to `id<DownloadableAccount>`. `ASAccount` and `GoogleAccount` both
declare conformance.

Approx. call sites: `AccountsViewController`, `AccountsViewController+ButtonActions`,
`AppSalesAppDelegate.selectAccount:`, `ReportDownloadCoordinator`, `AccountStatusView`.

### Google auth — `GoogleAuthManager`

Self-contained class. Inputs: service-account JSON. Output: bearer access token
with ~1-hour TTL, cached in memory.

1. Parse JSON (standard `NSJSONSerialization`).
2. Build JWT:
   - Header `{ "alg": "RS256", "typ": "JWT" }`
   - Claims: `iss = client_email`, `scope = "https://www.googleapis.com/auth/devstorage.read_only"`,
     `aud = "https://oauth2.googleapis.com/token"`, `iat`, `exp` (+1h).
3. Sign the `base64url(header).base64url(claims)` payload with the private
   key from the JSON using `Security.framework` (`SecKeyCreateSignature`
   with `kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256`).
4. POST to `oauth2.googleapis.com/token` with
   `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=<JWT>`.
5. Cache returned `access_token` until 60s before its `expires_in`.

No external dependency required. Estimated ~80–120 lines of Obj-C.

### Download path — `GoogleReportDownloadOperation`

Sibling to the existing `ReportDownloadOperation`. Concurrent NSOperation,
own delegate, own progress reporting.

Steps per run:

1. Resolve the GCS bucket (`bucketName` on the `GoogleAccount`).
2. `GET storage.googleapis.com/storage/v1/b/<bucket>/o?prefix=sales/` and
   `?prefix=earnings/` — list of monthly file objects.
3. Filter to months strictly newer than `lastImportedMonth`. (Re-importing
   the most recent month is also acceptable to catch late-arriving data;
   see "Idempotency" below.)
4. For each new month:
   - `GET .../o/<name>?alt=media` → `.zip` bytes.
   - Unzip via the existing `ZIPArchive` submodule already in `Vendor/`.
   - Parse CSV with the appropriate parser.
5. On success, advance `lastImportedMonth` and save the context.

### Parsers

- **`GoogleSalesReportParser`** — input: `salesreport_YYYYMM.csv`. Per row,
  emit a `Transaction` attached to the matching Google-side `Product`
  (resolved by package name), grouped into a `DailyReport` keyed by the row's
  **Transaction Date** column. So one monthly CSV expands into ~30 `DailyReport`
  rows, each with the transactions that actually happened that day. This is
  how we get the synthesized-daily view.

- **`GoogleEarningsReportParser`** — input: `earnings_YYYYMM_XX.csv`. Per row,
  emit a `Payment` on the `GoogleAccount`. One CSV per country/currency
  combination; combine into a single payment record per month per currency.

Both parsers must:
- Translate Google "Transaction Type" values (Charge, Charge refund,
  Chargeback, Tax, Google fee, …) into the existing Apple-style transaction
  type constants used elsewhere. Refund rows must map to whatever refund
  transaction-type Apple uses, so existing aggregation handles them.
- Use **merchant currency** as the canonical amount (this is the figure that
  actually hits the bank). `CurrencyManager` continues to convert to the
  user's display currency.
- Tolerate missing optional columns; Google has changed the CSV schema before.

### Coordinator dispatch

`ReportDownloadCoordinator.downloadReportsForAccount:` becomes a 2-branch
dispatch:

```objc
if ([account isKindOfClass:[ASAccount class]]) {
    // existing path
} else if ([account isKindOfClass:[GoogleAccount class]]) {
    // new GoogleReportDownloadOperation
}
```

Or, cleaner: the protocol declares `- (NSOperation *)makeDownloadOperation;`
and the coordinator just enqueues whatever each account hands back.

### App-linking UI — `LinkedAppsViewController`

New screen reachable from Settings. Two-column layout:

```
iOS Apps              Android Apps
─────────────         ─────────────
[ ] MyApp ←──linked──→ [ ] MyApp
[ ] OtherApp           [ ] OtherApp Android
                       [ ] ThirdApp
```

Tap an iOS row, then tap an Android row → creates an `AppLink`. Tap a linked
row → offers "Unlink". Unlinked products on either side render as themselves
on the dashboard.

With under 5 apps per store, no filtering / search / drag-and-drop needed.

### Dashboard & detail views

- New helper `-[Product linkedDisplayIdentity]` returning either the
  `AppLink` (if one exists) or the `Product` itself.
- All per-app aggregation (`DashboardViewController`, `ReportDetailViewController`)
  groups by `linkedDisplayIdentity` instead of by `Product.productID`.
- Where the UI currently shows a per-product icon/colour/name, it now reads
  from the link (when present) so iOS + Android totals merge into a single
  row with one name and one colour.
- Sales chart already aggregates `Transaction` rows by date — no change needed
  once Google `Transaction` rows exist with real dates.

### Account picker

`AppSalesAppDelegate.selectAccount:` shows both `ASAccount` and `GoogleAccount`
in one list. Small platform glyph distinguishes Apple vs Play.

## Idempotency, edge cases, and known sharp edges

- **Re-imports.** Re-importing a month must replace, not duplicate. Strategy:
  on import, delete any `Transaction`/`Payment` rows associated with that
  month + `GoogleAccount` first, then insert fresh. Cheap, safe.
- **Late-arriving data.** Google occasionally re-publishes an earlier month
  with corrections. Always re-fetch the most recent already-imported month
  in addition to truly new months.
- **Refunds.** Google emits negative-quantity rows; map to Apple's refund
  transaction type so existing refund handling works without changes.
- **Currency.** Use merchant currency as the canonical amount in `Transaction`;
  `CurrencyManager` handles the display-currency conversion.
- **Empty current month.** No data lands until ~day 5 of the following month;
  this is honest behaviour, not a bug. The "today" tile may show only Apple
  numbers for several days; document this in-app if it confuses.
- **Service account expiry.** Service-account keys don't expire by default but
  the user may rotate them; surface "Token request failed" clearly so the
  user knows to re-paste.
- **Bucket discovery.** First-time setup needs the bucket name. Either ask
  the user to paste it (it's visible in Play Console → Download reports), or
  attempt to auto-list buckets the service account has access to via the
  GCS API and pick the one matching `pubsite_prod_rev_*`.

## Out of scope (v1)

- Google Play reviews (separate API; equivalent in effort to the existing
  `ReviewDownloadOperation`).
- Promo codes for Google Play.
- OAuth / "Sign in with Google" — service account only.
- Fuzzy app matching — manual only.
- Per-row currency display (we use one canonical merchant currency per row).
- Subscription-specific UI (subscriptions ride along as transactions for now).

## Effort estimate

| # | Chunk | Days |
|---|---|---|
| 1 | Core Data v8 + new entities + migration | 0.5 |
| 2 | `<DownloadableAccount>` protocol + retrofit | 0.5 |
| 3 | "Add Google Account" UI (paste JSON, test connection) | 0.5 |
| 4 | `GoogleAuthManager` (JWT + RS256 + token exchange) | 1.0 |
| 5 | GCS list + download + unzip | 0.5 |
| 6 | `GoogleSalesReportParser` | 1.5 |
| 7 | `GoogleEarningsReportParser` | 0.5 |
| 8 | `GoogleReportDownloadOperation` orchestration | 0.5 |
| 9 | `ReportDownloadCoordinator` dispatch | 0.5 |
| 10 | `AppLink` + `LinkedAppsViewController` | 1.0 |
| 11 | Dashboard + detail-view linked-app integration | 1.5 |
| 12 | Account picker shows both account types | 0.25 |
| 13 | Testing with real CSVs | 1.0 |
| | **Total focused work** | **~9.25 d** |
| | **Realistic calendar time** | **2–3 weeks** |

## Risks (ranked)

1. **JWT RS256 in Obj-C.** Doable with `Security.framework`, ~80–120 lines,
   but fiddlier than Swift. Mitigation: hand-roll first; a small git submodule
   in `Vendor/` as the escape hatch (matches the project's dependency style —
   it doesn't use CocoaPods or SPM).
2. **Dashboard aggregation refactor.** The aggregation code in
   `DashboardViewController` / `ReportDetail*` assumes "one account, key by
   Apple productID". Risk: 1.5 d estimate could grow to 3 d if tangled.
   Mitigation: route every aggregation through a single
   `-[Product linkedDisplayIdentity]` helper.
3. **Currency normalisation.** Decision (merchant currency) locked in the
   spec; parser is the only place it matters.
4. **Refund row mapping.** Easy to miss; surface in test cases early.

## Suggested decomposition (5 PRs)

1. **Data model** — v8 migration, `GoogleAccount`, `AppLink`,
   `<DownloadableAccount>` protocol. No new functionality. (~1.5 d)
2. **Google auth + download** — `GoogleAuthManager`, GCS list/download.
   Verifiable by dumping files to disk. (~2 d)
3. **Parsers + import** — parsers wire downloaded CSVs into Core Data.
   Behind a developer flag; data lands but UI doesn't show it yet. (~2.5 d)
4. **Linking UI + dashboard integration** — `LinkedAppsViewController`,
   `linkedDisplayIdentity`. Feature flips on here. (~2.5 d)
5. **Account picker + polish** — both account types in picker, edge cases.
   (~0.75 d)

Each PR is independently mergeable and ships a coherent slice.
