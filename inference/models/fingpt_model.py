"""FinGPT-Forecaster (Llama-3-8B-Instruct + LoRA), 4-bit via bitsandbytes.

Loaded only when a CUDA GPU with >= 10 GB is present and HF_TOKEN is set (the base
model is gated). Otherwise `available` is False with a reason, and the endpoint
reports "unavailable". Prompting and parsing are added in Milestone 7.
"""
import os

BASE_ID = "meta-llama/Meta-Llama-3-8B-Instruct"
LORA_ID = "korra141/fingpt-forecaster-llama3-lora"
MIN_VRAM_GB = 10


def probe() -> tuple[bool, str]:
    try:
        import torch
    except ImportError as e:
        return False, f"torch missing: {e}"
    if not torch.cuda.is_available():
        return False, "no CUDA GPU (bitsandbytes 4-bit needs CUDA; Apple MPS is not supported)"
    vram = torch.cuda.get_device_properties(0).total_memory / 2**30
    if vram < MIN_VRAM_GB:
        return False, f"GPU has {vram:.1f} GB VRAM, need >= {MIN_VRAM_GB} GB"
    if not os.environ.get("HF_TOKEN"):
        return False, "HF_TOKEN not set (Meta-Llama-3-8B-Instruct is gated)"
    try:
        import bitsandbytes  # noqa: F401
        import peft  # noqa: F401
    except ImportError as e:
        return False, f"missing dependency: {e}"
    return True, "ok"


class FinGPT:
    def __init__(self):
        import torch
        from peft import PeftModel
        from transformers import AutoModelForCausalLM, AutoTokenizer, BitsAndBytesConfig

        token = os.environ["HF_TOKEN"]
        q = BitsAndBytesConfig(load_in_4bit=True, bnb_4bit_compute_dtype=torch.float16, bnb_4bit_quant_type="nf4")
        self.tok = AutoTokenizer.from_pretrained(BASE_ID, token=token)
        base = AutoModelForCausalLM.from_pretrained(BASE_ID, token=token, quantization_config=q, device_map="cuda:0")
        self.model = PeftModel.from_pretrained(base, LORA_ID, token=token).eval()
