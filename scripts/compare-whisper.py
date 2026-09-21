#!/usr/bin/env python3
"""Compare resident Whisper models on deterministic local synthetic speech."""
import argparse
import array
import contextlib
import hashlib
import json
import math
import random
import re
import socket
import subprocess
import time
import urllib.request
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORK = ROOT / ".build/model-comparison-20260921"
AUDIO = WORK / "audio"
SUPPORT = Path.home() / "Library/Application Support/FnWhisper/Models"


def prepare(cases):
    AUDIO.mkdir(exist_ok=True)
    for case in cases:
        wav = AUDIO / (case["id"] + ".wav")
        if not wav.exists():
            aiff = AUDIO / (case["id"] + ".aiff")
            subprocess.run(["say", "-v", case["voice"], "-r", "175", "-o", str(aiff), case["text"]], check=True)
            subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(aiff), str(wav)], check=True)
        with wave.open(str(wav)) as audio:
            case["duration"] = audio.getnframes() / audio.getframerate()
        case["audio_sha256"] = hashlib.sha256(wav.read_bytes()).hexdigest()


def normalized(text):
    # Fixed reference equivalences only, independent of the app's normalizer.
    text = text.lower().replace("三点五", "3.5").replace("三点六", "3.6")
    for a, b in [("一千五百", "1500"), ("两千", "2000"), ("三点", "3点"), ("四点", "4点"),
                 ("第一", "第1"), ("第二", "第2"), ("第三", "第3")]:
        text = text.replace(a, b)
    return "".join(c for c in text if c.isalnum())


def add_noise(cases, snr):
    variants = []
    for case in cases:
        source = AUDIO / (case["id"] + ".wav")
        variant = dict(case, id=case["id"] + f"-snr{snr:g}")
        target = AUDIO / (variant["id"] + ".wav")
        with wave.open(str(source)) as stream:
            params = stream.getparams()
            samples = array.array("h", stream.readframes(stream.getnframes()))
        rms = math.sqrt(sum(x*x for x in samples) / len(samples))
        noise_rms = rms / 10**(snr/20)
        rng = random.Random(20260921)
        noisy = array.array("h", (int(max(-32768, min(32767, x + rng.gauss(0, noise_rms)))) for x in samples))
        with wave.open(str(target), "wb") as stream:
            stream.setparams(params)
            stream.writeframes(noisy.tobytes())
        variant["audio_sha256"] = hashlib.sha256(target.read_bytes()).hexdigest()
        variants.append(variant)
    return variants


def distance(a, b):
    row = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        nxt = [i]
        for j, cb in enumerate(b, 1):
            nxt.append(min(nxt[-1] + 1, row[j] + 1, row[j-1] + (ca != cb)))
        row = nxt
    return row[-1]


@contextlib.contextmanager
def server(model, threads, tag):
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    args = ["/opt/homebrew/bin/whisper-server", "--host", "127.0.0.1", "--port", str(port),
            "--model", str(SUPPORT / f"ggml-{model}.bin"), "--language", "auto", "--threads", str(threads),
            "--no-timestamps", "--best-of", "5", "--beam-size", "5"]
    with (WORK / f"{tag}.{model}.{threads}.log").open("w") as log:
        proc = subprocess.Popen(args, stdout=log, stderr=log)
        started = time.monotonic()
        try:
            while time.monotonic() - started < 45:
                if proc.poll() is not None:
                    raise RuntimeError("Whisper server exited before readiness")
                try:
                    with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=.5) as response:
                        if response.status == 200:
                            break
                except Exception:
                    pass
                time.sleep(.1)
            else:
                raise RuntimeError("Whisper readiness timeout")
            yield proc, port, time.monotonic() - started
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()


def transcribe(port, case):
    boundary = "FnWhisperBenchmark20260921"
    data = bytearray()
    for key, value in {"language": "auto", "response_format": "json", "temperature": "0"}.items():
        data.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="{key}"\r\n\r\n{value}\r\n'.encode())
    data.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="audio.wav"\r\nContent-Type: audio/wav\r\n\r\n'.encode())
    data.extend((AUDIO / (case["id"] + ".wav")).read_bytes())
    data.extend(f"\r\n--{boundary}--\r\n".encode())
    request = urllib.request.Request(f"http://127.0.0.1:{port}/inference", data=bytes(data),
                                    headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    started = time.monotonic()
    with urllib.request.urlopen(request, timeout=60) as response:
        result = json.load(response)
    return result.get("text", "").strip(), time.monotonic() - started


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--threads", default="4,6,8")
    parser.add_argument("--models", default="large-v3-q5_0,large-v3-turbo-q5_0")
    parser.add_argument("--holdout", action="store_true")
    parser.add_argument("--repeat", type=int, default=1)
    parser.add_argument("--noise-snr", type=float)
    options = parser.parse_args()
    cases = json.loads((ROOT / "Tests/ModelComparison/audio-cases.json").read_text())
    cases = [c for c in cases if bool(c.get("holdout")) == options.holdout]
    prepare(cases)
    if options.noise_snr is not None:
        cases = add_noise(cases, options.noise_snr)
    for threads in map(int, options.threads.split(",")):
        for model in options.models.split(","):
            path = WORK / f"{options.tag}.{model}.{threads}.jsonl"
            if path.exists():
                raise RuntimeError(f"Refusing to overwrite {path}")
            rows = []
            with server(model, threads, options.tag) as (proc, port, startup), path.open("w") as output:
                _, warmup = transcribe(port, cases[0])
                for repetition in range(1, options.repeat + 1):
                    order = list(cases)
                    random.Random(20260921 + repetition).shuffle(order)
                    for case in order:
                        text, elapsed = transcribe(port, case)
                        expected, actual = normalized(case["text"]), normalized(text)
                        errors = distance(expected, actual)
                        rss = int(subprocess.check_output(["ps", "-p", str(proc.pid), "-o", "rss="], text=True))
                        row = dict(model=model, threads=threads, id=case["id"], repeat=repetition,
                                   text=text, expected=case["text"], errors=errors, chars=len(expected),
                                   cer=errors/len(expected), seconds=elapsed, rtf=elapsed/case["duration"],
                                   duration=case["duration"], rss_kib=rss, audio_sha256=case["audio_sha256"],
                                   startup_seconds=startup, warmup_seconds=warmup)
                        output.write(json.dumps(row, ensure_ascii=False) + "\n")
                        output.flush()
                        rows.append(row)
            durations = sorted(r["seconds"] for r in rows)
            print(json.dumps(dict(model=model, threads=threads, cases=len(rows),
                                  cer=sum(r["errors"] for r in rows)/sum(r["chars"] for r in rows),
                                  exact=sum(r["errors"] == 0 for r in rows),
                                  median=durations[len(durations)//2],
                                  p95=durations[math.ceil(len(durations)*.95)-1],
                                  max_sampled_rss_mib=max(r["rss_kib"] for r in rows)/1024)), flush=True)


if __name__ == "__main__":
    main()
