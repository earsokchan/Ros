# Python 2.7, exact supplied ROS Legacy test build. Disabled by default.
# Game API reads and camera requests run on the existing engine Timer.
import sys
import time
import math
import os

BUILD = 'ROS-COMBAT-TEST-10'

def _write_esp_file(content):
    pass

_fly = sys.modules.get('ros_fly_mod')
if _fly is None:
    try:
        import ros_fly_mod as _fly
    except Exception:
        pass
if _fly is None:
    try:
        import ros_fly as _fly
    except Exception:
        pass
Globals = sys.modules.get('Globals')
if Globals is None and _fly:
    Globals = getattr(_fly, 'Globals', None)
_movement = getattr(_fly, '_movement', None) if _fly else None


def _resolve_game_timer():
    candidates = (
        getattr(_fly, 'Timer', None) if _fly else None,
        getattr(_movement, 'Timer', None) if _movement else None,
        sys.modules.get('common.Timer'),
        getattr(sys.modules.get('common'), 'Timer', None),
        getattr(Globals, 'Timer', None),
    )
    for candidate in candidates:
        if (candidate and callable(getattr(candidate, 'addRepeatTimer', None)) and
                callable(getattr(candidate, 'delTimer', None))):
            return candidate
    return None


Timer = getattr(_fly, 'Timer', None) if _fly else None
if Timer is None:
    Timer = _resolve_game_timer()
_esp = False
_aim = False
_aim_smooth = False
_esp_state = 0
_aim_state = 0
_timer = None
_last_tick = 0.0
_owner = None
_target_id = None
_frame = ()
_rich_esp_frame = ()
_last_esp_str = 'NONE'
_frame_time = 0.0
_last_error = ''
_last_skip = ''
_waiting = ''
_ticks = _scanned = _skipped = _aim_writes = 0
_fire_held = False
_capture_degrees = 180.0
_retain_degrees = 180.0
_max_lines = 64
_last_angles = (0.0, 0.0)


class Waiting(Exception):
    pass


def _binding(name, modules):
    for module in modules:
        value = getattr(module, name, None) if module is not None else None
        if value is not None:
            return value
    raise Waiting('Missing cached binding: ' + name)


def _bindings():
    # Dotted modules can exist without importable parents in this game loader.
    # Only reuse live objects; never import game files or fabricate packages.
    assist = sys.modules.get('weapon.ShootAssist')
    combat = sys.modules.get('CombatUnit')
    shoot = sys.modules.get('common.shoot_utils')
    client = sys.modules.get('client_utils')
    canvas = sys.modules.get('libclaudia.Settings.CanvasManager')
    camera_module = sys.modules.get('camera.PlayerCameraController')
    candidates = (_movement, assist, combat, shoot, client, camera_module)
    Camera = _binding('Camera', candidates)
    monitor = _binding('g_CombatUnitMonitor', (combat, assist, shoot))
    service = _binding('ServiceAPI', (combat, assist, camera_module))
    point = getattr(shoot, 'getModelCenter', None)
    if not callable(point):
        point = getattr(client, 'getAimPos', None)
    if not callable(point):
        def _fallback_point(target_go):
            try:
                t = getattr(target_go, 'transform', None)
                if t is not None:
                    return t.position
            except Exception:
                pass
            return None
        point = _fallback_point
    game3d = sys.modules.get('game3d')
    if game3d is None:
        game3d = _binding('game3d', (_movement, canvas))
    Vector2 = _binding('Vector2', candidates)
    Physics = None
    RaycastHit = None
    try:
        Physics = _binding('Physics', candidates)
        RaycastHit = _binding('RaycastHit', candidates)
    except Exception:
        pass
    for obj, name in ((monitor, 'allEnemys'), (service, 'isAvatar'),
                      (service, 'isRobot'), (game3d, 'get_window_size')):
        if not callable(getattr(obj, name, None)):
            raise Waiting('Missing live interface: ' + name)
    return Camera, monitor, service, point, game3d, Vector2, Physics, RaycastHit


def _finite(value):
    value = float(value)
    if not (value == value and -100000000.0 < value < 100000000.0):
        raise ValueError('Invalid coordinate')
    return value


def _xyz(vector):
    return tuple(_finite(getattr(vector, axis)) for axis in ('x', 'y', 'z'))


def _wrap(angle):
    return (angle + 180.0) % 360.0 - 180.0


