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
    # Running in Colab: always ensure we have the latest main branch.
    if not Path("/content/godot-llm").exists():
        # Fresh clone
        !git clone https://github.com/ChristianWebb0209/godot-llm.git /content/godot-llm
    %cd /content/godot-llm
    # Always pull latest from origin so template and training script updates apply.
    !git fetch origin
    !git reset --hard origin/master
else:
    # Local / other environment – assume current working directory is repo root.
    print("Not in Colab; please ensure the working directory is the repo root.")


# ## 0b. Persistent outputs (Google Drive) + auto-resume
#
# Colab runtimes can reset and wipe `/content`. To avoid losing long runs, we:
# - Mount Google Drive.
# - Save checkpoints to Drive (so training can resume automatically).
# - Save the final adapter to Drive.
#
# You can override the default Drive folder by setting:
#   %env DRIVE_RUN_DIR=/content/drive/MyDrive/some/other/folder
#

IN_COLAB = Path("/content").exists()
DRIVE_RUN_DIR = Path(os.environ.get("DRIVE_RUN_DIR", "/content/drive/MyDrive/godot-tools-lora")).resolve()
DEPS_MARKER = DRIVE_RUN_DIR / ".deps_ok"

if IN_COLAB:
    try:
        from google.colab import drive  # type: ignore

        drive.mount("/content/drive", force_remount=False)
        DRIVE_RUN_DIR.mkdir(parents=True, exist_ok=True)

        # Make checkpoint saving persistent + enable auto-resume by default.
        os.environ["CHECKPOINT_DIR"] = str(DRIVE_RUN_DIR / "checkpoints")
        os.environ["RESUME_FROM_CHECKPOINT"] = "auto"
        # Increase save frequency (default was 200, but on slow Colab runs it might crash before).
        os.environ["CHECKPOINT_STEPS"] = "50"
    except Exception as e:
        print(
            "WARNING: Could not mount Google Drive. "
            "Checkpoints/adapters will be saved under /content and may be lost on reset.\n"
            f"Drive mount error: {e}"
        )


# ## 1. Install Python dependencies (robust Colab / Py3.12)
#
# Colab often comes with preinstalled packages that conflict with this stack.
# If you see errors like:
#   - "numpy.dtype size changed, may indicate binary incompatibility"
#   - datasets/fsspec version conflicts
# this cell force-reinstalls a consistent set of versions and then restarts
# the runtime ONCE so compiled wheels line up with the pinned numpy version.
#
# NOTE: Pip may warn about other Colab packages (jax/opencv/etc). That's OK for
# our training environment; we only need the HF/TRL stack to be consistent.

if IN_COLAB and not DEPS_MARKER.exists():
    # Uninstall common conflicting packages first (ignore failures).
    !pip uninstall -y -q transformers numpy fsspec gcsfs datasets pyarrow pandas requests || true

    # Force-reinstall a consistent stack.
    #
    # - numpy pinned to 1.26.x to match TRL 0.9.x + many wheels
    # - fsspec pinned to satisfy datasets==3.0.0 constraint
    # - transformers pinned <5 (this template uses TRL 0.9.6 APIs)
    !pip install -q --no-cache-dir --force-reinstall \
      "numpy==1.26.4" \
      "pandas==2.2.2" \
      "requests==2.32.4" \
      "fsspec==2024.6.1" \
      "datasets==3.0.0" \
      "trl==0.9.6" \
      "transformers>=4.48.0,<4.49" \
      "accelerate==0.34.2" \
      "peft==0.13.0" \
      "bitsandbytes==0.43.3" \
      sentencepiece \
      einops \
      jedi

    # Mark deps installed (persistently, on Drive) and restart the runtime so
    # imports use the fresh wheels. Colab will show this as a "run failed" /
    # "kernel restarted" message, but it is expected once after installing deps.
    DEPS_MARKER.write_text("ok\n", encoding="utf-8")
    print("Dependencies installed. Restarting runtime now (this is expected once).")
    try:
        from google.colab import runtime  # type: ignore

        runtime.restart_runtime()
    except Exception:
        import os as _os, signal as _signal

        _os.kill(_os.getpid(), _signal.SIGKILL)
else:
    # Non-Colab environments can install deps manually, or rerun without restart.
    !pip install -q "numpy<2.0" \
      "trl==0.9.6" \
      "transformers>=4.48.0,<4.49" \
      accelerate==0.34.2 \
      datasets==3.0.0 \
      peft==0.13.0 \
      bitsandbytes==0.43.3 \
      sentencepiece \
      einops \
      jedi \
      "fsspec<=2024.6.1"


# ## 1b. Troubleshooting: bitsandbytes CUDA / triton (run if model load fails)
#
# If you see "Could not find the bitsandbytes CUDA binary" or "No module named
# 'triton.ops'", run this cell then **Runtime → Restart session** and re-run
# from the imports cell. We re-pin numpy<2 so pip does not upgrade to numpy 2.x
# (which breaks scipy/trl on Colab). HF_TOKEN warning is optional (gated models).


!pip install -q "numpy<2.0" triton
!pip install -q "numpy<2.0" --no-cache-dir --force-reinstall "bitsandbytes>=0.43.0"


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

CHECKPOINT_DIR = Path(os.environ.get("CHECKPOINT_DIR", "./godot-tools-lora")).resolve()
latest_checkpoint = None
if CHECKPOINT_DIR.exists():
    ckpt_dirs = [
        p for p in CHECKPOINT_DIR.iterdir()
        if p.is_dir() and p.name.startswith("checkpoint-")
    ]
    if ckpt_dirs:
        # Sort by global step encoded in "checkpoint-{step}" (fall back to name sort).
        def _step_key(p: Path) -> int:
            try:
                return int(p.name.split("-")[-1])
            except ValueError:
                return -1

        ckpt_dirs.sort(key=_step_key)
        latest_checkpoint = ckpt_dirs[-1]

resume_cfg = os.environ.get("RESUME_FROM_CHECKPOINT", "auto").lower()
use_resume = False
if resume_cfg in ("1", "true", "yes"):
    use_resume = latest_checkpoint is not None
elif resume_cfg in ("0", "false", "no"):
    use_resume = False
else:
    # "auto": resume iff we actually found a checkpoint
    use_resume = latest_checkpoint is not None

if use_resume and latest_checkpoint is not None:
    print(f"Resuming training from checkpoint: {latest_checkpoint}")
    trainer.train(resume_from_checkpoint=str(latest_checkpoint))
else:
    if latest_checkpoint is not None:
        print(
            f"Found existing checkpoint at {latest_checkpoint}, "
            "but RESUME_FROM_CHECKPOINT is set to disable auto-resume; "
            "starting a fresh run."
        )
    trainer.train()

adapter_out_dir = (
    (DRIVE_RUN_DIR / "adapter").as_posix()
    if (IN_COLAB and str(DRIVE_RUN_DIR).startswith("/content/drive/"))
    else "godot-tools-lora-adapter"
)
trainer.model.save_pretrained(adapter_out_dir)
tokenizer.save_pretrained(adapter_out_dir)
print(f"Saved LoRA adapter to: {adapter_out_dir}")
