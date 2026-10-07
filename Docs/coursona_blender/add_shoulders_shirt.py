"""작업 2 — Shoulders_shirt (짙은 네이비 카라 셔츠, Root·Neck 스킨, 단색 PBR).

실행:
    import sys; sys.path.insert(0, "/Users/<you>/Desktop/coursona_blender")
    import importlib, add_shoulders_shirt as S; importlib.reload(S); S.run()

가중치: 몸판·접기 정점은 원본 Bust 정점의 Root·Neck 값을 그대로, 칼라 정점은 가장 가까운 Bust 면에서 보간.
        두 그룹 합이 1 이 되게 정규화(둘 다 0 이면 Root 1). 'Weight Paint > Transfer Weights(Nearest Face
        Interpolated, Root·Neck 만)' 과 같은 결과를 스크립트로 결정적으로 만든다.
"""
import os

import bpy
import numpy as np
from mathutils import Matrix, Vector

import coursona_common as C
import shirt_geometry as SG
import tech_data as TD

NAME = "Shoulders_shirt"
COLLECTION = "Library_Shoulders"
MATERIAL = "M_Shirt_Navy"
NAVY_SRGB = (0x1E / 255, 0x2A / 255, 0x44 / 255)
BUTTON_MATERIAL = "M_Shirt_Button"
BUTTON_SRGB = (0x15 / 255, 0x1A / 255, 0x26 / 255)
SKIN = ("Root", "Neck")


def region_mask(bust, R, arm):
    w = C.group_weights(bust, "Shoulders")
    if (w > 0.5).sum() > 50:
        return w > 0.5
    z_seam = C.bone_rest_world(arm, "Neck")[2, 3] - 0.035 if "Neck" in arm.data.bones else 0.265
    C.log("Shoulders 그룹이 없어 높이로 대체: z <", round(float(z_seam), 4))
    return R["V"][:, 2] < z_seam


def skin_weights(bust, R, shirt, surf):
    wR = C.group_weights(bust, "Root")
    wN = C.group_weights(bust, "Neck")
    n = len(shirt["verts"])
    out = np.zeros((n, 2))
    for i in range(n):
        s = shirt["src"][i]
        if s >= 0:
            out[i] = (wR[s], wN[s])
            continue
        loc, nrm, fi, dist = surf.bvh.find_nearest(Vector(shirt["verts"][i]))
        f = R["F"][fi]
        d = np.linalg.norm(R["V"][list(f)] - np.array(loc), axis=1)
        k = 1.0 / np.maximum(d, 1e-5)
        k /= k.sum()
        out[i] = (float(np.dot(k, wR[list(f)])), float(np.dot(k, wN[list(f)])))
    tot = out.sum(axis=1)
    zero = tot < 1e-6
    out[zero] = (1.0, 0.0)
    out[~zero] /= tot[~zero, None]
    return out


def ensure_material():
    mat = bpy.data.materials.get(MATERIAL) or bpy.data.materials.new(MATERIAL)
    bsdf = C.principled(mat)
    lin = C.srgb_to_linear(NAVY_SRGB)
    C.set_input(bsdf, ["Base Color"], (float(lin[0]), float(lin[1]), float(lin[2]), 1.0))
    C.set_input(bsdf, ["Roughness"], 0.82)
    C.set_input(bsdf, ["Specular IOR Level", "Specular"], 0.30)
    C.set_input(bsdf, ["Metallic"], 0.0)
    C.set_input(bsdf, ["Sheen Weight", "Sheen"], 0.25)       # 블렌더 미리보기용(USD 프리뷰 서피스에는 안 나감)
    mat.diffuse_color = (*NAVY_SRGB, 1.0)
    btn = bpy.data.materials.get(BUTTON_MATERIAL) or bpy.data.materials.new(BUTTON_MATERIAL)
    b2 = C.principled(btn)
    lin2 = C.srgb_to_linear(BUTTON_SRGB)
    C.set_input(b2, ["Base Color"], (float(lin2[0]), float(lin2[1]), float(lin2[2]), 1.0))
    C.set_input(b2, ["Roughness"], 0.30)
    C.set_input(b2, ["Specular IOR Level", "Specular"], 0.5)
    btn.diffuse_color = (*BUTTON_SRGB, 1.0)
    return mat, btn


