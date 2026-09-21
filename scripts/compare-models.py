#!/usr/bin/env python3
"""Sequential local-only model comparison. No installation or preference changes.

Build Tests/ModelComparison/main.swift as the bridge first; see the benchmark report.
All generated files and model downloads belong under .build/.
"""
import argparse
import contextlib
import hashlib
import json
import math
import os
import random
import re
import socket
import subprocess
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORK = ROOT / ".build/model-comparison-20260921"
SUPPORT = Path.home() / "Library/Application Support/FnWhisper/Models"
MODELS = {
    "current-192": SUPPORT / "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
    "qwen3-2507": SUPPORT / "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
    "qwen3-original": SUPPORT / "Qwen3-4B-Q4_K_M.gguf",
    "qwen35-2b": WORK / "models/Qwen3.5-2B-Q4_K_M.gguf",
    "qwen35-4b": WORK / "models/Qwen3.5-4B-Q4_K_M.gguf",
    "gemma4-e2b": WORK / "models/gemma-4-E2B-it-Q4_K_M.gguf",
    "apple": None,
}
GGML_LIBRARY_DIR = None
REQUEST_SNAPSHOT = None
SERVER_EXECUTABLE = "/opt/homebrew/bin/llama-server"
MODEL_ALIAS = "fnwhisper-refiner"


def bridge(operation, **kwargs):
    result = subprocess.run(
        [str(WORK / "bridge")], input=json.dumps(dict(operation=operation, **kwargs)),
        text=True, capture_output=True, timeout=35,
    )
    if result.returncode:
        raise RuntimeError(f"bridge exited {result.returncode}: {result.stderr[-2000:]}")
    return json.loads(result.stdout)


def budget(source):
    return min(1024, max(192, math.ceil(len(source.encode("utf-8")) * 0.6) + 64))


def canonical(text):
    # Only punctuation/case and explicitly equivalent numeric spellings are ignored.
    # Do not run the app's normalizer over the gold answer.
    text = text.casefold().replace("第一页", "第1页").replace("下一页", "下1页")
    text = text.replace("一次", "1次")
    text = re.sub(r"(?<=\d)\.(?=\d)", "DECIMALPOINT", text)
    return "".join(c for c in text if c.isalnum() or c in "%/@_+-")


def gold_render(case):
    if len(case["items"]) == 1:
        return case["items"][0]
    parts = [case.get("lead", ""), "\n".join(f"{i}. {s}" for i, s in enumerate(case["items"], 1)), case.get("tail", "")]
    return "\n\n".join(p for p in parts if p)


def score(case, content):
    result = bridge("validate", source=case["source"], content=content)
    if not result.get("valid"):
        return dict(valid=False, exact=False, error=result.get("error", "invalid response"))
    expected = [gold_render(case)] + case.get("alternatives", [])
    result["exact"] = canonical(result["rendered"]) in [canonical(x) for x in expected]
    return result


