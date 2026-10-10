# 3DS checkout without the confirm step

This fixes the behavior described in Solidus Stripe issue #313. A server-side
PaymentIntent confirmation can return `requires_action` without raising an
exception. That response must not mark a Solidus payment as paid or finish the
order.

## Behavior

- Authorization succeeds only for `requires_capture` or `succeeded`.
- Purchase succeeds only for `succeeded`.
- Gateway logs use the actual confirmation response, rather than the cached
  pre-confirmation Intent.
- When confirm is absent, a failed Stripe attempt stays at the payment step.
- The payment template mounts the confirmation controller automatically when
  the current payment requires authentication. This works after submission of
  either a new card or a saved payment source.
- The authenticated return supports orders at payment when confirm is absent.
  It binds the Intent to the current order and payment method, retrieves Stripe
  state again, validates amount and currency, and processes it under an order
  lock. Failed attempts can recover after successful authentication.
- Authentication failure or cancellation returns to the payment page with an
  error and suppresses automatic reopening of that same challenge. The customer
  can submit another card.

## Existing installations

The Ruby changes load from this fork. Existing storefront files are copies of
installation templates and must also be updated:

1. `app/javascript/controllers/solidus_stripe_confirm_controller.js`
2. The authentication block at the end of
   `app/views/checkouts/payment/_stripe.html.erb`

Preserve local styling and Payment Element options when updating the template.
Restart Rails and compile assets using the application's normal deployment
procedure. No migration is introduced by this patch.

In the local mall checkout, the dependency uses `path: "../solidus_stripe"`.
This requires both directories on the machine. Before deploying elsewhere,
commit the fork changes and pin that commit from the fork's Git URL, or include
both directories in the deployment. This task does not publish commits.

## Verification

`gateway_confirmation_spec.rb` checks confirmation states for authorize and
purchase. `three_ds_return_spec.rb` checks authorization, untrusted redirect
status, amount mismatch, order ownership, and cancellation handling.
`three_ds_without_confirmation_spec.rb` uses real Stripe test-mode credentials
and a fresh live test-mode Intent, without VCR replay. It covers successful
3DS with manual/automatic capture, plus authentication failure and retry with another saved card.
The browser tests require a reachable Stripe service and Chrome.

These tests do not certify production credentials, all asynchronous payment
methods, or every browser's challenge UI. Cancellation handling is covered at
the server-return boundary; closing the actual issuer popup is not yet a
separate browser test.

## Local validation (2026-10-10)

The final Ruby changes passed 89 Gateway, PaymentIntent, return, webhook and
ordinary checkout examples in the mall test environment. Both real 3DS success
modes passed. The browser retry test initially encountered Stripe Link's saved
card UI; it now selects another actual Stripe test card through the user's
wallet and passed (seed 19887). No credentials or VCR recordings were added.

Direct execution of the fork's final browser spec also passed: 3 examples,
0 failures. Combined with the 89 non-browser regression examples, all selected
92 scenarios have passed against the final Ruby implementation. Ruby/JavaScript
syntax checks and git diff whitespace checks passed. Changes remain uncommitted.

The real browser scenarios require `SOLIDUS_STRIPE_LIVE_TESTS=1` and Stripe test-mode credentials. They are skipped in the default cassette-based CI; gateway and callback regression tests run without live credentials. Never commit credentials or live request recordings.
