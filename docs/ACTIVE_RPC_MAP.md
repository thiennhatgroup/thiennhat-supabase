# Active RPC Ownership Map

Generated from `supabase/migrations` by `scripts/generate_active_rpc_map.mjs`.

Refresh with:

```sh
node scripts/generate_active_rpc_map.mjs
```

Check that the committed map is current with:

```sh
node scripts/generate_active_rpc_map.mjs --check
```

## Summary

- Migrations scanned: 73
- Active RPC signatures: 89
- Active RPC signatures granted to `authenticated`: 89
- Active RPC signatures with prior duplicate definitions: 44
- Retired/dropped RPC signatures: 10

## Active RPCs

| RPC signature | Active owner | Authenticated grant | Superseded definitions |
| --- | --- | --- | --- |
| `rpc_ack_proposal_done(text)` | supabase/migrations/0061_ack_proposal_done.sql:10 | Yes (supabase/migrations/0061_ack_proposal_done.sql:21) | - |
| `rpc_add_department(text)` | supabase/migrations/0068_split_overbroad_permissions.sql:279 | Yes (supabase/migrations/0068_split_overbroad_permissions.sql:1080) | supabase/migrations/0030_proposal_edit_dept.sql:19<br>supabase/migrations/0067_audit_sensitive_actions.sql:380 |
| `rpc_add_group_members(uuid,jsonb)` | supabase/migrations/0054_chat_groups.sql:48 | Yes (supabase/migrations/0054_chat_groups.sql:127) | - |
| `rpc_add_material_group(text)` | supabase/migrations/0021_rpc_groups_bank_acceptance.sql:97 | Yes (supabase/migrations/0021_rpc_groups_bank_acceptance.sql:190) | - |
| `rpc_add_price_quote(date,text,text,numeric,text,text,numeric,text,text)` | supabase/migrations/0044_quote_vat_rate.sql:179 | Yes (supabase/migrations/0044_quote_vat_rate.sql:210) | - |
| `rpc_add_price_quotes_batch(text,date,jsonb)` | supabase/migrations/0050_quote_multi_covat.sql:178 | Yes (supabase/migrations/0050_quote_multi_covat.sql:205) | - |
| `rpc_add_proposer(text,text,uuid)` | supabase/migrations/0071_department_assignment_admin_fields.sql:47 | Yes (supabase/migrations/0071_department_assignment_admin_fields.sql:196) | - |
| `rpc_admin_create_user(text,text,text,text,uuid)` | supabase/migrations/0071_department_assignment_admin_fields.sql:94 | Yes (supabase/migrations/0071_department_assignment_admin_fields.sql:197) | - |
| `rpc_admin_list_audit_log(int,text,text,date,date)` | supabase/migrations/0067_audit_sensitive_actions.sql:241 | Yes (supabase/migrations/0067_audit_sensitive_actions.sql:481) | - |
| `rpc_admin_list_users()` | supabase/migrations/0068_split_overbroad_permissions.sql:301 | Yes (supabase/migrations/0068_split_overbroad_permissions.sql:1081) | supabase/migrations/0022_admin_users.sql:64 |
| `rpc_admin_reset_pin(uuid,text)` | supabase/migrations/0022_admin_users.sql:100 | Yes (supabase/migrations/0022_admin_users.sql:118) | - |
| `rpc_admin_update_user(uuid,text,text,text,text,uuid)` | supabase/migrations/0071_department_assignment_admin_fields.sql:136 | Yes (supabase/migrations/0071_department_assignment_admin_fields.sql:198) | - |
| `rpc_approve_payment_request(text,text)` | supabase/migrations/0018_rpc_payment_requests.sql:168 | Yes (supabase/migrations/0018_rpc_payment_requests.sql:252) | - |
| `rpc_approve_payreq_day(date,text)` | supabase/migrations/0048_payreq_day_batch.sql:60 | Yes (supabase/migrations/0048_payreq_day_batch.sql:150) | - |
| `rpc_approve_proposal(text,text)` | supabase/migrations/0065_proposal_ownership_visibility.sql:866 | Yes (supabase/migrations/0065_proposal_ownership_visibility.sql:1244) | supabase/migrations/0016_rpc_proposal_v2.sql:144<br>supabase/migrations/0025_approval_routing.sql:30<br>supabase/migrations/0029_rpc_attachments_flow.sql:81<br>supabase/migrations/0037_prepay_settlement.sql:150 |
| `rpc_audit_sensitive_file_link(text,text,text,text,text)` | supabase/migrations/0067_audit_sensitive_actions.sql:163 | Yes (supabase/migrations/0067_audit_sensitive_actions.sql:479) | - |
| `rpc_bootstrap()` | supabase/migrations/0068_split_overbroad_permissions.sql:49 | Yes (supabase/migrations/0068_split_overbroad_permissions.sql:1079) | supabase/migrations/0006_rpc_bootstrap_quotes.sql:16<br>supabase/migrations/0041_bootstrap_dvt.sql:7<br>supabase/migrations/0049_dept_catalog_selfservice.sql:59 |
| `rpc_bounce_payment_request(text,text)` | supabase/migrations/0048_payreq_day_batch.sql:74 | Yes (supabase/migrations/0048_payreq_day_batch.sql:151) | - |
| `rpc_bounce_proposal(text,text)` | supabase/migrations/0065_proposal_ownership_visibility.sql:795 | Yes (supabase/migrations/0065_proposal_ownership_visibility.sql:1243) | supabase/migrations/0039_bounce_proposal.sql:13<br>supabase/migrations/0042_oversight_detail.sql:56 |
| `rpc_cancel_payment_request(text,text)` | supabase/migrations/0034_oversight.sql:79 | Yes (supabase/migrations/0034_oversight.sql:118) | - |
| `rpc_cancel_proposal(text,text)` | supabase/migrations/0065_proposal_ownership_visibility.sql:764 | Yes (supabase/migrations/0065_proposal_ownership_visibility.sql:1242) | supabase/migrations/0034_oversight.sql:61 |
| `rpc_cashier_pay_line(uuid,jsonb,numeric,text)` | supabase/migrations/0062_cashier_ux_and_vat.sql:107 | Yes (supabase/migrations/0062_cashier_ux_and_vat.sql:176) | - |
| `rpc_check_business_attachment_access(text)` | supabase/migrations/0070_private_business_attachments.sql:158 | Yes (supabase/migrations/0070_private_business_attachments.sql:171) | supabase/migrations/0067_audit_sensitive_actions.sql:234 |
| `rpc_confirm_cong_no(text,numeric)` | supabase/migrations/0047_receipt_accounting_gate.sql:132 | Yes (supabase/migrations/0047_receipt_accounting_gate.sql:248) | - |
| `rpc_confirm_settlement(text)` | supabase/migrations/0009_rpc_dashboard_settlement.sql:177 | Yes (supabase/migrations/0037_prepay_settlement.sql:185) | - |
| `rpc_create_chat_group(text,jsonb)` | supabase/migrations/0054_chat_groups.sql:32 | Yes (supabase/migrations/0054_chat_groups.sql:126) | - |
| `rpc_create_material_quick(text,text,text)` | supabase/migrations/0049_dept_catalog_selfservice.sql:18 | Yes (supabase/migrations/0049_dept_catalog_selfservice.sql:111) | - |
| `rpc_create_payment_request(jsonb)` | supabase/migrations/0056_debt_filter_and_rich_notify.sql:154 | Yes (supabase/migrations/0056_debt_filter_and_rich_notify.sql:276) | supabase/migrations/0018_rpc_payment_requests.sql:43 |
| `rpc_create_payment(jsonb)` | supabase/migrations/0008_rpc_receipts_payments.sql:73 | Yes (supabase/migrations/0008_rpc_receipts_payments.sql:171) | - |
| `rpc_create_proposal(jsonb)` | supabase/migrations/0065_proposal_ownership_visibility.sql:286 | Yes (supabase/migrations/0065_proposal_ownership_visibility.sql:1234) | supabase/migrations/0007_rpc_proposals.sql:22<br>supabase/migrations/0016_rpc_proposal_v2.sql:11<br>supabase/migrations/0029_rpc_attachments_flow.sql:9<br>supabase/migrations/0030_proposal_edit_dept.sql:54<br>supabase/migrations/0037_prepay_settlement.sql:77<br>supabase/migrations/0051_prepay_percent.sql:9 |
| `rpc_create_supplier_quick(jsonb)` | supabase/migrations/0049_dept_catalog_selfservice.sql:36 | Yes (supabase/migrations/0049_dept_catalog_selfservice.sql:112) | - |
| `rpc_delete_payment(text)` | supabase/migrations/0068_split_overbroad_permissions.sql:620 | Yes (supabase/migrations/0068_split_overbroad_permissions.sql:1087) | supabase/migrations/0036_unify_payments.sql:46 |
| `rpc_delete_push_subscription(text)` | supabase/migrations/0055_push_subscriptions.sql:32 | Yes (supabase/migrations/0055_push_subscriptions.sql:40) | - |
| `rpc_export_payment_requests(date,date)` | supabase/migrations/0068_split_overbroad_permissions.sql:819 | Yes (supabase/migrations/0068_split_overbroad_permissions.sql:1090) | supabase/migrations/0027_export_and_improvements.sql:69 |
| `rpc_export_proposals(date,date)` | supabase/migrations/0065_proposal_ownership_visibility.sql:1130 | Yes (supabase/migrations/0065_proposal_ownership_visibility.sql:1248) | supabase/migrations/0027_export_and_improvements.sql:36<br>supabase/migrations/0038_link_material_supplier.sql:70 |
| `rpc_export_quotes(date,date)` | supabase/migrations/0068_split_overbroad_permissions.sql:850 | Yes (supabase/migrations/0068_split_overbroad_permissions.sql:1091) | supabase/migrations/0027_export_and_improvements.sql:99<br>supabase/migrations/0038_link_material_supplier.sql:108 |
| `rpc_get_approved_proposals(date)` | supabase/migrations/0065_proposal_ownership_visibility.sql:981 | Yes (supabase/migrations/0065_proposal_ownership_visibility.sql:1246) | supabase/migrations/0019_approved_and_unapprove.sql:14<br>supabase/migrations/0029_rpc_attachments_flow.sql:181<br>supabase/migrations/0030_proposal_edit_dept.sql:197<br>supabase/migrations/0033_history_rpcs.sql:8 |
| `rpc_get_cashier_queue()` | supabase/migrations/0058_cashier_per_line_and_nvmh_proof.sql:77 | Yes (supabase/migrations/0058_cashier_per_line_and_nvmh_proof.sql:105) | supabase/migrations/0057_cashier_and_dashboard.sql:146 |
| `rpc_get_conversation(uuid,int)` | supabase/migrations/0031_chat.sql:40 | Yes (supabase/migrations/0031_chat.sql:78) | - |
| `rpc_get_debt_dashboard(jsonb)` | supabase/migrations/0068_split_overbroad_permissions.sql:654 | Yes (supabase/migrations/0068_split_overbroad_permissions.sql:1088) | supabase/migrations/0009_rpc_dashboard_settlement.sql:22<br>supabase/migrations/0047_receipt_accounting_gate.sql:255 |
| `rpc_get_debt_detail(text)` | supabase/migrations/0072_harden_debt_detail_access.sql:58 | Yes (supabase/migrations/0072_harden_debt_detail_access.sql:121) | supabase/migrations/0059_detail_withdraw_cashier_amount.sql:10<br>supabase/migrations/0062_cashier_ux_and_vat.sql:69<br>supabase/migrations/0066_restrict_debt_payment_evidence_access.sql:301 |
| `rpc_get_group_conversation(uuid,int)` | supabase/migrations/0054_chat_groups.sql:84 | Yes (supabase/migrations/0054_chat_groups.sql:129) | - |
| `rpc_get_my_payment_requests(int)` | supabase/migrations/0018_rpc_payment_requests.sql:156 | Yes (supabase/migrations/0018_rpc_payment_requests.sql:251) | - |
| `rpc_get_my_proposals(int)` | supabase/migrations/0061_ack_proposal_done.sql:24 | Yes (supabase/migrations/0061_ack_proposal_done.sql:50) | supabase/migrations/0024_notif_myproposals_print.sql:42<br>supabase/migrations/0039_bounce_proposal.sql:60<br>supabase/migrations/0046_richer_lists.sql:34<br>supabase/migrations/0058_cashier_per_line_and_nvmh_proof.sql:108 |
| `rpc_get_notifications(int)` | supabase/migrations/0024_notif_myproposals_print.sql:10 | Yes (supabase/migrations/0024_notif_myproposals_print.sql:105) | - |
| `rpc_get_open_receipt_items(int)` | supabase/migrations/0066_restrict_debt_payment_evidence_access.sql:154 | Yes (supabase/migrations/0066_restrict_debt_payment_evidence_access.sql:551) | supabase/migrations/0008_rpc_receipts_payments.sql:13<br>supabase/migrations/0021_rpc_groups_bank_acceptance.sql:124<br>supabase/migrations/0029_rpc_attachments_flow.sql:236<br>supabase/migrations/0047_receipt_accounting_gate.sql:217 |
| `rpc_get_payable_debts(text)` | supabase/migrations/0056_debt_filter_and_rich_notify.sql:15 | Yes (supabase/migrations/0056_debt_filter_and_rich_notify.sql:274) | supabase/migrations/0018_rpc_payment_requests.sql:12<br>supabase/migrations/0029_rpc_attachments_flow.sql:263<br>supabase/migrations/0047_receipt_accounting_gate.sql:193 |
| `rpc_get_payment_request_history(int)` | supabase/migrations/0033_history_rpcs.sql:35 | Yes (supabase/migrations/0033_history_rpcs.sql:66) | - |
| `rpc_get_payment_request(text)` | supabase/migrations/0048_payreq_day_batch.sql:94 | Yes (supabase/migrations/0048_payreq_day_batch.sql:152) | - |
| `rpc_get_pending_payment_requests()` | supabase/migrations/0018_rpc_payment_requests.sql:145 | Yes (supabase/migrations/0018_rpc_payment_requests.sql:250) | - |
| `rpc_get_pending_payreq_grouped()` | supabase/migrations/0048_payreq_day_batch.sql:12 | Yes (supabase/migrations/0048_payreq_day_batch.sql:149) | - |
| `rpc_get_pending_proposals(int)` | supabase/migrations/0030_proposal_edit_dept.sql:168 | Yes (supabase/migrations/0030_proposal_edit_dept.sql:222) | supabase/migrations/0007_rpc_proposals.sql:102<br>supabase/migrations/0016_rpc_proposal_v2.sql:99<br>supabase/migrations/0025_approval_routing.sql:93<br>supabase/migrations/0029_rpc_attachments_flow.sql:120 |
| `rpc_get_printable_proposals(boolean)` | supabase/migrations/0065_proposal_ownership_visibility.sql:1173 | Yes (supabase/migrations/0065_proposal_ownership_visibility.sql:1249) | supabase/migrations/0024_notif_myproposals_print.sql:60<br>supabase/migrations/0026_print_permission.sql:12 |
| `rpc_get_proposal(text)` | supabase/migrations/0065_proposal_ownership_visibility.sql:480 | Yes (supabase/migrations/0065_proposal_ownership_visibility.sql:1236) | supabase/migrations/0030_proposal_edit_dept.sql:94<br>supabase/migrations/0040_get_proposal_reason.sql:7<br>supabase/migrations/0051_prepay_percent.sql:87 |
| `rpc_get_quote_dashboard(text,date,int)` | supabase/migrations/0050_quote_multi_covat.sql:10 | Yes (supabase/migrations/0050_quote_multi_covat.sql:204) | supabase/migrations/0006_rpc_bootstrap_quotes.sql:56<br>supabase/migrations/0011_fix_quote_dashboard.sql:15<br>supabase/migrations/0044_quote_vat_rate.sql:11 |
| `rpc_get_receipt_history(int)` | supabase/migrations/0066_restrict_debt_payment_evidence_access.sql:195 | Yes (supabase/migrations/0066_restrict_debt_payment_evidence_access.sql:552) | supabase/migrations/0033_history_rpcs.sql:51 |
| `rpc_get_receipt_review(int)` | supabase/migrations/0063_cashier_view_only_receipt.sql:12 | Yes (supabase/migrations/0063_cashier_view_only_receipt.sql:40) | supabase/migrations/0047_receipt_accounting_gate.sql:102 |
| `rpc_get_recent(text,jsonb)` | supabase/migrations/0068_split_overbroad_permissions.sql:723 | Yes (supabase/migrations/0068_split_overbroad_permissions.sql:1089) | supabase/migrations/0010_rpc_recent.sql:8<br>supabase/migrations/0065_proposal_ownership_visibility.sql:1038 |
| `rpc_leader_dashboard(date,date)` | supabase/migrations/0068_split_overbroad_permissions.sql:878 | Yes (supabase/migrations/0068_split_overbroad_permissions.sql:1092) | supabase/migrations/0057_cashier_and_dashboard.sql:174<br>supabase/migrations/0060_hardening.sql:144<br>supabase/migrations/0066_restrict_debt_payment_evidence_access.sql:442 |
| `rpc_list_catalog()` | supabase/migrations/0068_split_overbroad_permissions.sql:325 | Yes (supabase/migrations/0068_split_overbroad_permissions.sql:1082) | supabase/migrations/0014_rpc_catalog.sql:10<br>supabase/migrations/0021_rpc_groups_bank_acceptance.sql:8<br>supabase/migrations/0030_proposal_edit_dept.sql:40<br>supabase/migrations/0049_dept_catalog_selfservice.sql:85<br>supabase/migrations/0066_restrict_debt_payment_evidence_access.sql:78 |
| `rpc_list_chat_groups()` | supabase/migrations/0054_chat_groups.sql:64 | Yes (supabase/migrations/0054_chat_groups.sql:128) | - |
| `rpc_list_contacts()` | supabase/migrations/0031_chat.sql:22 | Yes (supabase/migrations/0031_chat.sql:77) | - |
| `rpc_list_open_debts(text)` | supabase/migrations/0068_split_overbroad_permissions.sql:534 | Yes (supabase/migrations/0068_split_overbroad_permissions.sql:1085) | supabase/migrations/0035_record_debt_payment.sql:9<br>supabase/migrations/0046_richer_lists.sql:10<br>supabase/migrations/0047_receipt_accounting_gate.sql:169<br>supabase/migrations/0056_debt_filter_and_rich_notify.sql:46 |
| `rpc_list_payments(text,int)` | supabase/migrations/0068_split_overbroad_permissions.sql:501 | Yes (supabase/migrations/0068_split_overbroad_permissions.sql:1084) | supabase/migrations/0036_unify_payments.sql:25<br>supabase/migrations/0060_hardening.sql:121<br>supabase/migrations/0066_restrict_debt_payment_evidence_access.sql:356 |
| `rpc_mark_all_notifications_read()` | supabase/migrations/0024_notif_myproposals_print.sql:34 | Yes (supabase/migrations/0024_notif_myproposals_print.sql:107) | - |
| `rpc_mark_notification_read(uuid)` | supabase/migrations/0024_notif_myproposals_print.sql:26 | Yes (supabase/migrations/0024_notif_myproposals_print.sql:106) | - |
| `rpc_oversight_proposal_detail(text)` | supabase/migrations/0065_proposal_ownership_visibility.sql:745 | Yes (supabase/migrations/0065_proposal_ownership_visibility.sql:1241) | supabase/migrations/0042_oversight_detail.sql:11<br>supabase/migrations/0051_prepay_percent.sql:145 |
| `rpc_oversight(date,date)` | supabase/migrations/0065_proposal_ownership_visibility.sql:684 | Yes (supabase/migrations/0065_proposal_ownership_visibility.sql:1240) | supabase/migrations/0034_oversight.sql:19<br>supabase/migrations/0053_oversight_fields.sql:7 |
| `rpc_payment_request_detail(text)` | supabase/migrations/0066_restrict_debt_payment_evidence_access.sql:390 | Yes (supabase/migrations/0066_restrict_debt_payment_evidence_access.sql:556) | supabase/migrations/0043_payreq_detail.sql:9 |
| `rpc_preview_settlement(text)` | supabase/migrations/0009_rpc_dashboard_settlement.sql:165 | Yes (supabase/migrations/0037_prepay_settlement.sql:184) | - |
| `rpc_proposal_detail(text)` | supabase/migrations/0065_proposal_ownership_visibility.sql:665 | Yes (supabase/migrations/0065_proposal_ownership_visibility.sql:1239) | supabase/migrations/0045_proposal_detail_any.sql:8<br>supabase/migrations/0051_prepay_percent.sql:104 |
| `rpc_record_debt_payment(text,numeric,date,text,text)` | supabase/migrations/0068_split_overbroad_permissions.sql:569 | Yes (supabase/migrations/0068_split_overbroad_permissions.sql:1086) | supabase/migrations/0035_record_debt_payment.sql:27<br>supabase/migrations/0060_hardening.sql:96 |
| `rpc_reject_payment_request(text,text)` | supabase/migrations/0018_rpc_payment_requests.sql:184 | Yes (supabase/migrations/0018_rpc_payment_requests.sql:253) | - |
| `rpc_reject_proposal(text,text)` | supabase/migrations/0065_proposal_ownership_visibility.sql:954 | Yes (supabase/migrations/0065_proposal_ownership_visibility.sql:1245) | supabase/migrations/0007_rpc_proposals.sql:184 |
| `rpc_rename_material_group(text,text)` | supabase/migrations/0021_rpc_groups_bank_acceptance.sql:108 | Yes (supabase/migrations/0021_rpc_groups_bank_acceptance.sql:191) | - |
| `rpc_return_receipt(text,text)` | supabase/migrations/0047_receipt_accounting_gate.sql:149 | Yes (supabase/migrations/0047_receipt_accounting_gate.sql:249) | - |
| `rpc_save_push_subscription(text,text,text)` | supabase/migrations/0055_push_subscriptions.sql:20 | Yes (supabase/migrations/0055_push_subscriptions.sql:39) | - |
| `rpc_send_group_message(uuid,text,jsonb,text)` | supabase/migrations/0054_chat_groups.sql:106 | Yes (supabase/migrations/0054_chat_groups.sql:130) | - |
| `rpc_send_message(uuid,text,jsonb,text)` | supabase/migrations/0031_chat.sql:59 | Yes (supabase/migrations/0031_chat.sql:79) | - |
| `rpc_submit_improvement(text)` | supabase/migrations/0027_export_and_improvements.sql:20 | Yes (supabase/migrations/0027_export_and_improvements.sql:124) | - |
| `rpc_submit_proposal(text)` | supabase/migrations/0067_audit_sensitive_actions.sql:286 | Yes (supabase/migrations/0067_audit_sensitive_actions.sql:482) | supabase/migrations/0029_rpc_attachments_flow.sql:64<br>supabase/migrations/0039_bounce_proposal.sql:77<br>supabase/migrations/0051_prepay_percent.sql:189<br>supabase/migrations/0065_proposal_ownership_visibility.sql:534 |
| `rpc_unapprove_proposal(text,text)` | supabase/migrations/0029_rpc_attachments_flow.sql:154 | Yes (supabase/migrations/0029_rpc_attachments_flow.sql:290) | supabase/migrations/0019_approved_and_unapprove.sql:60 |
| `rpc_update_payment_request(text,jsonb)` | supabase/migrations/0056_debt_filter_and_rich_notify.sql:195 | Yes (supabase/migrations/0056_debt_filter_and_rich_notify.sql:277) | supabase/migrations/0048_payreq_day_batch.sql:113 |
| `rpc_update_proposal(text,jsonb)` | supabase/migrations/0065_proposal_ownership_visibility.sql:393 | Yes (supabase/migrations/0065_proposal_ownership_visibility.sql:1235) | supabase/migrations/0030_proposal_edit_dept.sql:112<br>supabase/migrations/0037_prepay_settlement.sql:116<br>supabase/migrations/0051_prepay_percent.sql:52 |
| `rpc_update_receipt(jsonb)` | supabase/migrations/0068_split_overbroad_permissions.sql:425 | Yes (supabase/migrations/0068_split_overbroad_permissions.sql:1083) | supabase/migrations/0008_rpc_receipts_payments.sql:35<br>supabase/migrations/0021_rpc_groups_bank_acceptance.sql:156<br>supabase/migrations/0029_rpc_attachments_flow.sql:210<br>supabase/migrations/0030_proposal_edit_dept.sql:146<br>supabase/migrations/0047_receipt_accounting_gate.sql:68<br>supabase/migrations/0056_debt_filter_and_rich_notify.sql:235<br>supabase/migrations/0059_detail_withdraw_cashier_amount.sql:145<br>supabase/migrations/0062_cashier_ux_and_vat.sql:18<br>supabase/migrations/0066_restrict_debt_payment_evidence_access.sql:227 |
| `rpc_upsert_doi_tuong(jsonb)` | supabase/migrations/0021_rpc_groups_bank_acceptance.sql:36 | Yes (supabase/migrations/0021_rpc_groups_bank_acceptance.sql:189) | supabase/migrations/0014_rpc_catalog.sql:112 |
| `rpc_upsert_material(jsonb)` | supabase/migrations/0014_rpc_catalog.sql:50 | Yes (supabase/migrations/0014_rpc_catalog.sql:182) | - |
| `rpc_withdraw_payment_request(text,text)` | supabase/migrations/0059_detail_withdraw_cashier_amount.sql:38 | Yes (supabase/migrations/0059_detail_withdraw_cashier_amount.sql:55) | - |
| `rpc_withdraw_proposal(text,text)` | supabase/migrations/0065_proposal_ownership_visibility.sql:573 | Yes (supabase/migrations/0065_proposal_ownership_visibility.sql:1238) | supabase/migrations/0059_detail_withdraw_cashier_amount.sql:58 |

