"""코르소나 블렌더 작업 공통 모듈 — 블렌더 4.2 이상(4.4+ 권장) 내장 파이썬에서 실행.

원칙
- Bust·Armature 는 읽기만 한다(데이터·모디파이어·그룹·셰이프키 변경 없음).
- 레스트 기준 좌표는 Bust 셰이프키 Basis(없으면 정점) × matrix_world. 포즈·현재 프레임 값에 의존하지 않는다.
- 포즈 검사는 실제 포즈를 바꾸지 않고, 뼈 rest 행렬로 직접 계산한 선형 블렌드 스키닝(LBS)으로 한다.
"""
import json
import math
import os
import runpy

import bpy
import numpy as np
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree

REPORT = {"log": []}


def log(*args):
    msg = " ".join(str(a) for a in args)
    print("[coursona]", msg, flush=True)
    REPORT["log"].append(msg)


# ---------------------------------------------------------------- 장면 찾기
def find_bust(name="Bust"):
    ob = bpy.data.objects.get(name)
    if ob and ob.type == "MESH":
        return ob
    for ob in bpy.data.objects:
        if ob.type == "MESH" and "ARKitFace" in ob.vertex_groups and len(ob.data.vertices) >= 1220:
            log("Bust 이름이 다름 → %s 사용" % ob.name)
            return ob
    raise RuntimeError("Bust 메시를 찾지 못했다(이름 'Bust' 또는 ARKitFace 그룹 보유 메시)")


def find_armature(bust):
    if bust.parent and bust.parent.type == "ARMATURE":
        return bust.parent
    for m in bust.modifiers:
        if m.type == "ARMATURE" and m.object:
            return m.object
    ob = bpy.data.objects.get("Armature")
    if ob and ob.type == "ARMATURE":
        return ob
    raise RuntimeError("Armature 를 찾지 못했다")


def ensure_collection(name):
    """있으면 재사용(어느 부모 아래 있든), 없으면 만들어 씬에 연결. '.001' 생성 방지."""
    col = bpy.data.collections.get(name)
    if col is None:
        col = bpy.data.collections.new(name)
        parent = bpy.data.collections.get("Library") or bpy.context.scene.collection
        parent.children.link(col)
        log("컬렉션 생성:", name, "(부모 %s)" % parent.name)
    else:
        log("컬렉션 재사용:", name)
    return col


def remove_object(name):
    ob = bpy.data.objects.get(name)
    if ob is None:
        return False
    data = ob.data
    bpy.data.objects.remove(ob, do_unlink=True)
    if data is not None and getattr(data, "users", 1) == 0:
        if isinstance(data, bpy.types.Mesh):
            bpy.data.meshes.remove(data)
    return True


# ---------------------------------------------------------------- 레스트 데이터
def basis_coords(ob):
    me = ob.data
    n = len(me.vertices)
    co = np.empty(n * 3, np.float64)
    if me.shape_keys and me.shape_keys.reference_key:
        me.shape_keys.reference_key.data.foreach_get("co", co)
    else:
        me.vertices.foreach_get("co", co)
    return co.reshape(n, 3)


def key_coords(ob, key_name):
    me = ob.data
    if not me.shape_keys or key_name not in me.shape_keys.key_blocks:
        return None
    n = len(me.vertices)
    co = np.empty(n * 3, np.float64)
    me.shape_keys.key_blocks[key_name].data.foreach_get("co", co)
    return co.reshape(n, 3)


def to_world(ob, local):
    M = np.array(ob.matrix_world)
    return local @ M[:3, :3].T + M[:3, 3]


def polygons(me):
    return [tuple(p.vertices) for p in me.polygons]


def vertex_normals(V, faces):
    N = np.zeros_like(V)
    for f in faces:
        for i in range(1, len(f) - 1):
            a, b, c = f[0], f[i], f[i + 1]
            n = np.cross(V[b] - V[a], V[c] - V[a])
            N[a] += n
            N[b] += n
            N[c] += n
    return N / np.maximum(np.linalg.norm(N, axis=1, keepdims=True), 1e-12)


