"""
FBX 파츠 분리 유틸리티

하나의 FBX 파일에 포함된 여러 메시 오브젝트(상의, 하의, 무기, 악세서리 등)를
개별 FBX 파일로 분리하고, 분리 전/후 렌더링 이미지를 저장합니다.

Usage:
    # 단일 파일
    blender --background --python split_fbx.py -- \
        --input /path/to/model.fbx \
        --output /path/to/output/ \
        --min-vertices 100

    # 배치 (디렉토리)
    blender --background --python split_fbx.py -- \
        --input /path/to/directory/ \
        --output /path/to/output/ \
        --min-vertices 100 \
        --report split_report.csv
"""

import bpy
import argparse
import os
import csv
import sys
import math
from mathutils import Vector


# ---------------------------------------------------------------------------
# 씬 유틸리티
# ---------------------------------------------------------------------------

def clear_scene():
    """씬의 모든 오브젝트를 삭제하여 초기화한다."""
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)
    for block_collection in (
        bpy.data.meshes,
        bpy.data.materials,
        bpy.data.textures,
        bpy.data.images,
        bpy.data.armatures,
        bpy.data.cameras,
        bpy.data.lights,
    ):
        for block in block_collection:
            if block.users == 0:
                block_collection.remove(block)


def load_fbx(filepath):
    """FBX 파일을 로드하고 메시 오브젝트 리스트를 반환한다."""
    bpy.ops.import_scene.fbx(filepath=filepath)
    meshes = [obj for obj in bpy.context.scene.objects if obj.type == 'MESH']
    return meshes


def get_mesh_info(obj):
    """메시 오브젝트의 버텍스 수와 바운딩박스 크기를 반환한다."""
    mesh = obj.data
    vertex_count = len(mesh.vertices)

    bbox_corners = [obj.matrix_world @ Vector(corner) for corner in obj.bound_box]
    xs = [c.x for c in bbox_corners]
    ys = [c.y for c in bbox_corners]
    zs = [c.z for c in bbox_corners]

    size_x = max(xs) - min(xs)
    size_y = max(ys) - min(ys)
    size_z = max(zs) - min(zs)
    volume = size_x * size_y * size_z

    return {
        'name': obj.name,
        'vertex_count': vertex_count,
        'bbox_size': (round(size_x, 4), round(size_y, 4), round(size_z, 4)),
        'bbox_volume': round(volume, 6),
    }


# ---------------------------------------------------------------------------
# 렌더링
# ---------------------------------------------------------------------------

def setup_render_scene(resolution=512):
    """렌더링용 씬 설정 (EEVEE, 배경 투명)."""
    scene = bpy.context.scene
    scene.render.engine = 'BLENDER_EEVEE'
    scene.render.resolution_x = resolution
    scene.render.resolution_y = resolution
    scene.render.film_transparent = True
    scene.render.image_settings.file_format = 'PNG'
    scene.render.image_settings.color_mode = 'RGBA'


def get_scene_bounds(objects):
    """오브젝트 리스트의 전체 바운딩박스 중심과 크기를 구한다."""
    all_coords = []
    for obj in objects:
        if obj.type == 'MESH':
            for corner in obj.bound_box:
                all_coords.append(obj.matrix_world @ Vector(corner))

    if not all_coords:
        return Vector((0, 0, 0)), 1.0

    xs = [c.x for c in all_coords]
    ys = [c.y for c in all_coords]
    zs = [c.z for c in all_coords]

    center = Vector((
        (min(xs) + max(xs)) / 2,
        (min(ys) + max(ys)) / 2,
        (min(zs) + max(zs)) / 2,
    ))
    size = max(max(xs) - min(xs), max(ys) - min(ys), max(zs) - min(zs), 0.001)
    return center, size


def setup_camera_and_light(center, size):
    """카메라와 조명을 대상 오브젝트에 맞춰 배치한다."""
    # 기존 카메라/조명 제거
    for obj in list(bpy.data.objects):
        if obj.type in ('CAMERA', 'LIGHT'):
            bpy.data.objects.remove(obj, do_unlink=True)

    # 카메라 생성 — 대각선 45도 위에서 바라보기
    cam_data = bpy.data.cameras.new('RenderCam')
    cam_data.type = 'PERSP'
    cam_data.lens = 50
    cam_obj = bpy.data.objects.new('RenderCam', cam_data)
    bpy.context.scene.collection.objects.link(cam_obj)
    bpy.context.scene.camera = cam_obj

    distance = size * 2.0
    angle = math.radians(30)
    cam_obj.location = (
        center.x + distance * math.cos(angle),
        center.y - distance * math.cos(angle),
        center.z + distance * math.sin(angle),
    )

    direction = center - cam_obj.location
    rot_quat = direction.to_track_quat('-Z', 'Y')
    cam_obj.rotation_euler = rot_quat.to_euler()

    # 조명 — Sun
    light_data = bpy.data.lights.new('RenderLight', type='SUN')
    light_data.energy = 3.0
    light_obj = bpy.data.objects.new('RenderLight', light_data)
    bpy.context.scene.collection.objects.link(light_obj)
    light_obj.location = (center.x, center.y, center.z + size * 3)
    light_obj.rotation_euler = (math.radians(30), 0, math.radians(30))