## Duplicate Definition History

### `rpc_add_department(text)`

- supabase/migrations/0030_proposal_edit_dept.sql:19 - superseded
- supabase/migrations/0067_audit_sensitive_actions.sql:380 - superseded
- supabase/migrations/0068_split_overbroad_permissions.sql:279 - active owner

### `rpc_admin_list_users()`

- supabase/migrations/0022_admin_users.sql:64 - superseded
- supabase/migrations/0068_split_overbroad_permissions.sql:301 - active owner

### `rpc_approve_proposal(text,text)`

- supabase/migrations/0016_rpc_proposal_v2.sql:144 - superseded
- supabase/migrations/0025_approval_routing.sql:30 - superseded
- supabase/migrations/0029_rpc_attachments_flow.sql:81 - superseded
- supabase/migrations/0037_prepay_settlement.sql:150 - superseded
- supabase/migrations/0065_proposal_ownership_visibility.sql:866 - active owner

### `rpc_bootstrap()`

- supabase/migrations/0006_rpc_bootstrap_quotes.sql:16 - superseded
- supabase/migrations/0041_bootstrap_dvt.sql:7 - superseded
- supabase/migrations/0049_dept_catalog_selfservice.sql:59 - superseded
- supabase/migrations/0068_split_overbroad_permissions.sql:49 - active owner

