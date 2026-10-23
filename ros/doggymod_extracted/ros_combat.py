# Python 2.7, exact supplied ROS Legacy test build. Disabled by default.
# Game API reads and camera requests run on the existing engine Timer.
import sys
import time
import math
import os

BUILD = 'ROS-COMBAT-TEST-10'

def _io_dirs():
    # Directories where the menu (ObjC) and this script can exchange files.
    # __file__ sits next to the menu's Documents copy, so it is the most
    # reliable common location; the rest are fallbacks.
    dirs = []
    try:
        f = globals().get('__file__')
        if f:
            dirs.append(os.path.dirname(os.path.abspath(f)))
    except Exception:
        pass
    home = os.environ.get('HOME')
    if home:
        dirs.append(os.path.join(home, 'Documents'))
    dirs.append('/tmp')
    dirs.append('/var/mobile/Documents')
    seen = set()
    out = []
    for d in dirs:
        if d and d not in seen:
            seen.add(d)
            out.append(d)
    return out


_esp_path = None
_last_esp_write = 0.0
_last_esp_payload = None
_ESP_WRITE_INTERVAL = 0.033


def _pick_esp_path():
    global _esp_path
    if _esp_path:
        return _esp_path
    for d in _io_dirs():
        p = os.path.join(d, 'ros_esp.dat')
        tmp = p + '.tmp'
        try:
            with open(tmp, 'w') as f:
                f.write('')
            os.rename(tmp, p)
            _esp_path = p
            return p
        except Exception:
            try:
                os.unlink(tmp)
            except Exception:
                pass
    return None


def _write_esp_file(content, force=False):
    # Crash-safe file IPC to the menu overlay. Writes to a single cached file
    # (renamed atomically) and is throttled so the 30 Hz engine tick does not
    # hammer the filesystem. The menu polls at 10 Hz, so ~12 Hz is plenty.
    global _last_esp_write, _last_esp_payload
    payload = content if content else 'NONE'
    now = time.time()
    if payload == 'NONE':
        if _last_esp_payload == 'NONE':
            return
    elif not force and (now - _last_esp_write) < _ESP_WRITE_INTERVAL:
        return
    path = _pick_esp_path()
    if not path:
        return
    tmp = path + '.tmp'
    try:
        with open(tmp, 'w') as f:
            f.write(payload)
        os.rename(tmp, path)
        _last_esp_write = now
        _last_esp_payload = payload
    except Exception:
        try:
            os.unlink(tmp)
        except Exception:
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
_autoscope = False
_autoscope_zoom = 35.0
_autoscope_applied = False
_autoscope_native_fov = None
_autoscope_until = 0.0
_autoscope_fire_prev = False
_bulletlock = False
_bulletlock_until = 0.0
_bulletlock_fire_prev = False
_bulletlock_target = None
_bulletlock_degrees = 45.0
_bulletlock_hold = 0.45
_esp_state = 0
_aim_state = 0
_timer = None
_esp_timer = None
_lock_timer = None
_lock_cache = []
_lock_camera = None
_lock_physics = None
_lock_raycast = None
_lock_player = None
_lock_service = None
_lock_vector2 = None
_last_tick = 0.0
_owner = None
_target_id = None
_frame = ()
_rich_esp_frame = ()
_last_esp_str = 'NONE'
_last_esp_build = 0.0
_ESP_INTERVAL = 0.033
_esp_cache = []
_esp_camera = None
_esp_resolution = (0.0, 0.0)
_name_cache = {}
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
_weapon_debug = ''


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


