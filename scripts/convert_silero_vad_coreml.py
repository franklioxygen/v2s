#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11,<3.13"
# dependencies = [
#   "coremltools==9.0",
#   "numpy==1.26.4",
#   "torch==2.7.0",
# ]
# ///
"""Rebuild the pinned Silero VAD Core ML package from its upstream JIT weights."""

from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import os
import shutil
import sys
import tempfile
import urllib.parse
import uuid
from pathlib import Path
from typing import Mapping

import coremltools as ct
from coremltools.proto import Model_pb2
import numpy as np
import torch
import torch.nn.functional as F
from torch import Tensor, nn

UPSTREAM_COMMIT = "806dcba3f0b5d95282d0889a074954a2f8c6397b"
UPSTREAM_RAW_PATH = "src/silero_vad/data/silero_vad.jit"
UPSTREAM_SOURCE_URL = (
    "https://raw.githubusercontent.com/snakers4/silero-vad/"
    f"{UPSTREAM_COMMIT}/{UPSTREAM_RAW_PATH}"
)
UPSTREAM_LICENSE_URL = (
    "https://github.com/snakers4/silero-vad/blob/"
    f"{UPSTREAM_COMMIT}/LICENSE"
)
EXPECTED_SOURCE_SHA256 = (
    "e1122837f4154c511485fe0b9c64455f7b929c96fbb8d79fbdb336383ebd3720"
)

SAMPLE_RATE_HZ = 16_000
CHUNK_SAMPLES = 512
CONTEXT_SAMPLES = 64
AUDIO_SAMPLES = CONTEXT_SAMPLES + CHUNK_SAMPLES
STATE_SHAPE = (2, 1, 128)
PARITY_FRAMES = 16
PARITY_SEED = 806
PARITY_TOLERANCE = 1e-6
COREML_PROBABILITY_TOLERANCE = 5e-6
COREML_STATE_TOLERANCE = 1e-4

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = (
    REPOSITORY_ROOT / "Sources/V2SApp/Resources/SileroVAD.mlpackage"
)

WEIGHT_SHAPES: Mapping[str, tuple[int, ...]] = {
    "_model.stft.forward_basis_buffer": (258, 1, 256),
    "_model.encoder.0.reparam_conv.weight": (128, 129, 3),
    "_model.encoder.0.reparam_conv.bias": (128,),
    "_model.encoder.1.reparam_conv.weight": (64, 128, 3),
    "_model.encoder.1.reparam_conv.bias": (64,),
    "_model.encoder.2.reparam_conv.weight": (64, 64, 3),
    "_model.encoder.2.reparam_conv.bias": (64,),
    "_model.encoder.3.reparam_conv.weight": (128, 64, 3),
    "_model.encoder.3.reparam_conv.bias": (128,),
    "_model.decoder.rnn.weight_ih": (512, 128),
    "_model.decoder.rnn.weight_hh": (512, 128),
    "_model.decoder.rnn.bias_ih": (512,),
    "_model.decoder.rnn.bias_hh": (512,),
    "_model.decoder.decoder.2.weight": (1, 128, 1),
    "_model.decoder.decoder.2.bias": (1,),
}


class ConversionError(RuntimeError):
    """An integrity, parity, or output-contract failure."""


