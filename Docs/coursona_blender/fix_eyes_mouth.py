"""작업 3 — Eye_L / Eye_R / Mouth_Inner 를 '이름으로 찾을 수 있는 실제 메시'로 만든다.

순서: diagnose() → (있으면) 재사용 + 스킨→강체 전환 / (없으면) 생성 → 머티리얼 슬롯 순서 → 셰이프키 5개 + 드라이버 → 검사.
초상 .blend(10/4 README)에는 이미 Eye_L/R(r 12 mm, 3 머티리얼)과 Mouth_Inner(5 키, Bust 드라이버)가 '뼈 100% 스킨'으로
있다. 스킨 메시는 USD 에서 SkelRoot 아래 스킨 메시로 나가고, RealityKit 은 이를 스켈레톤 엔티티 하나로 합치므로
앱이 이름으로 못 찾는 것으로 본다(가설 — inspect_usdz.py 로 확인). 그래서 기본 동작은 '강체 전환'이다.

실행:
    import sys; sys.path.insert(0, "/Users/<you>/Desktop/coursona_blender")
    import importlib, fix_eyes_mouth as E; importlib.reload(E)
    E.diagnose()                # 먼저 보고만
    E.run(attach_mode="BONE")   # 계약 기본. USD 검사에서 여전히 합쳐지면 attach_mode="CHILD_OF"
"""
import json
import math

import bpy
import numpy as np
from mathutils import Matrix, Vector

import os
import coursona_common as C
import eyes_mouth_geometry as EM
import hair_texture as HT
import tech_data as TD

EYES = (("Eye_L", "Eye_L"), ("Eye_R", "Eye_R"))
MOUTH = "Mouth_Inner"
JAW_KEYS = ("jawOpen", "jawLeft", "jawRight", "jawForward")
ALL_KEYS = JAW_KEYS + ("tongueOut",)
# (이름, sRGB 기본색, roughness, 텍스처 파일 또는 None)
EYE_MATS = (("M_Eye_Sclera", (0.92, 0.90, 0.87), 0.18, "T_Eye_Sclera_base.png"),
            ("M_Eye_Iris", (0.30, 0.38, 0.42), 0.25, "T_Eye_Iris_base.png"),
            ("M_Eye_Pupil", (0.02, 0.02, 0.02), 0.10, None))
MOUTH_MATS = (("M_Teeth", (0.91, 0.88, 0.82), 0.35, "T_Teeth_base.png"), ("M_Gum", (0.71, 0.32, 0.35), 0.55, None),
              ("M_Tongue", (0.77, 0.42, 0.42), 0.60, None), ("M_MouthCavity", (0.23, 0.06, 0.07), 0.90, None))
TEXTURE_GEN = {"T_Eye_Iris_base.png": lambda: EM.iris_texture(), "T_Eye_Sclera_base.png": lambda: EM.sclera_texture(),
               "T_Teeth_base.png": lambda: EM.teeth_texture()}
EYE_KEYS_CHECK = ("eyeBlinkLeft", "eyeBlinkRight", "eyeWideLeft", "eyeWideRight", "eyeSquintLeft", "eyeSquintRight",
                  "eyeLookUpLeft", "eyeLookUpRight", "eyeLookDownLeft", "eyeLookDownRight")
MOUTH_KEYS_CHECK = ("jawOpen", "mouthClose", "mouthFunnel", "mouthPucker", "mouthRollLower", "mouthRollUpper",
                    "mouthSmileLeft", "mouthSmileRight", "jawLeft", "jawRight", "jawForward")


# ------------------------------------------------------------------ 진단
def _single_bone(ob):
    """모든 정점이 한 그룹에 ~1.0 이면 그 그룹 이름."""
    if not ob.vertex_groups:
        return None
    names = [g.name for g in ob.vertex_groups]
    one = set()
    for v in ob.data.vertices:
        gs = [(g.group, g.weight) for g in v.groups if g.weight > 1e-4]
        if len(gs) != 1 or gs[0][1] < 0.99:
            return None
        one.add(gs[0][0])
    return names[one.pop()] if len(one) == 1 else None


