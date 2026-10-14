"""Kronos-base momentum forecast: expected return over the next `pred_len` sessions.

Inputs come from OCaml, already truncated at the forecast date. The service only runs
the model. Each ticker is sampled with its own seed derived from (seed, ticker,
as_of), so a cached value does not depend on which other tickers were in the batch.
"""
import os
import sys
import zlib

import numpy as np
import pandas as pd
import torch

VENDOR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "vendor", "kronos")
sys.path.insert(0, VENDOR)
from model import Kronos, KronosPredictor, KronosTokenizer  # noqa: E402

# Kronos-small by default: ~4x faster than base on CPU, which makes the walk-forward backtest feasible
# (decision 2026-10-14). Select with KRONOS_MODEL=small|base. Both share Kronos-Tokenizer-base.
MODELS = {
    "small": ("NeoQuasar/Kronos-small", "901c26c1332695a2a8f243eb2f37243a37bea320"),
    "base": ("NeoQuasar/Kronos-base", "2b554741eca47781b64468546e77fef3e85130e6"),
}
VARIANT = os.environ.get("KRONOS_MODEL", "small")
MODEL_ID, MODEL_REV = MODELS[VARIANT]
TOKENIZER_ID = "NeoQuasar/Kronos-Tokenizer-base"
TOKENIZER_REV = "0e0117387f39004a9016484a186a908917e22426"  # pinned 2026-10-14
MAX_CONTEXT = 512  # Kronos-small/base limit


class KronosForecaster:
    def __init__(self, device: str, model_rev: str = MODEL_REV, tok_rev: str = TOKENIZER_REV):
        self.device = device
        self.tokenizer = KronosTokenizer.from_pretrained(TOKENIZER_ID, revision=tok_rev)
        self.model = Kronos.from_pretrained(MODEL_ID, revision=model_rev)
        self.tokenizer.eval()
        self.model.eval()
        self.predictor = KronosPredictor(self.model, self.tokenizer, device=device, max_context=MAX_CONTEXT)

    @staticmethod
    def seed_for(seed: int, ticker: str, as_of: str) -> int:
        return zlib.crc32(f"{seed}|{ticker}|{as_of}".encode()) & 0x7FFFFFFF

    def forecast(self, item, pred_len: int, sample_count: int, T: float, top_p: float, seed: int) -> dict:
        n = len(item.close)
        if not (len(item.dates) == len(item.open) == len(item.high) == len(item.low) == n == len(item.volume)):
            raise ValueError("dates/open/high/low/close/volume lengths differ")
        if n < 64:
            raise ValueError(f"need at least 64 bars of context, got {n}")
        if n > MAX_CONTEXT:
            raise ValueError(f"context {n} exceeds Kronos max_context {MAX_CONTEXT}; truncate on the client")
        df = pd.DataFrame({"open": item.open, "high": item.high, "low": item.low, "close": item.close,
                           "volume": item.volume})
        x_ts = pd.Series(pd.to_datetime(item.dates))
        # future session timestamps only feed Kronos' calendar embeddings (weekday/day/month)
        y_ts = pd.Series(pd.bdate_range(x_ts.iloc[-1] + pd.Timedelta(days=1), periods=pred_len))
        s = self.seed_for(seed, item.ticker, item.as_of)
        torch.manual_seed(s)
        np.random.seed(s)
        with torch.inference_mode():
            pred = self.predictor.predict(df=df, x_timestamp=x_ts, y_timestamp=y_ts, pred_len=pred_len, T=T,
                                          top_p=top_p, sample_count=sample_count, verbose=False)
        path = pred["close"].to_numpy(dtype=float)
        last = float(item.close[-1])
        return {
            "ticker": item.ticker,
            "as_of": item.as_of,
            "forecast_return": float(path[-1] / last - 1.0),
            "pred_close": path.tolist(),
            "context_len": n,
            "seed": s,
            "model": MODEL_ID,
        }
