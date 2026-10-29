# Kapani AI — integration into the existing Kapani wallet

The KapaniGPT website uses your existing Supabase project. To enable Kapani AI subscription checkout, open the Supabase SQL Editor for `npivvwwkdnbeqmjcwrke` and execute `supabase/023_kapani_ai_subscriptions.sql` once, after migrations 001–022.

This migration is additive. It does **not** change regular Kapani subscriptions, accounts, balances, or notification settings. It creates two authenticated RPCs: `kp_ai_status()` and `kp_ai_buy(p_plan, p_id)`. The purchase function validates the account, debits the authoritative Kapani wallet using `kp_v8_money` and sends a standard Kapani system notification including the amount spent and **remaining balance**. Payment retries with the same operation UUID do not debit a second time.

Kapani's existing realtime notifications system displays those messages as in-page toasts or system notifications when a browser tab is running in the background and notification permission is granted. Delivery with every Kapani tab completely closed additionally depends on the separately configured existing `kapani-push` service and its push subscriptions. The SQL alone cannot guarantee a closed-tab push.

Subscriptions last seven days without automatic renewal. Plus costs 499, ultra costs 1299, prime costs 2999 fictional Kapani rubles. A repeat purchase of the same still-active tier extends it by seven days. A purchase of a different tier starts a fresh seven-day period.

The deployed KapaniGPT site prompts for a Kapani nickname and password at checkout because it is hosted at a different origin and cannot read the main site's login session. Credentials go directly to Supabase Auth; only the access/refresh session tokens are retained in the current KapaniGPT tab.
