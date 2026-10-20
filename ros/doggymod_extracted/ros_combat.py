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
    raise RuntimeError('The existing Fly controller must load first')
Globals = _fly.Globals
Timer = _fly.Timer
_movement = _fly._movement
_esp = False
_aim = False
_esp_state = 0
_aim_state = 0
_timer = None
_last_tick = 0.0
_owner = None
_target_id = None
_frame = ()
_rich_esp_frame = ()
_frame_time = 0.0
_last_error = ''
_last_skip = ''
_waiting = ''
_ticks = _scanned = _skipped = _aim_writes = 0
_fire_held = False
_capture_degrees = 28.0
_retain_degrees = 38.0
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
        raise Waiting('Missing cached getModelCenter/getAimPos')
    game3d = sys.modules.get('game3d')
    if game3d is None:
        game3d = _binding('game3d', (_movement, canvas))
    Vector2 = _binding('Vector2', candidates)
    Physics = _binding('Physics', candidates)
    RaycastHit = _binding('RaycastHit', candidates)
    for obj, name in ((monitor, 'allEnemys'), (service, 'isAvatar'),
                      (service, 'isRobot'), (game3d, 'get_window_size'),
                      (Physics, 'RaycastWithScene')):
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
    xyz = _xyz(point)
    direction = tuple(a - b for a, b in zip(xyz, origin))
    # Check the actual camera forward; do not assume camera-space Z sign.
    if sum(a * b for a, b in zip(direction, forward)) <= 0.00001:
        return None
    projected = camera.WorldToScreenPoint(point)
    x, y = _finite(projected.x) / resolution[0], _finite(projected.y) / resolution[1]
    # world_to_screen already has the same top-left origin as UIKit. The game
    # CanvasManager flips its Y only for its bottom-left cocos canvas.
    if not (0.0 <= x <= 1.0 and 0.0 <= y <= 1.0):
        return None
    return x, y, direction


def _enemy(go, player, service):
    entity = getattr(go, 'entity', None)
    local = player.entity
    if entity is None or entity.id == local.id:
        return False
    if not (service.isAvatar(entity) or service.isRobot(entity)):
        return False
    if entity.campType == local.campType or local.isBattleMate(entity.id):
        return False
    return (float(entity.hp) > 0.0 and not getattr(entity, 'deadInGame', False))


def _visible(Physics, RaycastHit, camera_position, point):
    direction = point - camera_position
    distance = _finite(direction.magnitude)
    if distance <= 0.00001:
        return False
    return not Physics.RaycastWithScene(camera_position, direction, RaycastHit(), distance)


def _extract_real_name(entity, go):
    if entity is None:
        return 'Player'
    # Try real role / player name fields from ROS game engine safely
    for attr in ('role_name', 'roleName', 'nickname', 'nick_name', 'charName', 'char_name', 'userName', 'username'):
        try:
            val = getattr(entity, attr, None)
            if val and isinstance(val, (str, unicode)):
                s = str(val).strip()
                low = s.lower()
                if not ('(clone)' in low or 'avatar_' in low or 'robot_' in low or 'entity_' in low or 'gameobject' in low or 'lod' in low or 'enemy' in low):
                    clean = s.replace(' ', '_').replace(',', '').replace(';', '').replace('|', '').replace('\n', '').strip()[:14]
                    if clean and clean != 'None' and clean != 'null':
                        return clean
        except Exception:
            pass
    # Avoid showing Avatar_XXX(Clone) as user name
    try:
        raw_name = getattr(go, 'name', '') or ''
        if raw_name and isinstance(raw_name, (str, unicode)):
            low_go = str(raw_name).lower()
            if '(clone)' in low_go or 'avatar' in low_go or 'robot' in low_go:
                return 'Player'
            clean = str(raw_name).replace(' ', '_').replace(',', '').replace(';', '').replace('|', '').replace('\n', '').strip()[:14]
            if clean:
                return clean
    except Exception:
        pass
    return 'Player'


def _clear_frame():
    global _frame, _rich_esp_frame, _frame_time, _target_id, _fire_held
    _frame = ()
    _rich_esp_frame = ()
    _frame_time = 0.0
    _target_id = None
    _fire_held = False
    _write_esp_file('')


