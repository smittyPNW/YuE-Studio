# HiFi quick fix

HiFi is a modest creative starting point for fuller bass and clearer detail, not a fidelity-restoration algorithm. It cannot recover information absent from a recording. Use Before/After with Match listening level, and Undo if the original suits the song better.

## Recipe

- Bass: +1.5 dB low shelf at 100 Hz.
- Mud: -0.72 dB bell at 220 Hz.
- Mid macro: neutral.
- Air: +0.6 dB high shelf at 6 kHz.
- Punch: 0.08; warm exciter: 0.04; air exciter: 0.02 (engine control values, not decibels).
- Output target: -14 LUFS; true-peak limiting enabled; ceiling at -1 dBTP or the existing lower ceiling.

The values are our restrained tuning choices, not an industry HiFi standard. They are set absolutely, so repeated clicks do not compound boosts. Existing custom six-band EQ, stereo settings, fades and other controls remain intact. Applying HiFi only changes controls; rendering is explicit. Undo restores the entire previous parameter set.

The engine uses a small amount of dynamics processing tied to punch and mud. The recipe does not add stereo widening or noise, or replace the full offline renderer with a preview. It does change the sound and can be less suitable for already bass-heavy or heavily processed mixes.

## Research

[iZotope: Mastering low end](https://www.izotope.com/community/blog/mastering-low-end) discusses low shelves, bass fundamentals and harmonic support, and balancing bass against clarity. [Ozone Bass Control documentation](https://docs.izotope.com/ozone12/en/bass-control.html) explains why bass peaks and sustain need controlled treatment. These informed the design principles; no proprietary algorithm or preset was copied.
