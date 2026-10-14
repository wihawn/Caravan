"""Granite TTM r2 volatility forecast.

OCaml sends a 512-session daily log-variance series (built from OHLC, truncated at
as_of). TTM forecasts the next `horizon` values. The service returns the raw
log-variance path and the annualised volatility in the input's own units:
sqrt(252 * mean(exp(path))). Calibration (log-space bias, overnight gap) is done in
OCaml, next to the code that built the series.
"""
import numpy as np
import torch
from tsfm_public.models.tinytimemixer import TinyTimeMixerForPrediction
from tsfm_public.toolkit.get_model import get_model
from tsfm_public.toolkit.time_series_preprocessor import DEFAULT_FREQUENCY_MAPPING

MODEL_PATH = "ibm-granite/granite-timeseries-ttm-r2"
CONTEXT = 512
EXPECTED_BRANCH = "512-48-ft-r2.1"
BRANCH_SHA = "b972f0c22190b7502764526004d16e2b4ed39e8c"  # commit of that branch on 2026-10-14
FREQ_TOKEN = DEFAULT_FREQUENCY_MAPPING["d"]  # daily; the r2.1 branches use frequency-prefix tuning


class TTMVol:
    def __init__(self, device: str, horizon: int = 21):
        self.device = device
        self.horizon = horizon
        # with return_model_key=True get_model returns only the branch name (e.g. "512-48-ft-r2.1")
        self.branch = get_model(MODEL_PATH, context_length=CONTEXT, prediction_length=horizon, return_model_key=True)
        if self.branch != EXPECTED_BRANCH:
            raise RuntimeError(f"get_model chose {self.branch}, expected {EXPECTED_BRANCH}")
        # get_model passes the branch name as `revision`, so load the pinned commit of that branch directly,
        # with the same horizon filter get_model would apply
        self.model = TinyTimeMixerForPrediction.from_pretrained(MODEL_PATH, revision=BRANCH_SHA,
                                                                prediction_filter_length=horizon)
        self.model.to(device).eval()

    def forecast(self, items) -> list[dict]:
        out, batch, idx = [], [], []
        for k, it in enumerate(items):
            x = np.asarray(it.log_var, dtype=np.float32)
            if x.shape != (CONTEXT,):
                out.append({"ticker": it.ticker, "as_of": it.as_of, "error": f"need exactly {CONTEXT} values, got {x.shape[0]}"})
            elif not np.isfinite(x).all():
                out.append({"ticker": it.ticker, "as_of": it.as_of, "error": "non-finite input"})
            else:
                out.append(None)
                batch.append(x)
                idx.append(k)
        if batch:
            past = torch.from_numpy(np.stack(batch)[:, :, None]).to(self.device)  # (B, 512, 1)
            with torch.inference_mode():
                freq = torch.full((past.shape[0],), FREQ_TOKEN, dtype=torch.long, device=self.device)
                pred = self.model(past_values=past, freq_token=freq).prediction_outputs[:, : self.horizon, 0].cpu().numpy().astype(float)
            for k, p in zip(idx, pred):
                it = items[k]
                out[k] = {"ticker": it.ticker, "as_of": it.as_of, "log_var_path": p.tolist(),
                          "ann_vol": float(np.sqrt(252.0 * np.mean(np.exp(p)))), "branch": self.branch}
        return out
