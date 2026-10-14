# Milestone log

## M1 — Inference service (2026-10-14)

`inference/` is a FastAPI service.
- Start: `make up` (foreground) or `make up-bg`.
- Smoke test: `make smoke`.

Endpoints: `/health`, `/kronos`, `/ttm_vol`, `/finbert`, and `/fingpt` (returns 503
when unavailable). All run on CPU. Models are pinned to Hugging Face commits:

| Model | Commit |
|---|---|
| Kronos-base | `2b55474` |
| Kronos tokenizer | `0e01173` |
| FinBERT | `0bc2ac1` |
| TTM r2, branch `512-48-ft-r2.1` | `b972f0c` |

Kronos is vendored at `67b630e`.

Smoke test, 3 tickers, as of 2026-10-14:

| Ticker | Kronos 21d return | TTM ann. vol (GK units) | Trailing 21d GK vol | FinBERT |
|---|---|---|---|---|
| RELIANCE | +20.02% | 16.2% | 15.8% | no headlines found |
| HDFCBANK | +20.53% | 15.2% | 18.8% | −0.109 (20 headlines) |
| TITAGARH | +7.78% | 27.2% | 30.4% | no headlines found |

FinGPT: unavailable (no CUDA on Apple M4). Reported in `/health`; `/fingpt` returns 503.

### Issues found

1. **Kronos forecasts large mean reversion.**
   - +20% in 21 days for two large caps that sit near the bottom of their 2-year
     range. Forecasts move toward the 512-bar window mean.
   - Not an environment bug:
     - the tokenizer reconstructs prices to within about ₹3.5;
     - the forecast path starts at the last close and drifts, rather than jumping;
     - the drift persists at T = 0.1 and on MPS.
   - Absolute levels look implausible. Only the cross-sectional rank is used
     downstream, and backtest IC will show whether that rank has signal.
2. **Kronos cost.** About 2.9 s per sample per ticker on CPU, near-linear in
   `sample_count`. MPS is no faster: 19 s vs 23 s at 8 samples, and slower at 1 sample.
   About 8,000 backtest forecasts would take ~7 h at 1 sample, ~26 h at 4, ~52 h at 8.
   Decision needed.
3. **News.**
   - `yfinance.Ticker.news` is empty for every `.NS` symbol.
   - `yfinance.Search` returns some headlines, but they are thin and often off-target:
     for HDFCBANK, ADR market-wrap stories; for RELIANCE and TITAGARH, none.
   - FinBERT itself checks out on fixed sentences: +0.85, −0.92, −0.03 for
     positive, negative and neutral.
   - A better headline source is needed for the live layer.
4. TTM r2.1 branches require a frequency token (daily = 8, from granite-tsfm's
   mapping). `get_model` cannot pin a commit, so the service checks the selected
   branch and loads its pinned commit directly.

### M1 follow-up: switched to Kronos-small (decision 2026-10-14)

- `KRONOS_MODEL=small` (default; commit `901c26c`) or `base`.
- Kronos-small takes ~5.2 s per ticker at 8 samples on CPU, so the full backtest is
  roughly 11–12 h, once (cached).
- Its forecasts **disagree sharply with Kronos-base** on the same inputs:

  | Ticker | Kronos-small | Kronos-base |
  |---|---|---|
  | RELIANCE | +13.4% | +20.0% |
  | HDFCBANK | −0.1% | +20.5% |
  | TITAGARH | −5.6% | +7.8% |

  Treat Kronos as a weak, noisy signal until the backtest IC says otherwise.
- News source for the live layer: Google News RSS (Milestone 7).

## M2 — OCaml inference client (2026-10-14)

- **`src/inference_client.ml`.**
  - Typed records per model (`ppx_deriving_yojson`).
  - Synchronous ezcurl transport, swappable for tests.
  - Batched requests; per-item errors are reported, never cached.
  - Disk cache: `cache/<model-tag>/<ticker>/<as_of>.json` stores the input hash. Model
    tags include variant and sampling parameters, e.g.
    `kronos-Kronos-small_pl21_s8_T1_p0.9_seed17`, `ttm-512-48-ft-r2.1`. A changed
    input for the same key is recomputed and counted as stale.
  - Defensive check that no bar is dated after `as_of`; Kronos context capped at 512.
- **CLI.**
  - `fp health CONFIG` exits 3 with a "start it with `make up-bg`" message if the
    service is down.
  - `fp infer-smoke CONFIG` is an end-to-end check.
- **Build.** `make build` / `make test` (opam switch `fp`: yojson 3.0,
  ppx_deriving_yojson 3.10, ezcurl 0.4, alcotest 1.9.1).
- **Tests.** 8 alcotest cases pass, using a stub service:
  - wire format;
  - cache hit;
  - cache persistence across clients;
  - stale-input recompute;
  - per-item errors;
  - look-ahead guard;
  - 512 truncation;
  - unreachable-service message.
- **Live check.** OCaml reproduces the Python smoke-test outputs exactly. The second
  run is 100% cache hits.