def group_weights(ob, name):
    """정점 그룹 가중치 (N,) — 없으면 0."""
    n = len(ob.data.vertices)
    w = np.zeros(n)
    vg = ob.vertex_groups.get(name)
    if vg is None:
        return w
    gi = vg.index
    for v in ob.data.vertices:
        for g in v.groups:
            if g.group == gi:
                w[v.index] = g.weight
                break
    return w


def all_group_weights(ob):
    names = [g.name for g in ob.vertex_groups]
    W = np.zeros((len(ob.data.vertices), len(names)))
    for v in ob.data.vertices:
        for g in v.groups:
            W[v.index, g.group] = g.weight
    return names, W


def bust_rest(bust):
    V = to_world(bust, basis_coords(bust))
    F = polygons(bust.data)
    return dict(V=V, F=F, N=vertex_normals(V, F))


# ---------------------------------------------------------------- 표면 질의
class BVHSurface:
    """hair_geometry 가 쓰는 표면 인터페이스(BVH 기반, 정확한 최근접)."""

    def __init__(self, V, F):
        self.V = np.asarray(V)
        self.F = F
        self.bvh = BVHTree.FromPolygons([tuple(v) for v in self.V], F, all_triangles=False)

    def nearest(self, p):
        loc, nrm, idx, dist = self.bvh.find_nearest(Vector(p))
        if loc is None:
            return np.asarray(p), np.array([0.0, 0.0, 1.0]), 1.0
        q = np.array(loc)
        n = np.array(nrm)
        d = float(np.dot(np.asarray(p) - q, n))
        if abs(d) < 1e-9:
            d = 0.0
        return q, n, (abs(dist) if d >= 0 else -abs(dist))

    def ray_down(self, p, max_d):
        loc, nrm, idx, dist = self.bvh.ray_cast(Vector(p), Vector((0.0, 0.0, -1.0)), max_d)
        return None if loc is None else float(dist)

    def ray(self, origin, direction, max_d):
        loc, nrm, idx, dist = self.bvh.ray_cast(Vector(origin), Vector(direction).normalized(), max_d)
        if loc is None:
            return None
        return np.array(loc), np.array(nrm), int(idx), float(dist)

    def signed_distances(self, P, radius=None):
        out = np.full(len(P), np.inf)
        for i, p in enumerate(P):
            loc, nrm, idx, dist = (self.bvh.find_nearest(Vector(p)) if radius is None
                                   else self.bvh.find_nearest(Vector(p), radius))
            if loc is None:
                continue
            s = np.dot(np.asarray(p) - np.array(loc), np.array(nrm))
            out[i] = dist if s >= 0 else -dist
        return out


def overlap_count(Va, Fa, Vb, Fb):
    a = BVHTree.FromPolygons([tuple(v) for v in Va], Fa, all_triangles=False)
    b = BVHTree.FromPolygons([tuple(v) for v in Vb], Fb, all_triangles=False)
    return len(a.overlap(b))


# ---------------------------------------------------------------- 스키닝 계산(포즈 검사용)
def bone_rest_world(arm, bone_name):
    b = arm.data.bones[bone_name]
    return np.array(arm.matrix_world @ b.matrix_local)


def skin_matrices(arm, rotations):
    """rotations: {뼈이름: (rx, ry, rz) 도, 뼈 로컬 오일러 XYZ}. 반환 {뼈: 4x4 월드 스키닝 행렬}."""
    Mw = np.array(arm.matrix_world)
    Mw_inv = np.linalg.inv(Mw)
    pose = {}

    def rot(deg):
        rx, ry, rz = (math.radians(a) for a in deg)
        return np.array(Matrix.Rotation(rz, 4, "Z") @ Matrix.Rotation(ry, 4, "Y") @ Matrix.Rotation(rx, 4, "X"))

    for b in arm.data.bones:   # 부모가 먼저 나온다(블렌더 순서)
        rest = np.array(b.matrix_local)
        R = rot(rotations.get(b.name, (0, 0, 0)))
        if b.parent is None:
            pm = rest @ R
        else:
            prest = np.array(b.parent.matrix_local)
            pm = pose[b.parent.name] @ np.linalg.inv(prest) @ rest @ R
        pose[b.name] = pm
    out = {}
    for b in arm.data.bones:
        S = pose[b.name] @ np.linalg.inv(np.array(b.matrix_local))
        out[b.name] = Mw @ S @ Mw_inv
    return out