def mouth_bone(arm):
    """계약 스켈레톤은 Root > Spine > Neck > Head > {Eye_L, Eye_R} 6개뿐(검증기 skeleton.bones·skin.index).
    Mouth_Inner 뼈를 새로 만들지 않는다 — 있으면 쓰고(비계약), 없으면 Head 에 강체 고정. 턱 움직임은 셰이프키가 맡는다."""
    for b in ("Mouth_Inner", "Head"):
        if b in arm.data.bones:
            if b == "Mouth_Inner":
                C.log("경고: 계약 밖 뼈 Mouth_Inner 가 있다(검증기 clips.bones 경고 대상). 그대로 부모로 쓴다")
            return b
    raise RuntimeError("Head 뼈가 없다")


def diagnose():
    bust = C.find_bust()
    arm = C.find_armature(bust)
    info = {"bones": [b.name for b in arm.data.bones], "mouth_bone": mouth_bone(arm)}
    for name in ("Eye_L", "Eye_R", MOUTH):
        ob = bpy.data.objects.get(name)
        d = {"exists": ob is not None}
        if ob is not None:
            d.update(type=ob.type, parent=ob.parent.name if ob.parent else None, parent_type=ob.parent_type,
                     parent_bone=ob.parent_bone or None, modifiers=[m.type for m in ob.modifiers],
                     vertex_groups=[g.name for g in ob.vertex_groups], collections=[c.name for c in ob.users_collection],
                     hide_render=ob.hide_render, visible=ob.visible_get())
            if ob.type == "MESH":
                d.update(verts=len(ob.data.vertices), faces=len(ob.data.polygons),
                         materials=[m.name if m else None for m in ob.data.materials],
                         shape_keys=[k.name for k in ob.data.shape_keys.key_blocks] if ob.data.shape_keys else [],
                         single_bone_skin=_single_bone(ob) if C.is_skinned(ob) else None)
        if name in bpy.data.armatures[arm.data.name].bones:
            d["bone_with_same_name"] = True
        info[name] = d
    C.REPORT["eyes_mouth_diagnose"] = info
    C.log("진단", json.dumps(info, ensure_ascii=False))
    return info


# ------------------------------------------------------------------ 공통 처리
def ensure_textures(template_dir):
    """홍채·공막·치아 텍스처를 Template/textures 에 만들고(없을 때만) 블렌더 이미지로 읽는다."""
    tex_dir = os.path.join(template_dir, "textures")
    os.makedirs(tex_dir, exist_ok=True)
    imgs = {}
    for fname, gen in TEXTURE_GEN.items():
        dst = os.path.join(tex_dir, fname)
        if not os.path.isfile(dst):
            C.log("텍스처 생성:", fname)
            HT.save_png_bpy(gen(), dst, name=os.path.splitext(fname)[0])
        img = bpy.data.images.get(fname) or bpy.data.images.load(dst, check_existing=True)
        img.name = fname
        img.filepath = bpy.path.relpath(dst) if bpy.data.filepath else dst
        img.colorspace_settings.name = "sRGB"
        if img.packed_file:
            img.unpack(method="REMOVE")
        img.reload()
        imgs[fname] = img
    return imgs


def _materials(spec, imgs=None):
    out = []
    for name, rgb, rough, tex in spec:
        m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
        bsdf = C.principled(m)
        lin = C.srgb_to_linear(rgb)
        C.set_input(bsdf, ["Base Color"], (float(lin[0]), float(lin[1]), float(lin[2]), 1.0))
        C.set_input(bsdf, ["Roughness"], rough)
        if name.startswith("M_Eye"):
            C.set_input(bsdf, ["Coat Weight", "Clearcoat"], 0.6 if name != "M_Eye_Pupil" else 0.0)
            C.set_input(bsdf, ["Coat Roughness", "Clearcoat Roughness"], 0.05)
        m.diffuse_color = (*rgb, 1.0)
        if tex and imgs and tex in imgs:
            nt = m.node_tree
            node = nt.nodes.get("BaseTex") or nt.nodes.new("ShaderNodeTexImage")
            node.name = node.label = "BaseTex"
            node.image = imgs[tex]
            node.location = (-420, 120)
            for l in list(nt.links):
                if l.to_node == bsdf and l.to_socket.name == "Base Color":
                    nt.links.remove(l)
            nt.links.new(node.outputs["Color"], bsdf.inputs["Base Color"])
        out.append(m)
    return out