### `rpc_bounce_proposal(text,text)`

- supabase/migrations/0039_bounce_proposal.sql:13 - superseded
- supabase/migrations/0042_oversight_detail.sql:56 - superseded
- supabase/migrations/0065_proposal_ownership_visibility.sql:795 - active owner

### `rpc_cancel_proposal(text,text)`

- supabase/migrations/0034_oversight.sql:61 - superseded
- supabase/migrations/0065_proposal_ownership_visibility.sql:764 - active owner

### `rpc_check_business_attachment_access(text)`

- supabase/migrations/0067_audit_sensitive_actions.sql:234 - superseded
- supabase/migrations/0070_private_business_attachments.sql:158 - active owner

### `rpc_create_payment_request(jsonb)`

- supabase/migrations/0018_rpc_payment_requests.sql:43 - superseded
- supabase/migrations/0056_debt_filter_and_rich_notify.sql:154 - active owner

### `rpc_create_proposal(jsonb)`

- supabase/migrations/0007_rpc_proposals.sql:22 - superseded
- supabase/migrations/0016_rpc_proposal_v2.sql:11 - superseded
- supabase/migrations/0029_rpc_attachments_flow.sql:9 - superseded
- supabase/migrations/0030_proposal_edit_dept.sql:54 - superseded
- supabase/migrations/0037_prepay_settlement.sql:77 - superseded
- supabase/migrations/0051_prepay_percent.sql:9 - superseded
- supabase/migrations/0065_proposal_ownership_visibility.sql:286 - active owner

