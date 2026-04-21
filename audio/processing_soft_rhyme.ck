// A soft, baby-friendly rhyme pattern for gentle processing states.

3.2::second => dur LOOP_DUR;

Gain master => LPF soften => Gain dry => dac;
soften => JCRev rev => LPF revTone => Gain wet => dac;
dac => WvOut2 capture => blackhole;
(me.dir() + "output/processing_soft_rhyme.wav", IO.INT24) => capture.wavFilename;
0.98 => capture.fileGain;
1.36 => master.gain;
2300.0 => soften.freq;
0.82 => dry.gain;
0.18 => wet.gain;
0.16 => rev.mix;
1700.0 => revTone.freq;

fun void syllable(float freq, float amp, float pan, float breathAmt, dur hold, dur releaseTime)
{
    TriOsc lead => Gain blend => ADSR env => LPF tone => Gain voice => Pan2 p => master;
    SinOsc body => blend;
    Noise breath => LPF air => Gain airy => blend;

    pan => p.pan;
    freq => lead.freq;
    freq * 0.5 => body.freq;

    0.30 => lead.gain;
    0.18 => body.gain;

    2500.0 => air.freq;
    breathAmt => breath.gain;
    0.12 => airy.gain;

    freq * 2.7 => tone.freq;
    amp => voice.gain;

    env.set(8::ms, 55::ms, 0.42, releaseTime);
    env.keyOn();
    hold => now;
    env.keyOff();
    releaseTime => now;
}

fun void rhymePhrase(float a, float b, float c, float d, float panBias)
{
    spork ~ syllable(a, 0.92, -0.16 * panBias, 0.020, 90::ms, 120::ms);
    155::ms => now;
    spork ~ syllable(b, 0.78, 0.08 * panBias, 0.018, 80::ms, 120::ms);
    155::ms => now;
    spork ~ syllable(c, 0.84, -0.04 * panBias, 0.020, 95::ms, 130::ms);
    210::ms => now;
    spork ~ syllable(d, 0.72, 0.12 * panBias, 0.016, 110::ms, 160::ms);
    310::ms => now;
}

110::ms => now;
spork ~ rhymePhrase(523.25, 659.25, 587.33, 523.25, 1.0);
950::ms => now;
spork ~ rhymePhrase(440.00, 523.25, 493.88, 440.00, -1.0);
950::ms => now;
spork ~ rhymePhrase(392.00, 440.00, 523.25, 392.00, 1.0);
1190::ms => now;

capture.closeFile();