def _eye_uvs_and_materials(ob, center, mats):
    """슬롯 순서(공막·홍채·동공)대로 UV 를 다시 쓰고 텍스처 머티리얼을 끼운다."""
    me = ob.data
    Vw = C.rest_world(ob) - np.asarray(center)
    r = float(np.linalg.norm(Vw, axis=1).max())
    uv = me.uv_layers.get("UVMap") or me.uv_layers.new(name="UVMap")
    faces = [tuple(p.vertices) for p in me.polygons]
    mat = [p.material_index for p in me.polygons]
    luv = EM.eye_face_uvs(Vw, faces, mat, r)
    flat = [c for fu in luv for uvp in fu for c in uvp]
    uv.data.foreach_set("uv", flat)
    me.materials.clear()
    for m in mats:
        me.materials.append(m)


def _set_coords(ob, world_by_key, origin):
    """모든 셰이프키(없으면 정점)를 'origin 기준 로컬'로 다시 쓴다(회전 없음)."""
    me = ob.data
    o = np.asarray(origin)
    if me.shape_keys:
        for kb in me.shape_keys.key_blocks:
            kb.data.foreach_set("co", (world_by_key[kb.name] - o).ravel())
        me.vertices.foreach_set("co", (world_by_key[me.shape_keys.reference_key.name] - o).ravel())
    else:
        me.vertices.foreach_set("co", (world_by_key["__basis__"] - o).ravel())
    me.update()


def _world_by_key(ob):
    me = ob.data
    if me.shape_keys:
        return {kb.name: C.to_world(ob, C.key_coords(ob, kb.name)) for kb in me.shape_keys.key_blocks}
    return {"__basis__": C.to_world(ob, C.basis_coords(ob))}


def to_rigid(ob, arm, bone, origin, mode, shift=None):
    """스킨 해제(단일 뼈 100% 일 때만) → (선택) 메시 평행이동 → origin 으로 오리진 이동 → 뼈에 강체 부착."""
    wk = _world_by_key(ob)
    if shift is not None:
        wk = {k: v + np.asarray(shift) for k, v in wk.items()}
    if C.is_skinned(ob):
        sb = _single_bone(ob)
        if sb is None:
            C.log("경고: %s 는 여러 뼈에 스킨돼 있어 강체 전환을 건너뜀" % ob.name)
            return False
        for m in [m for m in ob.modifiers if m.type == "ARMATURE"]:
            ob.modifiers.remove(m)
        ob.vertex_groups.clear()
        C.log("%s: 스킨(%s 100%%) → 강체" % (ob.name, sb))
    ob.parent = None
    ob.matrix_world = Matrix.Identity(4)
    _set_coords(ob, wk, origin)
    attach(ob, arm, bone, origin, mode)
    return True


def attach(ob, arm, bone, origin, mode):
    ob.constraints.clear()
    T = Matrix.Translation(Vector(tuple(map(float, origin))))
    if mode == "BONE":
        ob.parent = arm
        ob.parent_type = "BONE"
        ob.parent_bone = bone
        ob.matrix_parent_inverse = Matrix.Identity(4)
        bpy.context.view_layer.update()
        ob.matrix_world = T
    elif mode == "CHILD_OF":
        ob.parent = None
        ob.matrix_world = T
        con = ob.constraints.new("CHILD_OF")
        con.target = arm
        con.subtarget = bone
        bpy.context.view_layer.update()
        con.inverse_matrix = (arm.matrix_world @ arm.pose.bones[bone].matrix).inverted()
    else:
        ob.parent = None
        ob.matrix_world = T
    bpy.context.view_layer.update()
    C.set_props(ob, coursona_bone=bone, coursona_attach=mode)


def _sphere_center(P):
    A = np.hstack([2 * P, np.ones((len(P), 1))])
    b = (P ** 2).sum(1)
    x, *_ = np.linalg.lstsq(A, b, rcond=None)
    return x[:3], math.sqrt(max(x[3] + (x[:3] ** 2).sum(), 0))