def lbs(Vw, names, W, mats):
    """월드 좌표 정점에 LBS. names/W: 정점 그룹 이름과 가중치(뼈 이름과 같은 그룹만 사용)."""
    out = np.zeros_like(Vw)
    tot = np.zeros(len(Vw))
    Vh = np.hstack([Vw, np.ones((len(Vw), 1))])
    for j, nm in enumerate(names):
        if nm not in mats:
            continue
        w = W[:, j]
        if not w.any():
            continue
        out += w[:, None] * (Vh @ mats[nm].T)[:, :3]
        tot += w
    keep = tot < 1e-6
    out[~keep] /= tot[~keep, None]
    out[keep] = Vw[keep]
    return out


POSES = {
    "yaw_L30": {"Head": (0, 15, 0), "Neck": (0, 15, 0)},
    "yaw_R30": {"Head": (0, -15, 0), "Neck": (0, -15, 0)},
    "pitch_down25": {"Head": (12, 0, 0), "Neck": (13, 0, 0)},
    "pitch_up20": {"Head": (-10, 0, 0), "Neck": (-10, 0, 0)},
    "tilt_L15": {"Neck": (0, 0, 15)},
    "tilt_R15": {"Neck": (0, 0, -15)},
    "combo": {"Head": (8, 10, 0), "Neck": (8, 10, 6)},
}


# ---------------------------------------------------------------- 오브젝트·메시 만들기
def make_mesh_object(name, Vlocal, faces, collection, loop_uv=None, mat_index=None, smooth=True):
    remove_object(name)
    me = bpy.data.meshes.get(name)
    if me is not None and me.users == 0:
        bpy.data.meshes.remove(me)
    me = bpy.data.meshes.new(name)
    me.from_pydata([tuple(map(float, v)) for v in Vlocal], [], [tuple(int(i) for i in f) for f in faces])
    me.update()
    if loop_uv is not None:
        uv = me.uv_layers.new(name="UVMap")
        flat = [c for fu in loop_uv for uvp in fu for c in uvp]
        uv.data.foreach_set("uv", flat)
    if mat_index is not None:
        me.polygons.foreach_set("material_index", list(mat_index))
    me.polygons.foreach_set("use_smooth", [smooth] * len(me.polygons))
    me.validate(clean_customdata=False)
    ob = bpy.data.objects.new(name, me)
    collection.objects.link(ob)
    return ob


def set_props(ob, **kw):
    for k, v in kw.items():
        ob[k] = json.dumps(v, ensure_ascii=False) if isinstance(v, (list, dict)) else v


def set_contract_props(ob, kind=None, bone=None, tint=None, textures=None, skin_groups=None):
    """내보내기 스크립트가 읽는 커스텀 속성. 초상 계열(chosang_*)과 코르소나 계열(coursona_*)을 둘 다 쓴다
    — export_coursona.py 가 어느 접두사를 읽든 같은 값이 나가게."""
    vals = {"kind": kind, "bone": bone, "tint": tint, "textures": textures, "skin_groups": skin_groups}
    for pre in ("chosang_", "coursona_"):
        set_props(ob, **{pre + k: v for k, v in vals.items() if v is not None})


