#pragma once
#include <JuceHeader.h>

/** Offline (export-quality) sample-rate conversion.
 *
 *  Deliberately separate from RealtimeSampleRateConverter: audition trades taps
 *  for a real-time budget, whereas a delivered master should be converted once,
 *  as transparently as we can afford. Same proven design - polyphase
 *  windowed-sinc with the cutoff scaled to the lower Nyquist when decimating -
 *  but with a far longer kernel and a Blackman-Harris window for a deeper
 *  stopband.
 *
 *  Mastering note: conversion changes intersample peaks, so the export path
 *  runs its true-peak limiter AFTER this stage. Resampling a finished master
 *  and shipping it unchecked is how a "-1.0 dBTP" master arrives over the
 *  ceiling.
 */
class OfflineResampler
{
public:
    static constexpr int taps = 256;      // 4x the audition kernel
    static constexpr int phases = 1024;

    /** Convert `source` to `destinationRate`. Returns false only for invalid
        arguments; an unchanged rate is a fast, bit-exact copy. */
    static bool convert (const juce::AudioBuffer<float>& source,
                         double sourceRate,
                         double destinationRate,
                         juce::AudioBuffer<float>& destination);

    /** Output length for a conversion, rounded like convert(). */
    static int outputLengthFor (int sourceSamples, double sourceRate, double destinationRate);
};
