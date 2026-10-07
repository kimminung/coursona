"""작업 1 — Hair_long_wave (긴 웨이브 진갈색, 어깨 위 1.8 cm 에서 끝남, Head 뼈 강체 고정, 회색+알파 틴트 텍스처).

실행(블렌더 Python 콘솔 또는 MCP execute):
    import sys; sys.path.insert(0, "/Users/<you>/Desktop/coursona_blender")
    import importlib, add_hair_long_wave as T; importlib.reload(T); T.run()

옵션: T.run(attach="BONE" | "CHILD_OF" | "ORIGIN", params={...}, template_dir=None, write_library=True)
  BONE     — Head 뼈 부모(parent_type BONE). 계약 기본값.
  CHILD_OF — 오브젝트 부모 없음 + Child Of(Head) 컨스트레인트. USD 에서 SkelRoot 밖 정적 프림으로 나간다.
  ORIGIN   — 부모 없음, 오리진만 Head 뼈 머리 위치.
  SKIN_HEAD — (대안) Armature 부모 + Head 그룹 100% + Armature 모디파이어. 초상 hair.py 방식.
             앱이 강체 부착을 아직 못 할 때 스켈레톤을 따라 자동으로 움직이게 하는 비상 경로(계약 기본값 아님).
주의: 검증기 hairStyles 에 long_wave 가 있어 초상 .blend 에는 Hair_long_wave 가 이미 있을 가능성이 높다.
      run() 은 .blend 사본을 먼저 저장하고 같은 이름으로 교체한다(계약상 이름은 바꾸면 안 됨).
"""
import os
import shutil

import bpy
import numpy as np
from mathutils import Matrix, Vector

import coursona_common as C
import hair_geometry as HG
import hair_texture as HT
import tech_data as TD

NAME = "Hair_long_wave"
COLLECTION = "Library_Hair"
MATERIAL = "M_Hair_LongWave"
TEXTURE = "T_Hair_LongWave_base.png"
MASK = "T_Hair_LongWave_mask.png"       # R 뿌리→끝, G 가닥 id, B 하이라이트(초상 _mask 규약) — 앱 선택 사용
HERE = os.path.dirname(os.path.abspath(__file__))


def scalp_submesh(bust, R):
    w = C.group_weights(bust, "Scalp")
    if not (w > 0.5).any():
        raise RuntimeError("Bust 에 Scalp 버텍스 그룹이 없거나 비어 있다")
    inside = w > 0.5
    faces = [f for f in R["F"] if all(inside[i] for i in f)]
    used = sorted({i for f in faces for i in f})
    remap = {v: k for k, v in enumerate(used)}
    sf = [tuple(remap[i] for i in f) for f in faces]
    edge = {}
    for f in sf:
        for a, b in zip(f, f[1:] + f[:1]):
            k = (min(a, b), max(a, b))
            edge[k] = edge.get(k, 0) + 1
    boundary = np.zeros(len(used), bool)
    for (a, b), c in edge.items():
        if c == 1:
            boundary[a] = boundary[b] = True
    return dict(v=R["V"][used], n=R["N"][used], faces=sf, boundary=boundary)


def head_frame(bust, arm, R, scalp):
    face_w = C.group_weights(bust, "ARKitFace")
    patch = R["V"][face_w > 0.5] if (face_w > 0.5).sum() >= 600 else R["V"][:1220]
    chin_z = float(patch[:, 2].min())
    crown_z = float(scalp["v"][:, 2].max())
    ys = np.concatenate([patch[:, 1], scalp["v"][:, 1]])
    head_c = np.array([0.0, float((ys.min() + ys.max()) / 2), (chin_z + crown_z) / 2])
    eyes = [b for b in ("Eye_L", "Eye_R") if b in arm.data.bones]
    if eyes:
        brow_z = float(np.mean([C.bone_rest_world(arm, b)[2, 3] for b in eyes])) + 0.022
    else:
        brow_z = chin_z + 0.55 * (float(patch[:, 2].max()) - chin_z)
    return patch, head_c, chin_z, brow_z