def backup_blend_once():
    """기존 오브젝트를 교체하기 전 .blend 사본을 한 번 저장한다(현재 파일은 그대로 열려 있음)."""
    if REPORT.get("backup") or not bpy.data.filepath:
        return REPORT.get("backup")
    import time
    path = os.path.join(blend_dir(), "backup_before_coursona_%s.blend" % time.strftime("%Y%m%d_%H%M%S"))
    bpy.ops.wm.save_as_mainfile(filepath=path, copy=True)
    REPORT["backup"] = path
    log("백업 저장:", path)
    return path


def record_existing(name):
    """교체 전 기존 오브젝트 상태를 보고서에 남긴다(계약상 이미 있을 수 있는 이름: Hair_long_wave, Shoulders_shirt)."""
    ob = bpy.data.objects.get(name)
    if ob is None:
        return None
    d = {"type": ob.type, "collections": [c.name for c in ob.users_collection],
         "parent": ob.parent.name if ob.parent else None, "parent_type": ob.parent_type,
         "skinned": is_skinned(ob) if ob.type == "MESH" else False,
         "props": {k: (ob[k] if isinstance(ob[k], (int, float, str)) else str(ob[k])) for k in ob.keys()}}
    if ob.type == "MESH":
        d.update(verts=len(ob.data.vertices), faces=len(ob.data.polygons),
                 materials=[m.name if m else None for m in ob.data.materials])
    REPORT.setdefault("replaced", {})[name] = d
    log("기존 %s 를 교체한다(이전 상태는 보고서 replaced 항목과 백업 .blend 에 있음)" % name)
    return d


def principled(mat):
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = next((n for n in nt.nodes if n.type == "BSDF_PRINCIPLED"), None)
    if bsdf is None:
        bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
        out = next((n for n in nt.nodes if n.type == "OUTPUT_MATERIAL"), None) or nt.nodes.new("ShaderNodeOutputMaterial")
        nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
    return bsdf


def set_input(bsdf, names, value):
    for n in names:
        if n in bsdf.inputs:
            bsdf.inputs[n].default_value = value
            return True
    return False


def srgb_to_linear(c):
    c = np.asarray(c, float)
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


# ---------------------------------------------------------------- 경로·library.json·내보내기
def blend_dir():
    return os.path.dirname(bpy.data.filepath) if bpy.data.filepath else os.path.expanduser("~/Desktop")


def find_template_dir(explicit=None):
    if explicit:
        os.makedirs(explicit, exist_ok=True)
        return explicit
    base = blend_dir()
    cand = os.path.join(base, "Template")
    if os.path.isdir(cand):
        return cand
    for root, dirs, files in os.walk(base):
        if root[len(base):].count(os.sep) > 3:
            dirs[:] = []
            continue
        if "Template.usdz" in files:
            return root
    os.makedirs(cand, exist_ok=True)
    log("Template 폴더가 없어 만들었다:", cand)
    return cand


def find_export_script(explicit=None):
    if explicit and os.path.isfile(os.path.expanduser(explicit)):
        return os.path.expanduser(explicit)
    txt = bpy.data.texts.get("export_coursona.py")
    if txt is not None and txt.filepath and os.path.isfile(bpy.path.abspath(txt.filepath)):
        return bpy.path.abspath(txt.filepath)
    home = os.path.expanduser("~")
    roots = [blend_dir(), os.path.join(blend_dir(), "build"), os.path.join(blend_dir(), "tools"),
             os.path.dirname(blend_dir())] + [os.path.join(home, d) for d in ("Desktop", "Developer", "Documents", "Projects", "GitHub")]
    for r in roots:
        if not os.path.isdir(r):
            continue
        for root, dirs, files in os.walk(r):
            if root[len(r):].count(os.sep) > 4:
                dirs[:] = []
                continue
            dirs[:] = [d for d in dirs if not d.startswith(".") and d not in ("node_modules", "DerivedData", "build_cache")]
            if "export_coursona.py" in files:
                return os.path.join(root, "export_coursona.py")
    return None