# ------------------------------------------------------------------ 눈
def _reorder_eye_slots(ob, center):
    """기하로 역할 판정: 앞축(−Y)에서 각도가 작은 슬롯 = 동공, 중간 = 홍채, 큰 = 공막 → 공막·홍채·동공 순서로."""
    me = ob.data
    if len(me.materials) != 3:
        return False
    Vw = C.rest_world(ob)
    ang = [[] for _ in range(3)]
    for p in me.polygons:
        c = Vw[list(p.vertices)].mean(axis=0) - center
        a = math.degrees(math.acos(np.clip(np.dot(c / np.linalg.norm(c), [0, -1, 0]), -1, 1)))
        ang[p.material_index].append(a)
    mean = [np.mean(a) if a else 999 for a in ang]
    order = list(np.argsort(mean))            # 동공, 홍채, 공막
    want = [order[2], order[1], order[0]]     # 공막, 홍채, 동공
    if want == [0, 1, 2]:
        return True
    mats = [me.materials[i] for i in want]
    remap = {old: new for new, old in enumerate(want)}
    idx = [remap[p.material_index] for p in me.polygons]
    me.materials.clear()
    for m in mats:
        me.materials.append(m)
    me.polygons.foreach_set("material_index", idx)
    C.log("%s 슬롯 재정렬 → %s" % (ob.name, [m.name for m in mats]))
    return True


def fix_eye(name, bone, arm, col, mode, rebuild=False, imgs=None, retexture=True):
    ob = bpy.data.objects.get(name)
    center_bone = C.bone_rest_world(arm, bone)[:3, 3]
    eye_mats = _materials(EYE_MATS, imgs)
    if ob is not None and ob.type == "MESH" and not rebuild:
        c, r = _sphere_center(C.rest_world(ob))
        dev = float(np.linalg.norm(c - center_bone))
        shift = None
        if dev <= 0.0005:                       # 계약 허용(검증기 skeleton.eye 0.5 mm)
            origin = center_bone
        elif dev <= 0.003:                      # 메시를 뼈 머리(= 계약 눈알 중심)로 옮긴다
            shift = center_bone - c
            origin = center_bone
            C.log("%s 메시 중심을 %s 뼈 머리로 %.2f mm 이동" % (name, bone, dev * 1000))
        else:
            origin = c
            C.REPORT.setdefault("contract_issues", []).append(
                "%s 메시 중심이 %s 뼈 머리와 %.1f mm 떨어짐 — 뼈(=template.json 눈알 중심)와 메시 중 무엇이 맞는지 확인 필요" % (name, bone, dev * 1000))
            C.log("경고:", C.REPORT["contract_issues"][-1])
        to_rigid(ob, arm, bone, origin, mode, shift=shift)
        c = origin
        if not _reorder_eye_slots(ob, c):
            C.log("%s 슬롯이 3개가 아니라 새로 만든다" % name)
            return fix_eye(name, bone, arm, col, mode, rebuild=True, imgs=imgs, retexture=retexture)
        if retexture:
            _eye_uvs_and_materials(ob, c, eye_mats)
            C.log("%s: 홍채·공막 텍스처 머티리얼 적용(UV 다시 씀)" % name)
        return ob, c, r
    V, F, mat, uv = EM.eyeball()
    ob = C.make_mesh_object(name, V, F, col, loop_uv=uv, mat_index=mat)
    for m in eye_mats:
        ob.data.materials.append(m)
    attach(ob, arm, bone, center_bone, mode)
    C.log("%s 생성(정점 %d)" % (name, len(V)))
    return ob, center_bone, EM.EYE_R


# ------------------------------------------------------------------ 입
def _mouth_loop(bust):
    """Bust 커스텀 속성 chosang_patch 의 입 루프(36 정점) — 검증기 measure.mouth 와 같은 정의(루프 평균)."""
    raw = bust.get("chosang_patch")
    if not raw:
        return None
    try:
        d = json.loads(raw) if isinstance(raw, str) else raw.to_dict()
    except Exception:
        return None
    stack = [d]
    while stack:
        x = stack.pop()
        if isinstance(x, dict):
            for k, v in x.items():
                if "mouth" in str(k).lower() and isinstance(v, list) and len(v) == 36 and all(isinstance(i, int) for i in v):
                    return v
                stack.append(v)
        elif isinstance(x, list):
            stack.extend(i for i in x if isinstance(i, (dict, list)))
    return None