def _ensure_timer():
    global _timer, _last_tick
    if _timer is None:
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
    global _esp, _aim, _esp_state, _aim_state, _last_error, _target_id
    try:
        if action == 'esp':
            _esp = not _esp
            _esp_state = 2 if _esp else 0
            if not _esp:
                _write_esp_file('')
                if not _aim:
                    _clear_frame()
        elif action == 'aim':
            _aim = not _aim
            _aim_state = 2 if _aim else 0
            _target_id = None
            if not _aim and not _esp:
                _clear_frame()
        elif action == 'off':
            _esp = _aim = False
            _esp_state = _aim_state = 0
            _clear_frame()
        else:
            raise ValueError('Unknown combat request')
        _last_error = ''
        if _esp or _aim:
            _ensure_timer()
        else:
            _stop_timer()
            _write_esp_file('')
        return True
    except Exception as error:
        _last_error = '%s: %s' % (type(error).__name__, error)
        _esp = _aim = False
        _esp_state = _aim_state = 0
        _clear_frame()
        return True


def _tick():
    global _last_tick, _owner, _target_id, _frame, _rich_esp_frame, _frame_time
    global _esp_state, _aim_state, _last_error, _last_skip, _waiting, _ticks, _scanned, _skipped
    global _fire_held, _aim_writes, _last_angles, _esp, _aim
    now = time.time()
    previous_tick = _last_tick
    _last_tick = now
    _ticks += 1
    try:
        if not (_esp or _aim):
            _clear_frame()
            _stop_timer()
            return
        _clear_previous_target = _target_id
        _clear_frame()
        _esp_state = 2 if _esp else 0
        _aim_state = 2 if _aim else 0
        if now < previous_tick or now - previous_tick > 0.75:
            _waiting = 'Resuming engine callbacks'
            return
        ownership = _fly._target()
        if ownership is None:
            _waiting = 'Waiting for local character'
            return
        unit, character, entity_id = ownership
        player = Globals.player
        if unit is None or getattr(player, 'entity', None) is None or getattr(player.entity, 'deadInGame', False):
            _esp_state = 3 if _esp else 0
            _aim_state = 3 if _aim else 0
            _waiting = 'Local character dead'
            return
        owner = (id(player), entity_id, id(character))
        if owner != _owner:
            _clear_previous_target = None
            _owner = owner
        Camera, monitor, service, get_point, game3d, Vector2, Physics, RaycastHit = _bindings()
        camera = getattr(Camera, 'main', None)
        if camera is None:
            raise Waiting('Waiting for main camera')
        camera_position = camera.transform.position
        origin, forward = _xyz(camera_position), _xyz(camera.transform.forward)
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
                point = get_point(go)
                projected = _screen_point(camera, point, resolution, origin, forward)
                if projected is None:
                    continue
                x, y, direction = projected
                entity = go.entity
                angle = _angle_between(direction, forward)
                distance2 = sum(n * n for n in direction)
                candidates.append((angle, entity.id, x, y, point, direction,
                                   go, distance2, bool(getattr(entity, 'invincible', False))))
            except Exception as error:
                # A despawning or not-yet-rendered object cannot become a target.
                _skipped += 1
                _last_skip = '%s: %s' % (type(error).__name__, error)
        candidates.sort(key=lambda item: (item[0], item[7], item[1]))
        _esp_state = 1 if _esp else 0
        _aim_state = 1 if _aim else 0
        _waiting = ''
        _frame = tuple((c[2], c[3], False) for c in candidates[:_max_lines]) if _esp else ()
        _frame_time = now
        selected = None
        if _aim:
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
                # CPlayerCameraController._onRotateCamera is an empty routine;
                # fail explicitly rather than claiming a lock on that backend.
                if (control is None or not callable(getattr(control, 'onRotateCamera', None))
                        or getattr(control, 'controller', None) is not None):
                    raise Waiting('Unsupported live camera controller')
                pool = [c for c in candidates if c[0] <= _capture_degrees and not c[8]]
                retained = [c for c in candidates if c[1] == _clear_previous_target
                            and c[0] <= _retain_degrees and not c[8]]
                if retained:
                    pool = retained + [c for c in pool if c[1] != retained[0][1]]
                # Visibility is recomputed while firing; a wall immediately drops lock.
                for candidate in pool[:8]:
                    if _visible(Physics, RaycastHit, camera_position, candidate[4]):
                        selected = candidate
                        break
                if selected is not None:
                    # Check ownership again immediately before the camera request.
                    latest = _fly._target()
                    if (latest is None or latest[0] is not unit or latest[1] is not character
                            or latest[2] != entity_id or Globals.player is not player):
                        raise Waiting('Local character changed')
                    if not _enemy(selected[6], player, service) or getattr(selected[6].entity, 'invincible', False):
                        selected = None
                    else:
                        yaw, pitch = _angle_offset(selected[5], forward)
                        _last_angles = (yaw, pitch)
                        # Same rotation API/Vector2(yaw,pitch) used by ShootAssist.
                        control.onRotateCamera(Vector2(yaw, pitch), True)
                        _aim_writes += 1
                        _aim_state = 5
                        _target_id = selected[1]
        if _esp:
            rich_items = []
            for i, c in enumerate(candidates[:_max_lines]):
                go = c[6]
                point = c[4]
                entity = getattr(go, 'entity', None)
                dist_val = math.sqrt(max(0.0, c[7]))

                # can_shoot: target locked or in active crosshair view
                can_shoot = bool(c[1] == _target_id)
                if not can_shoot and i == 0 and c[0] <= 0.20:
                    try:
                        can_shoot = bool(_visible(Physics, RaycastHit, camera_position, point))
                    except Exception:
                        can_shoot = False

                # Safe perspective bounding box calculation
                box_h = max(0.016, min(0.85, 2.0 / (dist_val + 0.5)))
                box_w = box_h * 0.48
                box_x = c[2] - box_w * 0.5
                box_y = c[3] - box_h * 0.45

                box_x = max(0.0, min(1.0 - box_w, box_x))
                box_y = max(0.0, min(1.0 - box_h, box_y))

                # Real player name (avoiding engine clone names)
                clean_name = _extract_real_name(entity, go)

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
            _frame = tuple((c[2], c[3], bool(cs_i)) for c in candidates[:_max_lines])
            _write_esp_file(';'.join('%d,%d,%d,%d,%d,%d,%d,%d,%s' % it for it in rich_items))
        else:
            _rich_esp_frame = ()
            _frame = ()
            _write_esp_file('')
        _frame_time = now
    except Waiting as error:
        _waiting = str(error)
        _target_id = None
        # Preserve ESP when only aim's input/controller is unavailable.
        if _esp_state != 1:
            _frame = ()
            _rich_esp_frame = ()
            _frame_time = 0.0
            _esp_state = 2 if _esp else 0
            _write_esp_file('')
        _aim_state = 2 if _aim else 0
    except Exception as error:
        _last_error = '%s: %s' % (type(error).__name__, error)
        _clear_frame()
        _esp_state = 4 if _esp else 0
        _aim_state = 4 if _aim else 0
        _esp = _aim = False
        _write_esp_file('')
        try:
            _stop_timer()
        except Exception:
            pass


