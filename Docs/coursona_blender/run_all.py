"""세 작업을 한 번에: 진단 → 셔츠 → 머리(셔츠·칼라까지 피해서) → 눈·입 → 보고서 → (선택) 내보내기 → (선택) USDZ 검사.

블렌더 쪽 Claude / Python 콘솔:
    import sys; sys.path.insert(0, "/Users/<you>/Desktop/coursona_blender")
    import importlib, run_all; importlib.reload(run_all)
    run_all.main(export=False)          # 먼저 만들고 검사만 → 보고서 확인
    run_all.main(export=True)           # 기존 export_coursona.py 실행(Apply Modifiers OFF 는 그 스크립트 설정) + USDZ 검사

순서 메모: 사용자 요청 번호는 1 머리, 2 셔츠, 3 눈·입이지만, 머리를 셔츠 다음에 만들어야 칼라·어깨와의 간격을
머리 생성 단계에서 같이 잡을 수 있다(강체 머리 vs 스킨 셔츠는 고개 숙임에서 부딪히기 쉽다).
"""
import importlib
import os

import bpy

import coursona_common as C
import hair_texture, hair_geometry, shirt_geometry, eyes_mouth_geometry
import add_hair_long_wave, add_shoulders_shirt, fix_eyes_mouth

for m in (C, hair_texture, hair_geometry, shirt_geometry, eyes_mouth_geometry,
          add_hair_long_wave, add_shoulders_shirt, fix_eyes_mouth):
    importlib.reload(m)


def main(export=False, attach_mode="BONE", template_dir=None, export_script=None, save_blend=True, sex="male",
         asset_opacity=0.10, colorless=True, mouth_protrusion=0.0, skin_carrier=True):
    """sex: 셔츠 칼라·단추 치수와 (생성형) 치아 비율 프리셋 — 머리카락(Hair_long_wave)은 여성 스타일 그대로.
    asset_opacity: 에셋 머티리얼 기본 불투명도(기본 0.10 = 90% 투명). colorless: 색을 빼고 무채색 연회색(기본 True).
    앱이 이미지 기반 페르소나로 색을 입히고 유령 룩(반투명 + 가장자리 블러)으로 합성한다. 형태 확인은 asset_opacity=1.0.
    mouth_protrusion: 입(치열·혀·입안) 전체를 앞으로 미는 양(m, 기본 0). +0.004 면 4 mm 돌출, 앞니도 그만큼 순측으로 기운다.
    skin_carrier: Bust 의 피부(살색) 머티리얼도 같은 무채색·불투명도로 바꾼다 — 머티리얼 값만, 메시·리그·그룹·UV·셰이프키는 그대로.
    (초상 프리비즈 렌더는 맨 흉상 기준이므로 다시 렌더하면 거의 비어 보인다. 원본은 백업 .blend 에 있다.)"""
    C.REPORT.clear()
    C.REPORT["log"] = []
    C.MANIFEST["assets"].clear()
    fix_eyes_mouth.diagnose()
    shirt, shirt_res = add_shoulders_shirt.run(template_dir=template_dir, sex=sex, asset_opacity=asset_opacity, colorless=colorless)
    hair, hair_res = add_hair_long_wave.run(attach_mode=attach_mode, template_dir=template_dir, asset_opacity=asset_opacity, colorless=colorless)
    em_res = fix_eyes_mouth.run(attach_mode=attach_mode, template_dir=template_dir, sex=sex, asset_opacity=asset_opacity,
                                colorless=colorless, mouth_protrusion=mouth_protrusion)
    bust = C.find_bust()
    arm = C.find_armature(bust)
    if skin_carrier:
        changed = []
        for m in bust.data.materials:
            if m is not None:
                C.make_transparent(m, asset_opacity, colorless=colorless)
                changed.append(m.name)
        C.set_props(bust, coursona_opacity=float(asset_opacity), coursona_colorless=bool(colorless))
        C.REPORT["bust_skin_materials"] = changed
        C.log("Bust 피부 머티리얼을 무채색 %.2f 로(메시 불변):" % asset_opacity, changed)
    old = arm.data.pose_position
    arm.data.pose_position = "REST"
    try:
        bpy.context.view_layer.update()
        C.REPORT["hair_vs_shirt"] = C.clearance_report(arm, hair, [shirt], need_rest=0.0015)
    finally:
        arm.data.pose_position = old
    tdir = C.find_template_dir(template_dir)
    summary = {
        "Hair_long_wave": hair_res.get("pass"), "Shoulders_shirt": shirt_res.get("pass"),
        "hair_vs_shirt": C.REPORT["hair_vs_shirt"]["pass"],
        "eyes": {k: v.get("pass") for k, v in em_res["eyes"].items()}, "mouth": em_res["mouth"].get("pass"),
        "library_json": os.path.join(tdir, "library.json"), "asset_opacity": asset_opacity, "colorless": colorless, "sex": sex, "mouth_protrusion": mouth_protrusion,
        "textures": [os.path.join(tdir, "textures", f) for f in
                     (add_hair_long_wave.TEXTURE, add_hair_long_wave.MASK, "T_Eye_Iris_base.png", "T_Eye_Sclera_base.png", "T_Teeth_base.png")],
    }
    C.MANIFEST["bust"] = {"prim": "Bust", "opacity": float(asset_opacity) if skin_carrier else None,
                          "presence": "앱이 bust.mesh 정점으로 같은 식을 계산(Bust 메시·UV 는 건드리지 않음)",
                          "faceContour": "앱이 트루뎁스 정점으로 만든다(블렌더 패치는 계약 위치 그대로)"}
    summary["manifest"] = C.write_manifest(tdir)
    C.REPORT["summary"] = summary
    C.log("요약", summary)
    if save_blend and bpy.data.filepath:
        bpy.ops.wm.save_mainfile()
        C.log("저장:", bpy.data.filepath)
    if export:
        script = C.find_export_script(export_script)
        if C.run_export(script):
            usdz = os.path.join(tdir, "Template.usdz")
            if os.path.isfile(usdz):
                try:
                    import inspect_usdz
                    importlib.reload(inspect_usdz)
                    C.REPORT["usdz"] = inspect_usdz.inspect(usdz, verbose=False)
                    C.log("USDZ 문제:", C.REPORT["usdz"]["problems"] or "없음")
                except Exception as e:  # pxr 없는 빌드
                    C.log("USDZ 검사 건너뜀:", e)
    C.write_report(os.path.join(tdir, "coursona_build_report.json"))
    changed = [os.path.join(tdir, "Template.usdz") + (" (내보냄)" if export else " (아직 안 내보냄)"),
               *summary["textures"], summary["library_json"]]
    C.log("바뀐 파일:", changed)
    return summary
