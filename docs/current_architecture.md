# Current architecture and integration plan

Status: Milestone 0 (read-only review). No code has been changed for the ML upgrade yet.

## 1. What the prototype does today

One command, `fp analyze CONFIG`, runs one rebalance for *today*, end to end
(`src/engine.ml`):

1. **Load.** One CSV per symbol from `daily_dir`, plus snapshot fundamentals, holdings
   and the benchmark (`src/data.ml`).
2. **Volatility.** Builds VolaTTM's 12-channel features (`src/features.ml`, a verified
   port of the model's reference code). Calls a **subprocess sidecar**
   (`sidecar/volattm_server.py`), which writes a JSON file, loads `AurelPx/VolaTTM` and
   writes another JSON file back. Falls back to Log-HAR, then EWMA (`src/volattm.ml`).
3. **Risk model.** Sigma = D·C·D. C is a Ledoit–Wolf (identity target) shrunk
   correlation of 252 daily log returns. D is VolaTTM's 22-day average vol, scaled to
   close-to-close (`src/risk.ml`).
4. **Factor ranking.** Five categories: value, quality, growth, momentum, low-vol.
   Each signal is winsorised at the 2.5/97.5 percentiles, z-scored, clipped to ±3 and
   sector-demeaned (value, quality and growth only). Signals are averaged per category,
   then blended with weights from config (`src/factors.ml`).
5. **Alpha.** Grinold: alpha = IC × vol × composite z.
6. **Optimiser** (`src/optimizer.ml`). Long-only mean-variance with:
   - expected return = equilibrium prior (λ·Σ·w_equal-weight) + alpha;
   - a smoothed L1 turnover penalty (costs spread over `holding_days`);
   - a quadratic penalty for sector caps;
   - an invested-fraction band, and an optional vol target found by searching over λ.

   Solver: projected gradient with backtracking onto {box ∩ budget band}.
7. **Trades.** BUY (new) / BUY (add) / SELL (trim) / SELL (exit) / HOLD against
   current share holdings, with a `min_trade` threshold.
8. **Reporting.** Terminal report, CSVs, `out/report.json`, a NAV log that gives
   time-weighted return, and a "backcast" (today's weights held constant over the
   last 252 days). This backcast is **not a backtest**.

Other entry points:
- `fp live`: streams `SYMBOL,PRICE` quotes on stdin; shows mark-to-market and alerts.
- `fp realize`: 1-minute bars → daily realised measures.
- `fp features`, `fp sample`: debugging and synthetic data.
- Web UI: `web/server.py` (stdlib HTTP) and `web/index.html`, which reads `report.json`.

## 2. Data sources and storage

| Data | Source | Storage |
|---|---|---|
| Daily OHLCV (split/dividend adjusted) | Yahoo Finance via `scripts/fetch_nse.py` (yfinance), `.NS` tickers, **5 years** | `india/data/daily/<SYM>.csv` |
| Universe | Current Nifty 50 from the NSE archive CSV, plus 4 holdings outside the index (BALRAMCHIN, HINDCOPPER, HINDZINC, TITAGARH): 54 names | implied by the files in `daily_dir` |
| Sector | NSE "Industry" field (hard-coded for the 4 non-index names) | `fundamentals.csv` |
| Fundamentals | yfinance **current snapshot** (latest annual statements + `info`) | `india/data/fundamentals.csv` |
| Benchmark | `^NSEI` via yfinance | `india/data/benchmark.csv` |
| Holdings | user file: `symbol,shares,cost_basis` | `india/data/portfolio.csv` |
| Realised measures | none for NSE: VolaTTM gets Garman–Klass OHLC proxies (out-of-distribution) | — |

**A second, parallel India setup exists that I did not create:** `config_india.ini`,
`tools/fetch_yahoo.py`, `india/daily/`, `india/fundamentals.csv`,
`india/portfolio.csv`, `india/benchmark.csv` and `out_india/`. Its data is 3 years and
uses an older Nifty list (it includes HEROMOTOCO, INDUSINDBK, WIPRO, VEDL and
NATIONALUM). The web UI and this plan use `india/config.ini` + `india/data/`.
I have left the parallel copy untouched.

## 3. Existing models, factors, risk, optimiser, backtest

