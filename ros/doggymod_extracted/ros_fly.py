# Python 2.7 / ROS Legacy 1.610637.617289, owner-authorised test build.
# Run inside the existing interpreter. Physics writes run on engine callbacks.
import sys
import time
import weakref
Globals = sys.modules.get('Globals')
_movement = sys.modules.get('helpers.move_unit')
if Globals is None or _movement is None:
    raise RuntimeError('The cached gameplay modules are not ready')
MoveUnit = getattr(_movement, 'MoveUnit', None)
if MoveUnit is None:
    raise RuntimeError('The cached movement module has no MoveUnit')


def _resolve_game_timer():
    # The game loader can cache dotted modules without importable parents.
    # Reuse existing gameplay bindings; do not create packages or import files.
    candidates = (
        getattr(_movement, 'Timer', None),
        sys.modules.get('common.Timer'),
        getattr(sys.modules.get('common'), 'Timer', None),
        getattr(Globals, 'Timer', None),
    )
    for candidate in candidates:
        if (callable(getattr(candidate, 'addRepeatTimer', None)) and
                callable(getattr(candidate, 'delTimer', None))):
            return candidate
    names = sorted(name for name in sys.modules if 'timer' in name.lower())
    summary = ', '.join(names[:24]) or '(none)'
    raise RuntimeError('No existing game Timer with addRepeatTimer/delTimer. '
                       'Loaded timer modules: ' + summary)


Timer = _resolve_game_timer()

BUILD = 'ROS-FLY-TEST-10'
_enabled = False
_vertical = 0
_speed = 300.0  # Responsive vertical flight speed
_horizontal_multiplier = 1.0
_horizontal_limit = 120.0
_walk_api_scale = 60.0
_sample_time_limit = 0.75
_timer = None
_record = None
_walk_record = None
_observed_position = None
_horizontal_samples = 0
_horizontal_moves = 0
_state = 0
_last_tick = 0.0
_last_error = ''


def _new_stats():
    return dict(ticks=0, gap_skips=0, relocation_skips=0, idle=0,
                last_gap=0.0, max_gap=0.0, last_step=0.0,
                last_speed=0.0, estimated_speed=0.0, last_boost_speed=0.0,
                fresh=0, reused=0, walk_speed=0.0, observed_speed=0.0,
                last_moving_speed=0.0)


_stats = _new_stats()


def _restore():
    global _record, _observed_position
    _observed_position = None
    walk_error = None
    try:
        _restore_walk()
    except Exception as error:
        walk_error = error
    saved = _record
    _record = None
    unit = saved[0]() if saved is not None else None
    character = getattr(unit, 'character', None) if unit is not None else None
    if (character is not None and id(character) == saved[1] and
            character.bindingEntityID == saved[3]):
        try:
            character.verticalVelocity = 0.0
        finally:
            character.setGravity(saved[2])
    if walk_error is not None:
        raise walk_error


def _position(character):
    vector = character.position
    values = (float(vector.x), float(vector.y), float(vector.z))
    if not all(value == value and -1000000.0 <= value <= 1000000.0 for value in values):
        raise ValueError('Invalid native character position')
    return values


def _movement_eligible(unit):
    return (getattr(unit, '_active', False) and
            getattr(unit, 'chInScene', False) and
            not getattr(unit, 'inVehicle', False) and
            not getattr(unit, '_useParachute', False) and
            not getattr(unit, '_observer', False))


def _walk_velocity(character):
    vector = character.getWalkDirection()
    values = (float(vector.x), float(vector.y), float(vector.z))
    if not all(value == value and -1000000.0 <= value <= 1000000.0 for value in values):
        raise ValueError('Invalid native walk velocity')
    return values


def _same_velocity(left, right):
    return all(abs(a - b) <= 0.0001 * (1.0 + max(abs(a), abs(b)))
               for a, b in zip(left, right))


def _write_walk_velocity(character, velocity):
    # Native setter multiplies by 60; physics consumes the stored velocity * dt.
    character.setWalkDirection(tuple(value / _walk_api_scale for value in velocity))


def _restore_walk():
    global _walk_record
    saved = _walk_record
    _walk_record = None
    unit = saved[0]() if saved is not None else None
    character = getattr(unit, 'character', None) if unit is not None else None
    if (character is not None and id(character) == saved[1] and
            character.bindingEntityID == saved[2] and unit.gameObject.entity.id == saved[2]):
        # Preserve a newer gameplay command; restore only our own velocity.
        if _same_velocity(_walk_velocity(character), saved[4]):
            _write_walk_velocity(character, saved[3])


def _boost_horizontal(unit, character, entity_id, now):
    global _walk_record, _observed_position, _horizontal_samples
    _horizontal_samples += 1
    try:
        current_position = _position(character)
        previous = _observed_position
        _observed_position = (id(character), entity_id, current_position, now)
        if previous is not None and previous[:2] == (id(character), entity_id):
            elapsed = now - previous[3]
            if elapsed > 0.000001:
                _stats['last_gap'] = elapsed
                dx = current_position[0] - previous[2][0]
                dz = current_position[2] - previous[2][2]
                step = (dx * dx + dz * dz) ** 0.5
                _stats['last_step'] = step
                _stats['observed_speed'] = step / elapsed
        vel = _walk_velocity(character)
        magnitude = (vel[0] * vel[0] + vel[2] * vel[2]) ** 0.5
        _stats['walk_speed'] = magnitude
        _stats['estimated_speed'] = magnitude
    except Exception:
        pass