def run_export(script_path, args=()):
    """기존 export_coursona.py 를 이 세션에서 실행. 검증기 문구상 CLI 플래그(--no-usdz 등)가 있는 스크립트이므로
    평소처럼 `Blender -b <파일>.blend -P export_coursona.py -- <인자>` 로 돌리는 것을 우선 권장한다.
    여기서는 sys.argv 를 [script, '--', *args] 로 맞춰 runpy 로 실행한다(--no-usdz 는 절대 넣지 않는다)."""
    import sys
    if not script_path:
        log("export_coursona.py 를 찾지 못했다 — 평소 방식(CLI)으로 직접 실행할 것")
        return False
    if any(a == "--no-usdz" for a in args):
        raise ValueError("--no-usdz 금지: Template.usdz 가 빠지면 검증 오류(files.usdz)")
    old = sys.argv
    sys.argv = [script_path, "--", *args]
    try:
        log("내보내기 실행:", script_path, list(args))
        runpy.run_path(script_path, run_name="__main__")
    finally:
        sys.argv = old
    return True


def load_library(path):
    if not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def update_library_json(path, entry):
    """같은 name 이 있으면 교체, 없으면 추가. 기존 최상위 형태(배열 / {items|assets|library: [...]})를 유지.
    파일이 없으면 배열로 새로 만든다(TemplateValidator 디코더 형태가 다르면 이 한 줄만 바꾸면 됨)."""
    data = load_library(path)
    if data is None:
        data = []
    if isinstance(data, list):
        items = data
    else:
        key = next((k for k in ("items", "assets", "library", "entries") if isinstance(data.get(k), list)), None)
        if key is None:
            key = "items"
            data[key] = []
        items = data[key]
    for i, it in enumerate(items):
        if isinstance(it, dict) and it.get("name") == entry["name"]:
            items[i] = entry
            break
    else:
        items.append(entry)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    log("library.json 갱신:", path, entry["name"])
    return path


def write_report(path):
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(REPORT, fh, ensure_ascii=False, indent=2, default=lambda o: o.tolist() if hasattr(o, "tolist") else str(o))
    log("보고서:", path)


# ---------------------------------------------------------------- 공통 관통 검사(레스트 + 포즈)
def rest_world(ob):
    """오브젝트의 레스트 월드 정점(셰이프키 Basis). 호출 전 Armature pose_position = 'REST' 권장."""
    return to_world(ob, basis_coords(ob))


def attach_bone(ob):
    """강체 부착 뼈 이름(뼈 부모 또는 Child Of) — 스킨 메시면 None."""
    if ob.parent is not None and ob.parent_type == "BONE":
        return ob.parent_bone
    for c in ob.constraints:
        if c.type == "CHILD_OF" and c.subtarget:
            return c.subtarget
    return None


def is_skinned(ob):
    return any(m.type == "ARMATURE" for m in ob.modifiers) and len(ob.vertex_groups) > 0


def posed_world(ob, Vrest, mats):
    """포즈 mats(skin_matrices 결과)에서의 월드 정점."""
    if is_skinned(ob):
        names, W = all_group_weights(ob)
        return lbs(Vrest, names, W, mats)
    b = attach_bone(ob)
    if b and b in mats:
        return (np.hstack([Vrest, np.ones((len(Vrest), 1))]) @ mats[b].T)[:, :3]
    return Vrest


