"""ProsusAI/finbert headline sentiment: mean of P(positive) - P(negative) per ticker."""
import torch
from transformers import AutoModelForSequenceClassification, AutoTokenizer

MODEL_ID = "ProsusAI/finbert"
REVISION = "0bc2ac10dda6929bcb1f77ccc43c7ec5c424f031"  # pinned 2026-10-14


class FinBERT:
    def __init__(self, device: str, revision: str = REVISION):
        self.device = device
        self.tok = AutoTokenizer.from_pretrained(MODEL_ID, revision=revision)
        self.model = AutoModelForSequenceClassification.from_pretrained(MODEL_ID, revision=revision).to(device).eval()
        labels = {v.lower(): k for k, v in self.model.config.id2label.items()}
        self.pos, self.neg = labels["positive"], labels["negative"]

    def score(self, items, batch_size: int = 32) -> list[dict]:
        out = []
        for it in items:
            heads = [h.strip() for h in it.headlines if h and h.strip()]
            if not heads:
                out.append({"ticker": it.ticker, "as_of": it.as_of, "score": None, "n": 0})
                continue
            diffs = []
            for i in range(0, len(heads), batch_size):
                enc = self.tok(heads[i:i + batch_size], padding=True, truncation=True, max_length=64,
                               return_tensors="pt").to(self.device)
                with torch.inference_mode():
                    p = torch.softmax(self.model(**enc).logits, dim=-1).cpu()
                diffs += (p[:, self.pos] - p[:, self.neg]).tolist()
            out.append({"ticker": it.ticker, "as_of": it.as_of, "score": float(sum(diffs) / len(diffs)),
                        "n": len(diffs), "per_headline": diffs})
        return out