### `rpc_delete_payment(text)`

- supabase/migrations/0036_unify_payments.sql:46 - superseded
- supabase/migrations/0068_split_overbroad_permissions.sql:620 - active owner

### `rpc_export_payment_requests(date,date)`

- supabase/migrations/0027_export_and_improvements.sql:69 - superseded
- supabase/migrations/0068_split_overbroad_permissions.sql:819 - active owner

### `rpc_export_proposals(date,date)`

- supabase/migrations/0027_export_and_improvements.sql:36 - superseded
- supabase/migrations/0038_link_material_supplier.sql:70 - superseded
- supabase/migrations/0065_proposal_ownership_visibility.sql:1130 - active owner

### `rpc_export_quotes(date,date)`

- supabase/migrations/0027_export_and_improvements.sql:99 - superseded
- supabase/migrations/0038_link_material_supplier.sql:108 - superseded
- supabase/migrations/0068_split_overbroad_permissions.sql:850 - active owner

### `rpc_get_approved_proposals(date)`

- supabase/migrations/0019_approved_and_unapprove.sql:14 - superseded
- supabase/migrations/0029_rpc_attachments_flow.sql:181 - superseded
- supabase/migrations/0030_proposal_edit_dept.sql:197 - superseded
- supabase/migrations/0033_history_rpcs.sql:8 - superseded
- supabase/migrations/0065_proposal_ownership_visibility.sql:981 - active owner