def _manual_screen_point(camera, point, resolution, origin, forward):
    # Camera-basis projection used when the engine camera lacks a working
    # WorldToScreenPoint. Assumes a standard Y-up view.
    try:
        xyz = _xyz(point)
        dx, dy, dz = xyz[0] - origin[0], xyz[1] - origin[1], xyz[2] - origin[2]
        fx, fy, fz = forward
        fl = math.sqrt(fx * fx + fy * fy + fz * fz)
        if fl < 0.000001:
            return None
        fx, fy, fz = fx / fl, fy / fl, fz / fl
        # right = forward x up(0,1,0)
        rx, ry, rz = -fz, 0.0, fx
        rl = math.sqrt(rx * rx + ry * ry + rz * rz)
        if rl < 0.000001:
            return None
        rx, ry, rz = rx / rl, ry / rl, rz / rl
        # up = right x forward
        ux = ry * fz - rz * fy
        uy = rz * fx - rx * fz
        uz = rx * fy - ry * fx
        view_x = dx * rx + dy * ry + dz * rz
        view_y = dx * ux + dy * uy + dz * uz
        view_z = dx * fx + dy * fy + dz * fz
        if view_z <= 0.001:
            return None
        fov_y = 60.0
        try:
            fov_attr = getattr(camera, 'fieldOfView', None)
            if fov_attr is not None:
                fov_y = float(fov_attr)
        except Exception:
            fov_y = 60.0
        if fov_y < 5.0 or fov_y > 170.0:
            fov_y = 60.0
        res_w, res_h = float(resolution[0]), float(resolution[1])
        if res_w <= 1.0 or res_h <= 1.0:
            return None
        aspect = res_w / res_h
        tan_y = math.tan(math.radians(fov_y) * 0.5)
        tan_x = tan_y * aspect
        if tan_x < 0.000001 or tan_y < 0.000001:
            return None
        x = 0.5 + (view_x / view_z) / (2.0 * tan_x)
        y = 0.5 - (view_y / view_z) / (2.0 * tan_y)
        if not (-0.5 <= x <= 1.5 and -0.5 <= y <= 1.5):
            return None
        direction = (dx, dy, dz)
        return x, y, direction
    except Exception:
        return None


def _screen_point(camera, point, resolution, origin, forward):
    direction = None
    try:
        xyz = _xyz(point)
        direction = tuple(a - b for a, b in zip(xyz, origin))
    except Exception:
        direction = None
    try:
        projected = camera.WorldToScreenPoint(point)
        if projected is not None:
            pz = getattr(projected, 'z', None)
            if pz is None or float(pz) > 0.05:
                px = getattr(projected, 'x', None)
                py = getattr(projected, 'y', None)
                if px is not None and py is not None:
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
                    if -0.5 <= x <= 1.5 and -0.5 <= y <= 1.5:
                        if direction is None:
                            xyz = _xyz(point)
                            direction = tuple(a - b for a, b in zip(xyz, origin))
                        if sum(a * b for a, b in zip(direction, forward)) > 0.00001:
                            return x, y, direction
    except Exception:
        pass
    # Try viewport projection (0..1 already) before falling back to manual math.
    try:
        vp = camera.WorldToViewportPoint(point)
        if vp is not None:
            vz = getattr(vp, 'z', None)
            vx = getattr(vp, 'x', None)
            vy = getattr(vp, 'y', None)
            if (vz is None or float(vz) > 0.05) and vx is not None and vy is not None:
                x = _finite(vx)
                y = 1.0 - _finite(vy)  # viewport origin is bottom-left
                if -0.5 <= x <= 1.5 and -0.5 <= y <= 1.5:
                    if direction is None:
                        xyz = _xyz(point)
                        direction = tuple(a - b for a, b in zip(xyz, origin))
                    if sum(a * b for a, b in zip(direction, forward)) > 0.00001:
                        return x, y, direction
    except Exception:
        pass
    return _manual_screen_point(camera, point, resolution, origin, forward)


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
    global _bulletlock_until, _bulletlock_fire_prev, _bulletlock_target
    global _lock_cache, _lock_camera
    _frame = ()
    _rich_esp_frame = ()
    _last_esp_str = 'NONE'
    _frame_time = 0.0
    _target_id = None
    _fire_held = False
    _bulletlock_until = 0.0
    _bulletlock_fire_prev = False
    _bulletlock_target = None
    _lock_cache = []
    _lock_camera = None
    _write_esp_file('')


_scene_fingerprint = None
_scene_change_time = 0.0

_auto_fire_tick = 0