class ExplicitSileroVAD(nn.Module):
    """The pinned 16 kHz Silero VAD expressed only as primitive tensor math."""

    def __init__(self, weights: Mapping[str, Tensor]) -> None:
        super().__init__()

        def keep(name: str) -> Tensor:
            return weights[name].detach().to(dtype=torch.float32, device="cpu").clone()

        self.register_buffer("stft_basis", keep("_model.stft.forward_basis_buffer"))
        self.register_buffer(
            "encoder0_weight", keep("_model.encoder.0.reparam_conv.weight")
        )
        self.register_buffer(
            "encoder0_bias", keep("_model.encoder.0.reparam_conv.bias")
        )
        self.register_buffer(
            "encoder1_weight", keep("_model.encoder.1.reparam_conv.weight")
        )
        self.register_buffer(
            "encoder1_bias", keep("_model.encoder.1.reparam_conv.bias")
        )
        self.register_buffer(
            "encoder2_weight", keep("_model.encoder.2.reparam_conv.weight")
        )
        self.register_buffer(
            "encoder2_bias", keep("_model.encoder.2.reparam_conv.bias")
        )
        self.register_buffer(
            "encoder3_weight", keep("_model.encoder.3.reparam_conv.weight")
        )
        self.register_buffer(
            "encoder3_bias", keep("_model.encoder.3.reparam_conv.bias")
        )
        self.register_buffer("lstm_weight_ih", keep("_model.decoder.rnn.weight_ih"))
        self.register_buffer("lstm_weight_hh", keep("_model.decoder.rnn.weight_hh"))
        self.register_buffer("lstm_bias_ih", keep("_model.decoder.rnn.bias_ih"))
        self.register_buffer("lstm_bias_hh", keep("_model.decoder.rnn.bias_hh"))
        self.register_buffer(
            "decoder_weight", keep("_model.decoder.decoder.2.weight")
        )
        self.register_buffer("decoder_bias", keep("_model.decoder.decoder.2.bias"))

    def forward(self, audio: Tensor, recurrent_state: Tensor) -> tuple[Tensor, Tensor]:
        # The upstream 16 kHz extractor reflects 64 samples only on the right.
        padded = F.pad(audio, (0, CONTEXT_SAMPLES), mode="reflect")
        spectrum = F.conv1d(
            padded.unsqueeze(1), self.stft_basis, stride=128, padding=0
        )
        real = spectrum[:, :129, :]
        imaginary = spectrum[:, 129:, :]
        encoded = torch.sqrt(real * real + imaginary * imaginary)

        encoded = F.relu(
            F.conv1d(
                encoded,
                self.encoder0_weight,
                self.encoder0_bias,
                stride=1,
                padding=1,
            )
        )
        encoded = F.relu(
            F.conv1d(
                encoded,
                self.encoder1_weight,
                self.encoder1_bias,
                stride=2,
                padding=1,
            )
        )
        encoded = F.relu(
            F.conv1d(
                encoded,
                self.encoder2_weight,
                self.encoder2_bias,
                stride=2,
                padding=1,
            )
        )
        encoded = F.relu(
            F.conv1d(
                encoded,
                self.encoder3_weight,
                self.encoder3_bias,
                stride=1,
                padding=1,
            )
        ).squeeze(-1)

        previous_hidden = recurrent_state[0]
        previous_cell = recurrent_state[1]
        gates = F.linear(encoded, self.lstm_weight_ih, self.lstm_bias_ih)
        gates = gates + F.linear(
            previous_hidden, self.lstm_weight_hh, self.lstm_bias_hh
        )
        input_gate = torch.sigmoid(gates[:, 0:128])
        forget_gate = torch.sigmoid(gates[:, 128:256])
        cell_gate = torch.tanh(gates[:, 256:384])
        output_gate = torch.sigmoid(gates[:, 384:512])
        cell = forget_gate * previous_cell + input_gate * cell_gate
        hidden = output_gate * torch.tanh(cell)

        logits = F.conv1d(
            F.relu(hidden).unsqueeze(-1),
            self.decoder_weight,
            self.decoder_bias,
        )
        probability = torch.sigmoid(logits).squeeze(-1)
        state_out = torch.stack((hidden, cell), dim=0)
        return probability, state_out


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Convert the pinned 16 kHz Silero VAD JIT weights into a float32 "
            "Core ML package."
        )
    )
    parser.add_argument(
        "--source",
        help=(
            "Local path or HTTPS URL for the pinned JIT artifact. The default "
            "downloads the artifact from its pinned upstream commit."
        ),
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT,
        help=f"Destination .mlpackage (default: {DEFAULT_OUTPUT})",
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Replace an existing output package after conversion succeeds.",
    )
    return parser.parse_args()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def download_https(location: str, destination: Path) -> None:
    parsed = urllib.parse.urlsplit(location)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
    ):
        raise ConversionError("source URL must be HTTPS without embedded credentials")
    try:
        port = parsed.port
    except ValueError as error:
        raise ConversionError(f"invalid HTTPS source port: {error}") from error

    request_target = urllib.parse.urlunsplit(
        ("", "", parsed.path or "/", parsed.query, "")
    )
    connection = http.client.HTTPSConnection(
        parsed.hostname, port=port, timeout=60
    )
    maximum_bytes = 16 * 1024 * 1024
    try:
        connection.request(
            "GET",
            request_target,
            headers={"User-Agent": "v2s-coreml-converter/1"},
        )
        response = connection.getresponse()
        if response.status < 200 or response.status >= 300:
            raise ConversionError(
                f"HTTPS source returned {response.status} {response.reason}"
            )
        total = 0
        with destination.open("wb") as output:
            while block := response.read(1024 * 1024):
                total += len(block)
                if total > maximum_bytes:
                    raise ConversionError(
                        f"HTTPS source exceeds {maximum_bytes} bytes"
                    )
                output.write(block)
    except ConversionError:
        raise
    except (OSError, http.client.HTTPException) as error:
        raise ConversionError(f"failed to download {location}: {error}") from error
    finally:
        connection.close()


