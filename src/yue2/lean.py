"""Lean model loading: only the weights PyTorch actually runs.

On Apple Silicon the acoustic (NAR) path runs on the Neural Engine or in MLX,
so the 2.6 GiB of NAR-path layer weights never need to sit in the PyTorch copy
of the model. ``load_model(..., nar=False)`` builds the model on the meta
device, streams each needed tensor straight from the safetensors file to the
target device (peak host memory: one tensor), and replaces the NAR-path
modules of every layer with a stub. The synthesis engines fetch a layer's NAR
weights through ``nar_layer_state`` which reads them from the checkpoint
on demand (memory-mapped, released afterwards).
"""
from __future__ import annotations
from pathlib import Path
import torch
from torch import nn

NAR_LAYER_KEYS = dict(in_norm="nar_input_layernorm.weight", q="nar_self_attn.q_proj.weight", k="nar_self_attn.k_proj.weight",
                      v="nar_self_attn.v_proj.weight", o="nar_self_attn.o_proj.weight", q_norm="nar_self_attn.q_norm.weight",
                      k_norm="nar_self_attn.k_norm.weight", mlp_norm="nar_pre_mlp_layernorm.weight",
                      gate="nar_mlp.gate_proj.weight", up="nar_mlp.up_proj.weight", down="nar_mlp.down_proj.weight")
NAR_MODULES = ("nar_input_layernorm", "nar_self_attn", "nar_pre_mlp_layernorm", "nar_mlp")


class StrippedModule(nn.Module):
    """Placeholder for NAR-path weights that were not loaded into PyTorch."""

    def forward(self, *args, **kwargs):
        raise RuntimeError("NAR weights are not loaded in PyTorch (lean model); synthesize with the ane or mlx engine")


def weight_files(model_dir):
    """{tensor name: safetensors path} for every tensor of a checkpoint directory."""
    from safetensors import safe_open
    mapping = {}
    for file in sorted(Path(model_dir).glob("*.safetensors")):
        with safe_open(str(file), framework="pt", device="cpu") as handle:
            for key in handle.keys():
                mapping[key] = file
    if not mapping:
        raise FileNotFoundError(f"No safetensors weights in {model_dir}")
    return mapping


def is_lean(model):
    return getattr(model, "_yue2_lean", None) is not None


def load_model(model_dir, device, *, nar=True, dtype=torch.bfloat16):
    """Build YuE2ForCausalLM with weights streamed from disk to ``device``.

    nar=False skips the per-layer NAR path (attention + MLP of every layer) and
    marks the model lean; ``nar_layer_state`` then serves those weights from disk.
    """
    from safetensors import safe_open
    from .modeling_yue2 import YuE2Config, YuE2ForCausalLM
    model_dir = Path(model_dir)
    config = YuE2Config.from_pretrained(model_dir, local_files_only=True)
    with torch.device("meta"):
        model = YuE2ForCausalLM(config)
    files = weight_files(model_dir)
    skip = ()
    if not nar:
        skip = tuple(f".{m}." for m in NAR_MODULES)
        for layer in model.model.layers:
            for name in NAR_MODULES:
                setattr(layer, name, StrippedModule())
    wanted = {name: True for name, _ in model.named_parameters()}
    wanted.update({name: False for name, _ in model.named_buffers()})
    missing = [name for name in wanted if name not in files]
    if missing:
        raise ValueError(f"Checkpoint is missing tensors: {missing[:5]}")
    by_file = {}
    for name in wanted:
        by_file.setdefault(files[name], []).append(name)
    modules = dict(model.named_modules())
    for file, names in by_file.items():
        with safe_open(str(file), framework="pt", device="cpu") as handle:
            for name in names:
                if any(s in name for s in skip):
                    continue
                owner, _, attr = name.rpartition(".")
                tensor = handle.get_tensor(name)
                module = modules[owner]
                if wanted[name]:
                    tensor = tensor.to(dtype=dtype if tensor.is_floating_point() else tensor.dtype)
                    module._parameters[attr] = nn.Parameter(tensor.to(device), requires_grad=False)
                else:
                    module._buffers[attr] = tensor.to(device)
    left = [n for n, p in model.named_parameters() if p.device.type == "meta"] + [n for n, b in model.named_buffers() if b.device.type == "meta"]
    if left:
        raise RuntimeError(f"Tensors left uninitialised: {left[:5]}")
    model._yue2_lean = None if nar else {"dir": model_dir, "files": files}
    model._yue2_weight_identity = checkpoint_identity(files, {name for name, _ in model.named_buffers()})
    return model.eval()


def checkpoint_identity(files, buffer_names=()):
    """Same identity the ANE cache derives from a fully loaded model (sorted parameter names and
    shapes), computed from the checkpoint so lean and full loads share compiled programs."""
    import hashlib
    from safetensors import safe_open
    entries = []
    by_file = {}
    for name, file in files.items():
        by_file.setdefault(file, []).append(name)
    for file, names in by_file.items():
        with safe_open(str(file), framework="pt", device="cpu") as handle:
            for name in names:
                if name not in buffer_names:
                    entries.append((name, tuple(handle.get_slice(name).get_shape())))
    return hashlib.sha256(str(sorted(entries)).encode()).hexdigest()[:16]


def nar_layer_state(model, index):
    """CPU tensors of layer ``index``'s NAR path, keyed like ``NAR_LAYER_KEYS``.

    From the module when loaded, otherwise read from the checkpoint (memory-mapped).
    """
    layer = model.model.layers[index]
    lean = getattr(model, "_yue2_lean", None)
    if lean is None:
        attn, mlp = layer.nar_self_attn, layer.nar_mlp
        return dict(in_norm=layer.nar_input_layernorm.weight, q=attn.q_proj.weight, k=attn.k_proj.weight, v=attn.v_proj.weight,
                    o=attn.o_proj.weight, q_norm=attn.q_norm.weight, k_norm=attn.k_norm.weight, mlp_norm=layer.nar_pre_mlp_layernorm.weight,
                    gate=mlp.gate_proj.weight, up=mlp.up_proj.weight, down=mlp.down_proj.weight)
    from safetensors import safe_open
    names = {short: f"model.layers.{index}.{suffix}" for short, suffix in NAR_LAYER_KEYS.items()}
    state = {}
    by_file = {}
    for short, name in names.items():
        by_file.setdefault(lean["files"][name], []).append(short)
    for file, shorts in by_file.items():
        with safe_open(str(file), framework="pt", device="cpu") as handle:
            for short in shorts:
                state[short] = handle.get_tensor(names[short]).clone()   # own the memory; the mapping is released on close
    return state
