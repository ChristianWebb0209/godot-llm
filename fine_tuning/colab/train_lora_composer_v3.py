"""
Colab training script for Composer LoRA/QLoRA fine-tuning (v3 default).

This trains only on:
  fine_tuning/data/composer_v3/train.jsonl
  fine_tuning/data/composer_v3/val.jsonl

It assumes the composer dataset already uses the Composer contract:
- AGENT mode: assistant emits <tool_call>...</tool_call> XML blocks
- ASK mode: assistant emits exactly one question and no <tool_call> blocks
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any, Dict, List

import torch

torch.backends.cuda.matmul.allow_tf32 = True
torch.backends.cudnn.allow_tf32 = True

from datasets import Dataset, DatasetDict
from transformers import AutoModelForCausalLM, AutoTokenizer, BitsAndBytesConfig, TrainingArguments
from peft import LoraConfig, get_peft_model, prepare_model_for_kbit_training
from trl import SFTTrainer


REPO_ROOT = Path(".").resolve()
DATA_VERSION = os.environ.get("COMPOSER_DATA_VERSION", "composer_v3").strip() or "composer_v3"
DATA_DIR = REPO_ROOT / "fine_tuning" / "data" / DATA_VERSION

COMPOSER_TRAIN = DATA_DIR / "train.jsonl"
COMPOSER_VAL = DATA_DIR / "val.jsonl"

BASE_MODEL_ID = os.environ.get("BASE_MODEL_ID", "Qwen/Qwen2.5-Coder-7B-Instruct")


def load_jsonl_dataset(path: Path) -> Dataset:
    if not path.exists():
        raise FileNotFoundError(f"Dataset not found: {path}")
    records: List[Dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            records.append(json.loads(line))
    if not records:
        raise ValueError(f"Dataset is empty: {path}")
    return Dataset.from_list(records)


def format_messages_example(example: Dict[str, Any]) -> str:
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
            parts.append(f"<assistant>{content}</assistant>")
        else:
            parts.append(str(content))
    return "\n".join(parts)


def load_tokenizer_and_model() -> tuple[AutoTokenizer, AutoModelForCausalLM]:
    tokenizer = AutoTokenizer.from_pretrained(BASE_MODEL_ID, trust_remote_code=True)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

    attn_impl = "flash_attention_2" if torch.cuda.is_available() and torch.cuda.get_device_capability()[0] >= 8 else "sdpa"

    # QLoRA 4-bit config for Colab
    bnb_config = BitsAndBytesConfig(
        load_in_4bit=True,
        bnb_4bit_compute_dtype=torch.float16,
        bnb_4bit_use_double_quant=True,
        bnb_4bit_quant_type="nf4",
    )

    lora_config = LoraConfig(
        r=8,
        lora_alpha=16,
        lora_dropout=0.05,
        bias="none",
        task_type="CAUSAL_LM",
    )

    try:
        model = AutoModelForCausalLM.from_pretrained(
            BASE_MODEL_ID,
            quantization_config=bnb_config,
            device_map="auto",
            trust_remote_code=True,
            attn_implementation=attn_impl,
        )
    except (RuntimeError, ModuleNotFoundError, OSError, ValueError):
        # Fallback: load bf16 without 4-bit if bitsandbytes/4bit fails.
        model = AutoModelForCausalLM.from_pretrained(
            BASE_MODEL_ID,
            torch_dtype=torch.bfloat16 if torch.cuda.is_available() else torch.float32,
            device_map="auto",
            trust_remote_code=True,
            attn_implementation=attn_impl,
        )

    model = prepare_model_for_kbit_training(model)
    model = get_peft_model(model, lora_config)

    # Required for gradient checkpointing + LoRA
    model.config.use_cache = False
    model.gradient_checkpointing_enable()
    model.enable_input_require_grads()

    return tokenizer, model


def build_trainer(tokenizer: AutoTokenizer, model: AutoModelForCausalLM, dataset: DatasetDict) -> SFTTrainer:
    output_dir = os.environ.get("CHECKPOINT_DIR", "./godot-composer-v3-lora")

    training_args = TrainingArguments(
        output_dir=output_dir,
        per_device_train_batch_size=3,
        per_device_eval_batch_size=1,
        gradient_accumulation_steps=2,
        num_train_epochs=1,
        learning_rate=2e-4,
        lr_scheduler_type="cosine",
        warmup_ratio=0.03,
        logging_steps=40,
        eval_strategy="no",
        save_strategy="steps",
        save_steps=700,
        save_total_limit=3,
        bf16=False,
        fp16=True,
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


def main() -> None:
    if not COMPOSER_TRAIN.exists() or not COMPOSER_VAL.exists():
        raise SystemExit(
            f"Missing {DATA_VERSION} datasets. Expected:\n- {COMPOSER_TRAIN}\n- {COMPOSER_VAL}"
        )

    train_ds = load_jsonl_dataset(COMPOSER_TRAIN)
    val_ds = load_jsonl_dataset(COMPOSER_VAL)

    train_ds = train_ds.map(lambda ex: {"text": format_messages_example(ex)}, remove_columns=train_ds.column_names)
    val_ds = val_ds.map(lambda ex: {"text": format_messages_example(ex)}, remove_columns=val_ds.column_names)

    dataset = DatasetDict({"train": train_ds, "val": val_ds})
    tokenizer, model = load_tokenizer_and_model()
    trainer = build_trainer(tokenizer, model, dataset)

    trainer.train()

    save_dir = os.environ.get("OUTPUT_ADAPTER_DIR", "godot-composer-v3-adapter")
    trainer.model.save_pretrained(save_dir)
    tokenizer.save_pretrained(save_dir)
    print(f"Saved adapter to: {save_dir}")


if __name__ == "__main__":
    main()