def http(url, body=None, timeout=20):
    request = urllib.request.Request(url, data=json.dumps(body).encode() if body is not None else None,
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


def process_sample(pid):
    values = subprocess.check_output(["ps", "-p", str(pid), "-o", "rss=,time="], text=True).split()
    return dict(rss_kib=int(values[0]), cpu_time=values[1]) if values else {}


@contextlib.contextmanager
def server(model, tag, threads=None):
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    log_path = WORK / f"{tag}.server.log"
    args = [SERVER_EXECUTABLE, "--offline", "--model", str(MODELS[model]),
            "--host", "127.0.0.1", "--port", str(port), "--alias", MODEL_ALIAS,
            "--ctx-size", "4096", "--parallel", "1", "--n-gpu-layers", "auto",
            "--reasoning", "off", "--reasoning-budget", "0",
            "--chat-template-kwargs", '{"enable_thinking":false}', "--no-ui"]
    if threads:
        args += ["--threads", str(threads), "--threads-batch", str(threads)]
    with log_path.open("w") as log:
        environment = dict(os.environ)
        if GGML_LIBRARY_DIR:
            environment["DYLD_LIBRARY_PATH"] = GGML_LIBRARY_DIR
            if (Path(GGML_LIBRARY_DIR) / "backends").is_dir():
                environment["GGML_BACKEND_PATH"] = str(Path(GGML_LIBRARY_DIR) / "backends")
        process = subprocess.Popen(args, stdout=log, stderr=log, env=environment)
        started = time.monotonic()
        try:
            while time.monotonic() - started < 45:
                if process.poll() is not None:
                    raise RuntimeError(f"server exited {process.returncode}: {log_path.read_text()[-2000:]}")
                try:
                    if http(f"http://127.0.0.1:{port}/health", timeout=0.5).get("status") == "ok":
                        break
                except Exception:
                    pass
                time.sleep(0.1)
            else:
                raise RuntimeError("server readiness timed out")
            yield process, f"http://127.0.0.1:{port}/v1/chat/completions", time.monotonic() - started
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def infer(model, source, tokens, url=None):
    if model == "apple":
        response = bridge("apple", source=source, tokens=tokens)
        if "error" in response:
            raise RuntimeError(response["error"])
        return response["content"], dict(seconds=response["seconds"], finish="native")
    if REQUEST_SNAPSHOT and source in REQUEST_SNAPSHOT:
        body = dict(REQUEST_SNAPSHOT[source], max_tokens=tokens)
    else:
        body = bridge("request", source=source, tokens=tokens)["body"]
    body["model"] = MODEL_ALIAS
    started = time.monotonic()
    response = http(url, body)
    elapsed = time.monotonic() - started
    choice = response["choices"][0]
    return choice["message"]["content"], dict(seconds=elapsed, finish=choice.get("finish_reason"),
                                               usage=response.get("usage"), timings=response.get("timings"))


def run(model, cases, tag, repeat, threads=None):
    result_path = WORK / f"{tag}.{model}.jsonl"
    if result_path.exists():
        raise RuntimeError(f"Refusing to overwrite evidence: {result_path}")
    cold = {}
    context = server(model, f"{tag}.{model}", threads) if model != "apple" else contextlib.nullcontext((None, None, None))
    with result_path.open("w") as output:
        try:
            with context as (process, url, startup):
                started = time.monotonic()
                try:
                    infer(model, "今天先检查文档。", 64, url)
                    cold = dict(startup_seconds=startup, warmup_seconds=time.monotonic() - started)
                except Exception as error:
                    cold = dict(startup_seconds=startup, warmup_error=str(error))
                for repetition in range(1, repeat + 1):
                    ordered = list(cases)
                    random.Random(20260921 + repetition).shuffle(ordered)
                    for case in ordered:
                        tokens = 192 if model == "current-192" else budget(case["source"])
                        row = dict(model=model, id=case["id"], round=case["round"], repeat=repetition,
                                   budget=tokens, cold=cold, source=case["source"], gold=gold_render(case),
                                   ggml_library_dir=GGML_LIBRARY_DIR)
                        try:
                            content, metrics = infer(model, case["source"], tokens, url)
                            row.update(metrics, content=content)
                            row.update(score(case, content))
                        except Exception as error:
                            row.update(valid=False, exact=False, error=str(error))
                        if process:
                            row.update(process_sample(process.pid))
                        output.write(json.dumps(row, ensure_ascii=False) + "\n")
                        output.flush()
                print_summary(result_path)
        except Exception as error:
            row = dict(model=model, startup_error=str(error))
            output.write(json.dumps(row, ensure_ascii=False) + "\n")
            print(f"{model}: STARTUP FAILURE: {error}", flush=True)


def print_summary(path):
    rows = [json.loads(line) for line in path.read_text().splitlines()]
    rows = [r for r in rows if "id" in r]
    if not rows:
        return
    durations = sorted(r["seconds"] for r in rows if "seconds" in r)
    stats = dict(model=rows[0]["model"], cases=len(rows), valid=sum(r["valid"] for r in rows),
                 exact=sum(r["exact"] for r in rows),
                 median=durations[len(durations)//2] if durations else None,
                 p95=durations[math.ceil(len(durations)*0.95)-1] if durations else None,
                 max_sampled_rss_mib=max((r.get("rss_kib", 0) for r in rows), default=0)/1024)
    print(json.dumps(stats, ensure_ascii=False), flush=True)


def main():
    global GGML_LIBRARY_DIR, REQUEST_SNAPSHOT, SERVER_EXECUTABLE
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rounds", default="1")
    parser.add_argument("--models", default=",".join(MODELS))
    parser.add_argument("--tag", required=True)
    parser.add_argument("--repeat", type=int, default=1)
    parser.add_argument("--threads", type=int)
    parser.add_argument("--ggml-lib-dir")
    parser.add_argument("--baseline-protocol", action="store_true")
    parser.add_argument("--server-executable", default=SERVER_EXECUTABLE)
    options = parser.parse_args()
    GGML_LIBRARY_DIR = options.ggml_lib_dir
    SERVER_EXECUTABLE = options.server_executable
    if options.baseline_protocol:
        REQUEST_SNAPSHOT = json.loads((ROOT / "Tests/ModelComparison/requests-baseline.json").read_text())
    rounds = {int(x) for x in options.rounds.split(",")}
    cases_path = ROOT / "Tests/ModelComparison/cases.json"
    cases = [c for c in json.loads(cases_path.read_text()) if c["round"] in rounds]
    print("Frozen corpus SHA256:", hashlib.sha256(cases_path.read_bytes()).hexdigest(), flush=True)
    for model in options.models.split(","):
        run(model, cases, options.tag, options.repeat, options.threads)


if __name__ == "__main__":
    main()