def materialize_source(source: str | None, temporary_directory: Path) -> tuple[Path, str]:
    location = source or UPSTREAM_SOURCE_URL
    if location.startswith("https://"):
        destination = temporary_directory / "silero_vad.jit"
        download_https(location, destination)
        return destination, location

    if "://" in location:
        raise ConversionError("--source must be a local path or an HTTPS URL")
    original_path = Path(location).expanduser().resolve()
    if not original_path.is_file():
        raise ConversionError(
            f"source does not exist or is not a file: {original_path}"
        )
    snapshot = temporary_directory / "silero_vad-local.jit"
    try:
        shutil.copyfile(original_path, snapshot)
    except OSError as error:
        raise ConversionError(
            f"failed to snapshot local source {original_path}: {error}"
        ) from error
    return snapshot, str(original_path)


def load_weights(source_path: Path) -> tuple[torch.jit.ScriptModule, dict[str, Tensor]]:
    try:
        upstream = torch.jit.load(str(source_path), map_location="cpu").eval()
    except Exception as error:
        raise ConversionError(f"failed to load the verified JIT source: {error}") from error

    state_dict = upstream.state_dict()
    weights: dict[str, Tensor] = {}
    for name, expected_shape in WEIGHT_SHAPES.items():
        if name not in state_dict:
            raise ConversionError(f"verified source is missing weight {name}")
        tensor = state_dict[name]
        actual_shape = tuple(tensor.shape)
        if actual_shape != expected_shape:
            raise ConversionError(
                f"weight {name} has shape {actual_shape}; expected {expected_shape}"
            )
        if tensor.dtype != torch.float32:
            raise ConversionError(
                f"weight {name} has dtype {tensor.dtype}; expected torch.float32"
            )
        weights[name] = tensor
    return upstream, weights


def deterministic_parity_frames() -> Tensor:
    generator = torch.Generator(device="cpu").manual_seed(PARITY_SEED)
    frames = torch.randn(
        (PARITY_FRAMES, 1, CHUNK_SAMPLES),
        generator=generator,
        dtype=torch.float32,
    ) * 0.1
    frames[0].zero_()
    return frames


