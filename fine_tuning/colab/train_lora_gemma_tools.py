"""
Colab training script for LoRA/QLoRA fine-tuning on Godot tool-use + code/docs data.

Run this in Google Colab (or similar) as a single Python script cell, or copy/paste
sections into a notebook. This script assumes:

- Repo root is the current working directory (contains fine_tuning/, rag_service/, etc.).
- Datasets:
  - fine_tuning/data/train.jsonl  (tool-use, messages + tool_calls)
  - fine_tuning/data/val.jsonl
  - fine_tuning/data/code_completion/code_style.jsonl (optional, code style)
  - fine_tuning/data/docs_qa/docs_qa.jsonl (optional, docs Q&A)

NOTE: This script is intentionally NOT executed here. You should:
- Open Colab
- `!git clone` this repo
- `!pip install` the dependencies (see section 1 below)
- Then run the cells step by step.
"""

# ======================================================================
# 0. Imports and basic config
# ======================================================================

import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import List, Dict, Any, Optional

import torch
from datasets import load_dataset, Dataset, DatasetDict, interleave_datasets
from transformers import (
    AutoModelForCausalLM,
    AutoTokenizer,
    BitsAndBytesConfig,
    TrainingArguments,
)
from peft import LoraConfig, get_peft_model
from trl import SFTTrainer


REPO_ROOT = Path(".").resolve()
DATA_DIR = REPO_ROOT / "fine_tuning" / "data"
# Tool-use data (already split) now lives under data/tool_usage/
TOOLS_TRAIN = DATA_DIR / "tool_usage" / "train.jsonl"
TOOLS_VAL = DATA_DIR / "tool_usage" / "val.jsonl"
# Optional extras
CODE_STYLE = DATA_DIR / "code_completion" / "code_style.jsonl"
DOCS_QA = DATA_DIR / "docs_qa" / "docs_qa.jsonl"
# Optional forums / discussion-style data (stackexchange, GitHub issues, etc.)
# NOTE: We now use the Godot forum help JSONL directly.
FORUMS = DATA_DIR / "forums" / "godot_forum_help.jsonl"


# ======================================================================
# 1. Colab setup (install deps)  [RUN THIS CELL IN COLAB]
# ======================================================================

COLAB_SETUP_INSTRUCTIONS = r"""
# In Colab, run this cell first:

%%bash
pip install -q bitsandbytes==0.43.3 \
  transformers==4.46.0 \
  accelerate==0.34.2 \
  datasets==3.0.0 \
  peft==0.13.0 \
  trl==0.9.6 \
  sentencepiece \
  einops
"""


# ======================================================================
# 2. Model choice and QLoRA config
# ======================================================================

"""
Choose a base chat **code** model. For Godot tool-use, we want:
- Code-aware behavior (good at GDScript-like and general coding patterns).
- Reasonable size (e.g. 7B) so Colab can handle it with QLoRA.
- Chat-style interface (system/user/assistant turns).

Recommended defaults:
- "Qwen/Qwen2.5-Coder-7B-Instruct"   # balanced code-focused 7B chat model
- (alternatively) "deepseek-ai/DeepSeek-Coder-V2-Lite-Instruct" if you have more GPU.

You can override via BASE_MODEL_ID env var in Colab if you want to try others.
"""

BASE_MODEL_ID = os.environ.get("BASE_MODEL_ID", "Qwen/Qwen2.5-Coder-7B-Instruct")

# 4-bit quantization config for QLoRA
bnb_config = BitsAndBytesConfig(
    load_in_4bit=True,
    bnb_4bit_compute_dtype=torch.float16,
    bnb_4bit_use_double_quant=True,
    bnb_4bit_quant_type="nf4",
)

# LoRA configuration – keep this modest for Colab
lora_config = LoraConfig(
    r=8,
    lora_alpha=16,
    lora_dropout=0.05,
    bias="none",
    task_type="CAUSAL_LM",
)


# ======================================================================
# 3. Dataset loading helpers
# ======================================================================