def _angle_offset(direction, forward):
    # NeoX/libclaudia camera forward is +Z, with Euler pitch about +X.
    dx, dy, dz = direction
    fx, fy, fz = forward
    horizontal = math.sqrt(dx * dx + dz * dz)
    forward_horizontal = math.sqrt(fx * fx + fz * fz)
    yaw = _wrap(math.degrees(math.atan2(dx, dz) - math.atan2(fx, fz)))
    pitch = _wrap(math.degrees(-math.atan2(dy, horizontal) +
                              math.atan2(fy, forward_horizontal)))
    return yaw, pitch


def _angle_between(left, right):
    magnitude = math.sqrt(sum(n * n for n in left) * sum(n * n for n in right))
    if magnitude < 0.000001:
        raise ValueError('Zero camera/target direction')
    cosine = sum(a * b for a, b in zip(left, right)) / magnitude
    return math.degrees(math.acos(max(-1.0, min(1.0, cosine))))


def _screen_point(camera, point, resolution, origin, forward):
    try:
        projected = camera.WorldToScreenPoint(point)
        if projected is None:
            return None
        pz = getattr(projected, 'z', None)
        if pz is not None and float(pz) <= 0.05:
            return None
        px = getattr(projected, 'x', None)
        py = getattr(projected, 'y', None)
        if px is None or py is None:
            return None
        res_w, res_h = resolution[0], resolution[1]
        px_val, py_val = _finite(px), _finite(py)
        if res_w > 1.0 and px_val > res_w * 1.5:
            scale = round(float(px_val) / res_w)
            if scale < 1.0:
                scale = 1.0
            x = px_val / (res_w * scale)
            y = py_val / (res_h * scale)
        else:
            x = px_val / res_w
            y = py_val / res_h
        if not (-0.5 <= x <= 1.5 and -0.5 <= y <= 1.5):
            return None
        xyz = _xyz(point)
        direction = tuple(a - b for a, b in zip(xyz, origin))
        if sum(a * b for a, b in zip(direction, forward)) <= 0.00001:
            return None
        return x, y, direction
    except Exception:
        return None


def _is_downed(entity, go=None):
    try:
        if entity is None and go is not None:
            entity = getattr(go, 'entity', None)
        if entity is None:
            return False
        try:
            hp_v = float(getattr(entity, 'hp', 1.0))
            if hp_v <= 0.0:
                return True
        except Exception:
            pass
        for d_attr in ('is_downed', 'isDowned', 'isKnocked', 'is_knocked', 'isBleedOut', 'isWounded', 'is_wounded'):
            try:
                val = getattr(entity, d_attr, False)
                if callable(val):
                    val = val()
                if bool(val):
                    return True
            except Exception:
                pass
        return False
    except Exception:
        return False


def _enemy(go, player, service):
    try:
        if go is None:
            return False
        entity = getattr(go, 'entity', None)
        local = getattr(player, 'entity', None) if player is not None else None
        if entity is None or local is None or getattr(entity, 'id', None) == getattr(local, 'id', None):
            return False
        if service is not None:
            is_av = bool(service.isAvatar(entity)) if callable(getattr(service, 'isAvatar', None)) else False
            is_rb = bool(service.isRobot(entity)) if callable(getattr(service, 'isRobot', None)) else False
            if not (is_av or is_rb):
                return False
        camp_e = getattr(entity, 'campType', None)
        camp_l = getattr(local, 'campType', None)
        if camp_e is not None and camp_l is not None and camp_e == camp_l:
            return False
        if callable(getattr(local, 'isBattleMate', None)) and local.isBattleMate(entity.id):
            return False
        return (float(getattr(entity, 'hp', 1.0)) > 0.0 and not getattr(entity, 'deadInGame', False))
    except Exception:
        return False

def is_holding_gun():
    return 1


def _visible(Physics, RaycastHit, camera_position, point):
    try:
        direction = point - camera_position
        distance = _finite(direction.magnitude)
        if distance <= 0.00001:
            return False
        if Physics is not None and RaycastHit is not None and callable(getattr(Physics, 'RaycastWithScene', None)):
            return not Physics.RaycastWithScene(camera_position, direction, RaycastHit(), distance)
        return True
    except Exception:
        return True


