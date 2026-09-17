# Credits and provenance

YuE Studio is a customized derivative of existing software. The underlying music model and the original Apple Silicon implementation belong to their original creators.

## Original Mac application and Apple Silicon implementation

**Tony Weston** — [tonywestonuk/YuE-Studio](https://github.com/tonywestonuk/YuE-Studio).

Tony’s project supplied the original native macOS YuE Studio app, Python setup and worker, Apple Silicon execution paths, MLX and Neural Engine synthesis work, lean loading, draft/full rendering support, and instrumental support. These are foundational upstream contributions, not work originated by this customized edition.

The starting source was YuE Studio v0.1 at commit [`907563b170b53c14f6b1065b249b6c5ecebc6777`](https://github.com/tonywestonuk/YuE-Studio/commit/907563b170b53c14f6b1065b249b6c5ecebc6777). The [archived upstream README](docs/UPSTREAM-README.md) preserves its original project description.

## Music model, research, and upstream inference code

**M·A·P and the YuE2 collaborators** — [multimodal-art-projection/YuE](https://github.com/multimodal-art-projection/YuE), [YuE2 model](https://huggingface.co/m-a-p/YuE2-3B).

They created the YuE2 model, its symbolic music-planning and audio-generation approach, and the upstream research and inference implementation. Please refer to the original project for its full author list, research citations, model documentation, and acknowledgments.

## This customized edition

Maintained by [smittyPNW](https://github.com/smittyPNW). This edition contributes the orange/ivory and charcoal interface, tuning-fork visual identity, revised library and player workflows, recovery/export safeguards, and an optional native mastering interface with processing-resource coordination.

The public repository is a curated source snapshot, rather than a member of GitHub’s upstream fork network. That publishing choice does not change its upstream origin, ownership, or attribution.

## Studio Mastering

The copyright holder contributed the selected audio engine, DSP, analysis, Smart Master policy and preset library to this community edition. It is published under AGPL-3.0-only, with ownership and dependency notices preserved in [mastering/NOTICE.md](mastering/NOTICE.md). This does not publish the original commercial application's UI, billing or other app-specific source, and grants no rights to its branding.

## Licenses and third-party work

- Studio/generation code retains the [Apache-2.0 license](LICENSE).
- Studio Mastering is [AGPL-3.0-only](mastering/LICENSE), using the pinned JUCE dependency under its open-source terms.
- YuE2 weights have a [separate model license](MODEL_LICENSE).
- Additional upstream components retain their [third-party notices](THIRD_PARTY_NOTICES.md) and license texts in `licenses/`.
- Original authors retain their rights. This customized edition does not imply endorsement by Tony Weston, M·A·P, or other upstream contributors.