### `rpc_get_cashier_queue()`

- supabase/migrations/0057_cashier_and_dashboard.sql:146 - superseded
- supabase/migrations/0058_cashier_per_line_and_nvmh_proof.sql:77 - active owner

### `rpc_get_debt_dashboard(jsonb)`

- supabase/migrations/0009_rpc_dashboard_settlement.sql:22 - superseded
- supabase/migrations/0047_receipt_accounting_gate.sql:255 - superseded
- supabase/migrations/0068_split_overbroad_permissions.sql:654 - active owner

### `rpc_get_debt_detail(text)`

- supabase/migrations/0059_detail_withdraw_cashier_amount.sql:10 - superseded
- supabase/migrations/0062_cashier_ux_and_vat.sql:69 - superseded
- supabase/migrations/0066_restrict_debt_payment_evidence_access.sql:301 - superseded
- supabase/migrations/0072_harden_debt_detail_access.sql:58 - active owner

### `rpc_get_my_proposals(int)`

- supabase/migrations/0024_notif_myproposals_print.sql:42 - superseded
- supabase/migrations/0039_bounce_proposal.sql:60 - superseded
- supabase/migrations/0046_richer_lists.sql:34 - superseded
- supabase/migrations/0058_cashier_per_line_and_nvmh_proof.sql:108 - superseded
- supabase/migrations/0061_ack_proposal_done.sql:24 - active owner

