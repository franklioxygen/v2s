# Third-party notices

## Silero VAD

This repository includes a converted model derived from [Silero VAD](https://github.com/snakers4/silero-vad) by the Silero Team and contributors.

- Pinned upstream commit: [`806dcba3f0b5d95282d0889a074954a2f8c6397b`](https://github.com/snakers4/silero-vad/tree/806dcba3f0b5d95282d0889a074954a2f8c6397b)
- Pinned upstream model: [`src/silero_vad/data/silero_vad.jit`](https://github.com/snakers4/silero-vad/blob/806dcba3f0b5d95282d0889a074954a2f8c6397b/src/silero_vad/data/silero_vad.jit)
- License: [MIT](LICENSES/Silero-VAD.txt) ([upstream source](https://github.com/snakers4/silero-vad/blob/806dcba3f0b5d95282d0889a074954a2f8c6397b/LICENSE))

`Sources/V2SApp/Resources/SileroVAD.mlpackage` is a Core ML conversion of the pinned 16 kHz Silero VAD model for on-device voice activity detection. The conversion preserves the original model weights and math. It can be reproduced with [`scripts/convert_silero_vad_coreml.py`](scripts/convert_silero_vad_coreml.py).