def render_to_file(output_path):
    """현재 씬을 렌더링하여 파일로 저장한다."""
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    bpy.context.scene.render.filepath = output_path
    bpy.ops.render.render(write_still=True)
    print(f"    [RENDER] {output_path}")


def render_current_scene(output_path, resolution=512):
    """현재 씬에 있는 메시 전체를 렌더링하여 이미지로 저장한다."""
    meshes = [obj for obj in bpy.context.scene.objects if obj.type == 'MESH']
    if not meshes:
        return
    setup_render_scene(resolution)
    center, size = get_scene_bounds(meshes)
    setup_camera_and_light(center, size)
    render_to_file(output_path)


def render_single_object(obj, output_path, resolution=512):
    """단일 메시 오브젝트만 보이게 한 뒤 렌더링한다."""
    all_meshes = [o for o in bpy.context.scene.objects if o.type == 'MESH']

    # 대상 외 숨기기
    hidden_states = {}
    for o in all_meshes:
        hidden_states[o.name] = o.hide_render
        o.hide_render = (o != obj)

    setup_render_scene(resolution)
    center, size = get_scene_bounds([obj])
    setup_camera_and_light(center, size)
    render_to_file(output_path)

    # 복원
    for o in all_meshes:
        if o.name in hidden_states:
            o.hide_render = hidden_states[o.name]


# ---------------------------------------------------------------------------
# 익스포트
# ---------------------------------------------------------------------------

def export_part(obj, output_path):
    """단일 메시 오브젝트를 개별 FBX 파일로 익스포트한다."""
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj

    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)

    os.makedirs(os.path.dirname(output_path), exist_ok=True)

    bpy.ops.export_scene.fbx(
        filepath=output_path,
        use_selection=True,
        apply_scale_options='FBX_SCALE_ALL',
        bake_space_transform=False,
    )


# ---------------------------------------------------------------------------
# 메인 분리 로직
# ---------------------------------------------------------------------------

def split_fbx(input_path, output_dir, min_vertices=100, render=True, resolution=512):
    """단일 FBX 파일을 메시 단위로 분리하여 개별 FBX로 익스포트한다."""
    clear_scene()

    basename = os.path.splitext(os.path.basename(input_path))[0]
    part_dir = os.path.join(output_dir, basename)
    render_dir = os.path.join(part_dir, '_renders')

    meshes = load_fbx(input_path)
    results = []

    if not meshes:
        print(f"  [SKIP] 메시 오브젝트 없음: {input_path}")
        return results

    # 분리 전 전체 렌더링
    if render:
        render_current_scene(os.path.join(render_dir, '_combined.png'), resolution)

    for obj in meshes:
        info = get_mesh_info(obj)
        exported = False
        skip_reason = ""

        safe_name = info['name'].replace('/', '_').replace('\\', '_').replace(':', '_')

        if info['vertex_count'] < min_vertices:
            skip_reason = f"vertices({info['vertex_count']}) < {min_vertices}"
        else:
            out_path = os.path.join(part_dir, f"{safe_name}.fbx")
            try:
                # 개별 파츠 렌더링
                if render:
                    render_single_object(
                        obj,
                        os.path.join(render_dir, f"{safe_name}.png"),
                        resolution,
                    )
                export_part(obj, out_path)
                exported = True
            except Exception as e:
                skip_reason = str(e)

        results.append({
            'source_file': input_path,
            'part_name': info['name'],
            'vertex_count': info['vertex_count'],
            'bbox_size': f"{info['bbox_size'][0]}x{info['bbox_size'][1]}x{info['bbox_size'][2]}",
            'bbox_volume': info['bbox_volume'],
            'exported': exported,
            'skip_reason': skip_reason,
        })

        status = "OK" if exported else f"SKIP ({skip_reason})"
        print(f"    {info['name']:40s}  verts={info['vertex_count']:>6d}  bbox={info['bbox_size']}  {status}")

    clear_scene()
    return results