def _trigger_auto_shoot(player, local_entity):
    global _auto_fire_tick
    _auto_fire_tick += 1
    try:
        input_go = getattr(Globals, 'userInput', None)
        if input_go is not None and hasattr(input_go, 'GetComponent'):
            ic = input_go.GetComponent('InputInterpred')
            if ic is not None:
                fire_state = True if (_auto_fire_tick % 3 != 0) else False
                if hasattr(ic, '_isFireBtnDwn'):
                    try:
                        ic._isFireBtnDwn = fire_state
                    except Exception:
                        pass
                for m_name in ('onFireBtnDown', 'OnFireBtnDown', 'onFire', 'fire'):
                    fn = getattr(ic, m_name, None)
                    if callable(fn):
                        try:
                            fn(fire_state)
                        except Exception:
                            try:
                                if fire_state: fn()
                            except Exception:
                                pass
                        break
    except Exception:
        pass


def _release_auto_shoot():
    try:
        input_go = getattr(Globals, 'userInput', None)
        if input_go is not None and hasattr(input_go, 'GetComponent'):
            ic = input_go.GetComponent('InputInterpred')
            if ic is not None:
                if hasattr(ic, '_isFireBtnDwn'):
                    try:
                        if getattr(ic, '_isFireBtnDwn', False):
                            ic._isFireBtnDwn = False
                    except Exception:
                        pass
                for m_name in ('onFireBtnUp', 'OnFireBtnUp', 'onFireRelease', 'releaseFire'):
                    fn = getattr(ic, m_name, None)
                    if callable(fn):
                        try:
                            fn()
                        except Exception:
                            pass
                        break
    except Exception:
        pass


_last_cfg_sync = 0.0

def _sync_config():
    global _aim, _aim_smooth, _aim_state, _last_cfg_sync, _autoscope, _autoscope_zoom
    global _esp, _esp_state, _bulletlock
    now = time.time()
    if now - _last_cfg_sync < 0.10:
        return
    _last_cfg_sync = now
    txt = None
    for d in _io_dirs():
        p = os.path.join(d, 'ros_combat.cfg')
        if os.path.exists(p):
            try:
                with open(p, 'r') as f:
                    txt = f.read()
                break
            except Exception:
                txt = None
    if txt is not None:
        try:
            if 'aim=' in txt:
                _aim = ('aim=1' in txt)
            if 'aimsmooth=' in txt:
                _aim_smooth = ('aimsmooth=1' in txt)
            if 'autoscope=' in txt:
                _autoscope = ('autoscope=1' in txt)
            if 'esp=' in txt:
                _esp = ('esp=1' in txt)
            if 'bulletlock=' in txt:
                _bulletlock = ('bulletlock=1' in txt)
            for line in txt.splitlines():
                if line.startswith('autoscope_range='):
                    try:
                        _autoscope_zoom = float(line.split('=', 1)[1].strip())
                    except Exception:
                        pass
        except Exception:
            pass
        _aim_state = 1 if (_aim or _aim_smooth) else 0
        _esp_state = 1 if _esp else 0
        if _esp or _aim or _aim_smooth or _autoscope or _bulletlock:
            _ensure_timer()
        return


def _ensure_timer():
    global _timer, _esp_timer, _lock_timer, _last_tick, Timer
    if Timer is None:
        Timer = _resolve_game_timer()
    if _timer is None and Timer is not None:
        try:
            _timer = Timer.addRepeatTimer(0.03333, _tick)
            _last_tick = time.time()
        except Exception:
            pass
    if _esp_timer is None and Timer is not None:
        try:
            # Lightweight ESP reprojection at 60 Hz (reuses the 30 Hz scan).
            _esp_timer = Timer.addRepeatTimer(0.01667, _esp_fast_tick)
        except Exception:
            pass
    if _lock_timer is None and Timer is not None:
        try:
            # Bullet Lock checks the fire button at 60 Hz so quick taps are caught.
            _lock_timer = Timer.addRepeatTimer(0.01667, _bulletlock_fast_tick)
        except Exception:
            pass


def _stop_timer():
    global _timer, _esp_timer, _lock_timer
    timer = _timer
    _timer = None
    if timer is not None:
        try:
            Timer.delTimer(timer)
        except Exception:
            pass
    esp_timer = _esp_timer
    _esp_timer = None
    if esp_timer is not None:
        try:
            Timer.delTimer(esp_timer)
        except Exception:
            pass
    lock_timer = _lock_timer
    _lock_timer = None
    if lock_timer is not None:
        try:
            Timer.delTimer(lock_timer)
        except Exception:
            pass