def mouth_frame(bust, R):
    lip = C.group_weights(bust, "LipInner") > 0.5
    rig = bust.get("chosang_rig")
    mc = None
    loop = _mouth_loop(bust)
    if loop:
        mc = R["V"][loop].mean(axis=0)
        C.log("입 중심 = chosang_patch 입 루프 36정점 평균", mc.round(4))
    if rig:
        try:
            d = json.loads(rig) if isinstance(rig, str) else dict(rig)
            for k, v in d.items():
                if mc is None and "mouth" in k.lower() and hasattr(v, "__len__") and len(v) == 3:
                    mc = np.array(v, float)
        except Exception:
            pass
    if lip.any():
        L = R["V"][lip]
        if mc is None:
            mc = L.mean(axis=0)
        half_w = float(np.abs(L[:, 0]).max())
        mid = L[np.abs(L[:, 0]) < 0.01]
        lip_back = float((mid if len(mid) else L)[:, 1].max())
    else:
        face = R["V"][C.group_weights(bust, "ARKitFace") > 0.5]
        if mc is None:
            mc = np.array([0.0, float(face[:, 1].min()) + 0.012, float(face[:, 2].min()) + 0.046])
        half_w, lip_back = 0.025, float(mc[1]) + 0.007
    return np.asarray(mc), half_w, lip_back


def jaw_fits(bust, R, mc):
    face = C.group_weights(bust, "ARKitFace") > 0.5
    P = R["V"]
    sel = face & (P[:, 2] < mc[2] - 0.012) & (np.abs(P[:, 0]) < 0.035) & (P[:, 1] < mc[1] + 0.02)
    fits = {}
    for k in JAW_KEYS:
        Kc = C.key_coords(bust, k)
        if Kc is None or sel.sum() < 12:
            continue
        Kw = C.to_world(bust, Kc)
        Rm, t = EM.kabsch(P[sel], Kw[sel])
        resid = np.linalg.norm(P[sel] @ Rm.T + t - Kw[sel], axis=1).mean()
        fits[k] = (Rm, t)
        disp = np.linalg.norm(Kw[sel] - P[sel], axis=1).mean()
        C.log("%s 강체 맞춤: 회전 %.1f°, 턱끝 평균 이동 %.1f mm, 잔차 %.2f mm (정점 %d)"
              % (k, EM.rot_angle_deg(Rm), disp * 1000, resid * 1000, int(sel.sum())))
    if "jawOpen" not in fits:      # Bust 에 키가 없을 때 대체: TMJ 축 회전 18°
        piv = np.array([0.0, mc[1] + 0.075, mc[2] + 0.035])
        a = math.radians(18)
        Rm = np.array([[1, 0, 0], [0, math.cos(a), -math.sin(a)], [0, math.sin(a), math.cos(a)]])
        fits["jawOpen"] = (Rm, piv - Rm @ piv)
        C.log("jawOpen: Bust 키 없음 → TMJ 축 18° 대체")
    for k, d in (("jawLeft", (0.006, 0, 0)), ("jawRight", (-0.006, 0, 0)), ("jawForward", (0, -0.005, 0))):
        fits.setdefault(k, (np.eye(3), np.array(d, float)))
    return fits


def fix_mouth(arm, bust, R, col, mode, rebuild=False, imgs=None, sex="male", protrusion=0.0):
    bone = mouth_bone(arm)
    mc, half_w, lip_back = mouth_frame(bust, R)
    fits = jaw_fits(bust, R, mc)
    ob = bpy.data.objects.get(MOUTH)
    created = False
    if ob is None or ob.type != "MESH" or rebuild:
        V, F, part, mat, jw, tongue, luv, meta = EM.mouth_inner(mc, half_w, lip_back, sex=sex, protrusion=protrusion)
        ob = C.make_mesh_object(MOUTH, V, F, col, loop_uv=luv, mat_index=mat)
        for m in _materials(MOUTH_MATS, imgs):
            ob.data.materials.append(m)
        ob.shape_key_add(name="Basis", from_mix=False)
        created = True
        C.log("Mouth_Inner 생성", meta)
    else:
        if not ob.data.shape_keys:
            ob.shape_key_add(name="Basis", from_mix=False)
        Vw = C.rest_world(ob)
        zmid = mc[2] - 0.0005
        jw = np.clip((zmid - Vw[:, 2]) / 0.004 + 0.5, 0, 1)
        tongue = np.zeros(len(Vw), bool)
        tmat = [i for i, m in enumerate(ob.data.materials) if m and ("tongue" in m.name.lower() or "혀" in m.name)]
        if tmat:
            for p in ob.data.polygons:
                if p.material_index in tmat:
                    tongue[list(p.vertices)] = True
            jw[tongue] = 1.0
    Vw = C.rest_world(ob)
    have = {kb.name for kb in ob.data.shape_keys.key_blocks}
    for k in ALL_KEYS:
        if k in have and not created:
            continue
        kb = ob.data.shape_keys.key_blocks.get(k) or ob.shape_key_add(name=k, from_mix=False)
        if k == "tongueOut":
            Wk = EM.tongue_out(Vw, tongue)
        else:
            Rm, t = fits[k]
            Wk = EM.apply_rigid(Vw, Rm, t, jw)
        Minv = np.linalg.inv(np.array(ob.matrix_world))
        kb.data.foreach_set("co", (Wk @ Minv[:3, :3].T + Minv[:3, 3]).ravel())
        C.log("Mouth_Inner 셰이프키 작성:", k)
    for k in ALL_KEYS:
        if bust.data.shape_keys and k in bust.data.shape_keys.key_blocks:
            C.driver_from_bust(ob, k, bust)
    to_rigid(ob, arm, bone, mc, mode)
    return ob, mc, tongue


