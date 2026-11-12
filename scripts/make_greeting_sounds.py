#!/usr/bin/env python3
"""Writes the greeting's two sounds into app/Resources. Needs numpy."""
import pathlib
import wave

import numpy as np

RATE = 44100
LOUDNESS_DB = -26
OUTPUT = pathlib.Path(__file__).resolve().parent.parent / "app" / "Resources"
random = np.random.default_rng(11)


def seconds(length):
    return np.arange(int(RATE * length)) / RATE


def pop():
    time = seconds(0.2)
    pitch = 330 + 190 * (1 - np.exp(-time / 0.02))
    envelope = np.minimum(time / 0.002, 1) * np.exp(-time / 0.05)
    return np.sin(2 * np.pi * np.cumsum(pitch) / RATE) * envelope


def voice(pitch, level, delay, length):
    """Two slightly detuned copies with gentle overtones, swelling in."""
    time = seconds(length)
    since = np.maximum(time - delay, 0)
    envelope = (1 - np.exp(-since / 0.09)) * np.exp(-since / 1.1)
    sound = 0
    for detune in (0.9985, 1.0015):
        tone = pitch * detune
        for overtone, strength in ((1, 1), (2, 0.22), (3, 0.06)):
            sound = sound + strength * np.sin(2 * np.pi * overtone * tone * time)
    return level * sound * envelope


def bloom():
    """An open D chord with an added ninth, rolled upward."""
    notes = [(146.83, 1), (220, 0.8), (293.66, 0.75), (369.99, 0.55), (440, 0.42), (659.25, 0.2)]
    return sum(voice(pitch, level, index * 0.022, 3.8) for index, (pitch, level) in enumerate(notes))


def in_room(sound, length, wet, tail):
    time = seconds(length)
    echo = random.standard_normal(len(time)) * np.exp(-time / (length / 5))
    echo /= np.sqrt(np.sum(echo**2))
    padded = np.concatenate([sound, np.zeros(int(RATE * tail))])
    return padded + wet * np.convolve(padded, echo)[: len(padded)]


def write(name, sound, gain):
    fade = np.minimum(np.arange(len(sound))[::-1] / (RATE * 0.15), 1)
    samples = np.clip(sound * fade * gain, -1, 1)
    with wave.open(str(OUTPUT / f"{name}.wav"), "wb") as file:
        file.setnchannels(1)
        file.setsampwidth(2)
        file.setframerate(RATE)
        file.writeframes((samples * 32767).astype("<i2").tobytes())
    peak = 20 * np.log10(np.abs(samples).max())
    print(f"{name}: {len(samples) / RATE:.2f} s, peak {peak:.1f} dB")


first = in_room(0.5 * pop(), 1, 0.45, 0.6)
second = in_room(0.16 * bloom(), 1, 0.45, 0.4)
audible = second[np.abs(second) > np.abs(second).max() * 0.01]
gain = 10 ** (LOUDNESS_DB / 20) / np.sqrt(np.mean(audible**2))
write("greeting-pop", first, gain)
write("greeting-bloom", second, gain)
