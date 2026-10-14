#!/usr/bin/env python3
"""Fetch NSE daily history, fundamentals and the Nifty 50 benchmark into the engine's CSV formats.

Usage: fetch_nse.py OUT_DIR SYMBOL[:Industry] ...      (NSE symbols, e.g. RELIANCE TITAGARH:"Capital Goods")
Also pulls the current Nifty 50 constituents from NSE unless --no-nifty50.

Daily bars are split/dividend adjusted. Yahoo has no long intraday history, so the
realised-measure columns are left out and the engine uses OHLC proxies for VolaTTM.
"""
import argparse, io, math, os, sys, urllib.request

import pandas as pd
import yfinance as yf

NIFTY50_URL = "https://archives.nseindia.com/content/indices/ind_nifty50list.csv"


def nifty50():
    req = urllib.request.Request(NIFTY50_URL, headers={"User-Agent": "Mozilla/5.0"})
    df = pd.read_csv(io.BytesIO(urllib.request.urlopen(req, timeout=30).read()))
    return dict(zip(df["Symbol"].str.strip(), df["Industry"].str.strip()))


def latest(df, rows, col=0):
    if df is None or df.empty:
        return math.nan
    for r in rows:
        if r in df.index and df.shape[1] > col:
            v = df.loc[r].iloc[col]
            if pd.notna(v):
                return float(v)
    return math.nan


def fundamentals(sym):
    t = yf.Ticker(sym + ".NS")
    info = t.info or {}
    inc, bal, cf = t.income_stmt, t.balance_sheet, t.cashflow
    return {
        "market_cap": info.get("marketCap", math.nan),
        "net_income": latest(inc, ["Net Income Common Stockholders", "Net Income"]),
        "book_equity": latest(bal, ["Common Stock Equity", "Stockholders Equity"]),
        "free_cash_flow": latest(cf, ["Free Cash Flow"]),
        "ebit": latest(inc, ["EBIT", "Operating Income"]),
        "enterprise_value": info.get("enterpriseValue", math.nan),
        "revenue": latest(inc, ["Total Revenue"]),
        "revenue_prev": latest(inc, ["Total Revenue"], col=1),
        "gross_profit": latest(inc, ["Gross Profit"]),
        "total_assets": latest(bal, ["Total Assets"]),
        "total_debt": latest(bal, ["Total Debt"]),
        "operating_cash_flow": latest(cf, ["Operating Cash Flow"]),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("symbols", nargs="*")
    ap.add_argument("--no-nifty50", action="store_true")
    ap.add_argument("--period", default="max")  # full history: the walk-forward backtest needs it
    a = ap.parse_args()

    universe = {} if a.no_nifty50 else nifty50()
    for s in a.symbols:
        sym, _, ind = s.partition(":")
        universe[sym.upper()] = ind or universe.get(sym.upper(), "Unknown")
    syms = sorted(universe)
    daily_dir = os.path.join(a.out, "daily")
    os.makedirs(daily_dir, exist_ok=True)

    print(f"downloading {len(syms)} symbols ({a.period})", file=sys.stderr)
    px = yf.download([s + ".NS" for s in syms], period=a.period, auto_adjust=True, group_by="ticker", progress=False, threads=True)

    def frame(sym, data):
        try:
            d = data[sym + ".NS"] if isinstance(data.columns, pd.MultiIndex) else data
            d = d.dropna(subset=["Open", "High", "Low", "Close"])
        except KeyError:
            return pd.DataFrame()
        return d[(d["Volume"] > 0) & (d["High"] >= d["Low"])] if not d.empty else d

    ok, kept = [], []
    for s in syms:
        d = frame(s, px)
        if len(d) < 60:  # Yahoo batch downloads drop tickers intermittently: retry once on its own
            d = frame(s, yf.download(s + ".NS", period=a.period, auto_adjust=True, group_by="ticker", progress=False))
        if len(d) < 60:
            if os.path.exists(os.path.join(daily_dir, f"{s}.csv")):
                print(f"  ! {s}: download failed; keeping the existing file", file=sys.stderr)
                kept.append(s)
            else:
                print(f"  ! {s}: only {len(d)} sessions, skipped", file=sys.stderr)
            continue
        out = pd.DataFrame({"date": d.index.strftime("%Y-%m-%d"), "open": d["Open"], "high": d["High"],
                            "low": d["Low"], "close": d["Close"], "volume": d["Volume"]})
        out.to_csv(os.path.join(daily_dir, f"{s}.csv"), index=False, float_format="%.4f")
        ok.append(s)

    bench = yf.download("^NSEI", period=a.period, auto_adjust=True, progress=False)["Close"].squeeze().dropna()
    pd.DataFrame({"date": bench.index.strftime("%Y-%m-%d"), "close": bench.values}).to_csv(
        os.path.join(a.out, "benchmark.csv"), index=False, float_format="%.2f")

    # keep previous fundamentals rows for symbols whose download failed this time
    fpath = os.path.join(a.out, "fundamentals.csv")
    old = pd.read_csv(fpath) if os.path.exists(fpath) else pd.DataFrame(columns=["symbol"])
    rows = old[old["symbol"].isin(kept)].to_dict("records")
    for i, s in enumerate(ok, 1):
        try:
            f = fundamentals(s)
        except Exception as e:  # keep going; missing fundamentals score neutral
            print(f"  ! {s}: fundamentals unavailable ({e})", file=sys.stderr)
            f = {}
        rows.append({"symbol": s, "sector": universe[s], **f})
        print(f"\r  fundamentals {i}/{len(ok)}", end="", file=sys.stderr)
    print(file=sys.stderr)
    pd.DataFrame(rows).to_csv(fpath, index=False)
    print(f"wrote {len(ok)} symbols to {a.out}" + (f"; kept previous data for {len(kept)}: {', '.join(kept)}" if kept else ""), file=sys.stderr)


if __name__ == "__main__":
    main()