def _fire_signal(input_component):
    # Returns True if a shot/fire appears active. Covers short taps that may
    # set a transient flag between ticks.
    try:
        if bool(getattr(input_component, '_isFireBtnDwn', False)):
            return True
    except Exception:
        pass
    for attr in ('_isFireBtn', '_fireBtnDwn', '_isFiring', '_isShoot', 'isFire', 'isShoot'):
        try:
            if getattr(input_component, attr, False):
                return True
        except Exception:
            pass
    return False


def _find_camera_controller(camera):
    try:
        get_component = getattr(camera, 'GetComponent', None)
        if callable(get_component):
            for name in ('PlayerCameraController', 'CameraController', 'PlayerCamera'):
                try:
                    control = get_component(name)
                except Exception:
                    control = None
                if control is not None:
                    return control
    except Exception:
        pass
    return None


def _set_camera_fov(camera, controller, value):
    # Best-effort FOV/zoom. Tries Unity Camera.fieldOfView first, then common
    # controller fields. Every attempt is guarded so a missing API never raises.
    try:
        if camera is not None and hasattr(camera, 'fieldOfView'):
            camera.fieldOfView = float(value)
            return True
    except Exception:
        pass
    if controller is None:
        return False
    for attr in ('fieldOfView', '_fieldOfView', 'fov', '_fov', 'Fov', 'defaultFov', 'currentFov'):
        try:
            if hasattr(controller, attr):
                setattr(controller, attr, float(value))
                return True
        except Exception:
            pass
    for attr in ('SetFov', 'SetFOV', 'setFov', 'SetFieldOfView'):
        fn = getattr(controller, attr, None)
        if callable(fn):
            try:
                fn(float(value))
                return True
            except Exception:
                pass
    return False


def _restore_native_fov(camera, controller):
    global _autoscope_native_fov
    if _autoscope_native_fov is not None:
        _set_camera_fov(camera, controller, _autoscope_native_fov)


def _apply_autoscope(camera, controller, engage):
    global _autoscope_applied, _autoscope_native_fov
    try:
        if engage:
            if not _autoscope_applied:
                if camera is not None and hasattr(camera, 'fieldOfView'):
                    try:
                        _autoscope_native_fov = float(camera.fieldOfView)
                    except Exception:
                        _autoscope_native_fov = None
                _autoscope_applied = _set_camera_fov(camera, controller, _autoscope_zoom)
        else:
            if _autoscope_applied:
                _restore_native_fov(camera, controller)
            _autoscope_applied = False
    except Exception:
        _autoscope_applied = False


def handle(action):
    global _esp, _aim, _aim_smooth, _esp_state, _aim_state, _last_error, _target_id
    global _autoscope, _autoscope_zoom, _bulletlock, _bulletlock_fire_prev, _bulletlock_target
    try:
        if action == 'esp':
            _esp = not _esp
            _esp_state = 1 if _esp else 0
            if not _esp:
                _write_esp_file('')
        elif action == 'aim':
            _aim = not _aim
            _aim_state = 1 if _aim else 0
            _target_id = None
            if not _aim and not _aim_smooth and not _esp and not _bulletlock:
                _clear_frame()
        elif action == 'aim_smooth':
            _aim_smooth = not _aim_smooth
            if not _aim and not _aim_smooth and not _esp and not _bulletlock:
                _clear_frame()
        elif action == 'autoscope':
            _autoscope = not _autoscope
        elif action == 'bulletlock':
            _bulletlock = not _bulletlock
            _bulletlock_fire_prev = False
            _bulletlock_target = None
        elif action == 'off':
            # Do NOT reset _aim, _aim_smooth, or _esp on background tap / menu close!
            pass
        else:
            raise ValueError('Unknown combat request')
        _last_error = ''
        if _esp or _aim or _aim_smooth or _autoscope or _bulletlock:
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
        _esp = bool(val)
        _esp_state = 1 if _esp else 0
        if _esp:
            _ensure_timer()
        else:
            _write_esp_file('')
        return True
    except Exception as error:
        _last_error = '%s: %s' % (type(error).__name__, error)
        return False