def clearance_report(arm, test_ob, ref_obs, need_rest=0.0009, radius=0.03, poses=None, test_mask=None):
    """test_ob 정점이 ref_obs 표면(바깥 법선) 바깥에 있는지. 레스트 최소 거리 + 포즈별 관통 정점 수."""
    poses = POSES if poses is None else poses
    Vt = rest_world(test_ob)
    if test_mask is not None:
        Vt_use = Vt[test_mask]
    else:
        Vt_use = Vt
    refs = [(r, rest_world(r), polygons(r.data)) for r in ref_obs]

    def union(Vs):
        V, F, off = [], [], 0
        for (r, _, Fr), Vr in zip(refs, Vs):
            V.append(Vr)
            F += [tuple(i + off for i in f) for f in Fr]
            off += len(Vr)
        return np.concatenate(V), F

    Vu, Fu = union([v for (_, v, _) in refs])
    sd = BVHSurface(Vu, Fu).signed_distances(Vt_use, radius=radius)
    out = {"rest_min_mm": float(np.min(sd) * 1000) if np.isfinite(sd).any() else None,
           "rest_below_need": int((sd < need_rest).sum()), "poses": {}}
    for pname, rot in poses.items():
        mats = skin_matrices(arm, rot)
        Vt_p = posed_world(test_ob, Vt, mats)
        if test_mask is not None:
            Vt_p = Vt_p[test_mask]
        Vu_p, _ = union([posed_world(r, v, mats) for (r, v, _) in refs])
        s2 = BVHSurface(Vu_p, Fu).signed_distances(Vt_p, radius=radius)
        out["poses"][pname] = {"min_mm": float(np.min(s2) * 1000) if np.isfinite(s2).any() else None,
                               "inside": int((s2 < 0).sum())}
    out["pass"] = out["rest_below_need"] == 0 and all(p["inside"] == 0 for p in out["poses"].values())
    return out


def union_surface(obs):
    V, F, off = [], [], 0
    for ob in obs:
        Vr = rest_world(ob)
        V.append(Vr)
        F += [tuple(i + off for i in f) for f in polygons(ob.data)]
        off += len(Vr)
    return BVHSurface(np.concatenate(V), F)


def driver_from_bust(target_ob, key_name, bust):
    """target_ob 의 셰이프키 key_name 값 ← Bust 의 같은 이름 키 값(블렌더 미리보기용. USD 에는 드라이버가 없다)."""
    kb = target_ob.data.shape_keys.key_blocks[key_name]
    try:
        kb.driver_remove("value")
    except Exception:
        pass
    fc = kb.driver_add("value")
    drv = fc.driver
    drv.type = "AVERAGE"
    var = drv.variables.new()
    var.name = "v"
    var.type = "SINGLE_PROP"
    var.targets[0].id_type = "KEY"
    var.targets[0].id = bust.data.shape_keys
    var.targets[0].data_path = 'key_blocks["%s"].value' % key_name
    return fc


# ---------------------------------------------------------------- 투명 틀(ghost carrier) 머티리얼
def make_transparent(mat, opacity=0.10, viewport_alpha=None, colorless=True, gray=0.80):
    """에셋은 형태·배치·실루엣만 담는 투명한 틀이다. 색·불투명도는 앱이 이미지 기반 페르소나로 입힌다.
    - Principled Alpha 를 상수 opacity(기본 0)로 둔다 → USD opacity 상수로 나간다(앱이 로드 뒤 올린다)
    - 알파 텍스처 링크는 끊되 노드(HairBase)는 남긴다: 앱이 실루엣 마스크로 쓴다(library textures.base 의 알파 채널)
    - 뷰포트에서는 viewport_alpha(0.15) 유령 미리보기"""
    bsdf = principled(mat)
    nt = mat.node_tree
    for l in list(nt.links):
        if l.to_node == bsdf and (l.to_socket.name == "Alpha" or (colorless and l.to_socket.name == "Base Color")):
            nt.links.remove(l)                    # 텍스처 노드는 참고용으로 남긴다(내보내기에는 안 나감)
    bsdf.inputs["Alpha"].default_value = float(opacity)
    if colorless:                                 # 색을 뺀다: 무채색 연회색, 금속·코팅 0
        set_input(bsdf, ["Base Color"], (gray, gray, gray, 1.0))
        set_input(bsdf, ["Metallic"], 0.0)
        set_input(bsdf, ["Coat Weight", "Clearcoat"], 0.0)
        set_input(bsdf, ["Sheen Weight", "Sheen"], 0.0)
        set_input(bsdf, ["Emission Strength"], 0.0)
    if viewport_alpha is None:
        viewport_alpha = max(float(opacity), 0.05)
    if hasattr(mat, "surface_render_method"):
        mat.surface_render_method = "BLENDED"
    if hasattr(mat, "blend_method"):
        try:
            mat.blend_method = "BLEND"
        except Exception:
            pass
    if hasattr(mat, "show_transparent_back"):
        mat.show_transparent_back = False
    c = (gray, gray, gray) if colorless else tuple(mat.diffuse_color)[:3]
    mat.diffuse_color = (*c, float(viewport_alpha))
    mat["coursona_opacity"] = float(opacity)
    mat["coursona_colorless"] = bool(colorless)
    return mat



