# PRD: Architecture Improvement Batch

## 1. Status

Draft for review.

Date: 2026-07-07

This PRD turns the architecture review into a concrete improvement batch. It is intentionally slice-based: each item should reduce a specific operational or security risk while preserving the current RPC-first Supabase model.

No issue tracker tickets have been published yet. The proposed issue breakdown at the end needs approval first.

## 2. Background

The app is a single-page purchasing and debt-tracking system for DXMH, nghiệm thu, DXTT, công nợ, and cashier payment workflows. Its core architecture is still directionally correct:

- Business mutations go through Supabase RPCs.
- RLS remains deny-by-default.
- Frontend screens are mostly workflow surfaces over server-side rules.
- New database behavior should be introduced by new migrations, not by rewriting old migration history.

The review found that the codebase has outgrown its current shape. Two database safety issues should be handled before larger redesign work:

1. `rpc_get_debt_detail(p_ma_cn text)` exposes sensitive debt detail after only checking that a user is logged in.
2. The older batch payment RPC remains callable while the UI now uses the newer per-line cashier payment RPC.

After those safety fixes, the next improvement area is codebase navigability: the frontend has too many duplicated route, screen, form, validation, and RPC-payload rules in one large HTML file, and the active RPC implementation is hard to inspect because functions are redefined across migration history.

## 3. Problem Statement

The system has good control points, but they are becoming hard to inspect and change safely.

For money and debt data, there should be one obvious server-side interface per workflow decision. Today, old and new RPC paths can coexist, and reviewers have to reconstruct the active implementation from migration order.

For the frontend, a change to one workflow can require touching unrelated routing, menu, rendering, parsing, upload, validation, and RPC-call code. That makes redesign slower and increases the chance that later agents break behavior they did not intend to touch.

## 4. Goals

- Close the highest-risk debt-detail and cashier-payment seams.
- Keep the RPC-first security model intact.
- Make active RPC ownership visible to reviewers before future migrations are merged.
- Improve frontend locality without a big rewrite.
- Add verification surfaces that exercise the real RPC and UI-facing interfaces.
- Remove irrelevant Markdown clutter from the project folder so future agents find the right docs quickly.
- Produce follow-up issues that independent agents can safely grab.

## 5. Non-goals

- Do not convert the whole app to full RLS-everywhere.
- Do not rewrite old migrations.
- Do not replace the current single-page app in one large frontend rewrite.
- Do not change business policy for urgent payments, missing originals, or pilot scope in this batch.
- Do not publish issue tracker tickets until the proposed breakdown is approved.

## 6. Users And Risks Covered

### KTTH / Accounting

Needs debt detail, receipt confirmation, supplier payment data, and DXTT state to be visible only to the right roles.

Risk covered: sensitive công nợ details are too broadly callable.

### Thủ quỹ / Cashier

Needs one reliable path to pay approved payment lines, upload proof, and update debt balances.

Risk covered: two payment mutation paths can drift or bypass newer invariants.

### NVMH / Purchasing Staff

Needs proposal draft/create/edit behavior to stay stable while validation and payload rules become easier to test.

Risk covered: draft payload logic is mixed with DOM rendering and can regress quietly.

### Admin / Maintainer

Needs to know which RPC signature is active, which migration owns it, and which older definitions are deprecated.

Risk covered: reviewers miss stale callable functions or grants because ownership is spread across migration history.

## 7. Functional Requirements

### 7.1 Debt Detail Visibility

- Authorized users can still open the debt detail views they use today.
- Unauthorized users cannot retrieve supplier bank data, VAT information, quote evidence, approval trail, payment state, or attachment metadata through the debt detail RPC.
- The rejection behavior must be explicit enough for the frontend to show a clear permission message.
- The change must be delivered through a new migration.

### 7.2 Payment Execution

- Cashier payment should have one authoritative mutation interface.
- The stale batch payment RPC must no longer be an alternate money-moving path.
- Existing per-line payment behavior must keep supporting proof uploads, partial actual payment amount, payment method, balance checks, and row-level safety.
- The active payment path should be covered by a real RPC-flow check.

### 7.3 Active RPC Map

- Maintainers can inspect active RPC signatures, owning migrations, grants, and deprecated predecessors.
- The map should make duplicate definitions visible instead of requiring manual search.
- The map can start as a generated Markdown artifact or a script-generated report, as long as it is repeatable.

### 7.4 Verification Surface

- Static checks should be callable from a single documented entrypoint where local tooling exists.
- When Supabase CLI, `psql`, or Deno are unavailable, the verification output should say so clearly.
- The AP flow simulation should track the current receipt-to-debt-to-payment lifecycle rather than stale payment interfaces.

### 7.5 Frontend Navigation Locality

