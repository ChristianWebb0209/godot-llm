"""
Colab notebook template for training a LoRA/QLoRA adapter on the Godot tools dataset.

Usage:
- In Colab, create a new notebook.
- Drag/drop this file into Colab or copy/paste the cells one by one.
"""


# # Godot Tools LoRA Training (Colab)
#
# This notebook trains a LoRA/QLoRA adapter on:
# - Tool-usage examples (`fine_tuning/data/tool_usage/*.jsonl`)
# - Code style completions (`code_completion/code_style.jsonl`)
# - Docs Q&A (`docs_qa/docs_qa.jsonl`)
# - Godot forum help threads (`forums/godot_forum_help.jsonl`)
#
# It assumes this repo is cloned in `/content/godot-llm` in Colab.


# ## 0. Runtime & repo setup
#
# - Make sure GPU is enabled (Runtime → Change runtime type → GPU).
# - Clone (or pull) the repo into `/content/godot-llm`.


import os
from pathlib import Path

if Path("/content").exists():
    # Running in Colab
    if not Path("/content/godot-llm").exists():
        # Fresh clone
        !git clone https://github.com/ChristianWebb0209/godot-llm.git /content/godot-llm
    %cd /content/godot-llm
else:
    # Local / other environment – assume current working directory is repo root.
    print("Not in Colab; please ensure the working directory is the repo root.")


# ## 1. Install Python dependencies
#
# Versions below work together in Colab (numpy 2 + trl >= 0.12 avoids binary/schema issues).
# Pip may warn about conflicts with preinstalled tensorflow/numba; those can be ignored.


!pip install -U "numpy>=2.0" \
  "trl>=0.12.0" \
  transformers==4.46.0 \
  accelerate==0.34.2 \
  datasets==3.0.0 \
  peft==0.13.0 \
  bitsandbytes==0.43.3 \
  sentencepiece \
  einops \
  jedi \
  fsspec


# ## 1b. Troubleshooting: bitsandbytes CUDA / triton (run if model load fails)
#
# If you see "Could not find the bitsandbytes CUDA binary" or "No module named
# 'triton.ops'", run this cell then **Runtime → Restart session** and re-run
# from the imports cell. HF_TOKEN warning is optional (only needed for gated models).


!pip install triton --quiet
!pip install --no-cache-dir --force-reinstall bitsandbytes>=0.43.0 --quiet


# ## 2. Imports and config
#
# We reuse the helpers from `fine_tuning/colab/train_lora_gemma_tools.py`,
# but we build the dataset via a *flat text* loader in this notebook to avoid
# Arrow schema issues from mixed JSON types in nested fields.


import json
from typing import Dict, Any, List

from datasets import Dataset, DatasetDict, interleave_datasets

from fine_tuning.colab.train_lora_gemma_tools import (
    format_messages_example,
    format_code_style_example,
    load_tokenizer_and_model,
    build_trainer,
)


REPO_ROOT = Path(".").resolve()
DATA_DIR = REPO_ROOT / "fine_tuning" / "data"
TOOLS_TRAIN = DATA_DIR / "tool_usage" / "train.jsonl"
TOOLS_VAL = DATA_DIR / "tool_usage" / "val.jsonl"
CODE_STYLE = DATA_DIR / "code_completion" / "code_style.jsonl"
DOCS_QA = DATA_DIR / "docs_qa" / "docs_qa.jsonl"
FORUMS = DATA_DIR / "forums" / "godot_forum_help.jsonl"


# ## 3. Robust JSONL → Dataset loader
#
# We *do not* let `datasets.load_dataset("json", ...)` infer a nested Arrow
# schema, because our tool usage JSONL can have mixed types inside
# `tool_calls[].arguments` (`string` vs `array`). Instead we:
# - Parse each line as a Python dict.
# - Map it to a plain `{"text": ...}` record using the formatters from the
#   Colab helper module.
# - Build a `Dataset` with `Dataset.from_list(records)`.
#
# This keeps the HF `Dataset` perfectly flat and avoids all "cannot mix list
# and non-list" style schema errors.


def _jsonl_to_dataset(path: Path, formatter) -> Dataset:
    if not path.exists():
        raise FileNotFoundError(f"{path} does not exist")
    records: List[Dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            obj = json.loads(line)
            records.append({"text": formatter(obj)})
    if not records:
        raise ValueError(f"{path} is empty")
    return Dataset.from_list(records)


# ## 4. Build mixed training/validation dataset
#
# The default mixture weights (by *example count*) are:
# - tools:  ~0.38
# - code:   ~0.32
# - forums: ~0.20
# - docs:   ~0.10
#
# Only datasets that exist on disk are included; weights are renormalized
# over the present components so you can easily ablate by deleting a file.
#
# To try different mixtures, tweak `target_weights` in this cell and rerun it.


def build_mixed_dataset_flat() -> DatasetDict:
    # Tools (train/val): messages → text
    tools_train = _jsonl_to_dataset(TOOLS_TRAIN, format_messages_example)
    tools_val = _jsonl_to_dataset(TOOLS_VAL, format_messages_example)

    train_components: List[tuple[str, Dataset]] = [("tools", tools_train)]

    if CODE_STYLE.exists():
        code_ds = _jsonl_to_dataset(CODE_STYLE, format_code_style_example)
        train_components.append(("code", code_ds))

    if DOCS_QA.exists():
        docs_ds = _jsonl_to_dataset(DOCS_QA, format_messages_example)
        train_components.append(("docs", docs_ds))

    if FORUMS.exists():
        forums_ds = _jsonl_to_dataset(FORUMS, format_messages_example)
        train_components.append(("forums", forums_ds))

    if len(train_components) == 1:
        train_combined = tools_train
    else:
        target_weights = {
            "tools": 0.38,
            "code": 0.32,
            "forums": 0.20,
            "docs": 0.10,
        }
        present = [(name, ds) for name, ds in train_components if name in target_weights]
        total = sum(target_weights[name] for name, _ in present)
        probs = [target_weights[name] / total for name, _ in present]
        datasets_only = [ds for _, ds in present]
        train_combined = interleave_datasets(
            datasets_only,
            probabilities=probs,
            seed=42,
        )

    return DatasetDict({"train": train_combined, "val": tools_val})


# ## 5. Load model/tokenizer and build trainer
#
# The base model ID defaults to `Qwen/Qwen2.5-Coder-7B-Instruct`, but you can
# override it via `BASE_MODEL_ID` environment variable *before* importing
# `load_tokenizer_and_model`.


dataset = build_mixed_dataset_flat()
tokenizer, model = load_tokenizer_and_model()
trainer = build_trainer(tokenizer, model, dataset)


# ## 6. Train and save adapters
#
# This may take a while depending on GPU. After training, we save the LoRA
# adapter and tokenizer to a local folder for download or later upload to a
# model hub.


trainer.train()

adapter_out_dir = "godot-tools-lora-adapter"
trainer.model.save_pretrained(adapter_out_dir)
tokenizer.save_pretrained(adapter_out_dir)
print(f"Saved LoRA adapter to: {adapter_out_dir}")