def _extract_real_name(entity, go=None):
    if entity is None and go is not None:
        entity = getattr(go, 'entity', None)
    if entity is None:
        return 'Player'
    for attr in ('role_name', 'roleName', 'nickname', 'nick_name', 'charName', 'char_name', 'userName', 'username'):
        try:
            val = getattr(entity, attr, None)
            if val:
                if isinstance(val, unicode):
                    val = val.encode('utf-8', 'ignore')
                s = str(val).strip()
                low = s.lower()
                if not ('(clone)' in low or 'avatar_' in low or 'robot_' in low or 'entity_' in low or 'gameobject' in low or 'lod' in low or 'enemy' in low):
                    clean = s.replace(' ', '_').replace(',', '').replace(';', '').replace('|', '').replace('\n', '').strip()[:14]
                    if clean and clean != 'None' and clean != 'null':
                        return clean
        except Exception:
            pass
    return 'Player'


def _clear_frame():
    global _frame, _rich_esp_frame, _frame_time, _target_id, _fire_held, _last_esp_str
    _frame = ()
    _rich_esp_frame = ()
    _last_esp_str = 'NONE'
    _frame_time = 0.0
    _target_id = None
    _fire_held = False
    _write_esp_file('')


_scene_fingerprint = None
_scene_change_time = 0.0


def _ensure_timer():
    global _timer, _last_tick, Timer
    if Timer is None:
        Timer = _resolve_game_timer()
    if _timer is None and Timer is not None:
        try:
            _timer = Timer.addRepeatTimer(0.03333, _tick)
            _last_tick = time.time()
        except Exception:
            pass


def _stop_timer():
    global _timer
    timer = _timer
    _timer = None
    if timer is not None:
        try:
            Timer.delTimer(timer)
        except Exception:
            pass


def handle(action):
    global _esp, _aim, _aim_smooth, _esp_state, _aim_state, _last_error, _target_id
    try:
        if action == 'esp':
            _esp = False
            _esp_state = 0
            _write_esp_file('')
        elif action == 'aim':
            _aim = not _aim
            _aim_state = 1 if _aim else 0
            _target_id = None
            if not _aim and not _aim_smooth and not _esp:
                _clear_frame()
        elif action == 'aim_smooth':
            _aim_smooth = not _aim_smooth
            if not _aim and not _aim_smooth and not _esp:
                _clear_frame()
        elif action == 'off':
            # Do NOT reset _aim, _aim_smooth, or _esp on background tap / menu close!
            pass
        else:
            raise ValueError('Unknown combat request')
        _last_error = ''
        if _esp or _aim or _aim_smooth:
            _ensure_timer()
        else:
            _stop_timer()
            _write_esp_file('')
        return True
    except Exception as error:
        _last_error = '%s: %s' % (type(error).__name__, error)
        return True


def set_aim(val):
    global _aim, _aim_state, _last_error, _target_id
    try:
        _aim = bool(val)
        _aim_state = 1 if _aim else 0
        if _aim:
            _ensure_timer()
        else:
            _target_id = None
            if not _esp and not _aim_smooth:
                _clear_frame()
                _stop_timer()
        return _aim
    except Exception as error:
        _last_error = '%s: %s' % (type(error).__name__, error)
        return False


def set_esp(val):
    global _esp, _esp_state, _last_error
    try:
        _esp = False
        _esp_state = 0
        _write_esp_file('')
        return False
    except Exception as error:
        _last_error = '%s: %s' % (type(error).__name__, error)
        return False



def set_aim_smooth(val):
    global _aim_smooth, _last_error
    try:
        _aim_smooth = bool(val)
        if _aim_smooth or _esp or _aim:
            _ensure_timer()
        else:
            _stop_timer()
            _clear_frame()
        return _aim_smooth
    except Exception as error:
        _last_error = '%s: %s' % (type(error).__name__, error)
        return False