- Screen metadata should have one source of truth for id, label, permission, menu placement, and notification/deep-link behavior.
- Role menus, tabs, and notification navigation should derive from that source.
- Orphan or hidden route behavior should be resolved deliberately.

### 7.6 Proposal Draft Locality

- Proposal draft parsing, money/VAT normalization, required-field validation, quote/attachment handling, and RPC payload building should sit behind a smaller internal interface.
- Create and edit flows should call the same draft-building path.
- The UI should remain familiar to current users.

## 8. Rollout Plan

1. Ship the debt-detail and payment-path safety fixes first.
2. Add active RPC inspection and update the AP flow simulation so later migration reviews have a better safety net.
3. Refactor frontend navigation and proposal draft behavior in narrow internal seams.
4. Keep each slice independently verifiable before starting the next dependent slice.

## 9. Success Criteria

- Unauthorized users cannot call the debt detail RPC to retrieve sensitive data.
- The stale batch payment RPC is no longer a callable alternate path.
- The current cashier payment UI still works through the per-line path.
- Reviewers can identify active RPC ownership without reading every migration manually.
- The AP simulation covers current KTTH confirmation and cashier payment behavior.
- Screen metadata is centralized enough that adding or renaming a screen does not require editing several disconnected lists.
- Proposal draft logic can be tested or inspected without driving the whole UI.
- Irrelevant Markdown files are removed from the project folder without deleting current operating docs.

## 10. Open Questions

- Should the stale batch payment RPC be dropped outright, revoked and left in place, or converted into a compatibility wrapper that delegates safely?
- Which roles should be allowed to view full debt detail: KTTH only, KTTH plus cashier for approved payment lines, leadership oversight, Admin, or a more specific permission helper?
- Should active RPC mapping be generated in CI immediately, or start as a local maintainer script first?
- Should frontend modules remain inside the current HTML file initially, or move to separate static JS files served from `public/`?
- Which Markdown files count as irrelevant versus useful historical handoff material?

## 11. Proposed Issue Breakdown

These issues are drafted as tracer-bullet slices. They should not be published until the breakdown is approved.

### Issue 1: Add An Active RPC Ownership Map

**Blocked by:** None

**User stories covered:** Admin / maintainer can see which RPC implementation is active before reviewing a migration.

#### What to build

Create a repeatable inspection surface that lists active RPC signatures, owning migrations, grants, and older duplicate definitions. The output should make stale callable functions visible before a reviewer has to inspect migration history by hand.

#### Acceptance criteria

- [ ] Maintainers can generate or read a current active RPC map from the repo.
- [ ] Duplicate RPC definitions are grouped by signature and ordered by migration.
- [ ] The map shows whether each active RPC is granted to authenticated users.
- [ ] The map identifies older definitions that are superseded or should be retired.
- [ ] The handoff or docs explain how to refresh the map.

#### Blocked by

None - can start immediately

### Issue 2: Harden Công Nợ Detail Access

**Blocked by:** None

**User stories covered:** KTTH and other authorized roles can inspect debt detail; unauthorized authenticated users cannot read sensitive supplier, VAT, quote, approval, or payment data.

#### What to build

Ship a new migration that tightens the debt-detail RPC permission boundary while preserving the current authorized debt-detail views. The frontend should continue to open detail views for allowed users and should show a clear permission failure for disallowed users.

#### Acceptance criteria

- [ ] Authorized roles can still open debt detail from existing app flows.
- [ ] Unauthorized authenticated users receive an explicit permission error.
- [ ] Sensitive supplier, VAT, quote, attachment, approval, and payment fields are not returned to unauthorized users.
- [ ] The change is made through a new migration only.
- [ ] A real RPC scenario check covers at least one allowed and one denied case.

#### Blocked by

None - can start immediately

### Issue 3: Retire The Stale Batch Payment Path

**Blocked by:** None

**User stories covered:** Thủ quỹ pays approved lines through one controlled cashier path; maintainers do not have to reason about two money-moving RPCs.

#### What to build

Remove the older batch payment RPC as an alternate payment mutation path. The accepted solution may drop it, revoke it, or convert it into a safe compatibility adapter, but it must leave one authoritative cashier payment behavior for approved payment lines.

#### Acceptance criteria

- [ ] The stale batch payment path can no longer bypass the current per-line cashier invariants.
- [ ] Current cashier payment from the UI still supports proof, payment method, actual amount, and balance checks.
- [ ] The chosen retirement strategy is documented in the migration or handoff note.
- [ ] A real RPC scenario check proves the stale path is unavailable or safely delegated.
- [ ] No old migration is rewritten.

#### Blocked by

None - can start immediately

### Issue 4: Refresh The AP Flow Simulation Around Current Payment Lifecycle

**Blocked by:** Issue 3

