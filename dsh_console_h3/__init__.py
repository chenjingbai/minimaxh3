# -*- coding: utf-8 -*-
"""
DSH Console · MiniMax H3 工作台
挂在 ComfyUI 自己的 PromptServer 路由上，不占新端口，隧道不用重开。

访问：<你的隧道域名>/dsh
"""

import asyncio
import json
import math
import queue
import threading
import time
import traceback
import urllib.error
import urllib.request
import uuid
from pathlib import Path

from aiohttp import web

try:
    import server
except Exception:  # pragma: no cover
    server = None

ROOT = Path(__file__).resolve().parent
WORKSPACE = Path("/workspace")
OUT_DIR = WORKSPACE / "dsh_out"
VIDEO_DIR = OUT_DIR / "video"
STATE_FILE = ROOT / "jobs.json"
MAX_JOBS = 300

for _d in (OUT_DIR, VIDEO_DIR):
    _d.mkdir(parents=True, exist_ok=True)

# ---------------------------------------------------------------- 基础工具

def _port():
    try:
        return int(server.PromptServer.instance.port)
    except Exception:
        return 8188


def _http_json(path, payload=None, timeout=60):
    url = "http://127.0.0.1:%d%s" % (_port(), path)
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


_OBJ_CACHE = {"t": 0.0, "data": None}


def object_info():
    """直接读 nodes.NODE_CLASS_MAPPINGS，不走 HTTP。

    注意：绝不能在这里 urllib 请求自己的 /object_info —— ComfyUI 是单线程
    事件循环，那样会自锁到超时，连带前端所有 await 卡死。
    """
    if _OBJ_CACHE["data"] is not None and time.time() - _OBJ_CACHE["t"] < 60:
        return _OBJ_CACHE["data"]

    out = {}
    try:
        import nodes as comfy_nodes
        mappings = getattr(comfy_nodes, "NODE_CLASS_MAPPINGS", {}) or {}
        for name, cls in mappings.items():
            entry = {}
            try:
                entry["input"] = cls.INPUT_TYPES()
            except Exception:
                entry["input"] = {}
            out[name] = entry
    except Exception as e:
        print("[DSH Console] 读取节点信息失败：%r" % (e,))
        return _OBJ_CACHE["data"] or {}

    _OBJ_CACHE["data"] = out
    _OBJ_CACHE["t"] = time.time()
    return out


def input_dir():
    try:
        import folder_paths
        return Path(folder_paths.get_input_directory())
    except Exception:
        return Path("/opt/ComfyUI/input")


def output_dir():
    try:
        import folder_paths
        return Path(folder_paths.get_output_directory())
    except Exception:
        return Path("/opt/ComfyUI/output")


# ---------------------------------------------------------------- 参数换算

TIERS = {"small": (640, 384), "mid": (960, 544), "big": (1344, 768)}