def batch_split(input_dir, output_dir, min_vertices=100, render=True,
                resolution=512, extensions=('.fbx',)):
    """디렉토리를 재귀 탐색하여 모든 FBX 파일을 배치 분리한다."""
    all_results = []
    fbx_files = []

    for root, dirs, files in os.walk(input_dir):
        for f in files:
            if os.path.splitext(f)[1].lower() in extensions:
                fbx_files.append(os.path.join(root, f))

    fbx_files.sort()
    total = len(fbx_files)
    print(f"\n총 {total}개의 FBX 파일 발견\n")

    for idx, fbx_path in enumerate(fbx_files, 1):
        print(f"[{idx}/{total}] {fbx_path}")
        try:
            results = split_fbx(fbx_path, output_dir, min_vertices, render, resolution)
            all_results.extend(results)
        except Exception as e:
            print(f"  [ERROR] {e}")
            all_results.append({
                'source_file': fbx_path,
                'part_name': '',
                'vertex_count': 0,
                'bbox_size': '',
                'bbox_volume': 0,
                'exported': False,
                'skip_reason': f"LOAD_ERROR: {e}",
            })

    return all_results


# ---------------------------------------------------------------------------
# 리포트
# ---------------------------------------------------------------------------

def write_report(results, report_path):
    """처리 결과를 CSV 파일로 저장한다."""
    os.makedirs(os.path.dirname(os.path.abspath(report_path)), exist_ok=True)

    fieldnames = ['source_file', 'part_name', 'vertex_count', 'bbox_size',
                  'bbox_volume', 'exported', 'skip_reason']
    with open(report_path, 'w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(results)

    print(f"\n리포트 저장: {report_path}")


def print_summary(results):
    """터미널에 처리 요약을 출력한다."""
    total = len(results)
    exported = sum(1 for r in results if r['exported'])
    skipped = total - exported
    source_files = set(r['source_file'] for r in results)

    print("\n" + "=" * 60)
    print("처리 요약")
    print("=" * 60)
    print(f"  원본 FBX 파일 수 : {len(source_files)}")
    print(f"  총 파츠 수       : {total}")
    print(f"  익스포트 성공     : {exported}")
    print(f"  스킵             : {skipped}")
    print("=" * 60)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    argv = sys.argv
    if '--' in argv:
        argv = argv[argv.index('--') + 1:]
    else:
        argv = []

    parser = argparse.ArgumentParser(
        description='FBX 파츠 분리 유틸리티 - 하나의 FBX에 포함된 메시를 개별 FBX로 분리합니다.',
    )
    parser.add_argument('--input', '-i', required=True,
                        help='입력 FBX 파일 또는 디렉토리 경로')
    parser.add_argument('--output', '-o', required=True,
                        help='출력 디렉토리 경로')
    parser.add_argument('--min-vertices', type=int, default=100,
                        help='최소 버텍스 수 (기본값: 100)')
    parser.add_argument('--report', '-r', default=None,
                        help='리포트 CSV 파일 경로 (미지정 시 {output}/report.csv)')
    parser.add_argument('--no-render', action='store_true',
                        help='렌더링 이미지 저장을 건너뜀')
    parser.add_argument('--resolution', type=int, default=512,
                        help='렌더링 이미지 해상도 (기본값: 512)')

    args = parser.parse_args(argv)

    input_path = os.path.abspath(args.input)
    output_dir = os.path.abspath(args.output)
    do_render = not args.no_render

    if not os.path.exists(input_path):
        print(f"[ERROR] 입력 경로가 존재하지 않습니다: {input_path}")
        sys.exit(1)

    os.makedirs(output_dir, exist_ok=True)

    if os.path.isfile(input_path):
        print(f"단일 파일 모드: {input_path}")
        results = split_fbx(input_path, output_dir, args.min_vertices,
                            do_render, args.resolution)
    elif os.path.isdir(input_path):
        print(f"배치 모드: {input_path}")
        results = batch_split(input_path, output_dir, args.min_vertices,
                              do_render, args.resolution)
    else:
        print(f"[ERROR] 입력 경로가 파일도 디렉토리도 아닙니다: {input_path}")
        sys.exit(1)

    report_path = args.report if args.report else os.path.join(output_dir, 'report.csv')
    write_report(results, report_path)
    print_summary(results)


if __name__ == '__main__':
    main()
