"""Stateless model-inference service for the OCaml equity analyser.

Models load once at startup and stay in memory. Endpoints take batches of
already-prepared inputs from OCaml. The service never fetches market data and
contains no trading, factor or portfolio logic.

    uvicorn inference.app:app --host 127.0.0.1 --port 8766      (or: make up)

Environment:
  INFER_DEVICE   cpu (default) | mps | cuda   device for Kronos/TTM/FinBERT
  INFER_MODELS   comma list to load (default: kronos,ttm,finbert,fingpt)
  HF_TOKEN       needed only for FinGPT (gated Llama-3 base); never logged
"""
import logging
import os
import platform
import time
import traceback

import torch
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

log = logging.getLogger("inference")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

DEVICE = os.environ.get("INFER_DEVICE", "cpu")
WANTED = {m.strip() for m in os.environ.get("INFER_MODELS", "kronos,ttm,finbert,fingpt").split(",") if m.strip()}
torch.use_deterministic_algorithms(False)  # some Kronos ops have no deterministic kernel; seeds still fix sampling

# ---------------------------------------------------------------- schemas

class KronosItem(BaseModel):
    ticker: str
    as_of: str
    dates: list[str]
    open: list[float]
    high: list[float]
    low: list[float]
    close: list[float]
    volume: list[float]


class KronosRequest(BaseModel):
    items: list[KronosItem]
    pred_len: int = Field(21, ge=1, le=120)
    sample_count: int = Field(8, ge=1, le=64)
    T: float = 1.0
    top_p: float = 0.9
    seed: int = 17


class TTMItem(BaseModel):
    ticker: str
    as_of: str
    log_var: list[float]


class TTMRequest(BaseModel):
    items: list[TTMItem]


class NewsItem(BaseModel):
    ticker: str
    as_of: str
    headlines: list[str]


class FinBERTRequest(BaseModel):
    items: list[NewsItem]


# ---------------------------------------------------------------- startup

STATE: dict = {"models": {}, "status": {}, "load_seconds": {}}


def _load(name, fn):
    if name not in WANTED:
        STATE["status"][name] = "disabled (INFER_MODELS)"
        return
    t0 = time.time()
    try:
        STATE["models"][name] = fn()
        STATE["status"][name] = "ok"
        log.info("loaded %s in %.1fs", name, time.time() - t0)
    except Exception as e:  # report in /health rather than crash the service
        STATE["status"][name] = f"failed: {type(e).__name__}: {e}"
        log.error("failed to load %s:\n%s", name, traceback.format_exc())
    STATE["load_seconds"][name] = round(time.time() - t0, 1)


app = FastAPI(title="analyser-inference")


@app.on_event("startup")
def startup():
    torch.set_num_threads(max(1, os.cpu_count() or 1))
    from inference.models import finbert_model, fingpt_model, kronos_model, ttm_model

    _load("kronos", lambda: kronos_model.KronosForecaster(DEVICE))
    _load("ttm", lambda: ttm_model.TTMVol(DEVICE))
    _load("finbert", lambda: finbert_model.FinBERT(DEVICE))
    if "fingpt" in WANTED:
        ok, why = fingpt_model.probe()
        if ok:
            _load("fingpt", fingpt_model.FinGPT)
        else:
            STATE["status"]["fingpt"] = f"unavailable: {why}"
            log.warning("FinGPT unavailable: %s", why)
    else:
        STATE["status"]["fingpt"] = "disabled (INFER_MODELS)"


def _model(name):
    m = STATE["models"].get(name)
    if m is None:
        raise HTTPException(503, detail=f"{name} unavailable: {STATE['status'].get(name, 'not loaded')}")
    return m


# ---------------------------------------------------------------- endpoints

@app.get("/health")
def health():
    import importlib.metadata as md

    def v(p):
        try:
            return md.version(p)
        except md.PackageNotFoundError:
            return None

    return {
        "ok": all(STATE["status"].get(m) == "ok" for m in ("kronos", "ttm", "finbert") if m in WANTED),
        "device": DEVICE,
        "models": STATE["status"],
        "load_seconds": STATE["load_seconds"],
        "ttm_branch": getattr(STATE["models"].get("ttm"), "branch", None),
        "kronos_model": getattr(__import__("inference.models.kronos_model", fromlist=["MODEL_ID"]), "MODEL_ID", None),
        "versions": {p: v(p) for p in ("torch", "transformers", "granite-tsfm", "lightgbm", "fastapi")},
        "python": platform.python_version(),
    }


@app.post("/kronos")
def kronos(req: KronosRequest):
    m = _model("kronos")
    out = []
    for it in req.items:
        t0 = time.time()
        try:
            r = m.forecast(it, req.pred_len, req.sample_count, req.T, req.top_p, req.seed)
            r["seconds"] = round(time.time() - t0, 2)
        except Exception as e:
            r = {"ticker": it.ticker, "as_of": it.as_of, "error": str(e)}
        out.append(r)
    return out


@app.post("/ttm_vol")
def ttm_vol(req: TTMRequest):
    return _model("ttm").forecast(req.items)


@app.post("/finbert")
def finbert(req: FinBERTRequest):
    return _model("finbert").score(req.items)


@app.post("/fingpt")
def fingpt(req: dict):
    _model("fingpt")
    raise HTTPException(501, detail="FinGPT prompting is implemented in Milestone 7")
