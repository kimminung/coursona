"""내보낸 Template.usdz / EyesMouth.usdz 검사 — 블렌더 내장 파이썬(pxr 포함)이나 USD 가 설치된 파이썬에서 실행.

    import sys; sys.path.insert(0, "/Users/<you>/Desktop/coursona_blender")
    import inspect_usdz as I; I.inspect("/path/to/Template.usdz")

확인 항목
  1. 이름 프림: Hair_long_wave, Shoulders_shirt, Eye_L, Eye_R, Mouth_Inner 가 '프림'으로 존재(조인트 이름만이면 실패)
  2. 강체 에셋(Hair·Eye·Mouth)은 스킨 바인딩 없음, SkelRoot 밖이면 '분리 엔티티 보장'으로 표시
  3. Shoulders_shirt 는 스킨 바인딩 + 조인트에 Root·Neck 포함
  4. Mouth_Inner 블렌드셰이프 5개 이름, Eye 머티리얼 하위집합 순서(공막·홍채·동공)
"""
from pxr import Usd, UsdGeom, UsdSkel, UsdShade

RIGID = ("Hair_long_wave", "Eye_L", "Eye_R", "Mouth_Inner")
MOUTH_KEYS = ("jawOpen", "jawLeft", "jawRight", "jawForward", "tongueOut")


def _skelroot(prim):
    p = prim.GetParent()
    while p and p.IsValid() and not p.IsPseudoRoot():
        if p.IsA(UsdSkel.Root):
            return p
        p = p.GetParent()
    return None


def _mesh_under(prim):
    if prim.IsA(UsdGeom.Mesh):
        return prim
    for c in Usd.PrimRange(prim):
        if c.IsA(UsdGeom.Mesh):
            return c
    return None


def inspect(path, verbose=True):
    stage = Usd.Stage.Open(path)
    report = {"file": path, "skeletons": {}, "assets": {}, "problems": []}
    for prim in stage.Traverse():
        if prim.IsA(UsdSkel.Skeleton):
            joints = UsdSkel.Skeleton(prim).GetJointsAttr().Get() or []
            report["skeletons"][str(prim.GetPath())] = [str(j).split("/")[-1] for j in joints]
    names = {}
    for prim in stage.Traverse():
        names.setdefault(prim.GetName(), []).append(prim)
    for n in RIGID + ("Shoulders_shirt",):
        prims = names.get(n, [])
        if not prims:
            report["assets"][n] = {"found": False}
            report["problems"].append("%s: 프림 없음(조인트 이름만 있거나 내보내기에서 빠짐)" % n)
            continue
        prim = prims[0]
        mesh = _mesh_under(prim)
        d = {"found": True, "path": str(prim.GetPath()), "type": prim.GetTypeName(),
             "under_skelroot": bool(_skelroot(prim)), "mesh": str(mesh.GetPath()) if mesh else None}
        if mesh:
            m = UsdGeom.Mesh(mesh)
            d["points"] = len(m.GetPointsAttr().Get() or [])
            d["faces"] = len(m.GetFaceVertexCountsAttr().Get() or [])
            bind = UsdSkel.BindingAPI(mesh)
            joints = bind.GetJointsAttr().Get() if bind.GetJointsAttr() else None
            skel = bind.GetSkeletonRel().GetTargets() if bind.GetSkeletonRel() else []
            try:
                has_w = bind.GetJointIndicesPrimvar().IsDefined()
            except Exception:
                has_w = False
            d["skeleton"] = [str(t) for t in skel]
            d["skinned"] = bool(has_w)          # 조인트 영향(가중치)이 있어야 '스킨'. 블렌드셰이프만 있으면 False
            d["skin_joints"] = [str(j).split("/")[-1] for j in (joints or [])]
            bs = bind.GetBlendShapesAttr().Get() if bind.GetBlendShapesAttr() else None
            d["blendshapes"] = list(bs or [])
            subsets = UsdGeom.Subset.GetAllGeomSubsets(m)
            mats = []
            for sub in subsets:
                mb = UsdShade.MaterialBindingAPI(sub.GetPrim()).ComputeBoundMaterial()[0]
                mats.append(mb.GetPrim().GetName() if mb else None)
            if not mats:
                mb = UsdShade.MaterialBindingAPI(mesh).ComputeBoundMaterial()[0]
                mats = [mb.GetPrim().GetName()] if mb else []
            d["materials"] = mats
            props = {}
            for p in (prim, mesh):
                for a in p.GetAttributes():
                    if "coursona_" in a.GetName():
                        props[a.GetName().split(":")[-1]] = a.Get()
            d["userProperties"] = props
        report["assets"][n] = d
        if n in RIGID and d.get("skinned"):
            report["problems"].append("%s: 스킨 바인딩이 남아 있음 → RealityKit 이 스켈레톤 엔티티에 합칠 수 있음" % n)
        if n in RIGID and d.get("under_skelroot"):
            report["problems"].append("%s: SkelRoot 아래 정적 프림 — 앱에서 findEntity 로 잡히는지 확인, 안 되면 attach_mode='CHILD_OF'" % n)
        if n == "Shoulders_shirt" and not ({"Root", "Neck"} <= set(d.get("skin_joints") or [])):
            report["problems"].append("Shoulders_shirt: 스킨 조인트에 Root·Neck 이 없음 %s" % d.get("skin_joints"))
        if n == "Mouth_Inner" and not set(MOUTH_KEYS) <= set(d.get("blendshapes") or []):
            report["problems"].append("Mouth_Inner: 블렌드셰이프 누락 %s" % sorted(set(MOUTH_KEYS) - set(d.get("blendshapes") or [])))
    if verbose:
        import json
        print(json.dumps(report, ensure_ascii=False, indent=2, default=str))
    return report