def _tick():
    global _last_tick, _owner, _target_id, _frame, _rich_esp_frame, _frame_time
    global _esp_state, _aim_state, _last_error, _last_skip, _waiting, _ticks, _scanned, _skipped
    global _fire_held, _aim_writes, _last_angles, _esp, _aim, _aim_smooth, _last_esp_str
    global _scene_fingerprint, _scene_change_time, _is_gun_held
    now = time.time()
    previous_tick = _last_tick
    _last_tick = now
    _ticks += 1
    try:
        if not (_esp or _aim or _aim_smooth):
            _clear_frame()
            _stop_timer()
            _is_gun_held = 0
            return
        _clear_previous_target = _target_id
        _esp_state = 1 if _esp else 0
        _aim_state = 1 if _aim else 0
        ownership = _fly._target() if _fly else None
        if ownership is None:
            _waiting = 'Waiting for local character'
            _clear_frame()
            _target_id = None
            _is_gun_held = 0
            return
        unit, character, entity_id = ownership
        player = getattr(Globals, 'player', None)
        if unit is None or character is None or player is None:
            _waiting = 'Waiting for local player/unit'
            _clear_frame()
            _target_id = None
            _is_gun_held = 0
            return
        local_entity = getattr(player, 'entity', None)
        if local_entity is None or getattr(local_entity, 'deadInGame', False):
            _esp_state = 3 if _esp else 0
            _aim_state = 3 if (_aim or _aim_smooth) else 0
            _waiting = 'Local character dead/unavailable'
            _clear_frame()
            _target_id = None
            _is_gun_held = 0
            return
        if (not getattr(unit, 'chInScene', False) or
                getattr(unit, 'inVehicle', False) or
                getattr(unit, '_useParachute', False) or
                getattr(unit, '_observer', False)):
            _waiting = 'Waiting for ground character (not in plane/parachute)'
            _clear_frame()
            _target_id = None
            _is_gun_held = 0
            return

        # 1. SCENE TRANSITION & MATCH LOADING SETTLING PERIOD (3.0s quiet period)
        fingerprint = (id(player), entity_id)
        if fingerprint != _scene_fingerprint:
            _scene_fingerprint = fingerprint
            _scene_change_time = now
            _waiting = 'Scene/match loading... settling'
            _clear_frame()
            _target_id = None
            _is_gun_held = 0
            return

        elapsed = now - _scene_change_time
        if elapsed < 3.0:
            _waiting = 'Character loading on map... (%.1fs)' % max(0.1, 3.0 - elapsed)
            _clear_frame()
            _target_id = None
            _is_gun_held = 0
            return

        owner = (id(player), entity_id)
        if owner != _owner:
            _clear_previous_target = None
            _owner = owner
        Camera, monitor, service, get_point, game3d, Vector2, Physics, RaycastHit = _bindings()
        camera = getattr(Camera, 'main', None) or getattr(Camera, 'current', None)
        if camera is None:
            try:
                all_cams = getattr(Camera, 'allCameras', None)
                if all_cams and len(all_cams) > 0:
                    camera = all_cams[0]
            except Exception:
                pass
        if camera is None:
            raise Waiting('Waiting for main camera')
        cam_tf = getattr(camera, 'transform', None)
        if cam_tf is None:
            raise Waiting('Waiting for camera transform')
        camera_position = cam_tf.position
        if abs(float(camera_position.x)) < 0.001 and abs(float(camera_position.y)) < 0.001 and abs(float(camera_position.z)) < 0.001:
            raise Waiting('Waiting for active camera spawn')
        origin, forward = _xyz(camera_position), _xyz(cam_tf.forward)
        pw = getattr(camera, 'pixelWidth', None)
        ph = getattr(camera, 'pixelHeight', None)
        if pw and ph and float(pw) > 10.0 and float(ph) > 10.0:
            resolution = (float(pw), float(ph))
        else:
            size = game3d.get_window_size()
            resolution = (_finite(size[0]), _finite(size[1]))
        if min(resolution) <= 1.0:
            raise Waiting('Waiting for game window resolution')
        candidates = []
        for go in list(monitor.allEnemys()):
            _scanned += 1
            try:
                if not _enemy(go, player, service):
                    continue
                point = None
                try:
                    point = get_point(go)
                except Exception:
                    pass
                if point is None:
                    continue

                xyz = _xyz(point)
                direction = tuple(a - b for a, b in zip(xyz, origin))
                angle = _angle_between(direction, forward)
                distance2 = sum(n * n for n in direction)
                projected = _screen_point(camera, point, resolution, origin, forward)
                x = projected[0] if projected is not None else -1.0
                y = projected[1] if projected is not None else -1.0
                entity = getattr(go, 'entity', None)
                eid = getattr(entity, 'id', None) if entity is not None else id(go)
                is_inv = False
                is_downed = False
                if entity is not None:
                    try:
                        is_inv = getattr(entity, 'invincible', False)
                        if callable(is_inv):
                            is_inv = is_inv()
                        is_inv = bool(is_inv) if isinstance(is_inv, (bool, int)) else False
                    except Exception:
                        is_inv = False
                    is_downed = _is_downed(entity, go)
                candidates.append((angle, eid, x, y, point, direction,
                                   go, distance2, is_inv, projected is not None, is_downed))
            except Exception as error:
                # A despawning or not-yet-rendered object cannot become a target.
                _skipped += 1
                _last_skip = '%s: %s' % (type(error).__name__, error)
        candidates.sort(key=lambda item: (item[7], item[0], item[1]))
        _esp_state = 1 if _esp else 0
        _aim_state = 1 if (_aim or _aim_smooth) else 0
        _waiting = ''
        esp_candidates = [c for c in candidates if c[9]]
        if _esp:
            try:
                rich_items = []
                for i, c in enumerate(esp_candidates[:_max_lines]):
                    go = c[6]
                    point = c[4]
                    entity = getattr(go, 'entity', None)
                    dist_val = math.sqrt(max(0.0, c[7]))

                    # can_shoot: target locked or in active crosshair view / closest visible
                    can_shoot = bool(c[1] == _target_id or c[0] <= 15.0 or dist_val <= 25.0)

                    # Safe perspective bounding box calculation
                    box_h = max(0.016, min(0.85, 2.0 / (dist_val + 0.5)))
                    box_w = box_h * 0.48
                    box_x = max(0.0, min(1.0 - box_w, c[2] - box_w * 0.5))
                    box_y = max(0.0, min(1.0 - box_h, c[3] - box_h * 0.5))

                    # Real player name (avoiding engine clone names)
                    clean_name = _extract_real_name(entity, go)
                    if not clean_name:
                        clean_name = 'Player'

                    # Detect if knocked / downed
                    is_downed = c[10]
                    if is_downed:
                        clean_name = clean_name + '_[Down]'

                    clean_name = clean_name.replace(' ', '_').replace(',', '').replace(';', '').replace('|', '')
                    if not clean_name:
                        clean_name = 'Player'
                    dist_m = int(dist_val + 0.5)

                    lx_i = int(c[2] * 10000.0 + 0.5)
                    ly_i = int((box_y + box_h) * 10000.0 + 0.5)
                    bx_i = int(box_x * 10000.0 + 0.5)
                    by_i = int(box_y * 10000.0 + 0.5)
                    bw_i = int(box_w * 10000.0 + 0.5)
                    bh_i = int(box_h * 10000.0 + 0.5)
                    cs_i = 1 if (can_shoot or c[1] == _target_id) else 0

                    rich_items.append((cs_i, lx_i, ly_i, bx_i, by_i, bw_i, bh_i, dist_m, clean_name))

                _rich_esp_frame = tuple(rich_items)
                _last_esp_str = (';'.join('%d,%d,%d,%d,%d,%d,%d,%d,%s' % it for it in rich_items) + ';') if rich_items else 'NONE'
                _frame = tuple((it[1] / 10000.0, it[2] / 10000.0, bool(it[0])) for it in rich_items)
                _write_esp_file(_last_esp_str if _last_esp_str != 'NONE' else '')
            except Exception as esp_err:
                _last_error = 'ESP process: %s: %s' % (type(esp_err).__name__, esp_err)
        else:
            _rich_esp_frame = ()
            _last_esp_str = 'NONE'
            _frame = ()
            _write_esp_file('')
        _frame_time = now

        selected = None
        if _aim or _aim_smooth:
            try:
                input_go = getattr(Globals, 'userInput', None)
                if input_go is None:
                    raise Waiting('Waiting for Globals.userInput')
                get_component = getattr(input_go, 'GetComponent', None)
                if not callable(get_component):
                    raise Waiting('Live UserInput GameObject has no GetComponent')
                input_component = get_component('InputInterpred')
                if input_component is None:
                    raise Waiting('Waiting for InputInterpred component')
                if not hasattr(input_component, '_isFireBtnDwn'):
                    raise Waiting('Live input has no _isFireBtnDwn')
                _fire_held = bool(input_component._isFireBtnDwn)
                if not getattr(input_component, '_inputEnable', False) or not getattr(input_component, '_canRotateCamera', False):
                    _aim_state = 3
                    _fire_held = False
                if _fire_held:
                    control = camera.GetComponent('PlayerCameraController')
                    if (control is None or not callable(getattr(control, 'onRotateCamera', None))
                            or getattr(control, 'controller', None) is not None):
                        raise Waiting('Unsupported live camera controller')
                    pool = [c for c in candidates if c[0] <= _capture_degrees and not c[8] and not c[10] and c[7] <= 10000.0]
                    retained = [c for c in pool if c[1] == _clear_previous_target and c[0] <= _retain_degrees]
                    if retained:
                        pool = retained + [c for c in pool if c[1] != retained[0][1]]
                    for candidate in pool[:8]:
                        if _visible(Physics, RaycastHit, camera_position, candidate[4]):
                            selected = candidate
                            break
                    if selected is None and pool:
                        selected = pool[0]
                    if selected is not None:
                        latest = _fly._target()
                        if (latest is None or latest[0] is not unit or latest[1] is not character
                                or latest[2] != entity_id or Globals.player is not player):
                            raise Waiting('Local character changed')
                        if not _enemy(selected[6], player, service) or getattr(selected[6].entity, 'invincible', False) or selected[10] or selected[7] > 10000.0:
                            selected = None
                            _target_id = None
                        else:
                            yaw, pitch = _angle_offset(selected[5], forward)
                            factor = 0.65
                            smooth_yaw = max(-36.0, min(36.0, yaw * factor))
                            smooth_pitch = max(-24.0, min(24.0, pitch * factor))
                            if abs(yaw) <= 1.8:
                                smooth_yaw = yaw
                            if abs(pitch) <= 1.4:
                                smooth_pitch = pitch
                            _last_angles = (smooth_yaw, smooth_pitch)
                            control.onRotateCamera(Vector2(smooth_yaw, smooth_pitch), True)
                            _aim_writes += 1
                            _aim_state = 5
                            _target_id = selected[1]
            except Waiting as aim_wait:
                _waiting = str(aim_wait)
                _target_id = None
                _aim_state = 2 if (_aim or _aim_smooth) else 0
            except Exception as aim_err:
                _last_error = 'Aim process: %s: %s' % (type(aim_err).__name__, aim_err)
                _target_id = None
                _aim_state = 2 if (_aim or _aim_smooth) else 0
    except Waiting as error:
        _waiting = str(error)
        _target_id = None
        _aim_state = 2 if (_aim or _aim_smooth) else 0
    except Exception as error:
        _last_error = '%s: %s' % (type(error).__name__, error)
        _target_id = None
        _aim_state = 2 if (_aim or _aim_smooth) else 0
        _esp_state = 2 if _esp else 0


