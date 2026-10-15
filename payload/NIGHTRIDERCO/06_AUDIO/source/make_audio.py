"""Create original, quiet synthetic alert sounds. No samples or borrowed melodies."""
from pathlib import Path
import json
import math
import struct
import wave

destination = Path("outputs/NIGHTRIDERCO/06_AUDIO")
destination.mkdir(parents=True, exist_ok=True)
sample_rate = 48000
specs = {
    "follow": (0.64, [(0.00, 1140, .65), (.10, 1710, .45)]),
    "sub": (0.92, [(0.00, 880, .60), (.13, 1320, .50), (.27, 1760, .42)]),
    "gift": (1.18, [(0.00, 960, .5), (.11, 1440, .46), (.23, 1920, .4), (.38, 2400, .3)]),
    "tip": (0.82, [(0.00, 1220, .60), (.12, 1830, .42), (.24, 2440, .24)]),
    "raid": (1.06, [(0.00, 660, .5), (.09, 990, .5), (.18, 1485, .45), (.30, 1980, .35)]),
}
report = {}
for name, (duration, notes) in specs.items():
    count = round(sample_rate * duration)
    samples = []
    for i in range(count):
        t = i / sample_rate
        value = 0.0
        for onset, hz, level in notes:
            age = t - onset
            if age >= 0:
                attack = 1 - math.exp(-age / .006)
                decay = math.exp(-age / .115)
                partial = math.sin(2 * math.pi * hz * age)
                partial += .17 * math.sin(2 * math.pi * (hz * 2.004) * age)
                partial += .07 * math.sin(2 * math.pi * (hz * 3.011) * age)
                value += level * attack * decay * partial
        edge = min(1, t / .01, (duration - t) / .09)
        samples.append(value * max(0, edge))
    scale = .20 / max(abs(v) for v in samples)
    integers = [max(-32767, min(32767, round(v * scale * 32767))) for v in samples]
    with wave.open(str(destination / f"{name}.wav"), "wb") as audio:
        audio.setnchannels(2)
        audio.setsampwidth(2)
        audio.setframerate(sample_rate)
        audio.writeframes(b"".join(struct.pack("<hh", value, value) for value in integers))
    report[name] = {"duration_seconds": duration, "sample_rate":sample_rate, "channels":2,
                    "peak_linear":round(max(abs(v) for v in integers)/32767,6),
                    "peak_dbfs":round(20*math.log10(max(abs(v) for v in integers)/32767),2),
                    "first_sample":integers[0], "last_sample":integers[-1]}
Path("work/native_motion/audio-validation.json").write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
