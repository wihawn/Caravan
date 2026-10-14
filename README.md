# factor_portfolio

An OCaml engine that tracks a live equity portfolio's returns and risk, ranks stocks
on fundamentals and momentum, and recommends buys and sells. The recommendations come
from a risk-adjusted optimisation. Volatility forecasts come from
[AurelPx/VolaTTM](https://huggingface.co/AurelPx/VolaTTM), a fine-tuned IBM Tiny
Time Mixer.

```
daily bars + realised measures ─┐
                                ├─ features.ml (12 channels, exact port of the model's reference code)
                                │        └─> sidecar/volattm_server.py ──> VolaTTM ──> 22-session log-variance path
                                │                                             (fallback: Log-HAR, then EWMA)
fundamentals ── factors.ml ─────┤  value · quality · growth · momentum · low-vol (VolaTTM) → composite z
                                │
risk.ml   Σ = D·C·D   D = VolaTTM vols (scaled to close-to-close), C = Ledoit–Wolf shrunk correlation
optimizer.ml   max  μ'w − λ/2 w'Σw − κ·|w − w₀|   s.t. long-only, position/sector caps, invested band, vol target
               μ = λΣw_eq (equilibrium prior) + IC·σ·z (Grinold alpha)
engine.ml → report.ml (terminal + out/*.csv) · live.ml (streaming mark-to-market + alerts)
```

## Quick start

```bash
brew install ocaml dune
uv venv --python 3.12 sidecar/.venv
uv pip install --python sidecar/.venv/bin/python "granite-tsfm==0.3.6" "torch>=2.10,<2.11"
dune build
./_build/default/bin/main.exe sample data        # synthetic demo data (fictitious tickers)
./_build/default/bin/main.exe analyze config.ini
```

## Web interface

```bash
python3 web/server.py --config india/config.ini     # then open http://127.0.0.1:8765
```

The page has six tabs:

- **Overview:** key numbers, a one-year growth chart and your positions.
- **Recommendations:** the trades, with now-vs-target weights.
- **Risk:** alerts, VaR, risk contribution, sector exposure and factor tilt.
- **Rankings:** all stocks with sortable factor z-scores.
- **Volatility:** VolaTTM forecasts against recent realised volatility.
- **Holdings & settings:** edit holdings, cash and optimiser settings.
- **Models:** the ML upgrade in progress.
  - Inference-service status for each model, with Start/Stop buttons (`make up-bg` /
    `make down`).
  - Kronos 21-day return and TTM 21-day volatility forecasts for holdings or all
    stocks (`fp forecasts`, cached).
  - Milestone progress and known caveats.
  - The other tabs still come from the prototype pipeline. The header says so.

The **Run analysis** and **Refresh data & run** buttons start the engine and the NSE
data download in the background. The server uses only the Python standard library and
listens only on 127.0.0.1. It accepts JSON from the page itself, and only the listed
settings can be changed.

## Commands

`fp` below means `./_build/default/bin/main.exe`. You can also set `alias fp=$PWD/_build/default/bin/main.exe`.

| command | what it does |
|---|---|
| `fp analyze [config] [--flow X]` | Full run: positions and P&L, backcast stats, VolaTTM forecasts, risk, factor ranking, optimisation, trades. Writes `out/*.csv` and upserts a NAV mark (`--flow` = cash added or withdrawn that day, used for time-weighted return). |
| `fp live [config]` | Runs `analyze`, then reads `SYMBOL,PRICE` lines from stdin. Shows NAV, session P&L, drawdown, live VaR and drift. Alerts on the stop-loss, drift, and moves above 3σ of the VolaTTM forecast. Commands: `REPORT`, `REBALANCE`, `QUIT`. Pipe any feed in: `my_feed \| fp live` |
| `fp realize intraday.csv out.csv` | Turns 1-minute bars (`date,time,open,high,low,close,volume[,trades]`) into daily realised measures. |
| `fp features daily.csv` | Prints the 12-channel model input matrix, for debugging. |
| `fp sample [dir]` | Generates synthetic data. |

## Input files

- `daily_dir/<SYMBOL>.csv`: `date,open,high,low,close,volume,trades,rv5,rv5_ss,bv5,rsn5,rk,rq5`.
  The realised columns are what VolaTTM was trained on. Get them from VOLARE, or build
  them from 1-minute bars with `fp realize`. **If they are missing**, the engine uses
  Garman–Klass OHLC proxies. The model still runs, but those inputs are
  out-of-distribution, so the forecast is flagged with `*`.
- `fundamentals.csv`: `symbol,sector,market_cap,net_income,book_equity,free_cash_flow,ebit,enterprise_value,revenue,revenue_prev,gross_profit,total_assets,total_debt,operating_cash_flow`
- `portfolio.csv`: `symbol,shares,cost_basis` (cost basis per share). Cash is set in `config.ini`.
- `benchmark.csv` (optional): `date,close`.

## Model notes

- **Features.** These are a line-for-line port of `make_volare_features` from the
  VolaTTM source repo. On the sample data they match the Python reference to about 1e-9.
- **Model output.** VolaTTM predicts log rv5, which covers only the trading session.
  The forecast is scaled by the trailing ratio of close-to-close variance to rv5, so it
  includes the overnight gap. Optimisation and VaR use the average of the 22-session
  path; 1-day figures use step 1.
- **Sidecar.** The model is pinned to revision `d469ad3a`. The sidecar is called once
  per run with all assets batched. If it fails, or a name has fewer than 512 valid
  sessions, the engine falls back to Log-HAR. Log-HAR is the benchmark the model card
  compares VolaTTM against.
- **Intended use.** The model card describes VolaTTM as research-only. It says the
  model is not for order execution, automated risk limits or investment advice.
  The output here is decision support. Nothing places orders.

## Tuning (`config.ini`)

- `w_*`: category weights.
- `ic`: alpha strength.
- `risk_aversion`, `target_vol`, `max_weight`, `max_sector`, `min_invested` / `max_invested`: risk and position limits.
- `tc_bps` and `holding_days`: turnover penalty, amortised over the holding period.
- `min_trade`: weight changes smaller than this become HOLD.
