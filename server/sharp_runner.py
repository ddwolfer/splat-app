"""Thin wrapper around apple/ml-sharp inference, shared by the benchmark (M1) and the API server (M2).

Mirrors `sharp.cli.predict.predict_image`, with one addition: optional mixed precision applied
*only* to the network forward pass. Postprocessing (unprojection uses torch.linalg.inv, which
does not support fp16/bf16) always runs in float32.
"""

from __future__ import annotations

from typing import Literal

import numpy as np
import torch
import torch.nn.functional as F

from sharp.cli.predict import DEFAULT_MODEL_URL
from sharp.models import PredictorParams, RGBGaussianPredictor, create_predictor
from sharp.utils.gaussians import Gaussians3D, unproject_gaussians

Amp = Literal["none", "fp16", "bf16"]
INTERNAL_SHAPE = (1536, 1536)
# fp32 needs ~10.9GB reserved (> 8GB on the RTX 4060); fp16 ~6.2GB with tiny error. See plans/server-M1.md.
DEFAULT_AMP: Amp = "fp16"


def load_model(device: torch.device, checkpoint_url: str = DEFAULT_MODEL_URL) -> RGBGaussianPredictor:
    state_dict = torch.hub.load_state_dict_from_url(checkpoint_url, progress=False)
    model = create_predictor(PredictorParams())
    model.load_state_dict(state_dict)
    del state_dict
    model.eval().to(device)
    return model


@torch.no_grad()
def predict(
    model: RGBGaussianPredictor,
    image: np.ndarray,
    f_px: float,
    device: torch.device,
    amp: Amp = DEFAULT_AMP,
) -> Gaussians3D:
    """Predict metric-space Gaussians from an HxWx3 uint8 RGB image (same math as the official CLI)."""
    image_pt = torch.from_numpy(image.copy()).float().to(device).permute(2, 0, 1) / 255.0
    _, height, width = image_pt.shape
    disparity_factor = torch.tensor([f_px / width]).float().to(device)

    image_resized_pt = F.interpolate(
        image_pt[None],
        size=(INTERNAL_SHAPE[1], INTERNAL_SHAPE[0]),
        mode="bilinear",
        align_corners=True,
    )
    del image_pt

    if amp == "none":
        gaussians_ndc = model(image_resized_pt, disparity_factor)
    else:
        dtype = torch.float16 if amp == "fp16" else torch.bfloat16
        with torch.autocast("cuda", dtype=dtype):
            gaussians_ndc = model(image_resized_pt, disparity_factor)
        gaussians_ndc = Gaussians3D(*(t.float() for t in gaussians_ndc))

    intrinsics = torch.tensor(
        [
            [f_px, 0, width / 2, 0],
            [0, f_px, height / 2, 0],
            [0, 0, 1, 0],
            [0, 0, 0, 1],
        ]
    ).float().to(device)
    intrinsics_resized = intrinsics.clone()
    intrinsics_resized[0] *= INTERNAL_SHAPE[0] / width
    intrinsics_resized[1] *= INTERNAL_SHAPE[1] / height

    return unproject_gaussians(
        gaussians_ndc, torch.eye(4).to(device), intrinsics_resized, INTERNAL_SHAPE
    )
