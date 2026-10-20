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
Globals = getattr(_fly, 'Globals', None) if _fly else None
Timer = getattr(_fly, 'Timer', None) if _fly else None
_movement = getattr(_fly, '_movement', None) if _fly else None
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
    try:
        entity = getattr(go, 'entity', None)
        local = getattr(player, 'entity', None)
        if entity is None or local is None or entity.id == local.id:
            return False
        try:
            is_avatar = bool(service.isAvatar(entity))
        except Exception:
            is_avatar = False
        try:
            is_robot = bool(service.isRobot(entity))
        except Exception:
            is_robot = False
        if not (is_avatar or is_robot):
            return False
        # Do not compare campType if either is None (solo, bot match, deathmatch)
        camp_e = getattr(entity, 'campType', None)
        camp_l = getattr(local, 'campType', None)
        if camp_e is not None and camp_l is not None and camp_e == camp_l:
            return False
        if callable(getattr(local, 'isBattleMate', None)):
            try:
                if local.isBattleMate(entity.id):
                    return False
            except Exception:
                pass
        if getattr(entity, 'deadInGame', False):
            return False
        try:
            hp_val = float(getattr(entity, 'hp', 1.0))
            if hp_val <= 0.0:
                return False
        except Exception:
            pass
        return True
    except Exception:
        return False

def _is_using_gun(player, local_entity):
    """
    Returns False ONLY if definitely unarmed (bare fists), holding melee (pan),
    or holding throwables (grenades).
    Defaults to True so Aim Smooth reliably locks onto enemies when using guns.
    """
    try:
        if local_entity is None and player is None:
            return True

        for obj in (local_entity, player):
            if obj is None:
                continue

            # 1. Explicit unarmed / fist boolean indicators
            for attr in ('is_unarmed', 'isUnarmed', 'is_fist', 'isFist', 'bare_hand', 'bareHand'):
                val = getattr(obj, attr, None)
                if val is not None:
                    try:
                        res = bool(val() if callable(val) else val)
                        if res:
                            return False
                    except Exception:
                        pass

            # 2. Check active weapon instance or weapon name
            for w_attr in ('cur_weapon', 'curWeapon', 'weapon', 'current_weapon', 'hold_weapon', 'holdWeapon'):
                w = getattr(obj, w_attr, None)
                if w is not None:
                    if callable(w):
                        try:
                            w = w()
                        except Exception:
                            w = None
                    if w is None:
                        continue
                    w_name = str(getattr(w, 'name', '') or getattr(w, 'weapon_name', '') or getattr(w, 'desc', '') or '').lower()
                    if w_name:
                        if any(term in w_name for term in ('fist', 'bare', 'unarm', 'hand', 'melee', 'pan', 'crowbar', 'chicken', 'stick', 'dagger', 'grenade', 'smoke', 'bomb', 'flash')):
                            return False
                        return True
                    # Check bullet attributes - guns have bullets
                    for b_attr in ('bullet_count', 'clip_bullet', 'cur_bullet', 'max_bullet', 'magazine', 'ammo'):
                        if hasattr(w, b_attr):
                            return True

            # 3. Check equip slot from bag / inventory:
            for bag_attr in ('bag', 'inventory', 'bag_comp', 'weapon_mgr'):
                bag = getattr(obj, bag_attr, None)
                if bag is not None:
                    for slot_attr in ('cur_equip_pos', 'curEquipPos', 'cur_pos', 'curPos', 'cur_weapon_pos', 'cur_slot'):
                        pos = getattr(bag, slot_attr, None)
                        if pos is not None:
                            try:
                                pos_int = int(pos)
                                if pos_int in (4, 5):  # Melee (pan) or grenade in ROS
                                    return False
                            except Exception:
                                pass

        return True
    except Exception:
        return True


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
    global _frame, _rich_esp_frame, _frame_time, _target_id, _fire_held, _last_esp_str
    _frame = ()
    _rich_esp_frame = ()
    _last_esp_str = 'NONE'
    _frame_time = 0.0
    _target_id = None
    _fire_held = False
    _write_esp_file('')