# ---------------------------------------------------------------- 테크 인터페이스(앱이 읽는 데이터)
import tech_data as TD

MANIFEST = {"schema": "coursona-assets/1",
            "coords": {"blender": "Z-up, 얼굴 −Y, 피사체 왼쪽 +X, m",
                       "usd": "Y-up, 얼굴 +Z, 피사체 왼쪽 +X, m — USD (x, y, z) = 블렌더 (x, z, −y)"},
            "presence": dict(TD.PRESENCE, version=TD.PRESENCE_VERSION,
                             uv="CoursonaData (uv1): x = presence, y = height01",
                             formula="presence = smoothstep(facing_lo, facing_hi, facing) * smoothstep(z_lo, z_hi, z_blender); "
                                     "facing = dot(normalize(xy − head_c.xy), (0, −1)) (블렌더) = dot(normalize(xz_usd − c), (0, +1)) (USD z)"),
            "assets": {}}


def add_data_uv(ob, xs, ys, name="CoursonaData"):
    """두 번째 UV(uv1)에 정점별 데이터(x = presence, y = height01)를 굽는다. 첫 UV(UVMap)는 렌더 UV 그대로."""
    me = ob.data
    if not me.uv_layers:
        me.uv_layers.new(name="UVMap")
    uv0 = me.uv_layers.get("UVMap") or me.uv_layers[0]
    data = me.uv_layers.get(name) or me.uv_layers.new(name=name)
    li = np.empty(len(me.loops), np.int32)
    me.loops.foreach_get("vertex_index", li)
    data.data.foreach_set("uv", np.stack([np.asarray(xs)[li], np.asarray(ys)[li]], 1).ravel().astype(np.float32))
    uv0.active = True
    uv0.active_render = True
    return data


def mesh_tris(me):
    tris = [tuple(p.vertices) for p in me.polygons]
    return tris, all(len(t) == 3 for t in tris)


def topology_hash_of(ob):
    tris, ok = mesh_tris(ob.data)
    return TD.topology_hash(len(ob.data.vertices), tris) if ok else None, len(tris), ok


def face_ranges_by_material(ob):
    labels = [(ob.data.materials[p.material_index].name if ob.data.materials and ob.data.materials[p.material_index]
               else str(p.material_index)) for p in ob.data.polygons]
    return TD.face_ranges(labels)


def manifest_add(name, entry):
    MANIFEST["assets"][name] = entry
    return entry


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=1, default=lambda o: o.tolist() if hasattr(o, "tolist") else str(o))
        fh.write("\n")
    log("JSON:", path)
    return path


def write_manifest(template_dir):
    return write_json(os.path.join(template_dir, "coursona_assets.json"), MANIFEST)


def hidden_collection(name="Splat_Hosts"):
    """내보내기에 섞이지 않게 뷰 레이어에서 제외한 컬렉션(스플랫 호스트 원본 보관용)."""
    col = bpy.data.collections.get(name) or bpy.data.collections.new(name)
    if col.name not in [c.name for c in bpy.context.scene.collection.children]:
        bpy.context.scene.collection.children.link(col)

    def find(lc):
        if lc.collection == col:
            return lc
        for ch in lc.children:
            r = find(ch)
            if r:
                return r
    lc = find(bpy.context.view_layer.layer_collection)
    if lc:
        lc.exclude = True
    return col