def set_aim_smooth(val):
    global _aim_smooth, _last_error
    try:
        _aim_smooth = bool(val)
        if _aim_smooth or _esp or _aim or _autoscope:
            _ensure_timer()
        else:
            _stop_timer()
            _clear_frame()
        return _aim_smooth
    except Exception as error:
        _last_error = '%s: %s' % (type(error).__name__, error)
        return False


def set_autoscope(val):
    global _autoscope, _last_error
    try:
        _autoscope = bool(val)
        if _autoscope:
            _ensure_timer()
        elif not (_esp or _aim or _aim_smooth or _bulletlock):
            _stop_timer()
            _clear_frame()
        return _autoscope
    except Exception as error:
        _last_error = '%s: %s' % (type(error).__name__, error)
        return False


def set_bulletlock(val):
    global _bulletlock, _last_error, _bulletlock_fire_prev, _bulletlock_target
    try:
        _bulletlock = bool(val)
        _bulletlock_fire_prev = False
        _bulletlock_target = None
        if _bulletlock:
            _ensure_timer()
        elif not (_esp or _aim or _aim_smooth or _autoscope):
            _stop_timer()
            _clear_frame()
        return _bulletlock
    except Exception as error:
        _last_error = '%s: %s' % (type(error).__name__, error)
        return False