def snapshot():
    global _esp_state, _aim_state, _last_error
    if (_esp or _aim or _aim_smooth) and (_timer is None or time.time() - _last_tick > 3.0):
        try:
            _stop_timer()
            _ensure_timer()
        except Exception as error:
            _last_error = 'Timer recovery: %s: %s' % (type(error).__name__, error)
            return '10,4,4,0'
    age = time.time() - _frame_time
    fresh = 0.0 <= age <= 3.0
    rows = _frame if fresh and _esp else ()
    esp_state = 1 if _esp else 0
    aim_state = 1 if (_aim or _aim_smooth) else 0
    parts = ['10', str(esp_state), str(aim_state), str(len(rows))]
    for x, y, locked in rows:
        parts.extend((str(int(x * 10000.0 + 0.5)), str(int(y * 10000.0 + 0.5)),
                      '1' if locked else '0'))
    return ','.join(parts)


def esp_snapshot():
    global _esp, _last_esp_str, _frame_time, _last_error
    if not _esp:
        return 'NONE'
    now = time.time()
    if _timer is None or now - _last_tick > 3.0:
        try:
            _stop_timer()
            _ensure_timer()
        except Exception as error:
            _last_error = 'Timer recovery: %s: %s' % (type(error).__name__, error)
    age = now - _frame_time
    if age < 0.0 or age > 3.0:
        return 'NONE'
    return _last_esp_str or 'NONE'


def diagnostics():
    return ('ESP/Aim build 11\nESP state: %d / Aim state: %d\n'
            'Timer ticks: %d / objects checked: %d\n'
            'Lines: %d / skipped objects: %d\n'
            'Fire held: %s / target: %s\nCamera requests: %d\n'
            'Last yaw/pitch: %.2f / %.2f degrees\n'
            'Capture/retain: 28 / 38 degrees\n'
            'Weapon detect: %s\n'
            'Waiting: %s\nLast skipped object: %s\nError: %s' % (_esp_state, _aim_state, _ticks, _scanned,
             len(_frame), _skipped, _fire_held, _target_id, _aim_writes,
             _last_angles[0], _last_angles[1],
             _weapon_debug or '(none)',
             _waiting or '(none)',
             _last_skip or '(none)', _last_error or '(none)'))


print('[ROS Combat] %s ready; ESP/Aim disabled by default' % BUILD)