def resolve_size(tier, orientation):
    w, h = TIERS.get(tier, TIERS["mid"])
    if orientation == "portrait":
        w, h = h, w
    # 强制 32 的倍数
    return (w // 32) * 32, (h // 32) * 32


def frames_for_seconds(sec):
    """H3 的帧数必须是 17n+5。"""
    target = max(5, int(round(sec * 24)))
    return target + (5 - target % 17) % 17


# ---------------------------------------------------------------- 超分 / 拼接 工具

UPSCALE_MODELS = [
    "4x-UltraSharp.pth",
    "4x_NMKD-Superscale-SP_178000_G.safetensors",
    "4x_NMKD-Superscale-SP_178000_G.pth",
    "RealESRGAN_x4plus.pth",
]


def upscale_node_chain(prev_images, up_model, scale):
    """在图像序列后追加超分节点，返回新的 (节点id字典, 末节点引用)。

    scale=2 时用 4x 模型放大再缩回一半 —— 比直接 1x 模型更锐，社区实测的常规做法。
    """
    if not up_model or scale in (0, 1, None):
        return {}, prev_images
    g = {}
    g["u1"] = {"class_type": "UpscaleModelLoader", "inputs": {"model_name": up_model}}
    g["u2"] = {"class_type": "ImageUpscaleWithModel",
               "inputs": {"upscale_model": ["u1", 0], "image": prev_images}}
    if scale == 2:
        g["u3"] = {"class_type": "ImageScaleBy",
                   "inputs": {"upscale_method": "lanczos", "scale_by": 0.5,
                              "image": ["u2", 0]}}
        return g, ["u3", 0]
    return g, ["u2", 0]


# ---------------------------------------------------------------- 工作流构建

def build_native(spec):
    """原生 H3（可选 8 步 turbo LoRA）。节点接线逐条对照官方 video_minimax_h3_i2v.json。"""
    w, h, length = spec["width"], spec["height"], spec["length"]
    g = {}
    g["1"] = {"class_type": "UNETLoader",
              "inputs": {"unet_name": spec["unet"], "weight_dtype": "default"}}
    model_src = ["1", 0]
    if spec.get("lora"):
        g["2"] = {"class_type": "LoraLoaderModelOnly",
                  "inputs": {"lora_name": spec["lora"],
                             "strength_model": float(spec.get("lora_strength", 1.0)),
                             "model": ["1", 0]}}
        model_src = ["2", 0]
    g["3"] = {"class_type": "CLIPLoader",
              "inputs": {"clip_name": spec["clip"], "type": "minimax", "device": "default"}}
    g["4"] = {"class_type": "VAELoader", "inputs": {"vae_name": spec["vae_video"]}}
    g["5"] = {"class_type": "VAELoader", "inputs": {"vae_name": spec["vae_audio"]}}
    g["6"] = {"class_type": "LoadImage", "inputs": {"image": spec["first_frame"]}}

    i2v = {
        "prompt": spec["prompt"],
        "width": w,
        "height": h,
        "length": length,
        "clip": ["3", 0],
        "vae": ["4", 0],
        "first_frame": ["6", 0],
    }
    if spec.get("last_frame"):
        g["7"] = {"class_type": "LoadImage", "inputs": {"image": spec["last_frame"]}}
        i2v["last_frame"] = ["7", 0]

    g["8"] = {"class_type": "MiniMaxH3ImageToVideo", "inputs": i2v}
    g["9"] = {"class_type": "RandomNoise", "inputs": {"noise_seed": int(spec["seed"])}}
    g["10"] = {"class_type": "KSamplerSelect",
               "inputs": {"sampler_name": spec.get("sampler", "res_multistep")}}
    g["11"] = {"class_type": "BasicScheduler",
               "inputs": {"scheduler": spec.get("scheduler", "simple"),
                          "steps": int(spec["steps"]), "denoise": 1, "model": model_src}}
    g["12"] = {"class_type": "BasicGuider",
               "inputs": {"model": model_src, "conditioning": ["8", 0]}}
    g["13"] = {"class_type": "SamplerCustomAdvanced",
               "inputs": {"noise": ["9", 0], "guider": ["12", 0], "sampler": ["10", 0],
                          "sigmas": ["11", 0], "latent_image": ["8", 1]}}
    g["14"] = {"class_type": "VAEDecode", "inputs": {"samples": ["13", 0], "vae": ["4", 0]}}
    g["15"] = {"class_type": "VAEDecodeAudio",
               "inputs": {"samples": ["13", 0], "vae": ["5", 0]}}

    up, images = upscale_node_chain(["14", 0], spec.get("upscale_model"),
                                    int(spec.get("upscale_scale") or 0))
    if up:
        g.update(up)

    g["16"] = {"class_type": "CreateVideo",
               "inputs": {"fps": 24, "bit_depth": 8, "color_space": "sRGB",
                          "chroma_subsampling": "auto", "codec": "none",
                          "images": images, "audio": ["15", 0]}}
    g["17"] = {"class_type": "SaveVideo",
               "inputs": {"filename_prefix": "dsh/h3", "format": "mp4",
                          "format.codec": "auto", "codec": "auto", "video": ["16", 0]}}
    return g


def build_hyperflow(spec):
    """HyperFlow Flash int8。接线逐条对照官方 hyperflow_i2v_int8.json。

    steps<=3 且配了 TaoMate LoRA 时，改走 BSAI TaoMate 3 步链路：
      HyperFlowLoader -> BSAITaoMateLoRALoader -> MiniMaxH3SigmaShift
      -> BSAITaoMateTimesteps -> SamplerCustomAdvanced(BSAITaoMateEulerSampler)
    """
    w, h, length = spec["width"], spec["height"], spec["length"]
    steps = int(spec["steps"])
    taomate = (spec.get("taomate_lora") or "").strip()
    use_tm = bool(taomate) and steps <= 3

    g = {}
    g["1"] = {"class_type": "HyperFlowLoader",
              "inputs": {"unet_name": spec["unet"], "weights_in": "auto"}}
    g["2"] = {"class_type": "CLIPLoader",
              "inputs": {"clip_name": spec["clip"], "type": "minimax", "device": "default"}}
    g["3"] = {"class_type": "VAELoader", "inputs": {"vae_name": spec["vae_video"]}}
    g["4"] = {"class_type": "VAELoader", "inputs": {"vae_name": spec["vae_audio"]}}
    g["5"] = {"class_type": "LoadImage", "inputs": {"image": spec["first_frame"]}}

    i2v = {
        "prompt": spec["prompt"],
        "width": w, "height": h, "length": length,
        "clip": ["2", 0], "vae": ["3", 0], "first_frame": ["5", 0],
    }
    if spec.get("last_frame"):
        g["6"] = {"class_type": "LoadImage", "inputs": {"image": spec["last_frame"]}}
        i2v["last_frame"] = ["6", 0]

    g["7"] = {"class_type": "MiniMaxH3ImageToVideo", "inputs": i2v}
    g["10"] = {"class_type": "RandomNoise", "inputs": {"noise_seed": int(spec["seed"])}}

    if use_tm:
        strength = float(spec.get("taomate_strength") or 1.0)
        # 真实签名（由 object_info 实测）：
        #   BSAITaoMateLoRALoader: model, lora_name, strength, strict_taomate_check -> MODEL
        #   MiniMaxH3SigmaShift:   model, shift_video, shift_audio -> MODEL
        #   BSAITaoMateTimesteps:  model, ladder -> SIGMAS
        #   BSAITaoMateEulerSampler: shift_video, shift_audio, schedule_mode, verbose -> SAMPLER
        g["tm2"] = {"class_type": "BSAITaoMateLoRALoader",
                    "inputs": {"model": ["1", 0],
                               "lora_name": taomate,
                               "strength": strength,
                               "strict_taomate_check": True}}
        g["tm3"] = {"class_type": "MiniMaxH3SigmaShift",
                    "inputs": {"model": ["tm2", 0],
                               "shift_video": 12.0,
                               "shift_audio": 3.0}}
        g["tm4"] = {"class_type": "BSAITaoMateTimesteps",
                    "inputs": {"model": ["tm3", 0],
                               "ladder": "999,750,500"}}
        g["tm5"] = {"class_type": "BSAITaoMateEulerSampler",
                    "inputs": {"shift_video": 12.0,
                               "shift_audio": 3.0,
                               "schedule_mode": "auto",
                               "verbose": False}}
        g["11"] = {"class_type": "BasicGuider",
                   "inputs": {"model": ["tm3", 0], "conditioning": ["7", 0]}}
        g["12"] = {"class_type": "SamplerCustomAdvanced",
                   "inputs": {"noise": ["10", 0], "guider": ["11", 0],
                              "sampler": ["tm5", 0], "sigmas": ["tm4", 0],
                              "latent_image": ["7", 1]}}
    else:
        model_src = ["1", 0]
        g["8"] = {"class_type": "HyperFlowSigmas",
                  "inputs": {"steps": steps, "model": model_src}}
        g["9"] = {"class_type": "KSamplerSelect", "inputs": {"sampler_name": "euler"}}
        g["11"] = {"class_type": "BasicGuider",
                   "inputs": {"model": model_src, "conditioning": ["7", 0]}}
        g["12"] = {"class_type": "SamplerCustomAdvanced",
                   "inputs": {"noise": ["10", 0], "guider": ["11", 0],
                              "sampler": ["9", 0], "sigmas": ["8", 0],
                              "latent_image": ["7", 1]}}

    g["13"] = {"class_type": "VAEDecode", "inputs": {"samples": ["12", 0], "vae": ["3", 0]}}
    g["14"] = {"class_type": "VAEDecodeAudio",
               "inputs": {"samples": ["12", 0], "vae": ["4", 0]}}

    up, images = upscale_node_chain(["13", 0], spec.get("upscale_model"),
                                    int(spec.get("upscale_scale") or 0))
    if up:
        g.update(up)

    g["15"] = {"class_type": "CreateVideo",
               "inputs": {"fps": 24, "bit_depth": 8, "color_space": "sRGB",
                          "chroma_subsampling": "auto", "codec": "none",
                          "images": images, "audio": ["14", 0]}}
    g["16"] = {"class_type": "SaveVideo",
               "inputs": {"filename_prefix": "dsh/hf", "format": "mp4",
                          "format.codec": "auto", "codec": "auto", "video": ["15", 0]}}
    return g


# ---------------------------------------------------------------- 视频工具（拆帧/超分/拼接）

def _pyav():
    import av
    return av


def video_info(path):
    av = _pyav()
    with av.open(str(path)) as c:
        vid = [s for s in c.streams if s.type == "video"]
        aud = [s for s in c.streams if s.type == "audio"]
        if not vid:
            return {"ok": False, "error": "无视频流"}
        v = vid[0]
        return {
            "ok": True,
            "width": v.codec_context.width,
            "height": v.codec_context.height,
            "fps": float(v.average_rate) if v.average_rate else 24.0,
            "frames": v.frames or 0,
            "has_audio": bool(aud),
            "audio_codec": aud[0].codec_context.name if aud else "",
            "duration": (c.duration or 0) / 1e6,
        }


# ---------------------------------------------------------------- 任务存储

_jobs = {}
_order = []
_jlock = threading.Lock()


def _load_state():
    global _jobs, _order
    try:
        d = json.loads(STATE_FILE.read_text("utf-8"))
        _jobs = d.get("jobs", {}) or {}
        _order = d.get("order", []) or []
        for j in _jobs.values():
            if j.get("status") in ("queued", "running"):
                j["status"] = "interrupted"
                j["error"] = "服务重启，任务中断"
    except Exception:
        _jobs, _order = {}, []


def _save_state():
    try:
        with _jlock:
            payload = {"jobs": _jobs, "order": _order[-MAX_JOBS:]}
        STATE_FILE.write_text(json.dumps(payload, ensure_ascii=False), "utf-8")
    except Exception:
        pass


def _public(job):
    d = dict(job)
    d.pop("spec", None)
    d.pop("graph", None)
    return d


_load_state()

# ---------------------------------------------------------------- websocket 进度

_progress = {}
_ws_started = {"v": False}


def _start_ws():
    if _ws_started["v"]:
        return
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        try:
            loop = asyncio.get_event_loop()
        except Exception:
            return
    _ws_started["v"] = True
    try:
        loop.create_task(_ws_loop())
    except Exception:
        _ws_started["v"] = False


async def _ws_loop():
    import aiohttp
    cid = "dsh-%s" % uuid.uuid4().hex[:8]
    url = "http://127.0.0.1:%d/ws?clientId=%s" % (_port(), cid)
    while True:
        try:
            async with aiohttp.ClientSession() as sess:
                async with sess.ws_connect(url, heartbeat=25) as ws:
                    async for msg in ws:
                        if msg.type != aiohttp.WSMsgType.TEXT:
                            continue
                        if msg.data == "ping":
                            continue
                        try:
                            d = json.loads(msg.data)
                        except Exception:
                            continue
                        t = d.get("type")
                        data = d.get("data") or {}
                        pid = data.get("prompt_id")
                        if not pid:
                            continue
                        rec = _progress.setdefault(pid, {})
                        if t == "progress":
                            rec["value"] = data.get("value")
                            rec["max"] = data.get("max")
                        elif t == "executing":
                            rec["node"] = data.get("node")
                        elif t in ("execution_error", "execution_interrupted"):
                            rec["error"] = str(data.get("exception_message") or t)
        except Exception:
            await asyncio.sleep(3)


# ---------------------------------------------------------------- 执行线程

_q = queue.Queue()
_worker_lock = threading.Lock()
_worker_on = {"v": False}


def _ensure_worker():
    with _worker_lock:
        if _worker_on["v"]:
            return
        _worker_on["v"] = True
    threading.Thread(target=_worker, daemon=True).start()


def _worker():
    while True:
        job_id = _q.get()
        try:
            _run(job_id)
        except Exception:
            _finish(job_id, "error", traceback.format_exc())
        finally:
            _q.task_done()
            _save_state()


def _finish(job_id, status, error=None, outputs=None, elapsed=None):
    with _jlock:
        j = _jobs.get(job_id)
        if not j:
            return
        j["status"] = status
        if error:
            j["error"] = error[-2000:]
        if outputs:
            j["outputs"] = outputs
        if elapsed is not None:
            j["elapsed"] = round(elapsed, 1)
        j["finished"] = time.time()


def _run(job_id):
    with _jlock:
        job = _jobs.get(job_id)
        if not job:
            return
        if job.get("status") == "cancelled":
            return
        job["status"] = "running"
        job["started"] = time.time()
        job["prompt_id"] = None
        spec = dict(job["spec"])
    _save_state()

    kind = spec.get("kind")

    # ---- 本地视频处理任务（不走 ComfyUI 图）----
    if kind == "upscale":
        t0 = time.time()
        try:
            outs = _do_upscale(job_id, spec)
            _finish(job_id, "done", outputs=outs, elapsed=time.time() - t0)
        except Exception:
            _finish(job_id, "error", traceback.format_exc(), elapsed=time.time() - t0)
        return

    if kind == "concat":
        t0 = time.time()
        try:
            outs = _do_concat(job_id, spec)
            _finish(job_id, "done", outputs=outs, elapsed=time.time() - t0)
        except Exception:
            _finish(job_id, "error", traceback.format_exc(), elapsed=time.time() - t0)
        return

    # ---- 长片：拆成多段链式生成再拼接 ----
    if spec.get("segments_total", 1) > 1:
        t0 = time.time()
        try:
            outs = _do_longfilm(job_id, spec)
            _finish(job_id, "done", outputs=outs, elapsed=time.time() - t0)
        except Exception as e:
            msg = str(e)
            if msg == "已取消":
                _finish(job_id, "cancelled", elapsed=time.time() - t0)
            else:
                _finish(job_id, "error", traceback.format_exc(), elapsed=time.time() - t0)
        return

    graph = build_hyperflow(spec) if spec.get("engine") == "hyperflow" else build_native(spec)
    t0 = time.time()

    try:
        resp = _http_json("/prompt", {"prompt": graph, "client_id": "dsh-console"}, timeout=120)
    except Exception as e:
        _finish(job_id, "error", "提交失败：%s" % e)
        return

    pid = resp.get("prompt_id")
    with _jlock:
        if job_id in _jobs:
            _jobs[job_id]["prompt_id"] = pid
    if not pid:
        _finish(job_id, "error", "提交被拒：%s" % json.dumps(resp, ensure_ascii=False)[:800])
        return

    deadline = time.time() + 3 * 3600
    while time.time() < deadline:
        with _jlock:
            if _jobs[job_id].get("status") == "cancelled":
                try:
                    _http_json("/interrupt", {}, timeout=15)
                except Exception:
                    pass
                _finish(job_id, "cancelled", elapsed=time.time() - t0)
                return
        try:
            hist = _http_json("/history/%s" % pid, timeout=30)
        except Exception:
            time.sleep(1.0)
            continue
        if pid in hist:
            entry = hist[pid]
            st = (entry.get("status") or {})
            if st.get("status_str") == "error":
                msgs = st.get("messages") or []
                _finish(job_id, "error", json.dumps(msgs, ensure_ascii=False)[-1800:],
                        elapsed=time.time() - t0)
                return
            outs = _collect_outputs(pid, entry.get("outputs") or {})
            _finish(job_id, "done", outputs=outs, elapsed=time.time() - t0)
            return
        time.sleep(1.0)

    _finish(job_id, "error", "超时（3 小时）", elapsed=time.time() - t0)


def _collect_outputs(pid, outputs):
    got = []
    odir = output_dir()
    for node_id, node_out in outputs.items():
        if not isinstance(node_out, dict):
            continue
        for key, val in node_out.items():
            if not isinstance(val, list):
                continue
            for item in val:
                if not isinstance(item, dict) or "filename" not in item:
                    continue
                fn = item["filename"]
                sub = item.get("subfolder") or ""
                src = odir / sub / fn
                if not src.is_file():
                    continue
                ext = src.suffix.lower()
                if ext not in (".mp4", ".webm", ".mov", ".mkv", ".gif", ".png", ".jpg"):
                    continue
                dst_name = "%s_%s" % (pid[:8], fn)
                dst = VIDEO_DIR / dst_name
                try:
                    dst.write_bytes(src.read_bytes())
                except Exception:
                    continue
                got.append({"name": dst_name, "url": "/dsh/api/media/%s" % dst_name,
                            "bytes": dst.stat().st_size, "kind": ext.lstrip(".")})
    return got


# ---------------------------------------------------------------- 本地视频处理实现

def _set_progress(job_id, cur, total, stage=""):
    with _jlock:
        j = _jobs.get(job_id)
        if j is not None:
            j["progress"] = {"value": cur, "max": total}
            if stage:
                j["stage"] = stage


def _cancelled(job_id):
    with _jlock:
        j = _jobs.get(job_id)
        return bool(j and j.get("status") == "cancelled")


def _load_upscale_model(model_name):
    """用 ComfyUI 自己的目录解析 + spandrel 加载放大模型。"""
    import torch
    import folder_paths
    import comfy.model_management

    path = folder_paths.get_full_path("upscale_models", model_name)
    if not path:
        raise RuntimeError("找不到超分模型：%s（放到 /opt/ComfyUI/models/upscale_models/）" % model_name)

    try:
        from spandrel import ModelLoader
        with open(path, "rb") as fh:
            pass
        import safetensors.torch as st
        if path.endswith(".safetensors"):
            sd = st.load_file(path)
        else:
            import torch as _t
            sd = _t.load(path, map_location="cpu", weights_only=True)
        model = ModelLoader().load_from_state_dict(sd)
        model.eval()
        return model.to(comfy.model_management.get_torch_device())
    except Exception as e:
        raise RuntimeError("加载超分模型失败：%s" % e)


def _do_upscale(job_id, spec):
    """逐帧放大，再用 PyAV 重新封装（音轨原样复制）。"""
    import numpy as np
    import torch
    av = _pyav()

    src = VIDEO_DIR / spec["name"]
    scale = int(spec["scale"])
    out_name = "up%d_%s" % (scale, spec["name"])
    dst = VIDEO_DIR / out_name

    model = _load_upscale_model(spec["model"])
    dev = next(model.parameters()).device

    with av.open(str(src)) as ic:
        vs = [s for s in ic.streams if s.type == "video"][0]
        fps = float(vs.average_rate) if vs.average_rate else 24.0
        total = vs.frames or 0

        oc = av.open(str(dst), "w")
        ost = oc.add_stream("libx264", rate=int(round(fps)) or 24)
        ost.width = vs.codec_context.width * scale
        ost.height = vs.codec_context.height * scale
        ost.pix_fmt = "yuv420p"
        ost.options = {"crf": "16", "preset": "medium"}

        n = 0
        try:
            for frame in ic.decode(vs):
                if _cancelled(job_id):
                    raise RuntimeError("已取消")
                arr = frame.to_ndarray(format="rgb24")
                t = torch.from_numpy(arr).permute(2, 0, 1).float().div(255).unsqueeze(0).to(dev)
                with torch.no_grad():
                    out = model(t)
                out = out.squeeze(0).clamp(0, 1).cpu()
                h, w = ost.height, ost.width
                if out.shape[1] != h or out.shape[2] != w:
                    out = torch.nn.functional.interpolate(
                        out.unsqueeze(0), size=(h, w), mode="bilinear",
                        align_corners=False).squeeze(0)
                buf = (out.mul(255).round().byte().numpy().transpose(1, 2, 0))
                vf = av.VideoFrame.from_ndarray(buf, format="rgb24")
                for pkt in ost.encode(vf):
                    oc.mux(pkt)
                n += 1
                if total:
                    _set_progress(job_id, n, total, "逐帧超分 %d/%d" % (n, total))
            for pkt in ost.encode():
                oc.mux(pkt)
        finally:
            oc.close()

    return [{"name": out_name, "url": "/dsh/api/media/%s" % out_name,
             "bytes": dst.stat().st_size, "kind": "mp4"}]


def _do_concat(job_id, spec):
    """按顺序拼接，尺寸不一致统一缩放；音频逐段解码后合并重编码。"""
    import numpy as np
    av = _pyav()
    from PIL import Image

    names = spec["names"]
    paths = [VIDEO_DIR / n for n in names]
    infos = [video_info(p) for p in paths]
    base = infos[0]
    tw, th = base["width"], base["height"]
    fps = base["fps"] or 24.0

    out_name = "cat_%s_%dseg.mp4" % (time.strftime("%H%M%S"), len(paths))
    dst = VIDEO_DIR / out_name

    total_frames = sum(i["frames"] for i in infos) or 1
    done = 0
    audio_frames = []

    oc = av.open(str(dst), "w")
    ost = oc.add_stream("libx264", rate=int(round(fps)))
    ost.width, ost.height = tw, th
    ost.pix_fmt = "yuv420p"
    ost.options = {"crf": "18", "preset": "medium"}

    try:
        for p, info in zip(paths, infos):
            with av.open(str(p)) as ic:
                vs = [s for s in ic.streams if s.type == "video"][0]
                for frame in ic.decode(vs):
                    if _cancelled(job_id):
                        raise RuntimeError("已取消")
                    arr = frame.to_ndarray(format="rgb24")
                    if (info["width"], info["height"]) != (tw, th):
                        arr = np.asarray(Image.fromarray(arr).resize((tw, th), Image.LANCZOS))
                    vf = av.VideoFrame.from_ndarray(arr, format="rgb24")
                    for pkt in ost.encode(vf):
                        oc.mux(pkt)
                    done += 1
                    _set_progress(job_id, done, total_frames, "拼接 %d/%d" % (done, total_frames))

                aud = [s for s in ic.streams if s.type == "audio"]
                if aud:
                    for fr in ic.decode(aud[0]):
                        audio_frames.append(fr)

        for pkt in ost.encode():
            oc.mux(pkt)

        if audio_frames:
            _mux_audio(oc, av, np, audio_frames)
    finally:
        oc.close()

    return [{"name": out_name, "url": "/dsh/api/media/%s" % out_name,
             "bytes": dst.stat().st_size, "kind": "mp4"}]


def _mux_audio(oc, av, np, frames):
    """把解码出的音频帧重编码进容器。失败不影响视频。"""
    try:
        sr = frames[0].sample_rate or 32000
        layout = frames[0].layout.name if frames[0].layout else "stereo"
        oa = oc.add_stream("aac", rate=sr)
        oa.bit_rate = 192000
        oa.layout = layout
        for fr in frames:
            fr.pts = None
            try:
                for pkt in oa.encode(fr):
                    oc.mux(pkt)
            except Exception:
                continue
        for pkt in oa.encode():
            oc.mux(pkt)
    except Exception:
        pass


# ---------------------------------------------------------------- 长片：分段链式生成

SEG_MAX_FRAMES = 362          # 15 秒 = 362 帧（17*21+5），H3 单段上限
SEG_MAX_SECONDS = 15.0


def plan_segments(total_seconds, seg_seconds):
    """把总时长拆成若干段，每段不超过 seg_seconds 且帧数满足 17n+5。"""
    seg_seconds = min(float(seg_seconds or 15), SEG_MAX_SECONDS)
    total = float(total_seconds)
    n = max(1, int(math.ceil(total / seg_seconds - 1e-9)))
    per = total / n
    out = []
    for i in range(n):
        # 最后一段用总时长余量，保证换算后总帧数接近目标
        sec = per
        frames = frames_for_seconds(sec)
        if frames > SEG_MAX_FRAMES:
            frames = SEG_MAX_FRAMES
        out.append({"index": i, "seconds": round(frames / 24.0, 3), "frames": frames})
    return out


def _extract_last_frame(video_path, out_png):
    """取视频最后一帧存成 PNG，作为下一段首帧。"""
    av = _pyav()
    from PIL import Image
    last = None
    with av.open(str(video_path)) as c:
        vs = [s for s in c.streams if s.type == "video"][0]
        for fr in c.decode(vs):
            last = fr
    if last is None:
        raise RuntimeError("取末帧失败：视频无帧")
    arr = last.to_ndarray(format="rgb24")
    Image.fromarray(arr).save(str(out_png))
    return out_png


def _submit_graph(graph):
    """提交到 ComfyUI 并等完成，返回 (prompt_id, outputs)。"""
    resp = _http_json("/prompt", {"prompt": graph, "client_id": "dsh-console"}, timeout=120)
    pid = resp.get("prompt_id")
    if not pid:
        raise RuntimeError("提交被拒：%s" % json.dumps(resp, ensure_ascii=False)[:600])

    deadline = time.time() + 3 * 3600
    while time.time() < deadline:
        try:
            hist = _http_json("/history/%s" % pid, timeout=30)
        except Exception:
            time.sleep(1.0)
            continue
        if pid in hist:
            entry = hist[pid]
            st = entry.get("status") or {}
            if st.get("status_str") == "error":
                raise RuntimeError("生成失败：%s" %
                                   json.dumps(st.get("messages") or [], ensure_ascii=False)[-1200:])
            return pid, _collect_outputs(pid, entry.get("outputs") or {})
        time.sleep(1.0)
    raise RuntimeError("超时")


def _do_longfilm(job_id, spec):
    """把长片拆成 N 段：末帧接下一段首帧，最后拼接。"""
    total = spec["segments_total"]
    seg_sec = float(spec.get("seg_seconds") or 15)
    plan = plan_segments(spec.get("total_seconds") or (total * seg_sec), seg_sec)

    in_dir = input_dir()
    seg_outputs = []
    cur_first = spec["first_frame"]

    for i, seg in enumerate(plan):
        if _cancelled(job_id):
            raise RuntimeError("已取消")

        with _jlock:
            j = _jobs.get(job_id)
            if j is not None:
                j["stage"] = "段 %d/%d" % (i + 1, total)
                j["progress"] = {"value": i, "max": total}

        sub = dict(spec)
        sub.pop("segments_total", None)
        sub["first_frame"] = cur_first
        sub["length"] = seg["frames"]
        sub["seed"] = int(spec["seed"]) + i        # 每段换种子避免完全重复
        sub["kind"] = None
        sub["filename_prefix"] = "dsh/lf%d" % i

        graph = build_hyperflow(sub) if sub.get("engine") == "hyperflow" else build_native(sub)
        # 每段的输出前缀，便于收集
        for nid, nd in graph.items():
            if nd.get("class_type") == "SaveVideo":
                nd["inputs"]["filename_prefix"] = "dsh/lf%02d" % i

        pid, outs = _submit_graph(graph)
        seg_outputs.append(outs[0]["name"] if outs else None)

        # 取末帧做下一段首帧（最后一段不用）
        if i < len(plan) - 1:
            last_src = VIDEO_DIR / outs[0]["name"]
            nxt = in_dir / ("dsh_seg%02d.png" % (i + 1))
            _extract_last_frame(last_src, nxt)
            cur_first = nxt.name

    seg_outputs = [s for s in seg_outputs if s]
    if not seg_outputs:
        raise RuntimeError("没有任何分段产出")

    # 单段就不用拼
    if len(seg_outputs) == 1:
        return [{"name": seg_outputs[0], "url": "/dsh/api/media/%s" % seg_outputs[0],
                 "bytes": (VIDEO_DIR / seg_outputs[0]).stat().st_size, "kind": "mp4"}]

    with _jlock:
        j = _jobs.get(job_id)
        if j is not None:
            j["stage"] = "拼接 %d 段" % len(seg_outputs)

    out_name = "lf_%s_%dseg.mp4" % (time.strftime("%H%M%S"), len(seg_outputs))
    _concat_files(job_id, seg_outputs, out_name)
    return [{"name": out_name, "url": "/dsh/api/media/%s" % out_name,
             "bytes": (VIDEO_DIR / out_name).stat().st_size, "kind": "mp4"}]


def _concat_files(job_id, names, out_name):
    """把 VIDEO_DIR 里的多个文件按顺序拼成一个。"""
    import numpy as np
    av = _pyav()
    from PIL import Image

    paths = [VIDEO_DIR / n for n in names]
    infos = [video_info(p) for p in paths]
    base = infos[0]
    tw, th = base["width"], base["height"]
    fps = base["fps"] or 24.0
    dst = VIDEO_DIR / out_name

    total_frames = sum(i["frames"] for i in infos) or 1
    done = 0
    audio_frames = []

    oc = av.open(str(dst), "w")
    ost = oc.add_stream("libx264", rate=int(round(fps)))
    ost.width, ost.height = tw, th
    ost.pix_fmt = "yuv420p"
    ost.options = {"crf": "18", "preset": "medium"}

    try:
        for p, info in zip(paths, infos):
            if not p.is_file():
                continue
            with av.open(str(p)) as ic:
                vs = [s for s in ic.streams if s.type == "video"][0]
                for frame in ic.decode(vs):
                    if _cancelled(job_id):
                        raise RuntimeError("已取消")
                    arr = frame.to_ndarray(format="rgb24")
                    if (info["width"], info["height"]) != (tw, th):
                        arr = np.asarray(Image.fromarray(arr).resize((tw, th), Image.LANCZOS))
                    vf = av.VideoFrame.from_ndarray(arr, format="rgb24")
                    for pkt in ost.encode(vf):
                        oc.mux(pkt)
                    done += 1
                    _set_progress(job_id, done, total_frames, "拼接 %d/%d" % (done, total_frames))

                aud = [s for s in ic.streams if s.type == "audio"]
                if aud:
                    for fr in ic.decode(aud[0]):
                        audio_frames.append(fr)

        for pkt in ost.encode():
            oc.mux(pkt)
        if audio_frames:
            _mux_audio(oc, av, np, audio_frames)
    finally:
        oc.close()

    return dst


# ---------------------------------------------------------------- 路由

routes = web.RouteTableDef()


@routes.get("/dsh")
async def _page(request):
    f = ROOT / "ui.html"
    if not f.is_file():
        return web.Response(text="ui.html missing", status=500)
    return web.Response(text=f.read_text("utf-8"), content_type="text/html", charset="utf-8")


@routes.get("/dsh/api/status")
async def _status(request):
    _start_ws()
    info = {"vram": {}, "ram": {}, "disk": {}, "cpu": {}, "queue": 0}
    try:
        import torch
        if torch.cuda.is_available():
            free, total = torch.cuda.mem_get_info()
            info["vram"] = {"free": free, "total": total,
                            "name": torch.cuda.get_device_name(0)}
    except Exception as e:
        info["vram"] = {"error": str(e)}
    try:
        cur = int(Path("/sys/fs/cgroup/memory.current").read_text().strip())
        mx = Path("/sys/fs/cgroup/memory.max").read_text().strip()
        total = None if mx == "max" else int(mx)
        info["ram"] = {"used": cur, "total": total}
    except Exception as e:
        info["ram"] = {"error": str(e)}
    try:
        st = __import__("shutil").disk_usage("/workspace")
        info["disk"] = {"used": st.used, "total": st.total, "free": st.free}
    except Exception:
        pass
    try:
        import os
        info["cpu"] = {"load": os.getloadavg()[0], "cores": os.cpu_count()}
    except Exception:
        pass
    with _jlock:
        info["queue"] = sum(1 for j in _jobs.values() if j.get("status") in ("queued", "running"))
    return web.json_response(info)


@routes.get("/dsh/api/options")
async def _options(request):
    oi = object_info()

    def files(kind):
        try:
            import folder_paths
            return folder_paths.get_filename_list(kind)
        except Exception:
            return []

    h3_inputs = {}
    for name in ("MiniMaxH3ImageToVideo", "MiniMaxH3ReferenceToVideo"):
        node = oi.get(name)
        if not node:
            continue
        inp = node.get("input") or {}
        keys = []
        for sect in ("required", "optional"):
            keys.extend((inp.get(sect) or {}).keys())
        h3_inputs[name] = keys

    return web.json_response({
        "unet": files("diffusion_models"),
        "lora": files("loras"),
        "vae": files("vae"),
        "clip": files("text_encoders"),
        "upscale_models": files("upscale_models"),
        "nodes": {
            "HyperFlowLoader": "HyperFlowLoader" in oi,
            "HyperFlowSigmas": "HyperFlowSigmas" in oi,
            "H3": "MiniMaxH3ImageToVideo" in oi,
            "Upscale": "ImageUpscaleWithModel" in oi,
            "TaoMate": "BSAITaoMateLoRALoader" in oi,
            "TaoMateSteps": "BSAITaoMateTimesteps" in oi,
            "SigmaShift": "MiniMaxH3SigmaShift" in oi,
        },
        "h3_inputs": h3_inputs,
        "tiers": {k: list(v) for k, v in TIERS.items()},
    })


def validate_graph(graph):
    """按 object_info 校验节点与输入名，防止版本漂移导致静默错误。"""
    oi = object_info()
    if not oi:
        return []
    problems = []
    h3_keys = None
    node = oi.get("MiniMaxH3ImageToVideo") or {}
    inp = node.get("input") or {}
    if node:
        h3_keys = set()
        for sect in ("required", "optional"):
            h3_keys |= set((inp.get(sect) or {}).keys())
    for nid, nd in graph.items():
        ct = nd.get("class_type")
        if ct not in oi:
            problems.append("节点 %s 类型 %s 不存在" % (nid, ct))
            continue
        if ct == "MiniMaxH3ImageToVideo" and h3_keys:
            for k in nd.get("inputs", {}):
                if k not in h3_keys:
                    problems.append("MiniMaxH3ImageToVideo 不支持输入 %r" % k)
    return problems


@routes.post("/dsh/api/upload")
async def _upload(request):
    data = await request.post()
    f = data.get("file")
    if f is None or not getattr(f, "file", None):
        return web.json_response({"ok": False, "error": "no file"}, status=400)
    raw = f.file.read()
    name = str(data.get("name") or getattr(f, "filename", "upload.png"))
    ext = Path(name).suffix.lower() or ".png"
    safe = "dsh_%s%s" % (uuid.uuid4().hex[:12], ext)
    dst = input_dir() / safe
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes(raw)
    w = h = 0
    try:
        from PIL import Image
        with Image.open(dst) as im:
            w, h = im.size
    except Exception:
        pass
    return web.json_response({"ok": True, "name": safe, "width": w, "height": h,
                              "bytes": len(raw)})


@routes.post("/dsh/api/submit")
async def _submit(request):
    try:
        spec = await request.json()
    except Exception:
        return web.json_response({"ok": False, "error": "bad json"}, status=400)

    if not spec.get("first_frame"):
        return web.json_response({"ok": False, "error": "缺少首帧图"}, status=400)
    if not (spec.get("prompt") or "").strip():
        return web.json_response({"ok": False, "error": "缺少提示词"}, status=400)

    engine = spec.get("engine") or "native"
    spec["engine"] = engine
    w, h = resolve_size(spec.get("tier", "mid"), spec.get("orientation", "landscape"))
    spec["width"], spec["height"] = w, h
    spec["length"] = frames_for_seconds(float(spec.get("seconds", 5)))
    spec["steps"] = int(spec.get("steps", 8 if engine == "native" else 6))
    spec["seed"] = int(spec.get("seed") or 0)
    if engine == "native" and spec.get("use_lora"):
        spec["sampler"] = spec.get("sampler") or "euler"
        spec["scheduler"] = spec.get("scheduler") or "simple"

    # 超分：0=不超分，2=2x，4=4x（仅单段任务生效）
    spec["upscale_scale"] = int(spec.get("upscale_scale") or 0)
    spec["upscale_model"] = (spec.get("upscale_model") or "").strip()
    if spec["upscale_scale"] > 1 and not spec["upscale_model"]:
        return web.json_response({"ok": False, "error": "选了超分但没选超分模型"}, status=400)

    # TaoMate 3 步
    spec["taomate_lora"] = (spec.get("taomate_lora") or "").strip()
    spec["taomate_strength"] = float(spec.get("taomate_strength") or 1.0)

    # 长片：按目标总时长拆段
    total_sec = float(spec.get("total_seconds") or spec.get("seconds") or 5)
    seg_sec = float(spec.get("seg_seconds") or 15)
    if total_sec > SEG_MAX_SECONDS + 0.01:
        plan = plan_segments(total_sec, seg_sec)
        spec["segments_total"] = len(plan)
        spec["seg_seconds"] = min(seg_sec, SEG_MAX_SECONDS)
        spec["total_seconds"] = total_sec
        # 单段实际帧数取第一段
        spec["length"] = plan[0]["frames"]
        if spec["upscale_scale"] > 1:
            return web.json_response({
                "ok": False,
                "error": "长片暂不支持生成时超分，请生成完成后在任务卡片上单独超分"
            }, status=400)
    else:
        spec["segments_total"] = 1

    # 提交前校验：节点是否存在、输入名是否被版本改过
    graph = build_hyperflow(spec) if engine == "hyperflow" else build_native(spec)
    problems = validate_graph(graph)
    if problems:
        return web.json_response({"ok": False, "error": "工作流校验失败：" + "；".join(problems[:5])},
                                 status=400)

    ab_group = (spec.get("ab_group") or "").strip()

    job_id = uuid.uuid4().hex[:12]
    job = {
        "id": job_id,
        "status": "queued",
        "created": time.time(),
        "engine": engine,
        "prompt_preview": (spec.get("prompt") or "")[:120],
        "width": w, "height": h, "length": spec["length"],
        "steps": spec["steps"], "seed": spec["seed"],
        "upscale_scale": spec["upscale_scale"],
        "ab_group": ab_group,
        "segments_total": spec["segments_total"],
        "total_seconds": round(
            spec["length"] * spec["segments_total"] / 24.0, 1),
        "seconds": round(spec["length"] / 24.0, 2),
        "spec": spec,
    }
    with _jlock:
        _jobs[job_id] = job
        _order.append(job_id)
    _save_state()
    _q.put(job_id)
    _ensure_worker()
    return web.json_response({"ok": True, "job": _public(job)})


@routes.get("/dsh/api/jobs")
async def _jobs_list(request):
    _start_ws()
    with _jlock:
        ids = list(reversed(_order))[:60]
        out = []
        for i in ids:
            j = _jobs.get(i)
            if not j:
                continue
            d = _public(j)
            pr = _progress.get(j.get("prompt_id") or "") if j.get("prompt_id") else None
            if pr:
                d["progress"] = {"value": pr.get("value"), "max": pr.get("max")}
                if pr.get("error"):
                    d["progress"]["error"] = pr["error"]
            out.append(d)
    return web.json_response({"jobs": out})


@routes.post("/dsh/api/jobs/{job_id}/cancel")
async def _cancel(request):
    jid = request.match_info["job_id"]
    with _jlock:
        j = _jobs.get(jid)
        if not j:
            return web.json_response({"ok": False, "error": "not found"}, status=404)
        if j.get("status") in ("queued", "running"):
            j["status"] = "cancelled"
    _save_state()
    return web.json_response({"ok": True})


@routes.post("/dsh/api/jobs/{job_id}/delete")
async def _delete(request):
    jid = request.match_info["job_id"]
    with _jlock:
        _jobs.pop(jid, None)
        if jid in _order:
            _order.remove(jid)
    _save_state()
    return web.json_response({"ok": True})


# ---------------------------------------------------------------- 超分任务

@routes.post("/dsh/api/upscale")
async def _upscale_submit(request):
    """把一个已出片的视频送去超分，生成新任务。"""
    try:
        body = await request.json()
    except Exception:
        return web.json_response({"ok": False, "error": "bad json"}, status=400)

    name = (body.get("name") or "").strip()
    scale = int(body.get("scale") or 2)
    if "/" in name or ".." in name or not name:
        return web.json_response({"ok": False, "error": "文件名非法"}, status=400)

    src = VIDEO_DIR / name
    if not src.is_file():
        return web.json_response({"ok": False, "error": "文件不存在"}, status=400)

    up_model = (body.get("model") or "").strip()
    if not up_model:
        return web.json_response({"ok": False, "error": "没选超分模型"}, status=400)

    info = video_info(src)
    if not info.get("ok"):
        return web.json_response({"ok": False, "error": info.get("error", "读取失败")}, status=400)

    job_id = uuid.uuid4().hex[:12]
    job = {
        "id": job_id,
        "status": "queued",
        "created": time.time(),
        "engine": "upscale",
        "kind": "upscale",
        "prompt_preview": "超分 %dx · %s" % (scale, name),
        "width": info["width"] * scale // 2 if scale == 2 else info["width"] * scale,
        "height": info["height"] * scale // 2 if scale == 2 else info["height"] * scale,
        "length": info["frames"],
        "steps": 0,
        "upscale_scale": scale,
        "source": name,
        "spec": {"kind": "upscale", "name": name, "scale": scale,
                 "model": up_model, "fps": info["fps"]},
    }
    if scale == 2:
        job["width"] = info["width"] * 2
        job["height"] = info["height"] * 2

    with _jlock:
        _jobs[job_id] = job
        _order.append(job_id)
    _save_state()
    _q.put(job_id)
    _ensure_worker()
    return web.json_response({"ok": True, "job": _public(job)})


# ---------------------------------------------------------------- 拼接任务

@routes.post("/dsh/api/concat")
async def _concat_submit(request):
    """把多个视频按顺序拼成一个（保留各自音轨，统一重采样）。"""
    try:
        body = await request.json()
    except Exception:
        return web.json_response({"ok": False, "error": "bad json"}, status=400)

    names = body.get("names") or []
    if not isinstance(names, list) or len(names) < 2:
        return web.json_response({"ok": False, "error": "至少选 2 个视频"}, status=400)

    files = []
    for n in names[:40]:
        if "/" in n or ".." in n:
            return web.json_response({"ok": False, "error": "文件名非法"}, status=400)
        p = VIDEO_DIR / n
        if not p.is_file():
            return web.json_response({"ok": False, "error": "不存在：%s" % n}, status=400)
        files.append(p)

    infos = [video_info(p) for p in files]
    bad = [i for i in infos if not i.get("ok")]
    if bad:
        return web.json_response({"ok": False, "error": "有文件读取失败"}, status=400)

    base = infos[0]
    mismatch = [i for i in infos
                if (i["width"], i["height"]) != (base["width"], base["height"])]
    total_frames = sum(i["frames"] for i in infos)

    job_id = uuid.uuid4().hex[:12]
    job = {
        "id": job_id,
        "status": "queued",
        "created": time.time(),
        "engine": "concat",
        "kind": "concat",
        "prompt_preview": "拼接 %d 段 · %s" % (len(files), names[0]),
        "width": base["width"], "height": base["height"],
        "length": total_frames, "steps": 0,
        "resize_needed": bool(mismatch),
        "spec": {"kind": "concat", "names": [p.name for p in files],
                 "fps": base["fps"]},
    }
    with _jlock:
        _jobs[job_id] = job
        _order.append(job_id)
    _save_state()
    _q.put(job_id)
    _ensure_worker()
    return web.json_response({
        "ok": True, "job": _public(job),
        "warn": ("有 %d 段尺寸不一致，将统一缩放到 %dx%d"
                 % (len(mismatch), base["width"], base["height"])) if mismatch else "",
    })


CTYPES = {
    ".mp4": "video/mp4",
    ".webm": "video/webm",
    ".mov": "video/quicktime",
    ".mkv": "video/x-matroska",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".gif": "image/gif",
}


@routes.get("/dsh/api/media/{name}")
async def _media(request):
    """支持 Range（206）的实现。

    之前用 FileResponse 并覆盖 headers，导致 Accept-Ranges/Content-Length 丢失，
    浏览器 seek 失败 -> 播 2 秒重头开始，无限循环。
    """
    name = request.match_info["name"]
    if "/" in name or "\\" in name or ".." in name:
        return web.Response(status=400)
    f = VIDEO_DIR / name
    if not f.is_file():
        return web.Response(status=404)

    size = f.stat().st_size
    ctype = CTYPES.get(f.suffix.lower(), "application/octet-stream")
    rng = request.headers.get("Range", "")
    common = {"Accept-Ranges": "bytes", "Cache-Control": "no-cache"}

    if rng.startswith("bytes="):
        spec = rng[6:].split(",")[0].strip()
        start_s, _, end_s = spec.partition("-")
        try:
            if start_s == "":  # bytes=-N 尾部
                length = int(end_s)
                start = max(0, size - length)
                end = size - 1
            else:
                start = int(start_s)
                end = int(end_s) if end_s else size - 1
            if start > end or start >= size:
                raise ValueError
            end = min(end, size - 1)
        except Exception:
            return web.Response(status=416,
                                headers={"Content-Range": "bytes */%d" % size})
        length = end - start + 1
        with f.open("rb") as fh:
            fh.seek(start)
            body = fh.read(length)
        return web.Response(body=body, status=206, headers={
            **common,
            "Content-Type": ctype,
            "Content-Length": str(length),
            "Content-Range": "bytes %d-%d/%d" % (start, end, size),
        })

    return web.Response(body=f.read_bytes(), status=200, headers={
        **common,
        "Content-Type": ctype,
        "Content-Length": str(size),
    })


@routes.get("/dsh/api/logs")
async def _logs(request):
    p = WORKSPACE / "comfy.log"
    n = int(request.query.get("lines", 120))
    if not p.is_file():
        return web.json_response({"ok": False, "error": "no comfy.log"})
    try:
        lines = p.read_text("utf-8", errors="replace").splitlines()[-n:]
    except Exception as e:
        return web.json_response({"ok": False, "error": str(e)})
    return web.json_response({"ok": True, "lines": lines})


# ---------------------------------------------------------------- 文件管理
#
# 允许浏览/删除的根目录白名单。所有路径先 resolve() 再校验前缀，
# 防止 ../ 越权。

FILES_ROOTS = {
    "workspace_output": Path("/workspace/dsh_out/video"),
    "comfy_output": Path("/opt/ComfyUI/output"),
    "h3_models": Path("/workspace/h3-models"),
}


def _safe_path(root_key, rel):
    root = FILES_ROOTS.get(root_key)
    if root is None:
        return None, None
    if not root.exists():
        return root, None
    rel = (rel or "").lstrip("/")
    if ".." in Path(rel).parts:
        return root, None
    target = (root / rel).resolve()
    try:
        target.relative_to(root.resolve())
    except ValueError:
        return root, None          # 越界
    return root, target


@routes.get("/dsh/api/files")
async def _files(request):
    key = request.query.get("root", "comfy_output")
    rel = request.query.get("path", "")
    root, target = _safe_path(key, rel)
    if root is None:
        return web.json_response({"ok": False, "error": "非法 root"}, status=400)
    if target is None:
        return web.json_response({"ok": False, "error": "路径越界"}, status=400)
    if not target.is_dir():
        return web.json_response({"ok": False, "error": "目录不存在"}, status=404)

    items = []
    try:
        for p in target.iterdir():
            if p.name.startswith("."):
                continue
            try:
                st = p.stat()
            except Exception:
                continue
            is_dir = p.is_dir()
            items.append({
                "name": p.name,
                "dir": is_dir,
                "bytes": 0 if is_dir else st.st_size,
                "mtime": st.st_mtime,
                "kind": "" if is_dir else p.suffix.lower().lstrip("."),
            })
    except Exception as e:
        return web.json_response({"ok": False, "error": str(e)}, status=500)

    items.sort(key=lambda x: (not x["dir"], -x["mtime"]))

    total = 0
    try:
        for p in target.rglob("*"):
            if p.is_file() and not p.name.startswith("."):
                total += p.stat().st_size
    except Exception:
        pass

    rel_out = ""
    try:
        rel_out = str(target.relative_to(root.resolve()))
        if rel_out == ".":
            rel_out = ""
    except Exception:
        pass

    return web.json_response({
        "ok": True, "root": key, "path": rel_out,
        "root_label": str(root), "items": items,
        "total_bytes": total,
        "parent": str(Path(rel_out).parent) if rel_out else None,
    })


@routes.get("/dsh/api/files/raw")
async def _file_raw(request):
    """给预览用的，支持 Range，和 media 同样实现。"""
    key = request.query.get("root", "comfy_output")
    rel = request.query.get("path", "")
    root, target = _safe_path(key, rel)
    if target is None or not target.is_file():
        return web.Response(status=404)

    size = target.stat().st_size
    ctype = CTYPES.get(target.suffix.lower(), "application/octet-stream")
    common = {"Accept-Ranges": "bytes", "Cache-Control": "no-cache"}
    rng = request.headers.get("Range", "")

    if rng.startswith("bytes="):
        spec = rng[6:].split(",")[0].strip()
        a, _, b = spec.partition("-")
        try:
            if a == "":
                start = max(0, size - int(b)); end = size - 1
            else:
                start = int(a); end = int(b) if b else size - 1
            if start > end or start >= size:
                raise ValueError
            end = min(end, size - 1)
        except Exception:
            return web.Response(status=416, headers={"Content-Range": "bytes */%d" % size})
        with target.open("rb") as fh:
            fh.seek(start)
            body = fh.read(end - start + 1)
        return web.Response(body=body, status=206, headers={
            **common, "Content-Type": ctype,
            "Content-Length": str(len(body)),
            "Content-Range": "bytes %d-%d/%d" % (start, end, size),
        })

    return web.Response(body=target.read_bytes(), status=200, headers={
        **common, "Content-Type": ctype, "Content-Length": str(size),
    })


@routes.get("/dsh/api/files/download")
async def _file_download(request):
    key = request.query.get("root", "comfy_output")
    rel = request.query.get("path", "")
    root, target = _safe_path(key, rel)
    if target is None or not target.is_file():
        return web.Response(status=404)
    return web.FileResponse(target, headers={
        "Content-Disposition": 'attachment; filename="%s"' % target.name,
    })


@routes.post("/dsh/api/files/delete")
async def _file_delete(request):
    try:
        body = await request.json()
    except Exception:
        return web.json_response({"ok": False, "error": "bad json"}, status=400)

    key = body.get("root", "comfy_output")
    paths = body.get("paths") or []
    if not isinstance(paths, list) or not paths:
        return web.json_response({"ok": False, "error": "没有选中文件"}, status=400)

    done, failed = [], []
    for rel in paths[:200]:                      # 单次上限，防止误操作
        root, target = _safe_path(key, rel)
        if target is None:
            failed.append({"path": rel, "error": "路径越界"})
            continue
        if target == root.resolve():
            failed.append({"path": rel, "error": "不能删除根目录"})
            continue
        try:
            if target.is_dir():
                import shutil
                shutil.rmtree(target)
            elif target.is_file():
                target.unlink()
            else:
                failed.append({"path": rel, "error": "不存在"})
                continue
            done.append(rel)
        except Exception as e:
            failed.append({"path": rel, "error": str(e)})

    # 清掉工作台缓存的副本（如果删的是 dsh_out）
    if done and key == "workspace_output":
        with _jlock:
            for j in _jobs.values():
                outs = j.get("outputs") or []
                if outs:
                    j["outputs"] = [o for o in outs
                                    if (VIDEO_DIR / o.get("name", "")).exists()]

    return web.json_response({"ok": True, "deleted": done, "failed": failed})


# ---------------------------------------------------------------- 注册
#
# ComfyUI 0.45 的启动顺序：
#   PromptServer(loop, asset_manager)  ->  nodes.init_extra_nodes()（加载本插件）
#   ->  prompt_server.add_routes()     ->  app.add_routes(self.routes)
#
# 插件 import 时 instance 一定存在，但直接把路由塞进 instance.routes 有风险：
# add_routes() 会先复制一份 /api 前缀的副本，再整体 add 到 app。
# 为了让路由 100% 生效，这里给 PromptServer.add_routes 打一个幂等猴补丁，
# 在它原本逻辑跑之前先把我们的 RouteTableDef 并入 self.routes。

_installed = {"v": False}


def _install(host_cls):
    if _installed["v"]:
        return True
    orig = getattr(host_cls, "add_routes", None)
    if orig is None or getattr(orig, "_dsh_wrapped", False):
        _installed["v"] = True
        return True

    def wrapped(self, *a, **kw):
        try:
            table = getattr(self, "routes", None)
            if table is not None:
                for rd in routes:
                    # RouteTableDef 迭代出来的是 RouteDef；逐条注册到宿主路由表
                    table.route(rd.method, rd.path)(rd.handler, **rd.kwargs)
                print("[DSH Console] 注入 %d 条路由" % len(list(routes)))
        except Exception as e:
            print("[DSH Console] 路由注入失败：%r" % (e,))
        return orig(self, *a, **kw)

    wrapped._dsh_wrapped = True
    host_cls.add_routes = wrapped
    _installed["v"] = True
    print("[DSH Console] 已挂载路由，访问 /dsh")
    return True


if server is not None:
    try:
        _install(server.PromptServer)
    except Exception as e:  # pragma: no cover
        print("[DSH Console] 安装失败：%r" % (e,))

NODE_CLASS_MAPPINGS = {}
NODE_DISPLAY_NAME_MAPPINGS = {}