### `rpc_get_open_receipt_items(int)`

- supabase/migrations/0008_rpc_receipts_payments.sql:13 - superseded
- supabase/migrations/0021_rpc_groups_bank_acceptance.sql:124 - superseded
- supabase/migrations/0029_rpc_attachments_flow.sql:236 - superseded
- supabase/migrations/0047_receipt_accounting_gate.sql:217 - superseded
- supabase/migrations/0066_restrict_debt_payment_evidence_access.sql:154 - active owner

### `rpc_get_payable_debts(text)`

- supabase/migrations/0018_rpc_payment_requests.sql:12 - superseded
- supabase/migrations/0029_rpc_attachments_flow.sql:263 - superseded
- supabase/migrations/0047_receipt_accounting_gate.sql:193 - superseded
- supabase/migrations/0056_debt_filter_and_rich_notify.sql:15 - active owner

### `rpc_get_pending_proposals(int)`

- supabase/migrations/0007_rpc_proposals.sql:102 - superseded
- supabase/migrations/0016_rpc_proposal_v2.sql:99 - superseded
- supabase/migrations/0025_approval_routing.sql:93 - superseded
- supabase/migrations/0029_rpc_attachments_flow.sql:120 - superseded
- supabase/migrations/0030_proposal_edit_dept.sql:168 - active owner