def assert_parity(upstream: torch.jit.ScriptModule, manual: ExplicitSileroVAD) -> None:
    frames = deterministic_parity_frames()

    upstream.reset_states()
    recurrent_state = torch.zeros(STATE_SHAPE, dtype=torch.float32)
    context = torch.zeros((1, CONTEXT_SAMPLES), dtype=torch.float32)
    maximum_probability_error = 0.0
    maximum_state_error = 0.0

    with torch.inference_mode():
        for frame_index, frame in enumerate(frames):
            expected_probability = upstream(frame, SAMPLE_RATE_HZ)
            manual_audio = torch.cat((context, frame), dim=1)
            actual_probability, recurrent_state = manual(
                manual_audio, recurrent_state
            )
            expected_state = upstream._state

            probability_error = float(
                torch.max(torch.abs(actual_probability - expected_probability)).item()
            )
            state_error = float(
                torch.max(torch.abs(recurrent_state - expected_state)).item()
            )
            if not np.isfinite(probability_error) or not np.isfinite(state_error):
                raise ConversionError(
                    f"manual parity produced a non-finite result at frame {frame_index}"
                )
            maximum_probability_error = max(
                maximum_probability_error, probability_error
            )
            maximum_state_error = max(maximum_state_error, state_error)
            context = frame[:, -CONTEXT_SAMPLES:]

    print(
        "Parity max errors: "
        f"probability={maximum_probability_error:.3g}, "
        f"state={maximum_state_error:.3g} "
        f"({PARITY_FRAMES} deterministic stateful frames)"
    )
    maximum_error = max(maximum_probability_error, maximum_state_error)
    if maximum_error > PARITY_TOLERANCE:
        raise ConversionError(
            "manual implementation parity failed: "
            f"maximum error {maximum_error:.9g} exceeds {PARITY_TOLERANCE:g}"
        )


def assert_coreml_parity(
    upstream: torch.jit.ScriptModule, model: ct.models.MLModel
) -> None:
    frames = deterministic_parity_frames()
    upstream.reset_states()
    recurrent_state = np.zeros(STATE_SHAPE, dtype=np.float32)
    context = np.zeros((1, CONTEXT_SAMPLES), dtype=np.float32)
    maximum_probability_error = 0.0
    maximum_state_error = 0.0

    for frame_index, frame in enumerate(frames):
        with torch.inference_mode():
            expected_probability = (
                upstream(frame, SAMPLE_RATE_HZ).detach().cpu().numpy()
            )
            expected_state = upstream._state.detach().cpu().numpy()

        frame_array = frame.detach().cpu().numpy()
        audio = np.concatenate((context, frame_array), axis=1)
        try:
            outputs = model.predict(
                {"audio": audio, "recurrent_state": recurrent_state}
            )
        except Exception as error:
            raise ConversionError(
                f"Core ML parity prediction failed at frame {frame_index}: {error}"
            ) from error

        if "probability" not in outputs or "state_out" not in outputs:
            raise ConversionError(
                f"Core ML parity outputs are missing at frame {frame_index}: "
                f"{sorted(outputs)}"
            )
        actual_probability = np.asarray(
            outputs["probability"], dtype=np.float32
        )
        actual_state = np.asarray(outputs["state_out"], dtype=np.float32)
        if actual_probability.shape != (1, 1) or actual_state.shape != STATE_SHAPE:
            raise ConversionError(
                f"Core ML parity shape mismatch at frame {frame_index}: "
                f"probability={actual_probability.shape}, state={actual_state.shape}"
            )
        if not np.all(np.isfinite(actual_probability)) or not np.all(
            np.isfinite(actual_state)
        ):
            raise ConversionError(
                f"Core ML parity produced a non-finite result at frame {frame_index}"
            )

        probability_error = float(
            np.max(np.abs(actual_probability - expected_probability))
        )
        state_error = float(np.max(np.abs(actual_state - expected_state)))
        maximum_probability_error = max(
            maximum_probability_error, probability_error
        )
        maximum_state_error = max(maximum_state_error, state_error)
        recurrent_state = actual_state
        context = frame_array[:, -CONTEXT_SAMPLES:]

    print(
        "Core ML parity max errors: "
        f"probability={maximum_probability_error:.3g}, "
        f"state={maximum_state_error:.3g} "
        f"({PARITY_FRAMES} deterministic stateful frames)"
    )
    if maximum_probability_error > COREML_PROBABILITY_TOLERANCE:
        raise ConversionError(
            "Core ML probability parity failed: "
            f"{maximum_probability_error:.9g} exceeds "
            f"{COREML_PROBABILITY_TOLERANCE:g}"
        )
    if maximum_state_error > COREML_STATE_TOLERANCE:
        raise ConversionError(
            "Core ML state parity failed: "
            f"{maximum_state_error:.9g} exceeds {COREML_STATE_TOLERANCE:g}"
        )