def run(params=None, template_dir=None, write_library=True, sex="male", asset_opacity=0.10, colorless=True):
    bust = C.find_bust()
    arm = C.find_armature(bust)
    old_pp = arm.data.pose_position
    arm.data.pose_position = "REST"
    try:
        bpy.context.view_layer.update()
        R = C.bust_rest(bust)
        mask = region_mask(bust, R, arm)
        surf = C.BVHSurface(R["V"], R["F"])
        shirt = SG.build_shirt(R["V"], R["F"], R["N"], mask, surf, params=params, log=C.log, sex=sex)
        Minv = np.linalg.inv(np.array(arm.matrix_world))
        Vloc = shirt["verts"] @ Minv[:3, :3].T + Minv[:3, 3]
        C.backup_blend_once()
        C.record_existing(NAME)       # 검증기 requiredLibrary 에 Shoulders_shirt 가 있어 이미 있을 수 있다
        col = C.ensure_collection(COLLECTION)
        ob = C.make_mesh_object(NAME, Vloc, shirt["faces"], col, loop_uv=shirt["loop_uv"], mat_index=shirt["mat_index"])
        ob.parent = arm
        ob.parent_type = "OBJECT"
        ob.matrix_parent_inverse = Matrix.Identity(4)
        ob.matrix_basis = Matrix.Identity(4)
        W = skin_weights(bust, R, shirt, surf)
        for j, g in enumerate(SKIN):
            vg = ob.vertex_groups.new(name=g)
            for i in range(len(W)):
                if W[i, j] > 0:
                    vg.add([i], float(W[i, j]), "REPLACE")
        src_mod = next((m for m in bust.modifiers if m.type == "ARMATURE"), None)
        mod = ob.modifiers.new("Armature", "ARMATURE")
        mod.object = arm
        mod.use_vertex_groups = True
        mod.use_bone_envelopes = False
        if src_mod is not None:
            mod.use_deform_preserve_volume = src_mod.use_deform_preserve_volume
        mat, btn = ensure_material()
        if asset_opacity < 1.0 or colorless:
            C.make_transparent(mat, asset_opacity, colorless=colorless)
            C.make_transparent(btn, asset_opacity, colorless=colorless)
        ob.data.materials.clear()
        ob.data.materials.append(mat)
        ob.data.materials.append(btn)
        C.set_props(ob, coursona_opacity=float(asset_opacity), coursona_colorless=bool(colorless))
        C.set_contract_props(ob, kind="shoulders", bone="Root", tint=False, skin_groups=list(SKIN))
        bpy.context.view_layer.update()
        Vw = C.rest_world(ob)
        head_c = C.bone_rest_world(arm, "Head")[:3, 3] + np.array([0.0, 0.0, 0.09])
        C.add_data_uv(ob, TD.presence(Vw, head_c), TD.height01(Vw))
        thash, ntri, _ = C.topology_hash_of(ob)
        ranges = TD.face_ranges(shirt["face_kind"])
        collar = shirt["kind"] == 2
        res = {"body": C.clearance_report(arm, ob, [bust], need_rest=0.0018, test_mask=~collar),
               "collar": C.clearance_report(arm, ob, [bust], need_rest=0.0028, test_mask=collar),
               "buttons": int((shirt["kind"] == 4).sum() // (2 * SG.DEFAULTS["button_seg"] + 1)),
               "weights": {"root_mean": float(W[:, 0].mean()), "neck_max": float(W[:, 1].max())}}
        res["pass"] = res["body"]["pass"] and res["collar"]["pass"]
        C.REPORT[NAME] = dict(stats=shirt["stats"], check=res)
        C.log("검사", res)
        tdir = C.find_template_dir(template_dir)
        entry = {"name": NAME, "kind": "shoulders", "bone": "Root", "tintable": False,
                 "vertexCount": len(ob.data.vertices), "faceCount": len(ob.data.polygons),
                 "triangleCount": ntri, "topologyHash": thash,
                 "materials": [m.name for m in ob.data.materials], "skinGroups": list(SKIN)}
        C.manifest_add(NAME, {
            "prim": NAME, "kind": "shoulders", "attach": {"mode": "skin", "joints": list(SKIN)},
            "material": {"opacity": float(asset_opacity), "colorless": bool(colorless),
                         "slots": [{"name": ob.data.materials[0].name, "role": "cloth"},
                                   {"name": ob.data.materials[1].name, "role": "buttons"}]},
            "uvSets": {"UVMap": "uv0 — u 둘레 각도(정면 0.5), v 높이(0 아래 끝 → 1 칼라 위)", "CoursonaData": "uv1 — (presence, height01)"},
            "vertexCount": len(ob.data.vertices), "triangleCount": ntri, "topologyHash": thash, "faceRanges": ranges,
            "splatHost": "self(body·collar 구간)",
            "platform": {"iOS": "메시 틀: 어깨 사진 평균색 + presence + 하단 페이드", "macOS": "body·collar 구간에 스플랫 바인딩, 단추는 메시로"}})
        if write_library:
            C.update_library_json(os.path.join(tdir, "library.json"), entry)
        C.REPORT.setdefault("library", {})[NAME] = entry
        return ob, res
    finally:
        arm.data.pose_position = old_pp