- **Factors:** earnings yield, book/price, FCF yield, EBIT/EV, ROE, gross
  profitability, debt/**assets**, accruals, revenue growth, `mom_12_1` (t−252→t−21),
  `mom_6_1`, % of 52-week high, low-vol (VolaTTM forecast).
- **Ranking:** fixed category weights. No learned model.
- **Risk model:** as in §1. No explicit PSD check. (The LW mix is PSD in exact
  arithmetic, but nothing verifies it.)
- **Optimiser:** as in §1. No max-Sharpe objective, no top-N eligibility, no
  drop-small-weights step.
- **Backtest:** **none.** The only history-based figure is the constant-weight backcast.

## 4. Core types and conventions

- **Dates:** ISO `YYYY-MM-DD` strings, compared lexicographically. No date type.
- **Tickers:** upper-case `string`. Cross-sectional data is `float array` indexed by
  universe position, with a parallel `syms : string array`.
- **Time series:** `Types.series = { sym; bars : bar array; measured }`, where
  `bar = { date; o; h; l; c; volume; trades; rv5; rv5_ss; bv5; rsn5; rk; rq5 }`.
- **Portfolio:** `holding = { hsym; shares; cost }`, with weights derived from prices
  and NAV. `Engine.result` carries everything for one rebalance.
- **No `as_of` concept anywhere.** Every function sees each series' full history,
  which is fine for a single live run and unsafe for a backtest.
- **Errors:** `failwith` for fatal input problems; warnings collected into
  `result.warnings`.

## 5. Libraries, build and test

- **OCaml:** 5.5.1 from **Homebrew** (no opam, no switch, no `.opam` file). dune 3.24.
- **Libraries:** stdlib + `unix` only. Hand-rolled JSON (`src/json.ml`), CSV
  (`src/util.ml`) and linear algebra (`src/linalg.ml`: Gaussian elimination, no
  eigendecomposition). No Owl, Core, Lwt or Eio. Fully synchronous.
- **Build:** `dune build`. Binary: `_build/default/bin/main.exe` (the `fp` alias).
- **Tests: none.** Verification so far was ad hoc: the feature port was checked
  against the Python reference to ~1e-9.
- **Python:** `sidecar/.venv` (Python 3.12, torch 2.10, granite-tsfm 0.3.6,
  transformers 4.57, yfinance).
- **Machine constraints:**
  - **3.9 GB free disk**;
  - 16 GB RAM;
  - Apple M4 (torch MPS available, **no CUDA**);
  - no Docker, no opam.

## 6. Gap mapping onto the target pipeline

| # | Target stage | Status | Notes |
|---|---|---|---|
| 1 | Factor + model signals per stock per date | **Exists, needs changing** | Factors exist but are computed only for "now", with no `as_of`. Missing: `realised_vol_63d`, `debt_to_equity` (have debt/assets). Kronos, TTM-base, FinBERT, FinGPT missing. |
| 1a | Point-in-time fundamentals | **Missing** | Today's fundamentals are a yfinance snapshot and would leak future data into a backtest. |
| 1b | Feature table: ±3σ winsor, z, sign-flip, 0-fill + `*_missing` | **Missing** | The prototype's normalisation (percentile winsor, sector demean) differs. It stays as-is for the "prototype" ablation arm. |
| 2 | Trained ranker (LightGBM lambdarank, walk-forward) | **Missing** | Fixed category weights today. |
| 3 | Forward-looking covariance | **Exists, mostly fine** | Already D·C·D with LW shrinkage over 252 days. Changes: allow D from base TTM (spec) or VolaTTM (current), LW on covariance → correlation as specified, add a PSD check with eigenvalue clipping (needs a Jacobi eigensolver). |
| 4 | Optimiser | **Exists, needs changing** | Keep the current mean-variance + turnover optimiser behind `optimizer = prototype`. Add the spec optimiser: max-Sharpe (default) or mean-variance, L2 γ, 10% stock / 30% sector caps, top-25 eligibility, drop <1% then renormalise. Plus the cvxpy cross-check. |
| 5 | BUY / SELL / HOLD / EXIT signals | **Exists, needs changing** | Thresholds are `min_trade` (1%) today, the spec says 2 pp. Add score, rank, top-3 features (from SHAP), FinGPT concerns. Output to `reports/signals_YYYY-MM-DD.csv`. |
| 6 | Honest backtest vs `^NSEI` + ablations | **Missing** | Needs a date-loop engine, PIT data views, cost model, metrics, IC, ablations, HTML report. |
| — | Inference service (HTTP, models stay loaded) | **Exists in a different form** | The VolaTTM sidecar is a one-shot subprocess using file I/O. To be replaced by a FastAPI service; the subprocess path is kept as a fallback. |
| — | Disk cache of model outputs | **Missing** | |
| — | No-look-ahead enforcement + tests | **Missing** | No `as_of`, no tests. |

## 7. Integration plan

### Language boundary
- **OCaml** keeps all logic.
- **`inference/`** is a FastAPI + uvicorn service with the endpoints `/health`,
  `/kronos`, `/ttm_vol`, `/finbert`, `/fingpt`, `/rank/train`, `/rank/predict`.
  Optionally it also serves `/volattm`, so the prototype arm keeps its model.
- `make up` starts the service. Docker isn't installed here, so `make up` runs uvicorn
  from the venv. A Dockerfile is provided for other machines.

### LightGBM route: Python service
opam has **no LightGBM bindings**. I checked `lightgbm`, `ocaml-lightgbm` and
`lightgbm-ocaml`. The only gradient-boosting package is `xgboost.0.2.1`, a single old
release, and XGBoost isn't the model the spec asks for. So:
- OCaml builds the normalised feature table and quintile labels and sends them to
  `/rank/train` and `/rank/predict`.
- `/rank/train` is stateless: it returns the model as a LightGBM model string, which
  OCaml stores in the disk cache.
- Feature importance and `pred_contrib` (SHAP) come back in the response.

### QP solver: projected gradient in OCaml
opam has no OSQP bindings. Projected gradient onto the capped simplex
(per-name cap + sector caps + budget) reuses the existing solver.
- Sector caps are enforced exactly, by alternating projections (Dykstra), instead of
  today's penalty.
- **Max-Sharpe** = golden-section search over risk aversion λ along the mean-variance
  frontier. Sharpe is unimodal along that frontier.
- The cvxpy cross-check in `inference/tools/` uses the standard homogenised max-Sharpe
  QP and asserts agreement to 1e-3.

### OCaml dependencies
The prototype is synchronous, so the HTTP client should be synchronous too:

| | Option A — recommended | Option B |
|---|---|---|
| Install | opam using the **existing Homebrew compiler** (`ocaml-system`, so no compiler build; about 300–500 MB) | nothing new |
| JSON | `yojson` + `ppx_deriving_yojson` (typed records) | extend the existing `Json` module with hand-written typed decoders |
| HTTP | `ezcurl` (synchronous libcurl bindings) | ~80-line HTTP/1.1 POST client over `Unix` sockets (localhost only) |
| Tests | `alcotest` | a small in-repo test runner |

**Owl is not proposed.** It needs OpenBLAS and is heavy, and n ≤ 60, so a ~40-line
Jacobi eigensolver covers the PSD repair.

### Look-ahead control (structural)
- `Pit.t`: an abstract type that can only be built by `Pit.truncate ~as_of`, which
  copies only bars dated ≤ `as_of`.
- Every feature function takes a `Pit.t`, never a raw `series`.
- Fundamentals:
  - `Fundamentals.get : 'mode Fundamentals.source -> string -> as_of:date -> ...`;
  - a phantom type separates point-in-time sources (`[`Pit]`) from snapshot sources
    (`[`Snapshot]`);
  - `Backtest.run` only accepts a `[`Pit]` source, so snapshot data can't reach a
    backtest at compile time.
- Tests: alter every bar and filing after t, then assert features at t are
  bit-identical. One test per feature family.

### Model I/O
- **Kronos:**
  - input: OHLCV + amount (≈ volume × close), at most 512 bars, ≤ `as_of`;
  - output: mean predicted close at t+21 / close_t − 1;
  - averaged over N samples with a fixed seed.
- **TTM (base r2, 512-length context branch):**
  - input: a daily log-variance series, Garman–Klass from OHLC, 512 sessions ≤ `as_of`;
  - output: annualised vol over 21 days.
- **FinBERT:** P(pos) − P(neg), averaged per ticker over recent headlines.
- **FinGPT:** prompt in the FinGPT-Forecaster format. Answers that can't be parsed
  become 0 and are logged.
- **Cache:** `cache/<model>/<ticker>/<as_of>.json`, plus a hash of the inputs, so a
  data change invalidates the stale entry instead of silently reusing it.

### Ranker
- One query group per rebalance date; label = forward 21-day return quintile (0–4).
- At date t, train only on dates d with d + 21 trading days ≤ t. Expanding window;
  first prediction after 3 years of labelled dates.
- Fixed seeds; deterministic LightGBM settings (`deterministic=true`,
  `force_row_wise=true`, `num_threads=1`).
- IC (Spearman) per date and per-year gain importance go into the report.

### CLI
Kept as `fp`, with a dune `public_name analyser` added so
`dune exec -- analyser ...` also works.
- `analyze` gains `pipeline = prototype | ml` and writes
  `reports/signals_YYYY-MM-DD.csv` + an HTML summary. This is the spec's `live`.
- `backtest` is new.
- The existing streaming `live` command keeps its name and behaviour.
- `report.json` stays backward compatible, so the web UI keeps working.

## 8. Things that limit the plan (need your input)

1. **History length vs walk-forward.** The data is 5 years. Warm-up needs 252 days
   (momentum, covariance) and Kronos/TTM want up to 512 bars. Then the ranker needs
   3 years of labelled dates. On 5 years that leaves **almost no out-of-sample
   period**. I'll re-fetch with `--period max` (Yahoo NSE data mostly starts around
   2007), giving out-of-sample from about 2013–2014: roughly 150 monthly rebalances.
2. **Kronos compute.** About 150 dates × 54 stocks ≈ 8,000 Kronos-base forecasts, each
   autoregressive over 21 steps. On CPU/MPS that is plausibly **several hours**,
   one-time thanks to the cache. I'll time it on the smoke test and report before the
   full run.
3. **Point-in-time fundamentals from Screener.in.**
   - My understanding of Screener's export: about 10 years of *annual* P&L, balance
     sheet and cash flow, but only the last ~10–13 *quarters*.
   - If so, quarterly coverage won't reach the early backtest years. I'd use annual
     rows (60-day lag: SEBI LODR deadline for audited annual results) where no
     quarterly rows exist, and quarterly rows (45-day lag, as you specified) where
     they do.
   - Balance-sheet items (book value, debt) are annual or half-yearly in India, so
     book/price, ROE and D/E are inherently stale between filings.
   - Please export one company so I can lock the parser to the real format.
4. **TTM model choice.** The spec names base `granite-timeseries-ttm-r2`. The
   prototype uses `AurelPx/VolaTTM`, a fine-tune of that same base trained
   specifically for realised volatility. VolaTTM expects intraday realised measures,
   which we don't have for NSE, so it currently runs out-of-distribution on OHLC
   proxies. Base TTM on a GK log-variance series is a fairer zero-shot use. Proposal:
   base TTM for the new pipeline (as specified), VolaTTM kept for the prototype arm,
   and an extra ablation comparing the two inside the ML pipeline.
5. **FinGPT can't run on this machine.**
   - It needs CUDA (bitsandbytes 4-bit doesn't support Apple MPS).
   - The 8B base model download is about 16 GB, with 3.9 GB free.
   - The service will start without it and report `fingpt: unavailable` in `/health`,
     as the spec requires.
   - A Hugging Face token is only needed if you'll run the service on a CUDA machine.
     It would be read from the `HF_TOKEN` environment variable and never written to
     disk.
6. **News headlines.** FinBERT and FinGPT need headlines, which nothing in the
   repository fetches yet. For live mode only, I'd use yfinance's `Ticker.news`
   (free; mixed coverage of Indian names), fetched on the OCaml side's request
   through a small script, so the service still never fetches data itself. Tell me if
   you have a better source.
7. **Disk budget.** Kronos-base + tokenizer ≈ 0.45 GB, FinBERT ≈ 0.45 GB,
   TTM r2 < 0.1 GB, FastAPI/LightGBM/cvxpy ≈ 0.2 GB. Plus option A ≈ 0.4 GB, and the
   15-year price re-fetch and model cache ≈ 0.2 GB. Total ≈ **1.8 GB of 3.9 GB free**.
8. **Survivorship.** The universe is today's Nifty 50 + 4 holdings. Without
   `data/constituents/` lists, the backtest overstates returns. The report will say so.
9. **The parallel India copy** (§2): keep, merge, or delete? I won't touch it without
   your say.

## 9. Decisions (approved 2026-10-14)

- OCaml dependencies: **option A**. opam on the Homebrew compiler; yojson +
  ppx_deriving_yojson, ezcurl, alcotest.
- Volatility: **base TTM r2** in the ML pipeline, VolaTTM in the prototype arm, plus a
  TTM-vs-VolaTTM ablation.
- History: **re-fetch the full Yahoo history** (`--period max`).
- Parallel India copy: **deleted**.