def snapshot():
    global _esp_state, _aim_state, _last_error
    # ASCII integers only. Normalised screen coordinates are independent of
    # Retina scale. UIKit must discard stale frames, never draw old enemies.
    if (_esp or _aim) and (_timer is None or time.time() - _last_tick > 1.0):
        # Scene changes can discard the engine registry while a handle remains.
        try:
            _stop_timer()
            _ensure_timer()
        except Exception as error:
            handle('off')
            _esp_state = _aim_state = 4
            _last_error = 'Timer recovery: %s: %s' % (type(error).__name__, error)
            return '10,4,4,0'
    age = time.time() - _frame_time
    fresh = 0.0 <= age <= 0.85
    rows = _frame if fresh and _esp else ()
    if not _esp:
        esp_state = 0
    else:
        esp_state = 2 if _esp_state == 1 and not fresh else _esp_state
    if not _aim:
        aim_state = 0
    else:
        aim_state = 2 if _aim_state in (1, 5) and not fresh else _aim_state
    parts = ['10', str(esp_state), str(aim_state), str(len(rows))]
    for x, y, locked in rows:
        parts.extend((str(int(x * 10000.0 + 0.5)), str(int(y * 10000.0 + 0.5)),
                      '1' if locked else '0'))
    return ','.join(parts)


def esp_snapshot():
    global _esp_state, _aim_state, _last_error
    if not _esp:
        return "NONE"
    age = time.time() - _frame_time
    if age < 0.0 or age > 0.85:
        return "NONE"
    try:
        if not _rich_esp_frame:
            return "NONE"
        parts = []
        for item in _rich_esp_frame:
            parts.append('%d,%d,%d,%d,%d,%d,%d,%d,%s' % item)
        if not parts:
            return "NONE"
        return ';'.join(parts)
    except Exception:
        return "NONE"


def diagnostics():
    return ('ESP/Aim build 10\nESP state: %d / Aim state: %d\n'
            'Timer ticks: %d / objects checked: %d\n'
            'Lines: %d / skipped objects: %d\n'
            'Fire held: %s / target: %s\nCamera requests: %d\n'
            'Last yaw/pitch: %.2f / %.2f degrees\n'
            'Capture/retain: 28 / 38 degrees\n'
            'Waiting: %s\nLast skipped object: %s\nError: %s' % (_esp_state, _aim_state, _ticks, _scanned,
             len(_frame), _skipped, _fire_held, _target_id, _aim_writes,
             _last_angles[0], _last_angles[1], _waiting or '(none)',
             _last_skip or '(none)', _last_error or '(none)'))


print('[ROS Combat] %s ready; ESP/Aim disabled by default' % BUILD)