def _tick():
    global _last_tick, _owner, _target_id, _frame, _rich_esp_frame, _frame_time
    global _esp_state, _aim_state, _last_error, _last_skip, _waiting, _ticks, _scanned, _skipped
    global _fire_held, _aim_writes, _last_angles, _esp, _aim, _aim_smooth, _last_esp_str, _last_esp_build
    global _esp_cache, _esp_camera, _esp_resolution
    global _scene_fingerprint, _scene_change_time, _is_gun_held, _autoscope
    global _autoscope_until, _autoscope_fire_prev, _bulletlock
    global _bulletlock_until, _bulletlock_fire_prev, _bulletlock_target
    global _lock_cache, _lock_camera, _lock_physics, _lock_raycast, _lock_player, _lock_service, _lock_vector2
    now = time.time()
    previous_tick = _last_tick
    _last_tick = now
    _ticks += 1
    try:
        _sync_config()
        if not (_esp or _aim or _aim_smooth or _autoscope or _bulletlock):
            _clear_frame()
            _release_auto_shoot()
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
            _name_cache.clear()
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
        if _bulletlock:
            _lock_cache = [c for c in candidates[:_max_lines] if not c[8] and not c[10]]
            _lock_camera = camera
            _lock_physics = Physics
            _lock_raycast = RaycastHit
            _lock_player = player
            _lock_service = service
            _lock_vector2 = Vector2
        else:
            _lock_cache = []
        _esp_state = 1 if _esp else 0
        _aim_state = 1 if (_aim or _aim_smooth) else 0
        _waiting = ''
        if _esp:
            # The full enemy scan is expensive → keep it at 30 Hz and hand the
            # candidate list (with world positions) to the 60 Hz reprojection
            # pass so ESP tracks the camera without waiting for the next scan.
            _esp_cache = [(c[1], c[4], c[8], c[10], c[6]) for c in candidates[:_max_lines] if c[4] is not None]
            _esp_camera = camera
            _esp_resolution = resolution
        else:
            _esp_cache = []
            _esp_camera = None
            _rich_esp_frame = ()
            _last_esp_str = 'NONE'
            _frame = ()
            _write_esp_file('')
        _frame_time = now

        # Auto Scope: zoom the camera in on close-range fire, restore otherwise.
        if _autoscope:
            try:
                fire_now = False
                input_go = getattr(Globals, 'userInput', None)
                input_component = None
                if input_go is not None and hasattr(input_go, 'GetComponent'):
                    input_component = input_go.GetComponent('InputInterpred')
                if input_component is not None:
                    fire_now = _fire_signal(input_component)
                # Latch on a fire edge (covers short taps), and hold briefly so a
                # brief click still visibly scopes in.
                if fire_now and not _autoscope_fire_prev:
                    has_close = False
                    for c in candidates:
                        if c[7] <= 5625.0:
                            has_close = True
                            break
                    if has_close:
                        _autoscope_until = now + 0.7
                _autoscope_fire_prev = fire_now
                engaged = fire_now or (now < _autoscope_until)
                controller = _find_camera_controller(camera)
                _apply_autoscope(camera, controller, engaged)
            except Exception as scope_err:
                _last_error = 'AutoScope: %s: %s' % (type(scope_err).__name__, scope_err)
        elif _autoscope_applied:
            _apply_autoscope(camera, _find_camera_controller(camera), False)

        # Bullet Lock: on every shot, redirect the bullet to the enemy closest to
        # the crosshair. Keeps that enemy locked for the whole burst even if the
        # player clicked slightly off-target or on the wrong enemy.
        lock_selected = None
        if _bulletlock:
            input_go = getattr(Globals, 'userInput', None)
            lock_component = None
            if input_go is not None and callable(getattr(input_go, 'GetComponent', None)):
                try:
                    lock_component = input_go.GetComponent('InputInterpred')
                except Exception:
                    lock_component = None
            lock_fire = _fire_signal(lock_component) if lock_component is not None else False
            if lock_fire and not _bulletlock_fire_prev:
                pool = [c for c in candidates if c[0] <= _bulletlock_degrees and not c[8] and not c[10]]
                pool.sort(key=lambda item: (item[0], item[7], item[1]))
                _bulletlock_target = None
                for candidate in pool[:16]:
                    if _visible(Physics, RaycastHit, camera_position, candidate[4]):
                        _bulletlock_target = candidate[1]
                        _bulletlock_until = now + _bulletlock_hold
                        break
            _bulletlock_fire_prev = lock_fire
            if lock_fire or now < _bulletlock_until:
                retained = [c for c in candidates if c[1] == _bulletlock_target
                            and not c[8] and not c[10]]
                if retained:
                    lock_selected = retained[0]
                else:
                    pool = [c for c in candidates if c[0] <= _bulletlock_degrees and not c[8] and not c[10]]
                    pool.sort(key=lambda item: (item[0], item[7], item[1]))
                    for candidate in pool[:16]:
                        if _visible(Physics, RaycastHit, camera_position, candidate[4]):
                            lock_selected = candidate
                            _bulletlock_target = candidate[1]
                            break
            else:
                _bulletlock_target = None
            if lock_selected is not None:
                control = camera.GetComponent('PlayerCameraController')
                if (control is not None and callable(getattr(control, 'onRotateCamera', None))
                        and getattr(control, 'controller', None) is None):
                    latest_player = getattr(Globals, 'player', None)
                    if latest_player is not None and latest_player is player:
                        if (_enemy(lock_selected[6], player, service)
                                and not getattr(lock_selected[6].entity, 'invincible', False)):
                            yaw, pitch = _angle_offset(lock_selected[5], forward)
                            _last_angles = (yaw, pitch)
                            control.onRotateCamera(Vector2(yaw, pitch), True)
                            _aim_writes += 1
                            _target_id = lock_selected[1]
                            if not (_aim or _aim_smooth):
                                _aim_state = 6
                        else:
                            lock_selected = None
                else:
                    lock_selected = None

        selected = lock_selected
        if selected is None and (_aim or _aim_smooth):
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
            # Aim Smooth auto-aims 100% of the time without requiring fire button!
            should_aim = _aim_smooth or _fire_held
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
                retained = [c for c in candidates if c[1] == _clear_previous_target
                            and c[0] <= _retain_degrees and not c[8]]
                if retained:
                    # If another enemy is much closer than the retained target, switch to the closer threat
                    if pool and pool[0][7] < retained[0][7] * 0.5:
                        pass
                    else:
                        pool = retained + [c for c in pool if c[1] != retained[0][1]]
                # Visibility is recomputed while firing/aiming; pick closest visible enemy
                for candidate in pool[:12]:
                    if _visible(Physics, RaycastHit, camera_position, candidate[4]):
                        selected = candidate
                        break
                if selected is not None:
                    # Check player validity before the camera request.
                    latest_player = getattr(Globals, 'player', None)
                    if latest_player is None or latest_player is not player or getattr(latest_player, 'entity', None) is None:
                        raise Waiting('Local character changed')
                    if not _enemy(selected[6], player, service) or getattr(selected[6].entity, 'invincible', False):
                        selected = None
                        _target_id = None
                    else:
                        yaw, pitch = _angle_offset(selected[5], forward)
                        if _aim_smooth and not _fire_held:
                            # 100% Auto Aim Smooth: glide crosshair smoothly towards target without clicking shoot
                            smooth_yaw = max(-14.0, min(14.0, yaw * 0.32))
                            smooth_pitch = max(-9.0, min(9.0, pitch * 0.32))
                            _last_angles = (smooth_yaw, smooth_pitch)
                            control.onRotateCamera(Vector2(smooth_yaw, smooth_pitch), True)
                        elif _aim_smooth and _fire_held:
                            # User clicked shoot: higher tracking response
                            smooth_yaw = max(-24.0, min(24.0, yaw * 0.60))
                            smooth_pitch = max(-16.0, min(16.0, pitch * 0.60))
                            _last_angles = (smooth_yaw, smooth_pitch)
                            control.onRotateCamera(Vector2(smooth_yaw, smooth_pitch), True)
                        else:
                            # Instant lock when Aimbot 360 Lock is used alone
                            _last_angles = (yaw, pitch)
                            control.onRotateCamera(Vector2(yaw, pitch), True)
                        _aim_writes += 1
                        _aim_state = 5
                        _target_id = selected[1]
    except Waiting as error:
        _waiting = str(error)
        _target_id = None
        _release_auto_shoot()
        _aim_state = 2 if (_aim or _aim_smooth) else 0
    except Exception as error:
        _last_error = '%s: %s' % (type(error).__name__, error)
        _target_id = None
        _release_auto_shoot()
        _aim_state = 2 if (_aim or _aim_smooth) else 0
        _esp_state = 2 if _esp else 0


