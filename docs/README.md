# docs

Design and roadmap for Thingino on-camera AI detection.

- [ai.md](ai.md) — architecture, the two hardware paths, the pipeline.
- [tasks.md](tasks.md) — phased task breakdown with gates (v3 first).
- [done.md](done.md) — tasks.md items that are implemented (and, where it applies, verified on a camera).
- [benchmark.md](benchmark.md) — how we benchmark against the Aqara G100.
- [jzdl-runtime.md](jzdl-runtime.md) — ojzdl, our own T31 JZDL runtime: bit-identical to libjzdl, MXU2 kernels, as fast on the camera.
- [nna-runtime.md](nna-runtime.md) — toward an open T41 NNA runtime: what venus does, layer by layer, reproduced exactly in NumPy.
- [t41-onna-deployment.md](t41-onna-deployment.md) — live T41NQ silicon results (`yoloxn3-v1` + `ONNA=1`), reproducible `rvd` cross-build, and firmware optimization notes.
- [distillation.md](distillation.md) — training the camera model from a bigger teacher (YOLOX-S/M/L) or from its own float net; GPU guidance.
- [aqara-g100-detections.md](aqara-g100-detections.md) — the G100 detection/event catalog (the commercial reference we borrow from).

Household/LAN operational detail (camera addresses, build host) is kept in private notes, not here. The JZDL model-format notes migrate here next (held while a training run uses them).