def ensure_texture(template_dir):
    tex_dir = os.path.join(template_dir, "textures")
    os.makedirs(tex_dir, exist_ok=True)
    dst = os.path.join(tex_dir, TEXTURE)
    src = os.path.join(HERE, "textures", TEXTURE)
    if os.path.isfile(src):
        shutil.copyfile(src, dst)
        C.log("텍스처 복사:", dst)
    elif not os.path.isfile(dst):
        C.log("패키지 텍스처가 없어 블렌더에서 생성(약 20초)")
        HT.save_png_bpy(HT.generate(), dst, name=os.path.splitext(TEXTURE)[0])
    msrc, mdst = os.path.join(HERE, "textures", MASK), os.path.join(tex_dir, MASK)
    if os.path.isfile(msrc):
        shutil.copyfile(msrc, mdst)
    elif not os.path.isfile(mdst):
        HT.save_png_bpy(HT.generate(mode="mask"), mdst, name=os.path.splitext(MASK)[0])
    img = bpy.data.images.get(TEXTURE) or bpy.data.images.load(dst, check_existing=True)
    img.name = TEXTURE
    img.filepath = bpy.path.relpath(dst) if bpy.data.filepath else dst
    img.colorspace_settings.name = "sRGB"
    img.alpha_mode = "STRAIGHT"
    if img.packed_file:
        img.unpack(method="REMOVE")
    img.reload()
    return img


def ensure_material(img):
    mat = bpy.data.materials.get(MATERIAL) or bpy.data.materials.new(MATERIAL)
    bsdf = C.principled(mat)
    nt = mat.node_tree
    tex = nt.nodes.get("HairBase") or nt.nodes.new("ShaderNodeTexImage")
    tex.name = tex.label = "HairBase"
    tex.image = img
    tex.location = (-420, 120)
    for l in list(nt.links):
        if l.to_node == bsdf and l.to_socket.name in ("Base Color", "Alpha"):
            nt.links.remove(l)
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    nt.links.new(tex.outputs["Alpha"], bsdf.inputs["Alpha"])
    C.set_input(bsdf, ["Roughness"], 0.45)
    C.set_input(bsdf, ["Specular IOR Level", "Specular"], 0.35)
    C.set_input(bsdf, ["Metallic"], 0.0)
    if hasattr(mat, "surface_render_method"):
        mat.surface_render_method = "DITHERED"
    if hasattr(mat, "blend_method"):
        try:
            mat.blend_method = "HASHED"
        except Exception:
            pass
    mat.use_backface_culling = False
    mat.diffuse_color = (0.35, 0.24, 0.17, 1.0)   # 뷰포트 단색 미리보기(진갈색)
    return mat


def attach(ob, arm, head_world, mode):
    ob.constraints.clear()
    if mode == "BONE":
        ob.parent = arm
        ob.parent_type = "BONE"
        ob.parent_bone = "Head"
        ob.matrix_parent_inverse = Matrix.Identity(4)
        bpy.context.view_layer.update()
        ob.matrix_world = Matrix.Translation(Vector(tuple(map(float, head_world))))
    elif mode == "CHILD_OF":
        ob.parent = None
        ob.matrix_world = Matrix.Translation(Vector(tuple(map(float, head_world))))
        con = ob.constraints.new("CHILD_OF")
        con.target = arm
        con.subtarget = "Head"
        bpy.context.view_layer.update()
        pb = arm.pose.bones["Head"]
        con.inverse_matrix = (arm.matrix_world @ pb.matrix).inverted()
    elif mode == "SKIN_HEAD":
        ob.parent = arm
        ob.parent_type = "OBJECT"
        ob.matrix_parent_inverse = Matrix.Identity(4)
        bpy.context.view_layer.update()
        ob.matrix_world = Matrix.Translation(Vector(tuple(map(float, head_world))))
        vg = ob.vertex_groups.get("Head") or ob.vertex_groups.new(name="Head")
        vg.add(list(range(len(ob.data.vertices))), 1.0, "REPLACE")
        mod = ob.modifiers.new("Armature", "ARMATURE")
        mod.object = arm
    else:
        ob.parent = None
        ob.matrix_world = Matrix.Translation(Vector(tuple(map(float, head_world))))
    bpy.context.view_layer.update()