### `rpc_get_printable_proposals(boolean)`

- supabase/migrations/0024_notif_myproposals_print.sql:60 - superseded
- supabase/migrations/0026_print_permission.sql:12 - superseded
- supabase/migrations/0065_proposal_ownership_visibility.sql:1173 - active owner

### `rpc_get_proposal(text)`

- supabase/migrations/0030_proposal_edit_dept.sql:94 - superseded
- supabase/migrations/0040_get_proposal_reason.sql:7 - superseded
- supabase/migrations/0051_prepay_percent.sql:87 - superseded
- supabase/migrations/0065_proposal_ownership_visibility.sql:480 - active owner

### `rpc_get_quote_dashboard(text,date,int)`

- supabase/migrations/0006_rpc_bootstrap_quotes.sql:56 - superseded
- supabase/migrations/0011_fix_quote_dashboard.sql:15 - superseded
- supabase/migrations/0044_quote_vat_rate.sql:11 - superseded
- supabase/migrations/0050_quote_multi_covat.sql:10 - active owner

### `rpc_get_receipt_history(int)`

- supabase/migrations/0033_history_rpcs.sql:51 - superseded
- supabase/migrations/0066_restrict_debt_payment_evidence_access.sql:195 - active owner

### `rpc_get_receipt_review(int)`

- supabase/migrations/0047_receipt_accounting_gate.sql:102 - superseded
- supabase/migrations/0063_cashier_view_only_receipt.sql:12 - active owner

### `rpc_get_recent(text,jsonb)`

- supabase/migrations/0010_rpc_recent.sql:8 - superseded
- supabase/migrations/0065_proposal_ownership_visibility.sql:1038 - superseded
- supabase/migrations/0068_split_overbroad_permissions.sql:723 - active owner

### `rpc_leader_dashboard(date,date)`

- supabase/migrations/0057_cashier_and_dashboard.sql:174 - superseded
- supabase/migrations/0060_hardening.sql:144 - superseded
- supabase/migrations/0066_restrict_debt_payment_evidence_access.sql:442 - superseded
- supabase/migrations/0068_split_overbroad_permissions.sql:878 - active owner

### `rpc_list_catalog()`

- supabase/migrations/0014_rpc_catalog.sql:10 - superseded
- supabase/migrations/0021_rpc_groups_bank_acceptance.sql:8 - superseded
- supabase/migrations/0030_proposal_edit_dept.sql:40 - superseded
- supabase/migrations/0049_dept_catalog_selfservice.sql:85 - superseded
- supabase/migrations/0066_restrict_debt_payment_evidence_access.sql:78 - superseded
- supabase/migrations/0068_split_overbroad_permissions.sql:325 - active owner

### `rpc_list_open_debts(text)`

- supabase/migrations/0035_record_debt_payment.sql:9 - superseded
- supabase/migrations/0046_richer_lists.sql:10 - superseded
- supabase/migrations/0047_receipt_accounting_gate.sql:169 - superseded
- supabase/migrations/0056_debt_filter_and_rich_notify.sql:46 - superseded
- supabase/migrations/0068_split_overbroad_permissions.sql:534 - active owner

### `rpc_list_payments(text,int)`

- supabase/migrations/0036_unify_payments.sql:25 - superseded
- supabase/migrations/0060_hardening.sql:121 - superseded
- supabase/migrations/0066_restrict_debt_payment_evidence_access.sql:356 - superseded
- supabase/migrations/0068_split_overbroad_permissions.sql:501 - active owner

### `rpc_oversight_proposal_detail(text)`

- supabase/migrations/0042_oversight_detail.sql:11 - superseded
- supabase/migrations/0051_prepay_percent.sql:145 - superseded
- supabase/migrations/0065_proposal_ownership_visibility.sql:745 - active owner

### `rpc_oversight(date,date)`

- supabase/migrations/0034_oversight.sql:19 - superseded
- supabase/migrations/0053_oversight_fields.sql:7 - superseded
- supabase/migrations/0065_proposal_ownership_visibility.sql:684 - active owner

### `rpc_payment_request_detail(text)`

- supabase/migrations/0043_payreq_detail.sql:9 - superseded
- supabase/migrations/0066_restrict_debt_payment_evidence_access.sql:390 - active owner

### `rpc_proposal_detail(text)`