# ------------------------------------------------------------------ 검사
def check_eyes(bust, R, eyes):
    lid = C.group_weights(bust, "LidInner") > 0.5
    out = {}
    for name, (ob, c, r) in eyes.items():
        Vw = C.rest_world(ob)
        r_mesh = float(np.max(np.linalg.norm(Vw - c, axis=1)))
        near = lid & (np.linalg.norm(R["V"] - c, axis=1) < 0.02)
        res = {}
        for k in ("Basis",) + EYE_KEYS_CHECK:
            Kc = C.key_coords(bust, k) if k != "Basis" else C.basis_coords(bust)
            if Kc is None or not near.any():
                continue
            Kw = C.to_world(bust, Kc)[near]
            res[k] = round(float((np.linalg.norm(Kw - c, axis=1) - r_mesh).min() * 1000), 2)
        out[name] = {"lid_gap_min_mm": res, "radius_mm": round(r_mesh * 1000, 2),
                     "pass": all(v >= 0.2 for v in res.values()) if res else None}
    return out


def check_mouth(bust, R, ob, tongue):
    lip = C.group_weights(bust, "LipInner") > 0.5
    if not lip.any():
        return {"skipped": "LipInner 그룹 없음"}
    Fl = [f for f in R["F"] if any(lip[i] for i in f)]
    teeth = np.zeros(len(ob.data.vertices), bool)
    tm = [i for i, m in enumerate(ob.data.materials) if m and ("teeth" in m.name.lower() or "tooth" in m.name.lower() or "치아" in m.name)]
    for p in ob.data.polygons:
        if p.material_index in tm:
            teeth[list(p.vertices)] = True
    if not teeth.any():
        teeth[:] = True
    res = {}
    keys = {kb.name for kb in ob.data.shape_keys.key_blocks} if ob.data.shape_keys else set()
    for k in ("Basis",) + MOUTH_KEYS_CHECK:
        Kc = C.basis_coords(bust) if k == "Basis" else C.key_coords(bust, k)
        if Kc is None:
            continue
        Bw = C.to_world(bust, Kc)
        Mw = C.to_world(ob, C.key_coords(ob, k)) if k in keys else C.rest_world(ob)
        sd = C.BVHSurface(Bw, Fl).signed_distances(Mw[teeth], radius=0.006)
        fin = sd[np.isfinite(sd)]
        res[k] = {"min_mm": round(float(fin.min() * 1000), 2) if len(fin) else None, "inside": int((fin < 0).sum())}
    return {"teeth_vs_lips": res, "pass": all(v["inside"] == 0 for v in res.values())}