def load_jsonl_dataset(path: Path) -> Dataset:
    """
    Load a JSONL file into a Hugging Face Dataset.
    Expects one JSON object per line. We load line-by-line and use from_list()
    so that mixed types in nested fields (e.g. tool_calls[].arguments with
    sometimes string, sometimes array values) do not trigger Arrow schema errors.
    """
    if not path.exists():
        raise FileNotFoundError(f"{path} does not exist")
    records: List[Dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            records.append(json.loads(line))
    if not records:
        raise ValueError(f"{path} is empty")
    return Dataset.from_list(records)


def safe_concat(datasets: List[Dataset]) -> Dataset:
    """Concatenate non-empty datasets; if only one is non-empty, return it."""
    non_empty = [ds for ds in datasets if len(ds) > 0]
    if not non_empty:
        raise ValueError("No non-empty datasets to concatenate")
    if len(non_empty) == 1:
        return non_empty[0]
    return Dataset.concatenate_non_empty_datasets(non_empty)  # type: ignore[attr-defined]


# ======================================================================
# 4. Formatting examples into a single training string
# ======================================================================

"""
We have three kinds of data:
- Tool-use:   {"messages": [..., {"role": "assistant", "tool_calls": [...]}]}
- Code-style: {"code": "...", metadata...}
- Docs Q&A:   {"messages": [..., {"role": "assistant", "content": "docs snippet"}]}

We map each to a single text string using a *chat-style template*.

For simplicity (and to keep this script self-contained), we use a generic
XML-ish template here:

  <system>...</system>\n<user>...</user>\n<assistant>...tool_calls JSON...</assistant>

This works with any chat code model (Qwen, DeepSeek, Gemma, etc.) and is good
enough for a first run.

Later, you can switch to the model's native chat template (recommended for best
quality) by:

- Using tokenizer.apply_chat_template(...) inside a custom collator, OR
- Pre-formatting messages into the exact prompt string each model expects.

For tool-use examples, we include the tool_calls JSON literally in the assistant
turn. This trains the model to emit the correct JSON shape as plain text.
"""


def format_messages_example(example: Dict[str, Any]) -> str:
    """Format a messages-style JSON example into a single string (generic template)."""
    msgs = example.get("messages") or []
    parts: List[str] = []
    for m in msgs:
        role = m.get("role")
        content = m.get("content", "")
        if role == "system":
            parts.append(f"<system>{content}</system>")
        elif role == "user":
            parts.append(f"<user>{content}</user>")
        elif role == "assistant":
            # Include tool_calls JSON as part of content when present
            tool_calls = m.get("tool_calls")
            if tool_calls:
                tc_json = json.dumps(tool_calls, ensure_ascii=False)
                if content:
                    content = content + "\n" + tc_json
                else:
                    content = tc_json
            parts.append(f"<assistant>{content}</assistant>")
        else:
            parts.append(content)
    return "\n".join(parts)


def format_code_style_example(example: Dict[str, Any]) -> str:
    """Format a code-style record into a simple completion-style string."""
    code = example.get("code", "")
    path = example.get("path", "")
    extends_class = example.get("extends_class", "")
    header = f"# File: {path} (extends {extends_class})"
    return header + "\n" + code


def build_mixed_dataset() -> DatasetDict:
    """
    Build a mixed DatasetDict with:
    - 'train': tool-use + (optionally) code-style + docs Q&A
    - 'val':   tool-use val only (to monitor tool behavior)

    You can adjust this strategy:
    - train only on tool-use at first
    - run a second stage with code_style/docs_qa
    """
    # Load tool-use train/val
    tools_train = load_jsonl_dataset(TOOLS_TRAIN)
    tools_val = load_jsonl_dataset(TOOLS_VAL)

    # Format tool-use examples
    tools_train = tools_train.map(lambda ex: {"text": format_messages_example(ex)}, remove_columns=tools_train.column_names)
    tools_val = tools_val.map(lambda ex: {"text": format_messages_example(ex)}, remove_columns=tools_val.column_names)

    # Optionally add code-style, docs_qa, and forums into train with explicit weights.
    #
    # ROUGH SIZE ANALYSIS (2026‑03‑15, line counts ~= example counts):
    # - tool_usage/train.jsonl      ≈ 4063 lines
    # - code_completion/code_style  ≈ 4000 lines
    # - docs_qa/docs_qa.jsonl       ≈ 1450 lines
    # - forums/godot_forum_help     ≈  533 lines
    #
    # So tool_usage and code_style are comparable in count, docs_qa is ~1/3 of
    # those, and forums is currently the smallest pool. We still *upweight*
    # forums a bit because it carries long, noisy, multi‑turn threads that are
    # very valuable for robustness and “real user” Godot help behavior, even
    # if there are fewer lines.
    #
    # We weight by *sample count* (not token count) to keep the mental model
    # simple in Colab:
    # - Tool usage:  ~35%  (most critical + most fragile behavior)
    # - Code style:  ~30%  (core stylistic foundation, diverse)
    # - Forums:      ~25%  (real‑world reasoning + messy inputs)
    # - Docs Q&A:    ~10%  (pure reference text; lowest ROI per token)
    #
    # NOTE ON EXPERIMENTS:
    # - For a *pure tools run*, set target_weights = {"tools": 1.0} and comment
    #   out / skip the extras below.
    # - For a *code‑heavy run*, you can push code_style up to ~0.5 and shrink
    #   docs/forums to keep tools >= 0.3.
    # - For a *robust‑chat run*, you can push forums up to ~0.35–0.4 and shrink
    #   docs_qa first (docs tends to be the least sensitive lever).
    #
    # Only datasets that actually exist are used, and weights are renormalized
    # over the present ones so you can run ablations by adding/removing files
    # without touching the rest of the script.
    train_components: List[tuple[str, Dataset]] = [("tools", tools_train)]

    if CODE_STYLE.exists():
        code_ds = load_jsonl_dataset(CODE_STYLE)
        code_ds = code_ds.map(lambda ex: {"text": format_code_style_example(ex)}, remove_columns=code_ds.column_names)
        train_components.append(("code", code_ds))

    if DOCS_QA.exists():
        docs_ds = load_jsonl_dataset(DOCS_QA)
        docs_ds = docs_ds.map(lambda ex: {"text": format_messages_example(ex)}, remove_columns=docs_ds.column_names)
        train_components.append(("docs", docs_ds))

    if FORUMS.exists():
        forums_ds = load_jsonl_dataset(FORUMS)
        forums_ds = forums_ds.map(lambda ex: {"text": format_messages_example(ex)}, remove_columns=forums_ds.column_names)
        train_components.append(("forums", forums_ds))

    if len(train_components) == 1:
        # Only tool-use is present; fall back to pure tool-use training.
        train_combined = tools_train
    else:
        # DEFAULT MIXTURE FOR “GODOT TOOLS V1”
        #
        # This is intentionally skewed a bit toward *tools* and *code_style*,
        # while still giving forums enough probability mass that the model
        # regularly sees messy, multi‑turn help threads.
        #
        # If you want to try alternative mixtures in Colab, the recommended
        # pattern is to copy this dict into the notebook cell, tweak it there,
        # and then re‑import this module so you keep the canonical defaults
        # checked into the repo.
        target_weights = {
            "tools": 0.38,   # slightly above 1/N to bias toward correct tools JSON
            "code": 0.32,    # keep style/completion almost as frequent as tools
            "forums": 0.20,  # down a bit vs. earlier guess; line‑count is small
            "docs": 0.10,    # lowest because docs_qa is dense but less “risky”
        }
        present = [(name, ds) for name, ds in train_components if name in target_weights]
        if not present:
            # Should not happen in normal use: at least tools must be present.
            train_combined = tools_train
        else:
            total = sum(target_weights[name] for name, _ in present)
            probs = [target_weights[name] / total for name, _ in present]
            datasets_only = [ds for _, ds in present]
            train_combined = interleave_datasets(
                datasets_only,
                probabilities=probs,
                seed=42,
            )

    return DatasetDict({"train": train_combined, "val": tools_val})


# ======================================================================
# 5. Tokenizer and model loading  [RUN IN COLAB]
# ======================================================================

def load_tokenizer_and_model() -> tuple[AutoTokenizer, AutoModelForCausalLM]:
    """
    Load the base model with the tokenizer. Prefer 4-bit QLoRA; if bitsandbytes
    or triton fails (e.g. missing CUDA .so or triton.ops), fall back to bfloat16
    so Colab can still run (uses more VRAM).
    """
    tokenizer = AutoTokenizer.from_pretrained(BASE_MODEL_ID, trust_remote_code=True)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

    try:
        model = AutoModelForCausalLM.from_pretrained(
            BASE_MODEL_ID,
            quantization_config=bnb_config,
            device_map="auto",
            trust_remote_code=True,
        )
    except (RuntimeError, ModuleNotFoundError, OSError) as e:
        if "triton" in str(e).lower() or "bitsandbytes" in str(e).lower() or "libbitsandbytes" in str(e).lower():
            # Fallback: load in bfloat16 without 4-bit (needs more VRAM but works without bitsandbytes CUDA/triton)
            model = AutoModelForCausalLM.from_pretrained(
                BASE_MODEL_ID,
                torch_dtype=torch.bfloat16 if torch.cuda.is_available() else torch.float32,
                device_map="auto",
                trust_remote_code=True,
            )
        else:
            raise

    model = get_peft_model(model, lora_config)
    # Required for gradient checkpointing + LoRA: otherwise backward fails with
    # "element 0 of tensors does not require grad".
    model.enable_input_require_grads()
    return tokenizer, model


# ======================================================================
# 6. Training config and trainer  [RUN IN COLAB]
# ======================================================================

def build_trainer(tokenizer, model, dataset: DatasetDict) -> SFTTrainer:
    """
    Build an SFTTrainer for supervised fine-tuning.
    We train the model to generate the 'text' field.
    Tuned for ~15 GB Colab GPU: batch_size=1, max_seq_length=1024, gradient_checkpointing.

    To resume from a checkpoint after interrupt: call
      trainer.train(resume_from_checkpoint=True)
    (uses latest checkpoint in output_dir, e.g. ./godot-tools-lora/checkpoint-200).
    """
    training_args = TrainingArguments(
        output_dir="./godot-tools-lora",
        per_device_train_batch_size=1,
        per_device_eval_batch_size=1,
        gradient_accumulation_steps=16,
        num_train_epochs=2,
        learning_rate=2e-4,
        lr_scheduler_type="cosine",
        warmup_ratio=0.03,
        logging_steps=10,
        evaluation_strategy="steps",
        eval_steps=100,
        save_strategy="steps",
        save_steps=200,
        save_total_limit=3,
        bf16=torch.cuda.is_available(),
        fp16=not torch.cuda.is_available(),
        gradient_checkpointing=True,
        report_to="none",
    )

    trainer = SFTTrainer(
        model=model,
        tokenizer=tokenizer,
        train_dataset=dataset["train"],
        eval_dataset=dataset["val"],
        dataset_text_field="text",
        max_seq_length=1024,
        args=training_args,
    )
    return trainer


# ======================================================================
# 7. Colab main entrypoint (example usage)  [RUN IN COLAB]
# ======================================================================

COLAB_MAIN_EXAMPLE = r"""
# Example usage in a Colab cell (after installing deps and cloning the repo):

from train_lora_gemma_tools import (
    build_mixed_dataset,
    load_tokenizer_and_model,
    build_trainer,
)

dataset = build_mixed_dataset()
tokenizer, model = load_tokenizer_and_model()
trainer = build_trainer(tokenizer, model, dataset)

# Start training (this can take a while):
trainer.train()

# Save adapters:
trainer.model.save_pretrained("godot-tools-lora-adapter")
tokenizer.save_pretrained("godot-tools-lora-adapter")
"""


if __name__ == "__main__":
    # This script is meant to be imported in Colab, not run directly here.
    print(
        "This module defines helpers for Colab (dataset building, model loading, trainer construction).\n"
        "Import it in your notebook and follow the commented COLAB_* examples."
    )