- supabase/migrations/0045_proposal_detail_any.sql:8 - superseded
- supabase/migrations/0051_prepay_percent.sql:104 - superseded
- supabase/migrations/0065_proposal_ownership_visibility.sql:665 - active owner

### `rpc_record_debt_payment(text,numeric,date,text,text)`

- supabase/migrations/0035_record_debt_payment.sql:27 - superseded
- supabase/migrations/0060_hardening.sql:96 - superseded
- supabase/migrations/0068_split_overbroad_permissions.sql:569 - active owner

### `rpc_reject_proposal(text,text)`

- supabase/migrations/0007_rpc_proposals.sql:184 - superseded
- supabase/migrations/0065_proposal_ownership_visibility.sql:954 - active owner

### `rpc_submit_proposal(text)`

- supabase/migrations/0029_rpc_attachments_flow.sql:64 - superseded
- supabase/migrations/0039_bounce_proposal.sql:77 - superseded
- supabase/migrations/0051_prepay_percent.sql:189 - superseded
- supabase/migrations/0065_proposal_ownership_visibility.sql:534 - superseded
- supabase/migrations/0067_audit_sensitive_actions.sql:286 - active owner

### `rpc_unapprove_proposal(text,text)`

- supabase/migrations/0019_approved_and_unapprove.sql:60 - superseded
- supabase/migrations/0029_rpc_attachments_flow.sql:154 - active owner

### `rpc_update_payment_request(text,jsonb)`

- supabase/migrations/0048_payreq_day_batch.sql:113 - superseded
- supabase/migrations/0056_debt_filter_and_rich_notify.sql:195 - active owner

### `rpc_update_proposal(text,jsonb)`

- supabase/migrations/0030_proposal_edit_dept.sql:112 - superseded
- supabase/migrations/0037_prepay_settlement.sql:116 - superseded
- supabase/migrations/0051_prepay_percent.sql:52 - superseded
- supabase/migrations/0065_proposal_ownership_visibility.sql:393 - active owner

### `rpc_update_receipt(jsonb)`

- supabase/migrations/0008_rpc_receipts_payments.sql:35 - superseded
- supabase/migrations/0021_rpc_groups_bank_acceptance.sql:156 - superseded
- supabase/migrations/0029_rpc_attachments_flow.sql:210 - superseded
- supabase/migrations/0030_proposal_edit_dept.sql:146 - superseded
- supabase/migrations/0047_receipt_accounting_gate.sql:68 - superseded
- supabase/migrations/0056_debt_filter_and_rich_notify.sql:235 - superseded
- supabase/migrations/0059_detail_withdraw_cashier_amount.sql:145 - superseded
- supabase/migrations/0062_cashier_ux_and_vat.sql:18 - superseded
- supabase/migrations/0066_restrict_debt_payment_evidence_access.sql:227 - superseded
- supabase/migrations/0068_split_overbroad_permissions.sql:425 - active owner

### `rpc_upsert_doi_tuong(jsonb)`

- supabase/migrations/0014_rpc_catalog.sql:112 - superseded
- supabase/migrations/0021_rpc_groups_bank_acceptance.sql:36 - active owner

### `rpc_withdraw_proposal(text,text)`

- supabase/migrations/0059_detail_withdraw_cashier_amount.sql:58 - superseded
- supabase/migrations/0065_proposal_ownership_visibility.sql:573 - active owner

## Retired Or Dropped RPC Signatures

| RPC signature | Last definition | Retired by |
| --- | --- | --- |
| `rpc_add_price_quote(date,text,text,numeric,text,text,text,text)` | supabase/migrations/0006_rpc_bootstrap_quotes.sql:225 | supabase/migrations/0044_quote_vat_rate.sql:178 |
| `rpc_add_proposer(text,text)` | supabase/migrations/0067_audit_sensitive_actions.sql:403 | supabase/migrations/0071_department_assignment_admin_fields.sql:46 |
| `rpc_admin_create_user(text,text,text,text)` | supabase/migrations/0057_cashier_and_dashboard.sql:17 | supabase/migrations/0071_department_assignment_admin_fields.sql:93 |
| `rpc_admin_update_user(uuid,text,text,text,text)` | supabase/migrations/0057_cashier_and_dashboard.sql:52 | supabase/migrations/0071_department_assignment_admin_fields.sql:135 |
| `rpc_admin_update_user(uuid,text,text,text)` | supabase/migrations/0025_approval_routing.sql:191 | supabase/migrations/0034_oversight.sql:95 |
| `rpc_approve_proposal(text)` | supabase/migrations/0007_rpc_proposals.sql:138 | supabase/migrations/0016_rpc_proposal_v2.sql:142 |
| `rpc_cashier_pay_line(uuid,jsonb,numeric)` | supabase/migrations/0060_hardening.sql:23 | supabase/migrations/0062_cashier_ux_and_vat.sql:106 |
| `rpc_cashier_pay_line(uuid,jsonb)` | supabase/migrations/0058_cashier_per_line_and_nvmh_proof.sql:13 | supabase/migrations/0059_detail_withdraw_cashier_amount.sql:85 |
| `rpc_execute_payment_request(text,jsonb)` | supabase/migrations/0057_cashier_and_dashboard.sql:87 | supabase/migrations/0073_retire_batch_payment_request.sql:13 |
| `rpc_execute_payment_request(text)` | supabase/migrations/0036_unify_payments.sql:10 | supabase/migrations/0073_retire_batch_payment_request.sql:12 |