def check(ob, bust, arm, R, n_cap, refs):
    """레스트·포즈 7종 관통 검사. 기준: 캡 ≥ 0.9 mm, 카드 ≥ 1.4 mm(레스트), 포즈에서 관통 0, 삼각형 교차 0."""
    n = len(ob.data.vertices)
    cap = np.zeros(n, bool)
    cap[:n_cap] = True
    res = {"cap": C.clearance_report(arm, ob, refs, need_rest=0.0009, test_mask=cap),
           "cards": C.clearance_report(arm, ob, refs, need_rest=0.0014, test_mask=~cap)}
    Hw = C.rest_world(ob)
    res["rest_triangle_overlaps_with_bust"] = C.overlap_count(Hw, C.polygons(ob.data), R["V"], R["F"])
    res["pass"] = res["cap"]["pass"] and res["cards"]["pass"] and res["rest_triangle_overlaps_with_bust"] == 0
    return res


def run(attach_mode="BONE", params=None, template_dir=None, write_library=True, asset_opacity=0.10, colorless=True):
    """asset_opacity: 머티리얼 기본 불투명도. 0 = 투명한 틀(기본, 앱이 이미지 기반으로 입힘), 1 = 블렌더 확인용."""
    bust = C.find_bust()
    arm = C.find_armature(bust)
    old_pp = arm.data.pose_position
    arm.data.pose_position = "REST"
    try:
        R = C.bust_rest(bust)
        scalp = scalp_submesh(bust, R)
        patch, head_c, chin_z, brow_z = head_frame(bust, arm, R, scalp)
        C.log("머리 중심", head_c.round(4), "턱", round(chin_z, 4), "눈썹", round(brow_z, 4),
              "두피 정점", len(scalp["v"]))
        shirt = bpy.data.objects.get("Shoulders_shirt")
        refs = [bust] + ([shirt] if shirt is not None and shirt.type == "MESH" else [])
        if len(refs) > 1:
            C.log("Shoulders_shirt 가 있어 칼라·어깨까지 포함해 간격을 잡는다")
        surf = C.union_surface(refs)
        hair = HG.build_hair(scalp, patch, surf, head_c, chin_z, brow_z, params=params, log=C.log)
        head_world = C.bone_rest_world(arm, "Head")[:3, 3]
        C.backup_blend_once()
        C.record_existing(NAME)
        col = C.ensure_collection(COLLECTION)
        ob = C.make_mesh_object(NAME, hair["verts"] - head_world, hair["faces"], col, loop_uv=hair["loop_uv"])
        attach(ob, arm, head_world, attach_mode)
        tdir = C.find_template_dir(template_dir)
        img = ensure_texture(tdir)
        mat = ensure_material(img)
        if asset_opacity < 1.0 or colorless:
            C.make_transparent(mat, asset_opacity, colorless=colorless)
        ob.data.materials.clear()
        ob.data.materials.append(mat)
        C.set_contract_props(ob, kind="hair", bone="Head", tint=True, textures={"base": TEXTURE, "mask": MASK})
        C.set_props(ob, coursona_attach=attach_mode, coursona_opacity=float(asset_opacity), coursona_colorless=bool(colorless),
                    coursona_silhouette="alpha:" + TEXTURE)   # 앱: 실루엣 = base 텍스처 알파 채널
        # 테크 데이터: uv1 = (presence, height01), 면 구간, 위상 해시
        Vw = C.rest_world(ob)
        C.add_data_uv(ob, TD.presence(Vw, head_c), TD.height01(Vw))
        ranges = TD.face_ranges(hair["face_layer"])
        thash, ntri, _ = C.topology_hash_of(ob)
        # 스플랫 호스트(맥): 머리 볼륨 셸 3겹 — 블렌더에는 내보내기 제외 컬렉션에 두고, 앱에는 JSON 으로 준다
        shell = HG.build_shell(hair["strands"], surf, head_c, log=C.log)
        hcol = C.hidden_collection()
        hname = "SplatHost_" + NAME
        host = C.make_mesh_object(hname, shell["verts"] - head_world, shell["faces"], hcol,
                                  loop_uv=[[tuple(shell["uv"][i]) for i in f] for f in shell["faces"]])
        attach(host, arm, head_world, "BONE" if attach_mode in ("BONE", "SKIN_HEAD") else attach_mode)
        host_hash = TD.topology_hash(len(shell["verts"]), shell["faces"])
        host_rel = "hosts/%s.json" % hname
        tdir = C.find_template_dir(template_dir)
        C.write_json(os.path.join(tdir, host_rel), {
            "name": hname, "for": NAME, "bone": "Head", "coords": "usd(template, rest)",
            "headJointRest": TD.to_usd(head_world[None])[0].round(6),
            "vertexCount": len(shell["verts"]), "triangleCount": len(shell["faces"]), "topologyHash": host_hash,
            "layers": len(set(shell["layer"].tolist())),
            "positions": TD.to_usd(shell["verts"]).round(6).ravel(), "normals": TD.to_usd(shell["normal"]).round(4).ravel(),
            "flow": TD.to_usd(shell["flow"]).round(4).ravel(), "uv": shell["uv"].round(5).ravel(),
            "layer": shell["layer"], "triangles": np.asarray(shell["faces"]).ravel()})
        res = check(ob, bust, arm, R, len(scalp["v"]), refs)
        C.REPORT[NAME] = dict(stats=hair["stats"], check=res, attach=attach_mode)
        C.log("검사", res)
        entry = {"name": NAME, "kind": "hair", "bone": "Head", "tintable": True,
                 "vertexCount": len(ob.data.vertices), "faceCount": len(ob.data.polygons),
                 "triangleCount": ntri, "topologyHash": thash,
                 "materials": [m.name for m in ob.data.materials], "textures": {"base": TEXTURE, "mask": MASK}}
        C.manifest_add(NAME, {
            "prim": NAME, "kind": "hair", "attach": {"mode": "rigid", "bone": "Head", "blender": attach_mode},
            "material": {"opacity": float(asset_opacity), "colorless": bool(colorless),
                         "slots": [{"name": m.name, "role": "hair"} for m in ob.data.materials]},
            "textures": {"base": TEXTURE, "mask": MASK}, "silhouette": "textures.base alpha (opacity mask, threshold 0.45, 양면)",
            "uvSets": {"UVMap": "uv0 — 가닥 아틀라스(카드끼리 겹침, 사진 투영 불가)", "CoursonaData": "uv1 — (presence, height01)"},
            "vertexCount": len(ob.data.vertices), "triangleCount": ntri, "topologyHash": thash, "faceRanges": ranges,
            "splatHost": host_rel, "splatHostHash": host_hash,
            "platform": {"iOS": "메시 틀: 사진 머리색 틴트 + 실루엣 알파 + presence", "macOS": "스플랫을 splatHost 에 바인딩, 카드 메시는 숨김"}})
        if write_library:
            C.update_library_json(os.path.join(tdir, "library.json"), entry)
        C.REPORT.setdefault("library", {})[NAME] = entry
        return ob, res
    finally:
        arm.data.pose_position = old_pp