def run(attach_mode="BONE", rebuild=True, template_dir=None, retexture=True, sex="male", asset_opacity=0.10, colorless=True, mouth_protrusion=0.0):
    """rebuild=True(기본): 눈·입안을 삼각형 고밀도 생성기로 새로 만든다(초상 원본은 백업 .blend). False 면 기존 메시 재사용."""
    bust = C.find_bust()
    arm = C.find_armature(bust)
    old_pp = arm.data.pose_position
    arm.data.pose_position = "REST"
    try:
        bpy.context.view_layer.update()
        info = diagnose()
        R = C.bust_rest(bust)
        imgs = ensure_textures(C.find_template_dir(template_dir))
        col = None
        for name in ("Eye_L", "Eye_R", MOUTH):
            ob = bpy.data.objects.get(name)
            if ob is not None and ob.users_collection:
                col = ob.users_collection[0]
                break
        col = col or C.ensure_collection("Chosang_Template" if "Chosang_Template" in bpy.data.collections else "Template")
        eyes = {}
        for name, bone in EYES:
            if bone not in arm.data.bones:
                C.log("경고: %s 뼈가 없어 Head 에 붙인다" % bone)
                bone = "Head"
            eyes[name] = fix_eye(name, bone, arm, col, attach_mode, rebuild, imgs=imgs, retexture=retexture)
        mouth, mc, tongue = fix_mouth(arm, bust, R, col, attach_mode, rebuild, imgs=imgs, sex=sex, protrusion=mouth_protrusion)
        C.set_props(mouth, coursona_mouth_protrusion=float(mouth_protrusion),
                    coursona_textures={"teeth": "T_Teeth_base.png"})
        for e in ("Eye_L", "Eye_R"):
            C.set_props(eyes[e][0], coursona_textures={"iris": "T_Eye_Iris_base.png", "sclera": "T_Eye_Sclera_base.png"})
        if asset_opacity < 1.0 or colorless:                       # 투명한 틀: 눈·입안도 앱이 이미지 기반으로 입힌다
            for ob in (eyes["Eye_L"][0], eyes["Eye_R"][0], mouth):
                for m in ob.data.materials:
                    if m is not None:
                        C.make_transparent(m, asset_opacity, colorless=colorless)
                C.set_props(ob, coursona_opacity=float(asset_opacity), coursona_colorless=bool(colorless))
        if rebuild:
            C.backup_blend_once()
        head_c = C.bone_rest_world(arm, "Head")[:3, 3] + np.array([0.0, 0.0, 0.09])
        roles = {"M_Eye_Sclera": "sclera", "M_Eye_Iris": "iris", "M_Eye_Pupil": "pupil", "M_Teeth": "teeth",
                 "M_Gum": "gum", "M_Tongue": "tongue", "M_MouthCavity": "cavity"}
        for nm, ob, bone, tex in (("Eye_L", eyes["Eye_L"][0], "Eye_L", {"iris": "T_Eye_Iris_base.png", "sclera": "T_Eye_Sclera_base.png"}),
                                  ("Eye_R", eyes["Eye_R"][0], "Eye_R", {"iris": "T_Eye_Iris_base.png", "sclera": "T_Eye_Sclera_base.png"}),
                                  (MOUTH, mouth, mouth_bone(arm), {"teeth": "T_Teeth_base.png"})):
            Vw = C.rest_world(ob)
            C.add_data_uv(ob, TD.presence(Vw, head_c), TD.height01(Vw))
            thash, ntri, tri_ok = C.topology_hash_of(ob)
            C.manifest_add(nm, {
                "prim": nm, "kind": "eye" if nm.startswith("Eye") else "mouth",
                "attach": {"mode": "rigid", "bone": bone, "blender": attach_mode, "pivot": "오리진 = 눈알 중심 / 입 루프 평균"},
                "material": {"opacity": float(asset_opacity), "colorless": bool(colorless),
                             "slots": [{"name": m.name, "role": roles.get(m.name, m.name)} for m in ob.data.materials if m]},
                "textures": tex, "uvSets": {"UVMap": "uv0 — 눈: 홍채 평면·공막 구면 / 입: 치아 둘레·높이",
                                            "CoursonaData": "uv1 — (presence, height01)"},
                "blendShapes": [k.name for k in ob.data.shape_keys.key_blocks if k.name != "Basis"] if ob.data.shape_keys else [],
                "vertexCount": len(ob.data.vertices), "triangleCount": ntri, "allTriangles": tri_ok, "topologyHash": thash,
                "faceRanges": C.face_ranges_by_material(ob), "splatHost": None,
                "platform": {"iOS": "메시: 사진 투영 또는 폴백 텍스처", "macOS": "메시 유지(스플랫 바인딩 안 함)"}})
        res = {"eyes": check_eyes(bust, R, eyes), "mouth": check_mouth(bust, R, mouth, tongue),
               "names": {n: (bpy.data.objects.get(n) is not None) for n in ("Eye_L", "Eye_R", MOUTH)},
               "slots": {n: [m.name for m in bpy.data.objects[n].data.materials] for n in ("Eye_L", "Eye_R", MOUTH)},
               "mouth_keys": [kb.name for kb in mouth.data.shape_keys.key_blocks]}
        C.REPORT["eyes_mouth"] = res
        C.log("검사", json.dumps(res, ensure_ascii=False))
        return res
    finally:
        arm.data.pose_position = old_pp