def _stop_timer():
    global _timer
    timer = _timer
    _timer = None
    if timer is not None:
        Timer.delTimer(timer)


def _ensure_timer():
    global _timer, _last_tick
    if _timer is None:
        _timer = Timer.addRepeatTimer(0.01667, _tick)
        _last_tick = time.time()


def set_enabled(value):
    global _enabled, _vertical, _state, _observed_position, _stats
    global _horizontal_samples, _horizontal_moves
    _enabled = bool(value)
    _vertical = 0
    if _enabled:
        _state = 2
        _observed_position = None
        _stats = _new_stats()
        _horizontal_samples = _horizontal_moves = 0
    _ensure_timer()


def toggle():
    set_enabled(not _enabled)


def lift(direction):
    global _vertical
    _vertical = max(-1, min(1, int(direction))) if _enabled else 0


def _note_error(error):
    global _enabled, _vertical, _state, _last_error
    _last_error = '%s: %s' % (type(error).__name__, error)
    _enabled = False
    _vertical = 0
    _state = 4
    print('[ROS Fly] stopped: %s' % _last_error)


def handle(action, argument=0):
    # UI requests only change intent or schedule work; no character writes here.
    try:
        if action == 'toggle':
            toggle()
        elif action == 'lift':
            lift(argument)
        elif action == 'off':
            set_enabled(False)
        else:
            raise ValueError('Unknown Fly request')
        return True
    except Exception as error:
        _note_error(error)
        # An existing engine callback can still restore gravity after this error.
        return False


def set_speed(value):
    global _speed
    value = float(value)
    if not (0.5 <= value <= 2000.0):
        raise ValueError('Fly speed must be between 0.5 and 2000 game units/second')
    _speed = value


def _target():
    player = getattr(Globals, 'player', None)
    if player is None:
        return None
    unit = player.GetComponent('MoveUnit')
    if unit is None:
        return None
    entity = getattr(player, 'entity', None)
    character = getattr(unit, 'character', None)
    if entity is None or character is None:
        return None
    # The component and native character must agree about entity ownership.
    if unit.gameObject.entity.id != entity.id or character.bindingEntityID != entity.id:
        return None
    return unit, character, entity.id


def _tick():
    global _enabled, _vertical, _record, _state, _last_tick, _last_error
    _last_tick = time.time()
    _stats['ticks'] += 1
    try:
        if not _enabled:
            _restore()
            if _state != 4:
                _state = 0
            _stop_timer()
            return
        target = _target()
        if target is None:
            was_flying = _record is not None
            _restore()
            _vertical = 0
            if was_flying:
                _enabled = False
                _state = 0
                _stop_timer()
            else:
                _state = 2
            return
        unit, character, entity_id = target
        if _record is not None and (_record[0]() is not unit or
                _record[1] != id(character) or _record[3] != entity_id):
            _restore()
            _enabled = False
            _vertical = 0
            _state = 0
            _stop_timer()
            return
        if not _movement_eligible(unit):
            _vertical = 0
            _state = 3
            return
        if _record is None:
            _record = (weakref.ref(unit), id(character), character.getGravity(), entity_id)
        character.setGravity(0.0)
        character.verticalVelocity = _vertical * _speed
        _state = 1
        _boost_horizontal(unit, character, entity_id, _last_tick)
    except Exception as error:
        _note_error(error)
        try:
            _restore()
        except Exception:
            pass
        try:
            _stop_timer()
        except Exception:
            pass


def _before_character_removed(unit):
    global _enabled, _vertical, _state, _last_error
    if _record is not None and _record[0]() is unit:
        try:
            _restore()
            _state = 0
        except Exception as error:
            _last_error = '%s: %s' % (type(error).__name__, error)
            _state = 4
            print('[ROS Fly] restore failed during character removal: %s' % _last_error)
        finally:
            _enabled = False
            _vertical = 0


def _install_lifecycle_hooks():
    # Only hook OnDestroy when the character unit is actually destroyed
    if getattr(MoveUnit, '_ros_fly_lifecycle_installed', False):
        return
    original_destroy = MoveUnit.OnDestroy

    def destroy(unit, *args, **kwargs):
        _before_character_removed(unit)
        return original_destroy(unit, *args, **kwargs)

    MoveUnit.OnDestroy = destroy
    MoveUnit._ros_fly_lifecycle_installed = True


def status():
    # A scene transition may clear the engine's timer registry.
    if _enabled and _timer is not None and time.time() - _last_tick > 2.0:
        try:
            _stop_timer()
        except Exception:
            pass
        try:
            _ensure_timer()
        except Exception as error:
            _note_error(error)
    return int(_state)


def diagnostics():
    # Read-only text for the INFO alert; no physics writes or timer changes.
    return ('Build 10 / state %d\n'
            'Timer ticks: %d\n'
            'Vertical speed: %.1f units/s\n'
            'Walk speed: %.1f units/s\n'
            'Mode: Smooth 60 FPS Native Run\n'
            'Error: %s' % (_state, _stats['ticks'],
            _speed, _stats.get('walk_speed', 0.0),
            _last_error or '(none)'))



if not hasattr(Timer, 'addRepeatTimer') or not hasattr(Timer, 'delTimer'):
    raise RuntimeError('The client timer interface is not available')
_install_lifecycle_hooks()
_ready = True
print('[ROS Fly] %s ready; disabled by default' % BUILD)
