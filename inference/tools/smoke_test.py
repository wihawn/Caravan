#!/usr/bin/env python3
"""Milestone-1 smoke test: call /health, /kronos, /ttm_vol and /finbert for 3 tickers.

Inputs are built here the same way the OCaml client will build them (data truncated
at as_of). This is test tooling; the service itself never reads market data.
"""
import argparse, csv, math, os, sys, time

import httpx

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def bars(sym, as_of):
    with open(os.path.join(ROOT, "india", "data", "daily", f"{sym}.csv")) as f:
        rows = [r for r in csv.DictReader(f) if r["date"] <= as_of]
    return rows


def gk_logvar(r):
    o, h, l, c = (float(r[k]) for k in ("open", "high", "low", "close"))
    v = 0.5 * math.log(h / l) ** 2 - (2 * math.log(2) - 1) * math.log(c / o) ** 2
    return math.log(max(v, 1e-8))


def headlines(sym):
    try:
        import yfinance as yf
        # Ticker.news is empty for NSE symbols; the search endpoint does return Indian news
        name = yf.Ticker(sym + ".NS").info.get("longName") or sym
        return [n["title"] for n in yf.Search(name, news_count=20).news if n.get("title")]
    except Exception as e:  # network or API change: report rather than invent headlines
        print(f"  ! news fetch failed for {sym}: {e}", file=sys.stderr)
        return []


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:8766")
    ap.add_argument("--tickers", default="RELIANCE,HDFCBANK,TITAGARH")
    ap.add_argument("--as-of", default="9999-12-31")
    a = ap.parse_args()
    c = httpx.Client(base_url=a.url, timeout=1800)
    print("health:", c.get("/health").json())
    tickers = a.tickers.split(",")
    data = {t: bars(t, a.as_of) for t in tickers}
    as_of = {t: data[t][-1]["date"] for t in tickers}

    t0 = time.time()
    req = {"items": [{"ticker": t, "as_of": as_of[t],
                      **{k: [float(r[k]) for r in data[t][-512:]] for k in ("open", "high", "low", "close", "volume")},
                      "dates": [r["date"] for r in data[t][-512:]]} for t in tickers]}
    kr = c.post("/kronos", json=req).json()
    print(f"\n/kronos ({time.time() - t0:.1f}s total)")
    for r in kr:
        print(" ", r if "error" in r else
              f"{r['ticker']:9s} as_of {r['as_of']}  21d forecast return {r['forecast_return']:+.2%}  "
              f"last {data[r['ticker']][-1]['close']}  -> day21 {r['pred_close'][-1]:.2f}  ({r['seconds']}s, ctx {r['context_len']})")

    t0 = time.time()
    tr = c.post("/ttm_vol", json={"items": [{"ticker": t, "as_of": as_of[t],
                                              "log_var": [gk_logvar(r) for r in data[t][-512:]]} for t in tickers]}).json()
    print(f"\n/ttm_vol ({time.time() - t0:.1f}s)")
    for r in tr:
        if "error" in r:
            print(" ", r); continue
        t = r["ticker"]
        trail = math.sqrt(252 * sum(math.exp(gk_logvar(x)) for x in data[t][-21:]) / 21)
        print(f"  {t:9s} TTM ann. vol (GK units) {r['ann_vol']:.1%}   trailing 21d GK vol {trail:.1%}   branch {r['branch']}")

    news = {t: headlines(t) for t in tickers}
    t0 = time.time()
    fb = c.post("/finbert", json={"items": [{"ticker": t, "as_of": as_of[t], "headlines": news[t]} for t in tickers]}).json()
    print(f"\n/finbert ({time.time() - t0:.1f}s)")
    for r in fb:
        print(f"  {r['ticker']:9s} score {r['score'] if r['score'] is None else round(r['score'], 3)}  over {r['n']} headlines")
        for h, s in list(zip(news[r["ticker"]], r.get("per_headline", [])))[:3]:
            print(f"      {s:+.2f}  {h[:100]}")

    g = c.post("/fingpt", json={"items": []})
    print(f"\n/fingpt -> HTTP {g.status_code}: {g.json().get('detail')}")


if __name__ == "__main__":
    main()