def convert_model(manual: ExplicitSileroVAD, source_sha256: str) -> ct.models.MLModel:
    example_audio = torch.zeros((1, AUDIO_SAMPLES), dtype=torch.float32)
    example_state = torch.zeros(STATE_SHAPE, dtype=torch.float32)
    traced = torch.jit.trace(
        manual.eval(), (example_audio, example_state), check_trace=True, strict=True
    )
    traced = torch.jit.freeze(traced)

    model = ct.convert(
        traced,
        source="pytorch",
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT32,
        inputs=[
            ct.TensorType(
                name="audio", shape=(1, AUDIO_SAMPLES), dtype=np.float32
            ),
            ct.TensorType(
                name="recurrent_state", shape=STATE_SHAPE, dtype=np.float32
            ),
        ],
        outputs=[
            ct.TensorType(name="probability", dtype=np.float32),
            ct.TensorType(name="state_out", dtype=np.float32),
        ],
    )

    expected_inputs = ["audio", "recurrent_state"]
    expected_outputs = ["probability", "state_out"]
    specification = model.get_spec()
    actual_inputs = [feature.name for feature in specification.description.input]
    actual_outputs = [feature.name for feature in specification.description.output]
    if actual_inputs != expected_inputs or actual_outputs != expected_outputs:
        raise ConversionError(
            "converted feature contract mismatch: "
            f"inputs={actual_inputs}, outputs={actual_outputs}"
        )

    model.author = "Silero Team and contributors; converted for v2s"
    model.license = f"MIT ({UPSTREAM_LICENSE_URL})"
    model.short_description = (
        "Silero VAD probability and recurrent-state inference for 16 kHz audio."
    )
    model.input_description["audio"] = (
        "One 576-sample float32 window: 64 prior-context samples followed by "
        "512 new 16 kHz mono samples."
    )
    model.input_description["recurrent_state"] = (
        "Float32 recurrent hidden and cell state with shape [2, 1, 128]."
    )
    model.output_description["probability"] = "Speech probability with shape [1, 1]."
    model.output_description["state_out"] = (
        "Updated recurrent hidden and cell state with shape [2, 1, 128]."
    )
    model.user_defined_metadata.update(
        {
            "silero_vad_source": UPSTREAM_SOURCE_URL,
            "silero_vad_commit": UPSTREAM_COMMIT,
            "silero_vad_source_sha256": source_sha256,
            "sample_rate_hz": str(SAMPLE_RATE_HZ),
            "chunk_samples": str(CHUNK_SAMPLES),
            "context_samples": str(CONTEXT_SAMPLES),
        }
    )
    model.user_defined_metadata.pop(
        "com.github.apple.coremltools.conversion_date", None
    )
    return model