def _esp_fast_tick():
    # 60 Hz ESP reprojection. Reuses the world positions captured by the 30 Hz
    # scan but re-reads the live camera each frame, so boxes/lines stay glued to
    # enemies while the player rotates the view (no trailing during fast turns).
    global _last_esp_str, _rich_esp_frame, _frame, _last_error
    if not _esp:
        return
    cache = _esp_cache
    camera = _esp_camera
    resolution = _esp_resolution
    if not cache or camera is None:
        # No enemies (or no camera): clear once so stale boxes do not linger.
        if _last_esp_str != 'NONE':
            _rich_esp_frame = ()
            _frame = ()
            _last_esp_str = 'NONE'
            _write_esp_file('', force=True)
        return
    try:
        cam_tf = getattr(camera, 'transform', None)
        if cam_tf is None:
            return
        origin = _xyz(cam_tf.position)
        forward = _xyz(cam_tf.forward)
        if resolution[0] <= 1.0 or resolution[1] <= 1.0:
            return
        rich_items = []
        for item in cache:
            eid, point, is_inv, is_downed, go = item
            try:
                xyz = _xyz(point)
                direction = tuple(a - b for a, b in zip(xyz, origin))
                distance2 = sum(n * n for n in direction)
                dist_val = math.sqrt(max(0.0, distance2))
                projected = _screen_point(camera, point, resolution, origin, forward)
                if projected is None:
                    continue
                angle = _angle_between(direction, forward)
                can_shoot = bool(eid == _target_id or angle <= 15.0 or dist_val <= 25.0)

                box_h = max(0.016, min(0.85, 2.0 / (dist_val + 0.5)))
                box_w = box_h * 0.48
                box_x = max(0.0, min(1.0 - box_w, projected[0] - box_w * 0.5))
                box_y = max(0.0, min(1.0 - box_h, projected[1] - box_h * 0.5))

                base_name = _name_cache.get(eid)
                if base_name is None:
                    base_name = _extract_real_name(getattr(go, 'entity', None), go)
                    if not base_name:
                        base_name = 'Player'
                    base_name = base_name.replace(' ', '_').replace(',', '').replace(';', '').replace('|', '')
                    if not base_name:
                        base_name = 'Player'
                    if len(_name_cache) > 512:
                        _name_cache.clear()
                    _name_cache[eid] = base_name
                clean_name = base_name
                if is_downed:
                    clean_name = clean_name + '_[Down]'

                dist_m = int(dist_val + 0.5)
                lx_i = int(projected[0] * 10000.0 + 0.5)
                ly_i = int((box_y + box_h) * 10000.0 + 0.5)
                bx_i = int(box_x * 10000.0 + 0.5)
                by_i = int(box_y * 10000.0 + 0.5)
                bw_i = int(box_w * 10000.0 + 0.5)
                bh_i = int(box_h * 10000.0 + 0.5)
                cs_i = 1 if can_shoot else 0

                rich_items.append((cs_i, lx_i, ly_i, bx_i, by_i, bw_i, bh_i, dist_m, clean_name))
                if len(rich_items) >= _max_lines:
                    break
            except Exception:
                continue

        _rich_esp_frame = tuple(rich_items)
        _last_esp_str = (';'.join('%d,%d,%d,%d,%d,%d,%d,%d,%s' % it for it in rich_items) + ';') if rich_items else 'NONE'
        _frame = tuple((it[1] / 10000.0, it[2] / 10000.0, bool(it[0])) for it in rich_items)
        _write_esp_file(_last_esp_str if _last_esp_str != 'NONE' else '', force=True)
    except Exception as esp_err:
        _last_error = 'ESP fast: %s: %s' % (type(esp_err).__name__, esp_err)