**User stories covered:** Admin / maintainer can simulate the current flow from proposal through receipt confirmation, DXTT approval, cashier payment, and debt update.

#### What to build

Update the AP simulation so it exercises the current workflow interfaces instead of stale receipt or payment paths. The simulation should remain safe to run in a transaction with rollback and should report PASS/FAIL in a way a maintainer can trust.

#### Acceptance criteria

- [ ] The simulation covers receipt update, KTTH debt confirmation, payment request approval, cashier payment, and debt balance update.
- [ ] Required bank, VAT, receipt, and proof fields match current RPC expectations.
- [ ] The simulation no longer depends on retired payment interfaces.
- [ ] The output still gives clear PASS/FAIL rows.
- [ ] The handoff explains any tooling that was unavailable during verification.

#### Blocked by

- Issue 3

### Issue 5: Centralize Screen Registry And Navigation Intent

**Blocked by:** None

**User stories covered:** Users see the right screens for their role; notification and deep-link navigation route to the same screen definitions as the visible menus.

#### What to build

Create one screen registry that owns screen id, label, permission requirement, menu placement, tab placement, and notification or deep-link behavior. Existing navigation should keep working, but screen metadata should no longer be copied across several lists.

#### Acceptance criteria

- [ ] Role menus and tabs derive from one registry.
- [ ] Notification and hash navigation validate against the same screen definitions.
- [ ] Any orphan or hidden payment-related route is removed, redirected, or folded into the active payment/debt screen deliberately.
- [ ] Existing roles still land on appropriate default screens.
- [ ] Static frontend checks still pass.

#### Blocked by

None - can start immediately

### Issue 6: Extract Proposal Draft Payload And Validation

**Blocked by:** None

**User stories covered:** NVMH can create or edit purchase proposals with the same behavior as today; maintainers can change proposal validation without touching unrelated rendering and routing.

#### What to build

Move proposal draft parsing, money/VAT normalization, quote evidence handling, required-field validation, and RPC payload creation behind a smaller internal interface used by both create and edit flows.

#### Acceptance criteria

- [ ] Create and edit proposal flows use the same draft-building path.
- [ ] Existing validation messages and required fields remain understandable to users.
- [ ] Money, VAT, prepay, supplier, quote, and attachment fields produce the same payload shape as before unless a bug is explicitly fixed.
- [ ] The new seam can be exercised without clicking through the whole UI.
- [ ] Static frontend checks still pass.

#### Blocked by

None - can start immediately

### Issue 7: Unify Debt And Payment Detail UI Handling

**Blocked by:** Issue 2

**User stories covered:** KTTH, leadership, and cashier users get consistent debt/payment detail behavior; denied users get a clear message rather than confusing missing data.

#### What to build

Introduce one UI-facing detail loader and presentation path for debt/payment detail views. It should consume the hardened debt-detail RPC behavior and normalize loading, success, empty, and permission-denied states across the existing screens that show debt detail.

#### Acceptance criteria

- [ ] Existing debt/payment detail entry points use one shared loader or adapter.
- [ ] Permission-denied responses are shown consistently.
- [ ] Authorized users still see the same relevant debt, supplier, evidence, approval, and payment fields.
- [ ] The UI handles missing or partial detail data without breaking the current screen.
- [ ] Static frontend checks still pass.

#### Blocked by

- Issue 2

### Issue 8: Remove Irrelevant Markdown Files From The Project Folder

**Blocked by:** None

**User stories covered:** Future maintainers and follow-up agents can find the current setup, handoff, PRD, and operating docs without sorting through stale or unrelated Markdown notes.

#### What to build

Audit the Markdown files in the project folder and remove files that are unrelated, obsolete, duplicated, or only useful as discarded draft material. Keep current operating docs, setup docs, permission docs, PRDs, and handoff material that is still relevant to the product or deployment workflow.

#### Acceptance criteria

- [ ] The project-root and docs-folder Markdown files are inventoried before deletion.
- [ ] Irrelevant, obsolete, duplicate, or discarded-draft Markdown files are removed from the project folder.
- [ ] Current operating docs needed for setup, permissions, handoff, deployment, or active PRDs are preserved.
- [ ] Any references to removed Markdown files are updated or removed.
- [ ] The final handoff note lists which Markdown files were removed and why.
- [ ] No application runtime files, migrations, or frontend behavior are changed.

#### Blocked by

None - can start immediately

## 12. Approval Questions

- Is this granularity right, too coarse, or too fine?
- Are the dependencies correct, especially Issue 4 depending on Issue 3 and Issue 7 depending on Issue 2?
- Should any issues be merged or split before publishing?
- Should Issue 1 be required before the SQL safety fixes, or should the safety fixes stay independently startable?
- Should Issue 8 remove stale Markdown outright, or should some files be moved into an archive folder first?