def canonicalize_package(package: Path) -> None:
    """Remove serializer and manifest UUID nondeterminism from an mlpackage."""
    manifest_path = package / "Manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        entries = manifest["itemInfoEntries"]
        root_identifier = manifest["rootModelIdentifier"]
        identifier_mapping: dict[str, str] = {}
        canonical_entries: dict[str, dict[str, str]] = {}
        for identifier, item in entries.items():
            item_path = item["path"]
            canonical_identifier = str(
                uuid.uuid5(
                    uuid.NAMESPACE_URL,
                    f"{UPSTREAM_SOURCE_URL}#{item_path}",
                )
            ).upper()
            identifier_mapping[identifier] = canonical_identifier
            canonical_entries[canonical_identifier] = item
        canonical_root_identifier = identifier_mapping[root_identifier]
        manifest["itemInfoEntries"] = canonical_entries
        manifest["rootModelIdentifier"] = canonical_root_identifier

        model_item = canonical_entries[canonical_root_identifier]
        model_path = package / "Data" / model_item["path"]
        specification = Model_pb2.Model()
        specification.ParseFromString(model_path.read_bytes())
        model_path.write_bytes(
            specification.SerializeToString(deterministic=True)
        )
        manifest_path.write_text(
            json.dumps(manifest, indent=4, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    except (KeyError, OSError, TypeError, ValueError) as error:
        raise ConversionError(
            f"failed to canonicalize generated Core ML package: {error}"
        ) from error


def replace_output(model: ct.models.MLModel, output: Path, overwrite: bool) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix=f".{output.stem}-", dir=output.parent
    ) as temporary_directory:
        candidate = Path(temporary_directory) / output.name
        model.save(str(candidate))
        if not candidate.is_dir():
            raise ConversionError(f"Core ML did not create a package at {candidate}")
        canonicalize_package(candidate)

        if output.exists() or output.is_symlink():
            if not overwrite:
                raise ConversionError(
                    f"output already exists: {output} (pass --overwrite to replace it)"
                )
            if output.is_symlink() or output.is_file():
                output.unlink()
            else:
                shutil.rmtree(output)
        os.replace(candidate, output)


def package_size_and_tree_hash(package: Path) -> tuple[int, str]:
    digest = hashlib.sha256()
    total_size = 0
    files = sorted(path for path in package.rglob("*") if path.is_file())
    for path in files:
        relative_path = path.relative_to(package).as_posix().encode("utf-8")
        size = path.stat().st_size
        total_size += size
        digest.update(len(relative_path).to_bytes(8, "big"))
        digest.update(relative_path)
        digest.update(size.to_bytes(8, "big"))
        with path.open("rb") as source:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(block)
    return total_size, digest.hexdigest()


def main() -> int:
    arguments = parse_arguments()
    requested_output = arguments.output.expanduser()
    output = requested_output.parent.resolve() / requested_output.name
    if output.suffix != ".mlpackage":
        raise ConversionError(f"output must end in .mlpackage: {output}")
    if (output.exists() or output.is_symlink()) and not arguments.overwrite:
        raise ConversionError(
            f"output already exists: {output} (pass --overwrite to replace it)"
        )

    torch.manual_seed(PARITY_SEED)
    torch.set_num_threads(1)
    torch.use_deterministic_algorithms(True)

    with tempfile.TemporaryDirectory(prefix="silero-vad-coreml-") as temporary:
        source_path, source_label = materialize_source(
            arguments.source, Path(temporary)
        )
        source_sha256 = sha256_file(source_path)
        print(f"Source: {source_label}")
        print(f"Source SHA-256: {source_sha256}")
        if source_sha256 != EXPECTED_SOURCE_SHA256:
            raise ConversionError(
                "source hash mismatch: "
                f"expected {EXPECTED_SOURCE_SHA256}, got {source_sha256}"
            )

        upstream, weights = load_weights(source_path)
        manual = ExplicitSileroVAD(weights).eval()
        assert_parity(upstream, manual)
        model = convert_model(manual, source_sha256)
        assert_coreml_parity(upstream, model)
        replace_output(model, output, arguments.overwrite)

    size, tree_hash = package_size_and_tree_hash(output)
    print(f"Saved: {output}")
    print(f"Model package size: {size} bytes ({size / (1024 * 1024):.3f} MiB)")
    print(f"Model package tree SHA-256: {tree_hash}")
    print("Model metadata:")
    for key, value in sorted(model.user_defined_metadata.items()):
        print(f"  {key}: {value}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ConversionError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1) from error
    except Exception as error:
        print(f"error: unexpected conversion failure: {error}", file=sys.stderr)
        raise SystemExit(1) from error