def _ensure_timer():
    global _timer, _last_tick
    if _timer is None:
        try:
            _timer = Timer.addRepeatTimer(0.010, _tick)
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
            _esp = not _esp
            _esp_state = 1 if _esp else 0
            if not _esp:
                _write_esp_file('')
                if not _aim and not _aim_smooth:
                    _clear_frame()
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
            _esp = _aim = _aim_smooth = False
            _esp_state = _aim_state = 0
            _clear_frame()
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
    now = time.time()
    previous_tick = _last_tick
    _last_tick = now
    _ticks += 1
    try:
        if not (_esp or _aim or _aim_smooth):
            _clear_frame()
            _stop_timer()
            return
        _clear_previous_target = _target_id
        _esp_state = 1 if _esp else 0
        _aim_state = 1 if _aim else 0
        unit = None
        character = None
        entity_id = None
        player = getattr(Globals, 'player', None)
        if _fly:
            try:
                target = _fly._target()
                if target:
                    unit, character, entity_id = target
                    player = getattr(Globals, 'player', None) or player
            except Exception:
                pass
        if player is None:
            _waiting = 'Waiting for local player'
            return
        local_entity = getattr(player, 'entity', None)
        if local_entity is None:
            _waiting = 'Waiting for player.entity'
            return
        if getattr(local_entity, 'deadInGame', False):
            _esp_state = 3 if _esp else 0
            _aim_state = 3 if _aim else 0
            _waiting = 'Local character dead'
            return
        if entity_id is None:
            entity_id = getattr(local_entity, 'id', None)
        owner = (id(player), entity_id)
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
                xyz = _xyz(point)
                direction = tuple(a - b for a, b in zip(xyz, origin))
                angle = _angle_between(direction, forward)
                distance2 = sum(n * n for n in direction)
                projected = _screen_point(camera, point, resolution, origin, forward)
                x = projected[0] if projected is not None else -1.0
                y = projected[1] if projected is not None else -1.0
                entity = go.entity
                is_inv = getattr(entity, 'invincible', False)
                if callable(is_inv):
                    try:
                        is_inv = is_inv()
                    except Exception:
                        is_inv = False
                is_inv = bool(is_inv) if isinstance(is_inv, (bool, int)) else False
                candidates.append((angle, entity.id, x, y, point, direction,
                                   go, distance2, is_inv, projected is not None))
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
                    can_shoot = bool(c[1] == _target_id)
                    if not can_shoot and (c[0] <= 12.0 or i == 0):
                        try:
                            can_shoot = bool(_visible(Physics, RaycastHit, camera_position, point))
                        except Exception:
                            can_shoot = False

                    # Safe perspective bounding box calculation
                    box_h = max(0.016, min(0.85, 2.0 / (dist_val + 0.5)))
                    box_w = box_h * 0.48
                    box_x = max(0.0, min(1.0 - box_w, c[2] - box_w * 0.5))
                    box_y = max(0.0, min(1.0 - box_h, c[3] - box_h * 0.45))

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
                # Safely probe fire button without aborting if userInput component is not ready
                _fire_held = False
                try:
                    input_go = getattr(Globals, 'userInput', None)
                    if input_go is not None:
                        get_component = getattr(input_go, 'GetComponent', None)
                        if callable(get_component):
                            input_component = get_component('InputInterpred')
                            if input_component is not None and hasattr(input_component, '_isFireBtnDwn'):
                                _fire_held = bool(input_component._isFireBtnDwn)
                except Exception:
                    _fire_held = False

                # Aim Smooth auto-aims only when player is holding a firearm (gun)!
                # If user has no gun (bare hands / fists / melee / throwables / running unholstered), do not aimsmooth.
                using_gun = _is_using_gun(player, local_entity)
                should_aim = (_aim_smooth and using_gun) or (_aim and _fire_held)
                if not should_aim:
                    _target_id = None
                else:
                    control = camera.GetComponent('PlayerCameraController')
                    # CPlayerCameraController._onRotateCamera is an empty routine;
                    # fail explicitly rather than claiming a lock on that backend.
                    if (control is None or not callable(getattr(control, 'onRotateCamera', None))
                            or getattr(control, 'controller', None) is not None):
                        raise Waiting('Unsupported live camera controller')
                    # Prioritize closest enemy to player character (20m before 100m)
                    pool = [c for c in candidates if c[0] <= _capture_degrees and not c[8]]
                    # When shooting, retain locked target so sprays remain consistent on the target
                    if _fire_held and _clear_previous_target is not None:
                        retained = [c for c in pool if c[1] == _clear_previous_target]
                        if retained:
                            pool = retained + [c for c in pool if c[1] != _clear_previous_target]

                    # Immediate lock: Pass 1 finds closest visible enemy via direct physics raycast
                    selected = None
                    for candidate in pool[:10]:
                        if _visible(Physics, RaycastHit, camera_position, candidate[4]):
                            selected = candidate
                            break
                    # Pass 2: if direct raycast fails (e.g. grass, leaves, fence, window), lock onto closest enemy on screen
                    if selected is None:
                        for candidate in pool[:8]:
                            if candidate[9] or candidate[0] <= 80.0:
                                selected = candidate
                                break
                    # Pass 3: fallback to closest pool enemy
                    if selected is None and pool:
                        selected = pool[0]

                    if selected is not None:
                        # Check player validity before the camera request.
                        latest_player = getattr(Globals, 'player', None)
                        if latest_player is None or latest_player is not player or getattr(latest_player, 'entity', None) is None:
                            raise Waiting('Local character changed')
                        is_inv = getattr(selected[6].entity, 'invincible', False)
                        if callable(is_inv):
                            try:
                                is_inv = is_inv()
                            except Exception:
                                is_inv = False
                        is_inv = bool(is_inv) if isinstance(is_inv, (bool, int)) else False
                        if not _enemy(selected[6], player, service) or is_inv:
                            selected = None
                            _target_id = None
                        else:
                            yaw, pitch = _angle_offset(selected[5], forward)
                            if _aim_smooth and using_gun and not _fire_held:
                                # 100% Auto Aim Smooth: quick, smooth lock and steady tracking onto target
                                factor = 0.65
                                max_step_yaw = 36.0
                                max_step_pitch = 24.0
                                smooth_yaw = max(-max_step_yaw, min(max_step_yaw, yaw * factor))
                                smooth_pitch = max(-max_step_pitch, min(max_step_pitch, pitch * factor))
                                if abs(yaw) <= 1.8:
                                    smooth_yaw = yaw
                                if abs(pitch) <= 1.4:
                                    smooth_pitch = pitch
                                _last_angles = (smooth_yaw, smooth_pitch)
                                control.onRotateCamera(Vector2(smooth_yaw, smooth_pitch), True)
                            elif _aim_smooth and using_gun and _fire_held:
                                # High-speed responsive lock when shooting
                                factor = 0.85
                                max_step_yaw = 48.0
                                max_step_pitch = 32.0
                                smooth_yaw = max(-max_step_yaw, min(max_step_yaw, yaw * factor))
                                smooth_pitch = max(-max_step_pitch, min(max_step_pitch, pitch * factor))
                                if abs(yaw) <= 2.5:
                                    smooth_yaw = yaw
                                if abs(pitch) <= 1.8:
                                    smooth_pitch = pitch
                                _last_angles = (smooth_yaw, smooth_pitch)
                                control.onRotateCamera(Vector2(smooth_yaw, smooth_pitch), True)
                            else:
                                # Instant lock when Aimbot 360 Lock is used alone
                                _last_angles = (yaw, pitch)
                                control.onRotateCamera(Vector2(yaw, pitch), True)
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