def _bulletlock_fast_tick():
    # 60 Hz shot redirection. Reuses the candidate list from the 30 Hz scan and
    # re-reads the live camera so quick taps still snap the bullet to the enemy
    # nearest the crosshair instead of the enemy the player actually clicked.
    global _bulletlock_until, _bulletlock_fire_prev, _bulletlock_target
    global _target_id, _aim_writes, _last_angles, _last_error
    if not _bulletlock:
        return
    now = time.time()
    input_go = getattr(Globals, 'userInput', None)
    input_component = None
    if input_go is not None and callable(getattr(input_go, 'GetComponent', None)):
        try:
            input_component = input_go.GetComponent('InputInterpred')
        except Exception:
            input_component = None
    fire_now = _fire_signal(input_component) if input_component is not None else False
    if not fire_now and now >= _bulletlock_until:
        _bulletlock_fire_prev = False
        _bulletlock_target = None
        return
    camera = _lock_camera
    candidates = _lock_cache
    if camera is None or not candidates or _lock_vector2 is None:
        return
    try:
        cam_tf = getattr(camera, 'transform', None)
        if cam_tf is None:
            return
        origin = _xyz(cam_tf.position)
        forward = _xyz(cam_tf.forward)

        def _pick(pool):
            pool = sorted([c for c in pool if c[0] <= _bulletlock_degrees],
                          key=lambda item: (item[0], item[7], item[1]))
            for candidate in pool[:16]:
                if _visible(_lock_physics, _lock_raycast, origin, candidate[4]):
                    return candidate
            return None

        if fire_now and not _bulletlock_fire_prev:
            chosen = _pick(candidates)
            if chosen is not None:
                _bulletlock_target = chosen[1]
                _bulletlock_until = now + _bulletlock_hold
        _bulletlock_fire_prev = fire_now

        target = None
        for candidate in candidates:
            if candidate[1] == _bulletlock_target:
                target = candidate
                break
        if target is None:
            target = _pick(candidates)
            _bulletlock_target = target[1] if target is not None else None

        if target is None:
            return
        control = camera.GetComponent('PlayerCameraController')
        if (control is None or not callable(getattr(control, 'onRotateCamera', None))
                or getattr(control, 'controller', None) is not None):
            return
        latest_player = getattr(Globals, 'player', None)
        if latest_player is None or latest_player is not _lock_player:
            return
        if not _enemy(target[6], _lock_player, _lock_service):
            return
        if getattr(target[6].entity, 'invincible', False):
            return
        point = _xyz(target[4])
        direction = tuple(a - b for a, b in zip(point, origin))
        yaw, pitch = _angle_offset(direction, forward)
        _last_angles = (yaw, pitch)
        control.onRotateCamera(_lock_vector2(yaw, pitch), True)
        _aim_writes += 1
        _target_id = target[1]
    except Exception as lock_err:
        _last_error = 'BulletLock: %s: %s' % (type(lock_err).__name__, lock_err)


def snapshot():
    global _esp_state, _aim_state, _last_error
    if (_esp or _aim or _aim_smooth or _bulletlock) and (_timer is None or time.time() - _last_tick > 3.0):
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
try:
    _ensure_timer()
except Exception:
    pass
